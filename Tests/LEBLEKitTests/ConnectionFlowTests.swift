import XCTest
@preconcurrency import CoreBluetooth
@testable import LEBLEKit

final class ConnectionFlowTests: XCTestCase {
    func testConnectCompletesServiceDiscovery() async throws {
        let (connection, transport, _) = testConnection()
        try await bounded { try await connection.connect(timeout: 0.1) }
        let state = await connection.state
        guard case .connected = state else { return XCTFail("Expected connected") }
        XCTAssertEqual(transport.storage.snapshot.discoveries, 1)
        // Successful attempt must cancel its timer.
        try await Task.sleep(nanoseconds: 150_000_000)
        XCTAssertEqual(transport.storage.snapshot.cancelCount, 0)
    }

    func testConnectTimeoutDoesNotNeedSystemCallback() async {
        let (connection, transport, bridge) = testConnection()
        transport.autoConnect = false
        await expectBLEError({ if case .connectionTimeout = $0 { return true }; return false }) {
            try await connection.connect(timeout: 0.01)
        }
        XCTAssertGreaterThan(transport.storage.snapshot.cancelCount, 0)
        // A late completion must not resume the timed-out continuation again.
        bridge.completeConnect(uuid: transport.identifier, error: nil)
    }

    func testServiceDiscoveryTimeoutAlsoCompletes() async {
        let (connection, transport, _) = testConnection()
        transport.autoDiscover = false
        await expectBLEError({ if case .connectionTimeout = $0 { return true }; return false }) {
            try await connection.connect(timeout: 0.01)
        }
    }

    func testConnectCancellationCompletes() async throws {
        let (connection, transport, _) = testConnection()
        transport.autoConnect = false
        let pending = Task { try await connection.connect() }
        try await eventually { transport.storage.snapshot.connectCount == 1 }
        pending.cancel()
        do { try await bounded { try await pending.value }; XCTFail("Expected cancellation") }
        catch is CancellationError {} catch { XCTFail("\(error)") }
    }

    func testConcurrentConnectRejectedWithoutSecondRadioCall() async throws {
        let (connection, transport, _) = testConnection()
        transport.autoConnect = false
        let first = Task { try await connection.connect() }
        try await eventually { transport.storage.snapshot.connectCount == 1 }
        await expectBLEError({ if case .operationInProgress = $0 { return true }; return false }) {
            try await connection.connect()
        }
        transport.completeConnect()
        try await bounded { try await first.value }
        XCTAssertEqual(transport.storage.snapshot.connectCount, 1)
    }

    func testConcurrentReadRejectedButOriginalCompletes() async throws {
        let (connection, transport, _) = testConnection()
        try await connection.connect()
        let char = testCharacteristic()
        let first = Task { try await connection.read(char) }
        try await eventually { transport.storage.snapshot.reads.count == 1 }
        await expectBLEError({ if case .operationInProgress = $0 { return true }; return false }) {
            try await connection.read(char)
        }
        transport.emit(Data([42]), on: char)
        let data = try await bounded { try await first.value }
        XCTAssertEqual(data, Data([42]))
        XCTAssertEqual(transport.storage.snapshot.reads.count, 1)
    }

    func testDifferentCharacteristicsReadConcurrently() async throws {
        let (connection, transport, _) = testConnection()
        try await connection.connect()
        let a = testCharacteristic("2A37"), b = testCharacteristic("2A38")
        let first = Task { try await connection.read(a) }
        let second = Task { try await connection.read(b) }
        try await eventually { transport.storage.snapshot.reads.count == 2 }
        transport.emit(Data([2]), on: b)
        transport.emit(Data([1]), on: a)
        let values = try await bounded { (try await first.value, try await second.value) }
        XCTAssertEqual(values.0, Data([1])); XCTAssertEqual(values.1, Data([2]))
    }

    func testConcurrentWriteRejectedButOriginalCompletes() async throws {
        let (connection, transport, bridge) = testConnection()
        transport.autoWrite = false
        try await connection.connect()
        let char = testCharacteristic()
        let first = Task { try await connection.write(Data([1]), to: char) }
        try await eventually { transport.storage.snapshot.writes.count == 1 }
        await expectBLEError({ if case .operationInProgress = $0 { return true }; return false }) {
            try await connection.write(Data([2]), to: char)
        }
        bridge.completedWrite(uuid: transport.identifier, characteristic: char, error: nil)
        try await bounded { try await first.value }
        XCTAssertEqual(transport.storage.snapshot.writes, [Data([1])])
    }

