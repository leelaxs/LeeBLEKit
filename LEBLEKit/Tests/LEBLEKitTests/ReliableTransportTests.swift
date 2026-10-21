import XCTest
@preconcurrency import CoreBluetooth
@testable import LEBLEKit

final class ReliableTransportTests: XCTestCase {
    func make(_ connection: Connection, _ char: CBCharacteristic,
              timeout: TimeInterval = 0.02, retries: Int = 1,
              codec: any FrameProtocol = DefaultFrameProtocol(), maxMessages: Int = 128) async throws -> ReliableTransport {
        try await ReliableTransport(connection: connection,
            config: .init(writeCharUUID: char.uuid, notifyCharUUID: char.uuid, mtu: 20,
                          frameProtocol: codec, ackTimeout: timeout, maxRetransmissions: retries,
                          maxBufferedMessages: maxMessages), writeChar: char, notifyChar: char)
    }

    func testFinalSequenceCRCAndImmediateAck() async throws {
        let (conn, radio, _) = testConnection(); radio.maximumWriteLength = 20
        try await conn.connect()
        let char = testCharacteristic()
        let link = try await make(conn, char)
        radio.onWrite = { data in
            let codec = DefaultFrameProtocol()
            guard let frame = try? codec.decodeFrame(data), frame.kind == .data || frame.kind == .end else { return }
            radio.emit(try! codec.encodeFrame(.init(sequence: frame.sequence, kind: .ack), mtu: 20), on: char)
        }
        try await bounded { try await link.send(Data(repeating: 7, count: 13)) }
        try await bounded { try await link.send(Data([9])) }
        let frames = try radio.storage.snapshot.writes.map { try DefaultFrameProtocol().decodeFrame($0) }
        XCTAssertEqual(frames.map(\.sequence), [0, 1, 2])
        XCTAssertEqual(frames.map(\.kind), [.data, .end, .end])
        radio.onWrite = nil; await conn.disconnect()
    }

    func testMissingAckRetriesIdenticalFrameThenFails() async throws {
        let (conn, radio, _) = testConnection(); radio.maximumWriteLength = 20
        try await conn.connect(); let char = testCharacteristic(); let link = try await make(conn, char)
        await expectBLEError({ if case .operationTimeout = $0 { return true }; return false }) {
            try await link.send(Data([1]))
        }
        XCTAssertEqual(radio.storage.snapshot.writes.count, 2)
        XCTAssertEqual(radio.storage.snapshot.writes.first, radio.storage.snapshot.writes.last)
        XCTAssertGreaterThan(radio.storage.snapshot.cancelCount, 0)
    }

    func testWrongSequenceAckDoesNotCompleteSend() async throws {
        let (conn, radio, _) = testConnection(); radio.maximumWriteLength = 20
        try await conn.connect(); let char = testCharacteristic(); let link = try await make(conn, char, retries: 0)
        radio.onWrite = { _ in radio.emit(try! DefaultFrameProtocol().encodeFrame(.init(sequence: 99, kind: .ack), mtu: 20), on: char) }
        await expectBLEError({ if case .operationTimeout = $0 { return true }; return false }) { try await link.send(Data([1])) }
        radio.onWrite = nil
    }

    func testNackRetriesThenAckSucceeds() async throws {
        let (conn, radio, _) = testConnection(); radio.maximumWriteLength = 20
        try await conn.connect(); let char = testCharacteristic(); let link = try await make(conn, char)
        let writes = Locked(0)
        radio.onWrite = { _ in
            let count = writes.withValue { $0 += 1; return $0 }
            radio.emit(try! DefaultFrameProtocol().encodeFrame(.init(sequence: 0, kind: count == 1 ? .nack : .ack), mtu: 20), on: char)
        }
        try await bounded { try await link.send(Data([1])) }
        XCTAssertEqual(writes.snapshot, 2)
        radio.onWrite = nil; await conn.disconnect()
    }

