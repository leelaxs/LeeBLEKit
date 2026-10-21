import Foundation
@preconcurrency import CoreBluetooth

/// Stop-and-wait protocol with sequence-specific ACK/NACK and complete-message delivery.
public actor ReliableTransport {
    public struct Config: Sendable {
        public let writeCharUUID: CBUUID
        public let notifyCharUUID: CBUUID
        public let mtu: Int
        public let frameProtocol: any FrameProtocol
        public let ackTimeout: TimeInterval
        public let maxRetransmissions: Int
        public let windowSize: Int
        public let maxBufferedMessages: Int
        public let maxBufferedBytes: Int
        public init(writeCharUUID: CBUUID, notifyCharUUID: CBUUID, mtu: Int = 20,
                    frameProtocol: any FrameProtocol = DefaultFrameProtocol(), ackTimeout: TimeInterval = 0.5,
                    maxRetransmissions: Int = 3, windowSize: Int = 1,
                    maxBufferedMessages: Int = 128, maxBufferedBytes: Int = 1_048_576) {
            self.writeCharUUID = writeCharUUID; self.notifyCharUUID = notifyCharUUID
            self.mtu = mtu; self.frameProtocol = frameProtocol; self.ackTimeout = ackTimeout
            self.maxRetransmissions = maxRetransmissions; self.windowSize = windowSize
            self.maxBufferedMessages = maxBufferedMessages; self.maxBufferedBytes = maxBufferedBytes
        }
    }
    private let connection: Connection
    private let config: Config
    private let codec: any ReliableFrameProtocol
    private let writeChar: CBCharacteristic
    private let mtu: Int
    private let capacity: Int
    private let inbox: MessageInbox
    private var nextSeq: UInt16 = 0
    private var expectedSeq: UInt16 = 0
    private var message = Data()
    private var sending = false
    private var terminalError: Error?
    private var ackWaiter: (UInt16, OneShot<Void>)?
    private var notifyTask: Task<Void, Never>?
    // Serialize DATA and ACK writes on the same characteristic.
    private var writing = false
    private var writeSlots: [CheckedContinuation<Void, Never>] = []

    public init(connection: Connection, config: Config) async throws {
        var wc: CBCharacteristic?, nc: CBCharacteristic?
        for service in await connection.services {
            for char in try await connection.discoverCharacteristics(nil, for: service) {
                if char.uuid == config.writeCharUUID { wc = char }
                if char.uuid == config.notifyCharUUID { nc = char }
            }
        }
        guard let wc else { throw LEBLEError.characteristicNotFound(config.writeCharUUID) }
        guard let nc else { throw LEBLEError.characteristicNotFound(config.notifyCharUUID) }
        try await self.init(connection: connection, config: config, writeChar: wc, notifyChar: nc)
    }

    init(connection: Connection, config: Config, writeChar: CBCharacteristic, notifyChar: CBCharacteristic) async throws {
        guard let codec = config.frameProtocol as? any ReliableFrameProtocol else { throw LEBLEError.unsupportedProtocol }
        guard config.windowSize == 1, config.maxRetransmissions >= 0, config.maxRetransmissions <= 1000,
              config.ackTimeout > 0, config.maxBufferedMessages > 0, config.maxBufferedBytes > 0 else { throw LEBLEError.invalidData }
        _ = try timeoutNanoseconds(config.ackTimeout)
        self.connection = connection; self.config = config; self.codec = codec; self.writeChar = writeChar
        self.mtu = min(config.mtu, await connection.maximumWriteLength)
        self.capacity = try codec.maximumPayload(mtu: mtu)
        guard capacity > 0 else { throw LEBLEError.invalidData }
        self.inbox = MessageInbox(maxMessages: config.maxBufferedMessages, maxBytes: config.maxBufferedBytes)
        let stream = try await connection.subscribeReady(notifyChar)
        self.notifyTask = Task { [weak self] in
            for await raw in stream {
                guard !Task.isCancelled else { return }
                await self?.handle(raw)
            }
            await self?.finish(LEBLEError.disconnected(underlying: nil))
        }
    }

    deinit {
        notifyTask?.cancel()
        ackWaiter?.1.resolve(.failure(CancellationError()))
        let inbox = inbox
        Task { await inbox.finish(CancellationError()) }
    }

    public func send(_ payload: Data) async throws {
        try Task.checkCancellation()
        if let terminalError { throw terminalError }
        guard !sending else { throw LEBLEError.operationInProgress }
        guard payload.count <= config.maxBufferedBytes else { throw LEBLEError.bufferOverflow }
        sending = true
        defer { sending = false }
        let data = Data(payload)
        var offset = 0
        do {
            repeat {
                try Task.checkCancellation()
                let end = offset + min(capacity, data.count - offset)
                let frame = ReliableFrame(sequence: nextSeq, kind: end == data.count ? .end : .data,
                                          payload: data.subdata(in: offset..<end))
                let encoded = try codec.encodeFrame(frame, mtu: mtu)
                guard encoded.count <= mtu else { throw LEBLEError.invalidData }
                try await sendFrame(encoded, sequence: nextSeq)
                nextSeq &+= 1; offset = end
            } while offset < data.count
        } catch {
            await finish(error)
            await connection.disconnect()
            throw error
        }
    }

    private func sendFrame(_ frame: Data, sequence: UInt16) async throws {
        for attempt in 0...config.maxRetransmissions {
            try Task.checkCancellation()
            let waiter = OneShot<Void>()
            ackWaiter = (sequence, waiter) // register before writing: ACK can arrive immediately
            do {
                try await writeFrame(frame)
                let nanos = try timeoutNanoseconds(config.ackTimeout)
                let timer = Task {
                    do { try await Task.sleep(nanoseconds: nanos) } catch { return }
                    waiter.resolve(.failure(LEBLEError.operationTimeout))
                }
                defer { timer.cancel() }
                try await withTaskCancellationHandler {
                    try await withCheckedThrowingContinuation { waiter.install($0) }
                } onCancel: { waiter.resolve(.failure(CancellationError())) }
                ackWaiter = nil
                return
            } catch {
                ackWaiter = nil
                if error is CancellationError || terminalError != nil || attempt == config.maxRetransmissions { throw error }
            }
        }
    }

    private func writeFrame(_ data: Data) async throws {
        if writing { await withCheckedContinuation { writeSlots.append($0) } }
        else { writing = true }
        defer {
            if writeSlots.isEmpty { writing = false }
            else { writeSlots.removeFirst().resume() }
        }
        try Task.checkCancellation()
        if let terminalError { throw terminalError }
        // Use ATT acknowledged writes for control frames too; .write need not imply .writeWithoutResponse.
        try await connection.write(data, to: writeChar)
    }

    private func handle(_ raw: Data) async {
        guard terminalError == nil else { return }
        guard let frame = try? codec.decodeFrame(raw) else { return }
        do {
            switch frame.kind {
            case .ack, .nack:
                guard let (sequence, waiter) = ackWaiter, sequence == frame.sequence else { return }
                waiter.resolve(frame.kind == .ack ? .success(()) : .failure(LEBLEError.transportError(underlying: nil)))
            case .data, .end:
                let behind = expectedSeq &- frame.sequence
                if frame.sequence == expectedSeq {
                    guard frame.payload.count <= config.maxBufferedBytes - message.count else { throw LEBLEError.bufferOverflow }
                    message.append(frame.payload)
                    if frame.kind == .end { try await inbox.push(message); message.removeAll() }
                    expectedSeq &+= 1
                    try await sendControl(.ack, sequence: frame.sequence)
                } else if behind > 0 && behind < 32768 {
                    try await sendControl(.ack, sequence: frame.sequence) // lost ACK: do not deliver twice
                } else {
                    try await sendControl(.nack, sequence: frame.sequence)
                }
            }
        } catch {
            await finish(error)
            await connection.disconnect()
        }
    }

    private func sendControl(_ kind: ReliableFrame.Kind, sequence: UInt16) async throws {
        try await writeFrame(codec.encodeFrame(ReliableFrame(sequence: sequence, kind: kind), mtu: mtu))
    }
    public func receive() async throws -> Data { try await inbox.receive() }
    private func finish(_ error: Error) async {
        guard terminalError == nil else { return }
        terminalError = error; message.removeAll()
        ackWaiter?.1.resolve(.failure(error)); ackWaiter = nil
        await inbox.finish(error)
    }
}
