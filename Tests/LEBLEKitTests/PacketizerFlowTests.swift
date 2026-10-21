import XCTest
import CoreBluetooth
@testable import LEBLEKit

final class PacketizerFlowTests: XCTestCase {
    func makePacketizer(_ connection: Connection, _ char: CBCharacteristic) async throws -> Packetizer {
        try await bounded { try await Packetizer(connection: connection, writeChar: char, notifyChar: char) }
    }

    func testSubscriptionAcknowledgedBeforeConstructionReturns() async throws {
        let (connection, transport, bridge) = testConnection()
        transport.autoNotify = false
        try await connection.connect()
        let char = testCharacteristic()
        let constructed = Locked(false)
        let pending = Task {
            let packetizer = try await Packetizer(connection: connection, writeChar: char, notifyChar: char)
            constructed.withValue { $0 = true }
            return packetizer
        }
        try await eventually { transport.storage.snapshot.notifications == 1 }
        XCTAssertFalse(constructed.snapshot)
        bridge.notificationReady(uuid: transport.identifier, characteristic: char, error: nil, isNotifying: true)
        let packetizer = try await bounded { try await pending.value }
        try await packetizer.send(Data([7]))
        XCTAssertEqual(transport.storage.snapshot.writes, [Data([0, 1, 7])])
        await connection.disconnect()
    }

    func testNotificationErrorFailsInitialization() async throws {
        let (connection, transport, bridge) = testConnection()
        transport.autoNotify = false
        try await connection.connect()
        let char = testCharacteristic()
        let pending = Task { try await Packetizer(connection: connection, writeChar: char, notifyChar: char) }
        try await eventually { transport.storage.snapshot.notifications == 1 }
        bridge.notificationReady(uuid: transport.identifier, characteristic: char, error: TestFailure.radio, isNotifying: false)
        do { _ = try await bounded { try await pending.value }; XCTFail("Expected error") }
        catch TestFailure.radio {} catch { XCTFail("\(error)") }
    }

    func testImmediateReplyDuringSendIsRetainedUntilReceive() async throws {
        let (connection, transport, _) = testConnection()
        try await connection.connect()
        let char = testCharacteristic()
        let packetizer = try await makePacketizer(connection, char)
        transport.onWrite = { _ in transport.emit(Data([0, 1, 99]), on: char) }
        try await packetizer.send(Data([1]))
        let reply = try await bounded { try await packetizer.receive() }
        XCTAssertEqual(reply, Data([99]))
        transport.onWrite = nil
        await connection.disconnect()
    }

    func testCoalescedPacketsAndFragmentedHeaderAreDecodedWithoutMoreNotifications() async throws {
        let (connection, transport, _) = testConnection()
        try await connection.connect()
        let char = testCharacteristic()
        let packetizer = try await makePacketizer(connection, char)
        transport.emit(Data([0]), on: char)
        transport.emit(Data([2, 10]), on: char)
        transport.emit(Data([11, 0, 1, 12, 0, 0]), on: char)
        let values = try await bounded {
            [try await packetizer.receive(), try await packetizer.receive(), try await packetizer.receive()]
        }
        XCTAssertEqual(values, [Data([10, 11]), Data([12]), Data()])
        await connection.disconnect()
    }

    func testWriteChunksRespectMTUAndPreserveFrame() async throws {
        let (connection, transport, _) = testConnection()
        try await connection.connect()
        let packetizer = try await makePacketizer(connection, testCharacteristic())
        try await packetizer.send(Data([1, 2, 3, 4, 5, 6, 7]))
        XCTAssertEqual(transport.storage.snapshot.writes, [Data([0, 7, 1, 2]), Data([3, 4, 5, 6]), Data([7])])
        await connection.disconnect()
    }

    func testConcurrentSendsDoNotInterleaveFrames() async throws {
        let (connection, transport, bridge) = testConnection()
        transport.autoWrite = false
        try await connection.connect()
        let char = testCharacteristic()
        let packetizer = try await makePacketizer(connection, char)
        let first = Task { try await packetizer.send(Data([1, 2, 3])) }
        try await eventually { transport.storage.snapshot.writes.count == 1 }
        await expectBLEError({ if case .operationInProgress = $0 { return true }; return false }) {
            try await packetizer.send(Data([9]))
        }
        bridge.completedWrite(uuid: transport.identifier, characteristic: char, error: nil)
        try await eventually { transport.storage.snapshot.writes.count == 2 }
        bridge.completedWrite(uuid: transport.identifier, characteristic: char, error: nil)
        try await bounded { try await first.value }
        XCTAssertEqual(transport.storage.snapshot.writes, [Data([0, 3, 1, 2]), Data([3])])
        await connection.disconnect()
    }

    func testOversizedPayloadRejectedWithoutWriting() async throws {
        let (connection, transport, _) = testConnection()
        try await connection.connect()
        let packetizer = try await makePacketizer(connection, testCharacteristic())
        await expectBLEError({ if case .invalidData = $0 { return true }; return false }) {
            try await packetizer.send(Data(repeating: 0, count: 65_536))
        }
        XCTAssertTrue(transport.storage.snapshot.writes.isEmpty)
        await connection.disconnect()
    }

    func testMaximumPayloadAndEmptyPayload() async throws {
        let (connection, transport, _) = testConnection()
        transport.maximumWriteLength = 512
        try await connection.connect()
        let packetizer = try await makePacketizer(connection, testCharacteristic())
        let payload = Data(repeating: 0xA5, count: 65_535)
        try await bounded { try await packetizer.send(payload) }
        XCTAssertEqual(transport.storage.snapshot.writes.reduce(Data(), +), Data([255, 255]) + payload)
        try await packetizer.send(Data())
        XCTAssertEqual(transport.storage.snapshot.writes.last, Data([0, 0]))
        await connection.disconnect()
    }

    func testDisconnectCompletesPendingReceiveWithError() async throws {
        let (connection, _, _) = testConnection()
        try await connection.connect()
        let packetizer = try await makePacketizer(connection, testCharacteristic())
        let pending = Task { try await packetizer.receive() }
        await connection.disconnect()
        await expectBLEError({ if case .disconnected = $0 { return true }; return false }) { try await pending.value }
    }

    func testCancelledReceiverDoesNotConsumeNextPacket() async throws {
        let (connection, transport, _) = testConnection()
        try await connection.connect()
        let char = testCharacteristic()
        let packetizer = try await makePacketizer(connection, char)
        let pending = Task { try await packetizer.receive() }
        pending.cancel()
        do { _ = try await bounded { try await pending.value }; XCTFail("Expected cancellation") }
        catch is CancellationError {} catch { XCTFail("\(error)") }
        transport.emit(Data([0, 1, 7]), on: char)
        let value = try await bounded { try await packetizer.receive() }
        XCTAssertEqual(value, Data([7]))
        await connection.disconnect()
    }

    func testMultipleReceiversEachGetOnePacket() async throws {
        let (connection, transport, _) = testConnection()
        try await connection.connect()
        let char = testCharacteristic()
        let packetizer = try await makePacketizer(connection, char)
        let a = Task { try await packetizer.receive() }
        let b = Task { try await packetizer.receive() }
        transport.emit(Data([0, 1, 1, 0, 1, 2]), on: char)
        let values = try await bounded { [try await a.value, try await b.value] }
        XCTAssertEqual(Set(values), Set([Data([1]), Data([2])]))
        await connection.disconnect()
    }
}