    func testReceivesWholeMessageAndDoesNotDeliverDuplicate() async throws {
        let (conn, radio, _) = testConnection(); radio.maximumWriteLength = 20
        try await conn.connect(); let char = testCharacteristic(); let link = try await make(conn, char)
        let codec = DefaultFrameProtocol()
        radio.emit(try codec.encodeFrame(.init(sequence: 0, kind: .data, payload: Data([1, 2])), mtu: 20), on: char)
        radio.emit(try codec.encodeFrame(.init(sequence: 1, kind: .end, payload: Data([3])), mtu: 20), on: char)
        let payload = try await bounded { try await link.receive() }
        XCTAssertEqual(payload, Data([1, 2, 3]))
        radio.emit(try codec.encodeFrame(.init(sequence: 1, kind: .end, payload: Data([3])), mtu: 20), on: char)
        radio.emit(try codec.encodeFrame(.init(sequence: 2, kind: .end, payload: Data([4])), mtu: 20), on: char)
        let second = try await bounded { try await link.receive() }
        XCTAssertEqual(second, Data([4]))
        await conn.disconnect()
    }

    func testOutOfOrderFrameIsNackedAndRetriedInOrder() async throws {
        let (conn, radio, _) = testConnection(); radio.maximumWriteLength = 20
        try await conn.connect(); let char = testCharacteristic(); let link = try await make(conn, char)
        let codec = DefaultFrameProtocol()
        let future = try codec.encodeFrame(.init(sequence: 1, kind: .end, payload: Data([2])), mtu: 20)
        radio.emit(future, on: char)
        try await eventually { radio.storage.snapshot.writes.count == 1 }
        XCTAssertEqual(try codec.decodeFrame(radio.storage.snapshot.writes[0]).kind, .nack)
        radio.emit(try codec.encodeFrame(.init(sequence: 0, kind: .data, payload: Data([1])), mtu: 20), on: char)
        radio.emit(future, on: char)
        let payload = try await bounded { try await link.receive() }
        XCTAssertEqual(payload, Data([1, 2]))
        await conn.disconnect()
    }

    func testDuplexRoundTripAndLostAckRetransmission() async throws {
        let (a, ra, _) = testConnection(), (b, rb, _) = testConnection()
        ra.maximumWriteLength = 20; rb.maximumWriteLength = 20
        try await a.connect(); try await b.connect()
        let ca = testCharacteristic(), cb = testCharacteristic()
        let la = try await make(a, ca), lb = try await make(b, cb)
        let dropped = Locked(false)
        ra.onWrite = { rb.emit($0, on: cb) }
        rb.onWrite = { data in
            let frame = try! DefaultFrameProtocol().decodeFrame(data)
            if frame.kind == .ack && dropped.withValue({ value in if value { return false }; value = true; return true }) { return }
            ra.emit(data, on: ca)
        }
        let payload = Data(0..<30)
        try await bounded { try await la.send(payload) }
        let received = try await bounded { try await lb.receive() }
        XCTAssertEqual(received, payload)
        try await bounded { try await lb.send(Data([8, 9])) }
        let response = try await bounded { try await la.receive() }
        XCTAssertEqual(response, Data([8, 9]))
        XCTAssertTrue(dropped.snapshot)
        ra.onWrite = nil; rb.onWrite = nil; await a.disconnect(); await b.disconnect()
    }

    func testConcurrentReceiversCancellationAndDisconnect() async throws {
        let (conn, radio, _) = testConnection(); radio.maximumWriteLength = 20
        try await conn.connect(); let char = testCharacteristic(); let link = try await make(conn, char)
        let cancelled = Task { try await link.receive() }
        cancelled.cancel()
        do { _ = try await bounded { try await cancelled.value }; XCTFail("Expected cancellation") } catch is CancellationError {}
        let a = Task { try await link.receive() }, b = Task { try await link.receive() }
        let codec = DefaultFrameProtocol()
        radio.emit(try codec.encodeFrame(.init(sequence: 0, kind: .end, payload: Data([1])), mtu: 20), on: char)
        radio.emit(try codec.encodeFrame(.init(sequence: 1, kind: .end, payload: Data([2])), mtu: 20), on: char)
        let values = try await bounded { [try await a.value, try await b.value] }
        XCTAssertEqual(Set(values), Set([Data([1]), Data([2])]))
        let pending = Task { try await link.receive() }
        await conn.disconnect()
        await expectBLEError({ if case .disconnected = $0 { return true }; return false }) { try await pending.value }
    }

