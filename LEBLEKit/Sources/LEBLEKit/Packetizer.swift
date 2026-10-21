import Foundation
@preconcurrency import CoreBluetooth

/// Two-byte big-endian length followed by payload, split to the write MTU.
/// Notification subscription is acknowledged during initialization, before send.
public actor Packetizer {
    private let connection: Connection
    private let writeChar: CBCharacteristic
    public let mtu: Int
    private var buffer = Data()
    private var packets: [Data] = []
    private var receivers: [(UUID, CheckedContinuation<Data, Error>)] = []
    private var receiveTask: Task<Void, Never>?
    private var terminalError: Error?
    private var sending = false
    private var bufferedBytes = 0
    private let maxPackets = 128
    private let maxBytes = 1_048_576

    public init(connection: Connection, writeCharUUID: CBUUID, notifyCharUUID: CBUUID) async throws {
        var writeChar: CBCharacteristic?
        var notifyChar: CBCharacteristic?
        for service in await connection.services {
            for char in try await connection.discoverCharacteristics(nil, for: service) {
                if char.uuid == writeCharUUID { writeChar = char }
                if char.uuid == notifyCharUUID { notifyChar = char }
            }
        }
        guard let wc = writeChar else { throw LEBLEError.characteristicNotFound(writeCharUUID) }
        guard let nc = notifyChar else { throw LEBLEError.characteristicNotFound(notifyCharUUID) }
        try await self.init(connection: connection, writeChar: wc, notifyChar: nc)
    }

    /// Test seam still exercises the real Connection, subscription and write bridge.
    init(connection: Connection, writeChar: CBCharacteristic, notifyChar: CBCharacteristic) async throws {
        self.connection = connection
        self.writeChar = writeChar
        self.mtu = await connection.maximumWriteLength
        guard mtu > 0 else { throw LEBLEError.invalidData }
        let stream = try await connection.subscribeReady(notifyChar)
        self.receiveTask = Task { [weak self] in
            for await chunk in stream {
                guard !Task.isCancelled else { return }
                await self?.accept(chunk)
            }
            await self?.finish(LEBLEError.disconnected(underlying: nil))
        }
    }

    deinit {
        receiveTask?.cancel()
        for (_, receiver) in receivers { receiver.resume(throwing: CancellationError()) }
    }

    /// Concurrent sends are rejected, preventing frame chunks from interleaving.
    public func send(_ data: Data) async throws {
        try Task.checkCancellation()
        if let terminalError { throw terminalError }
        guard !sending else { throw LEBLEError.operationInProgress }
        guard data.count <= Int(UInt16.max) else { throw LEBLEError.invalidData }
        sending = true
        defer { sending = false }
        let count = UInt16(data.count)
        let framed = Data([UInt8(count >> 8), UInt8(count & 0xff)]) + data
        var offset = 0
        do {
            while offset < framed.count {
                try Task.checkCancellation()
                let end = offset + min(mtu, framed.count - offset)
                try await connection.write(framed.subdata(in: offset..<end), to: writeChar)
                offset = end
            }
        } catch {
            // An interrupted length-prefixed message cannot be resynchronized in-band.
            finish(error)
            await connection.disconnect()
            throw error
        }
    }

    /// Complete packets are buffered even when no receive() call is waiting.
    /// Multiple receivers consume packets in registration order.
    public func receive() async throws -> Data {
        try Task.checkCancellation()
        if let terminalError { throw terminalError }
        if !packets.isEmpty { let data = packets.removeFirst(); bufferedBytes -= data.count; return data }
        let id = UUID()
        return try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { receivers.append((id, $0)) }
        } onCancel: {
            Task { await self.cancelReceiver(id) }
        }
    }

    private func cancelReceiver(_ id: UUID) {
        guard let index = receivers.firstIndex(where: { $0.0 == id }) else { return }
        receivers.remove(at: index).1.resume(throwing: CancellationError())
    }

    private func accept(_ chunk: Data) async {
        guard terminalError == nil else { return }
        buffer.append(chunk)
        while buffer.count >= 2 {
            let start = buffer.startIndex
            let length = (Int(buffer[start]) << 8) | Int(buffer[start + 1])
            guard buffer.count >= length + 2 else { return }
            let payload = buffer.subdata(in: (start + 2)..<(start + 2 + length))
            buffer = Data(buffer.dropFirst(length + 2))
            if receivers.isEmpty {
                guard packets.count < maxPackets, payload.count <= maxBytes - bufferedBytes else {
                    finish(LEBLEError.bufferOverflow)
                    await connection.disconnect()
                    return
                }
                packets.append(payload); bufferedBytes += payload.count
            }
            else { receivers.removeFirst().1.resume(returning: payload) }
        }
    }

    private func finish(_ error: Error) {
        guard terminalError == nil else { return }
        terminalError = error
        buffer.removeAll()
        packets.removeAll(); bufferedBytes = 0
        let pending = receivers
        receivers.removeAll()
        for (_, receiver) in pending { receiver.resume(throwing: error) }
    }
}
