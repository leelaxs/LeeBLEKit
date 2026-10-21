import XCTest
import CoreBluetooth
@testable import LEBLEKit

final class ReadinessAndScanTests: XCTestCase {
    func testPowerOnAfterTimeoutDoesNotDoubleResume() async throws {
        let readiness = Readiness()
        await expectBLEError({ if case .scanningNotReady = $0 { return true }; return false }) {
            try await readiness.wait(timeout: 0.001)
        }
        readiness.update(.poweredOn)
        try await bounded { try await readiness.wait(timeout: 0.1) }
    }

    func testManyWaitersAllCompleteOnPowerOn() async throws {
        let readiness = Readiness()
        let waiters = (0..<20).map { _ in Task { try await readiness.wait(timeout: 1) } }
        readiness.update(.poweredOn)
        try await bounded { for waiter in waiters { try await waiter.value } }
    }

    func testCancellingOneWaiterDoesNotCancelOthers() async throws {
        let readiness = Readiness()
        let first = Task { try await readiness.wait(timeout: 1) }
        let second = Task { try await readiness.wait(timeout: 1) }
        first.cancel()
        do { try await bounded { try await first.value }; XCTFail("Expected cancellation") }
        catch is CancellationError {} catch { XCTFail("\(error)") }
        readiness.update(.poweredOn)
        try await bounded { try await second.value }
    }

    func testStateStreamsBothReceiveUpdates() async throws {
        let states = StateBroadcast<CBManagerState>(.poweredOff)
        let a = states.stream(), b = states.stream()
        states.update(.poweredOn)
        let values = try await bounded { () -> [CBManagerState] in
            var ia = a.makeAsyncIterator(), ib = b.makeAsyncIterator()
            return [await ia.next()!, await ib.next()!, await ia.next()!, await ib.next()!]
        }
        XCTAssertEqual(values, [.poweredOff, .poweredOff, .poweredOn, .poweredOn])
    }

    func testInvalidTimeoutsThrowInsteadOfTrapping() async {
        for timeout in [-1.0, Double.nan, Double.infinity, Double.greatestFiniteMagnitude] {
            await expectBLEError({ if case .invalidData = $0 { return true }; return false }) {
                try await Readiness().wait(timeout: timeout)
            }
        }
    }

    func testExpiringEarlierScanDoesNotExpireLaterScan() async throws {
        let queue = ScanQueue()
        let firstID = UUID(), secondID = UUID()
        let added = Locked(0)
        let first = Task {
            try await withCheckedThrowingContinuation { (cont: CheckedContinuation<ScanResult, Error>) in
                _ = queue.add(.init(id: firstID, rule: .nameIs("A"), timeout: 1, continuation: cont))
                added.withValue { $0 += 1 }
            }
        }
        try await eventually { added.snapshot == 1 }
        let second = Task {
            try await withCheckedThrowingContinuation { (cont: CheckedContinuation<ScanResult, Error>) in
                _ = queue.add(.init(id: secondID, rule: .nameIs("B"), timeout: 30, continuation: cont))
                added.withValue { $0 += 1 }
            }
        }
        try await eventually { added.snapshot == 2 }
        queue.remove(id: firstID, error: LEBLEError.scanTimeout)
        await expectBLEError({ if case .scanTimeout = $0 { return true }; return false }) { try await first.value }
        XCTAssertTrue(queue.hasPendingTasks)
        let expected = ScanResult(id: UUID(), name: "B", rssi: -40, advertisementData: [:])
        queue.checkAndResolve(expected)
        let result = try await bounded { try await second.value }
        XCTAssertEqual(result.id, expected.id)
        XCTAssertFalse(queue.hasPendingTasks)
        queue.remove(id: secondID, error: LEBLEError.scanTimeout) // late timer is harmless
    }

    func testPowerLossCancelsAllScans() async throws {
        let queue = ScanQueue()
        let added = Locked(0)
        let tasks = (0..<3).map { _ in Task {
            try await withCheckedThrowingContinuation { (cont: CheckedContinuation<ScanResult, Error>) in
                _ = queue.add(.init(id: UUID(), rule: .nameIs("missing"), timeout: 30, continuation: cont))
                added.withValue { $0 += 1 }
            }
        } }
        try await eventually { added.snapshot == 3 }
        queue.cancelAll()
        for task in tasks {
            await expectBLEError({ if case .scanningNotReady = $0 { return true }; return false }) { try await task.value }
        }
        XCTAssertFalse(queue.hasPendingTasks)
    }
}