    func testCancelWhileWaitingForAckEndsSession() async throws {
        let (conn, radio, _) = testConnection(); radio.maximumWriteLength = 20
        try await conn.connect(); let char = testCharacteristic(); let link = try await make(conn, char, timeout: 1)
        let pending = Task { try await link.send(Data([1])) }
        try await eventually { !radio.storage.snapshot.writes.isEmpty }
        pending.cancel()
        do { try await bounded { try await pending.value }; XCTFail("Expected cancellation") } catch is CancellationError {}
        XCTAssertGreaterThan(radio.storage.snapshot.cancelCount, 0)
    }

    func testInboxOverflowEndsSession() async throws {
        let (conn, radio, _) = testConnection(); radio.maximumWriteLength = 20
        try await conn.connect(); let char = testCharacteristic(); let link = try await make(conn, char, maxMessages: 1)
        let codec = DefaultFrameProtocol()
        for seq: UInt16 in [0, 1] { radio.emit(try codec.encodeFrame(.init(sequence: seq, kind: .end, payload: Data([1])), mtu: 20), on: char) }
        try await eventually { radio.storage.snapshot.cancelCount > 0 }
        await expectBLEError({ if case .bufferOverflow = $0 { return true }; return false }) { try await link.receive() }
    }

    struct CustomCodec: ReliableFrameProtocol {
        let base = DefaultFrameProtocol()
        func maximumPayload(mtu: Int) throws -> Int { try base.maximumPayload(mtu: mtu) }
        func encodeFrame(_ frame: ReliableFrame, mtu: Int) throws -> Data { try base.encodeFrame(frame, mtu: mtu) }
        func decodeFrame(_ data: Data) throws -> ReliableFrame { try base.decodeFrame(data) }
        func encode(_ data: Data, mtu: Int) -> [Data] { base.encode(data, mtu: mtu) }
        func decode(_ data: Data) -> DecodeResult { base.decode(data) }
    }
    func testCustomReliableCodecDeliversData() async throws {
        let (conn, radio, _) = testConnection(); radio.maximumWriteLength = 20
        try await conn.connect(); let char = testCharacteristic(); let codec = CustomCodec()
        let link = try await make(conn, char, codec: codec)
        radio.emit(try codec.encodeFrame(.init(sequence: 0, kind: .end, payload: Data([7])), mtu: 20), on: char)
        let value = try await bounded { try await link.receive() }
        XCTAssertEqual(value, Data([7])); await conn.disconnect()
    }

    func testInvalidMTUBoundsEmptyAndSlices() throws {
        let codec = DefaultFrameProtocol()
        for mtu in [Int.min, 0, 7, 8] {
            XCTAssertTrue(codec.encode(Data([1]), mtu: mtu).isEmpty)
            XCTAssertThrowsError(try codec.maximumPayload(mtu: mtu))
        }
        let frames = codec.encode(Data(), mtu: 20)
        XCTAssertEqual(frames.count, 1)
        XCTAssertEqual(try codec.decodeFrame(frames[0]).kind, .end)
        let original = Data([99]) + codec.encode(Data([1, 2]), mtu: 20)[0]
        XCTAssertEqual(try codec.decodeFrame(original.dropFirst()).payload, Data([1, 2]))
        let many = codec.encode(Data(repeating: 1, count: 65537), mtu: 9)
        XCTAssertEqual(try codec.decodeFrame(many[65536]).sequence, 0)
    }
}