    func testDisconnectFailsPendingReadWriteAndFinishesNotifications() async throws {
        let (connection, transport, _) = testConnection()
        transport.autoWrite = false
        try await connection.connect()
        let char = testCharacteristic()
        let stream = await connection.subscribe(char)
        let read = Task { try await connection.read(char) }
        let write = Task { try await connection.write(Data([1]), to: char) }
        try await eventually { transport.storage.snapshot.reads.count == 1 && transport.storage.snapshot.writes.count == 1 }
        await connection.disconnect()
        for task in [Task { _ = try await read.value }, write] {
            await expectBLEError({ if case .disconnected = $0 { return true }; return false }) { try await task.value }
        }
        let end = try await bounded { var iterator = stream.makeAsyncIterator(); return await iterator.next() }
        XCTAssertNil(end)
    }

    func testManualDisconnectCancelsScheduledReconnect() async throws {
        let (connection, transport, _) = testConnection()
        try await connection.connect()
        await connection.setRetryPolicy(FixedRetryPolicy(interval: 0.05, maxAttempts: 2))
        transport.storage.withValue { $0.connected = false }
        await connection.handleDisconnect(TestFailure.radio)
        await connection.disconnect()
        try await Task.sleep(nanoseconds: 100_000_000)
        XCTAssertEqual(transport.storage.snapshot.connectCount, 1)
    }

    func testUnexpectedDisconnectReconnects() async throws {
        let (connection, transport, _) = testConnection()
        try await connection.connect()
        await connection.setRetryPolicy(FixedRetryPolicy(interval: 0.01, maxAttempts: 1))
        transport.storage.withValue { $0.connected = false }
        await connection.handleDisconnect(TestFailure.radio)
        try await eventually { transport.storage.snapshot.connectCount == 2 && transport.storage.snapshot.discoveries == 2 }
        await connection.disconnect()
    }

    func testOldSubscriptionCancellationDoesNotRemoveNewSubscriber() async throws {
        let (connection, transport, _) = testConnection()
        try await connection.connect()
        let char = testCharacteristic()
        let first = await connection.subscribe(char)
        let consumer = Task { for await _ in first {} }
        let second = await connection.subscribe(char)
        consumer.cancel()
        await consumer.value
        transport.emit(Data([8]), on: char)
        let data = try await bounded { var iterator = second.makeAsyncIterator(); return await iterator.next() }
        XCTAssertEqual(data, Data([8]))
        await connection.disconnect()
    }
}

extension ConnectionFlowTests {
    func testReadErrorReleasesSlotForNextRead() async throws {
        let (connection, transport, bridge) = testConnection()
        try await connection.connect()
        let char = testCharacteristic()
        let first = Task { try await connection.read(char) }
        try await eventually { transport.storage.snapshot.reads.count == 1 }
        bridge.updatedValue(uuid: transport.identifier, characteristic: char, value: nil, error: TestFailure.radio)
        do { _ = try await bounded { try await first.value }; XCTFail("Expected failure") }
        catch TestFailure.radio {} catch { XCTFail("\(error)") }
        let second = Task { try await connection.read(char) }
        try await eventually { transport.storage.snapshot.reads.count == 2 }
        transport.emit(Data([5]), on: char)
        let value = try await bounded { try await second.value }
        XCTAssertEqual(value, Data([5]))
        await connection.disconnect()
    }

    func testDisconnectDuringServiceDiscoveryCompletesConnect() async throws {
        let (connection, transport, _) = testConnection()
        transport.autoDiscover = false
        let pending = Task { try await connection.connect() }
        try await eventually { transport.storage.snapshot.discoveries == 1 }
        transport.storage.withValue { $0.connected = false }
        await connection.handleDisconnect(TestFailure.radio)
        await expectBLEError({ if case .disconnected = $0 { return true }; return false }) { try await pending.value }
    }

