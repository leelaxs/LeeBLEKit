import XCTest
@preconcurrency import CoreBluetooth
@testable import LEBLEKit

final class AuditFixTests: XCTestCase {
    func testReadCancellationClosesSessionAndIgnoresLateCallback() async throws {
        let (conn, radio, bridge) = testConnection(); try await conn.connect()
        let char = testCharacteristic()
        let pending = Task { try await conn.read(char) }
        try await eventually { radio.storage.snapshot.reads.count == 1 }; pending.cancel()
        do { _ = try await bounded { try await pending.value }; XCTFail("Expected cancellation") } catch is CancellationError {}
        bridge.updatedValue(uuid: radio.identifier, characteristic: char, value: Data([9]), error: nil)
        await expectBLEError({ if case .disconnected = $0 { return true }; return false }) { try await conn.read(char) }
    }
    func testWriteCancellationCompletesWithoutCallback() async throws {
        let (conn, radio, _) = testConnection(); try await conn.connect(); radio.autoWrite = false
        let pending = Task { try await conn.write(Data([1]), to: testCharacteristic()) }
        try await eventually { radio.storage.snapshot.writes.count == 1 }; pending.cancel()
        do { try await bounded { try await pending.value }; XCTFail("Expected cancellation") } catch is CancellationError {}
    }
    func testSubscribeCancellationCompletesInitialization() async throws {
        let (conn, radio, _) = testConnection(); try await conn.connect(); radio.autoNotify = false
        let char = testCharacteristic()
        let pending = Task { try await Packetizer(connection: conn, writeChar: char, notifyChar: char) }
        try await eventually { radio.storage.snapshot.notifications == 1 }; pending.cancel()
        do { _ = try await bounded { try await pending.value }; XCTFail("Expected cancellation") } catch is CancellationError {}
    }
    func testReadDeadlineClosesConnection() async throws {
        let (conn, _, _) = testConnection(); try await conn.connect()
        await conn.setOperationTimeoutForTesting(0.01)
        await expectBLEError({ if case .operationTimeout = $0 { return true }; return false }) { try await conn.read(testCharacteristic()) }
    }
    func testPartialPacketCancellationPreventsNextMessage() async throws {
        let (conn, radio, bridge) = testConnection(); try await conn.connect(); radio.autoWrite = false
        let char = testCharacteristic(); let packetizer = try await Packetizer(connection: conn, writeChar: char, notifyChar: char)
        let task = Task { try await packetizer.send(Data([1, 2, 3])) }
        try await eventually { radio.storage.snapshot.writes.count == 1 }; task.cancel()
        bridge.completedWrite(uuid: radio.identifier, characteristic: char, error: nil)
        do { try await bounded { try await task.value }; XCTFail("Expected cancellation") } catch is CancellationError {}
        do { try await packetizer.send(Data([9])); XCTFail("Session must be terminal") } catch {}
        XCTAssertEqual(radio.storage.snapshot.writes, [Data([0, 3, 1, 2])])
    }
    func testSameUUIDInstancesHaveIndependentReadsAndNotifications() async throws {
        let (conn, radio, _) = testConnection(); try await conn.connect()
        let a = testCharacteristic(), b = testCharacteristic()
        let sa = await conn.subscribe(a), sb = await conn.subscribe(b)
        let ra = Task { try await conn.read(a) }, rb = Task { try await conn.read(b) }
        try await eventually { radio.storage.snapshot.reads.count == 2 }
        radio.emit(Data([1]), on: a); radio.emit(Data([2]), on: b)
        let values = try await bounded { [try await ra.value, try await rb.value] }
        XCTAssertEqual(values, [Data([1]), Data([2])])
        let notifications = try await bounded { () -> [Data?] in
            var ia = sa.makeAsyncIterator(), ib = sb.makeAsyncIterator()
            return [await ia.next(), await ib.next()]
        }
        XCTAssertEqual(notifications, [Data([1]), Data([2])]); await conn.disconnect()
    }
    func testWithoutResponseWaitsForCapacity() async throws {
        let (conn, radio, _) = testConnection(); try await conn.connect(); radio.canSendWithoutResponse = false
        let pending = Task { try await conn.write(Data([1]), to: testCharacteristic(), type: .withoutResponse) }
        try await Task.sleep(nanoseconds: 10_000_000)
        XCTAssertTrue(radio.storage.snapshot.writes.isEmpty)
        radio.canSendWithoutResponse = true; await conn.writeReady()
        try await bounded { try await pending.value }
        XCTAssertEqual(radio.storage.snapshot.writes, [Data([1])]); await conn.disconnect()
    }
    func testWithoutResponseCancellationEndsWaitingWriter() async throws {
        let (conn, radio, _) = testConnection(); try await conn.connect(); radio.canSendWithoutResponse = false
        let pending = Task { try await conn.write(Data([1]), to: testCharacteristic(), type: .withoutResponse) }
        try await Task.sleep(nanoseconds: 10_000_000); pending.cancel()
        do { try await bounded { try await pending.value }; XCTFail("Expected cancellation") } catch is CancellationError {}
        XCTAssertTrue(radio.storage.snapshot.writes.isEmpty)
    }
    func testWriteChecksPropertyAndLength() async throws {
        let (conn, radio, _) = testConnection(); try await conn.connect()
        let readOnly = CBMutableCharacteristic(type: CBUUID(string: "FFF1"), properties: .read, value: nil, permissions: .readable)
        await expectBLEError({ if case .invalidData = $0 { return true }; return false }) { try await conn.write(Data([1]), to: readOnly) }
        await expectBLEError({ if case .invalidData = $0 { return true }; return false }) { try await conn.write(Data(repeating: 1, count: 5), to: testCharacteristic()) }
        XCTAssertTrue(radio.storage.snapshot.writes.isEmpty); await conn.disconnect()
    }
    func testPacketBufferOverflowEndsSession() async throws {
        let (conn, radio, _) = testConnection(); try await conn.connect()
        let char = testCharacteristic(); let packets = try await Packetizer(connection: conn, writeChar: char, notifyChar: char)
        radio.emit(Data(repeating: 0, count: 2 * 129), on: char)
        try await eventually { radio.storage.snapshot.cancelCount > 0 }
        await expectBLEError({ if case .bufferOverflow = $0 { return true }; return false }) { try await packets.receive() }
    }
    func testDynamicInitialValueKeepsWriteAndNotifyCapabilities() {
        let config = CharacteristicConfig.readWriteNotify(uuid: CBUUID(string: "FFF1"), value: Data([1]))
        let char = config.makeCharacteristic()
        XCTAssertNil(char.value)
        XCTAssertTrue(char.properties.contains(.write)); XCTAssertTrue(char.properties.contains(.notify))
        let callbacks = PeripheralCallbacks()
        callbacks.access { $0.values[ObjectIdentifier(char)] = config.initialValue }
        XCTAssertEqual(callbacks.read(char), Data([1]))
        callbacks.access { $0.read = { _ in Data([2]) } }
        XCTAssertEqual(callbacks.read(char), Data([2]))
    }
    func testCallbackReplacementIsSynchronized() async throws {
        let callbacks = PeripheralCallbacks(); let char = testCharacteristic()
        await withTaskGroup(of: Void.self) { group in
            for _ in 0..<100 {
                group.addTask { callbacks.access { $0.read = { _ in Data([1]) } } }
                group.addTask { _ = callbacks.read(char) }
            }
        }
        XCTAssertEqual(callbacks.read(char), Data([1]))
    }
}

extension Connection {
    func setOperationTimeoutForTesting(_ value: TimeInterval) { operationTimeout = value }
}