    func testDisconnectDuringCharacteristicDiscoveryCompletesWaiter() async throws {
        let (connection, _, _) = testConnection()
        try await connection.connect()
        let service = CBMutableService(type: CBUUID(string: "180D"), primary: true)
        // Both registration and disconnect are actor-isolated; either ordering must return an error.
        let pending = Task { try await connection.discoverCharacteristics(nil, for: service) }
        await connection.disconnect()
        await expectBLEError({ if case .disconnected = $0 { return true }; return false }) { try await pending.value }
    }

    func testRejectedNotificationSetupDoesNotBreakOriginalSetup() async throws {
        let (connection, transport, bridge) = testConnection()
        try await connection.connect()
        transport.autoNotify = false
        let char = testCharacteristic()
        let original = Task { try await connection.subscribeReady(char) }
        try await eventually { transport.storage.snapshot.notifications == 1 }
        await expectBLEError({ if case .operationInProgress = $0 { return true }; return false }) {
            try await connection.subscribeReady(char)
        }
        bridge.notificationReady(uuid: transport.identifier, characteristic: char, error: nil, isNotifying: true)
        let stream = try await bounded { try await original.value }
        transport.emit(Data([8]), on: char)
        let value = try await bounded { var iterator = stream.makeAsyncIterator(); return await iterator.next() }
        XCTAssertEqual(value, Data([8]))
        await connection.disconnect()
    }

    func testBridgeHandlesConcurrentRegistrationAndCompletionAcrossDevices() async throws {
        let bridge = DelegateBridge()
        let char = testCharacteristic()
        try await bounded {
            try await withThrowingTaskGroup(of: Void.self) { group in
                for index in 0..<100 {
                    group.addTask {
                        let id = UUID()
                        let value: Data = try await withCheckedThrowingContinuation { continuation in
                            if bridge.setReadCont(continuation, for: id, characteristic: char) {
                                DispatchQueue.global().async {
                                    bridge.updatedValue(uuid: id, characteristic: char, value: Data([UInt8(index)]), error: nil)
                                }
                            }
                        }
                        XCTAssertEqual(value, Data([UInt8(index)]))
                    }
                }
                try await group.waitForAll()
            }
        }
    }

    func testCleanupDoesNotAffectAnotherDevice() async throws {
        let bridge = DelegateBridge()
        let a = UUID(), b = UUID(), char = testCharacteristic()
        let registered = Locked(0)
        func read(_ id: UUID) async throws -> Data {
            try await withCheckedThrowingContinuation { cont in
                _ = bridge.setReadCont(cont, for: id, characteristic: char)
                registered.withValue { $0 += 1 }
            }
        }
        let first = Task { try await read(a) }
        let second = Task { try await read(b) }
        try await eventually { registered.snapshot == 2 }
        bridge.cleanup(uuid: a)
        await expectBLEError({ if case .disconnected = $0 { return true }; return false }) { try await first.value }
        bridge.updatedValue(uuid: b, characteristic: char, value: Data([2]), error: nil)
        let value = try await bounded { try await second.value }
        XCTAssertEqual(value, Data([2]))
    }
}

extension ConnectionFlowTests {
    func testManualDisconnectCancelsReconnectAlreadyInFlight() async throws {
        let (connection, transport, _) = testConnection()
        try await connection.connect()
        transport.autoConnect = false
        await connection.setRetryPolicy(FixedRetryPolicy(interval: 0.01, maxAttempts: 2))
        transport.storage.withValue { $0.connected = false }
        await connection.handleDisconnect(TestFailure.radio)
        try await eventually { transport.storage.snapshot.connectCount == 2 }
        await connection.disconnect()
        try await Task.sleep(nanoseconds: 50_000_000)
        XCTAssertEqual(transport.storage.snapshot.connectCount, 2)
        let state = await connection.state
        guard case .disconnected = state else { return XCTFail("Expected disconnected") }
    }

    func testFinishedAttemptTimerCannotCancelLaterReconnect() async throws {
        let (connection, transport, _) = testConnection()
        try await connection.connect(timeout: 0.05)
        transport.autoConnect = false
        await connection.setRetryPolicy(FixedRetryPolicy(interval: 0.001, maxAttempts: 1))
        transport.storage.withValue { $0.connected = false }
        await connection.handleDisconnect(TestFailure.radio)
        try await eventually { transport.storage.snapshot.connectCount == 2 }
        try await Task.sleep(nanoseconds: 80_000_000)
        XCTAssertEqual(transport.storage.snapshot.cancelCount, 0)
        await connection.disconnect()
    }
}
