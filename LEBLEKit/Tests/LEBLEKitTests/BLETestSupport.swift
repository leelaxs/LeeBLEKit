import XCTest
import CoreBluetooth
@testable import LEBLEKit

final class Locked<Value>: @unchecked Sendable {
    private let lock = NSLock()
    private var value: Value
    init(_ value: Value) { self.value = value }
    func withValue<T>(_ body: (inout Value) -> T) -> T {
        lock.lock(); defer { lock.unlock() }
        return body(&value)
    }
    var snapshot: Value { withValue { $0 } }
}

enum TestFailure: Error { case timeout, radio }

extension XCTestCase {
    /// Never let a leaked production continuation hang the whole test process.
    func bounded<T>(_ operation: @escaping () async throws -> T) async throws -> T {
        let done = expectation(description: "operation completes")
        let result = Locked<Result<T, Error>?>(nil)
        let worker = Task {
            do { let value = try await operation(); result.withValue { $0 = .success(value) } }
            catch { result.withValue { $0 = .failure(error) } }
            done.fulfill()
        }
        await fulfillment(of: [done], timeout: 2)
        worker.cancel()
        guard let outcome = result.snapshot else { throw TestFailure.timeout }
        return try outcome.get()
    }

    func eventually(_ predicate: @escaping () -> Bool) async throws {
        for _ in 0..<1000 {
            if predicate() { return }
            try await Task.sleep(nanoseconds: 1_000_000)
        }
        XCTFail("Expected transport event did not arrive")
        throw TestFailure.timeout
    }

    func expectBLEError<T>(_ match: (LEBLEError) -> Bool,
                           operation: @escaping () async throws -> T,
                           file: StaticString = #filePath, line: UInt = #line) async {
        do { _ = try await bounded(operation); XCTFail("Expected error", file: file, line: line) }
        catch let error as LEBLEError { XCTAssertTrue(match(error), "Unexpected error: \(error)", file: file, line: line) }
        catch { XCTFail("Unexpected error: \(error)", file: file, line: line) }
    }
}

final class FakeTransport: ConnectionTransport, @unchecked Sendable {
    struct Storage {
        var connected = false
        var connectCount = 0
        var cancelCount = 0
        var reads: [CBUUID] = []
        var writes: [Data] = []
        var notifications = 0
        var discoveries = 0
    }
    let identifier = UUID()
    let name: String? = "Test device"
    let bridge: DelegateBridge
    let storage = Locked(Storage())
    var maximumWriteLength = 4
    var canSendWithoutResponse = true
    func maximumWriteLength(for type: CBCharacteristicWriteType) -> Int { maximumWriteLength }
    var autoConnect = true
    var autoDiscover = true
    var autoWrite = true
    var autoNotify = true
    var onWrite: ((Data) -> Void)?
    init(bridge: DelegateBridge) { self.bridge = bridge }
    var isConnected: Bool { storage.snapshot.connected }
    var isDisconnected: Bool { !storage.snapshot.connected }
    func connect() {
        storage.withValue { $0.connectCount += 1 }
        if autoConnect { completeConnect() }
    }
    func completeConnect(error: Error? = nil) {
        storage.withValue { $0.connected = error == nil }
        bridge.completeConnect(uuid: identifier, error: error)
    }
    func cancel() { storage.withValue { $0.cancelCount += 1; $0.connected = false } }
    func discoverServices(_ uuids: [CBUUID]?) {
        storage.withValue { $0.discoveries += 1 }
        if autoDiscover { bridge.discoveredServices(uuid: identifier, services: [], error: nil) }
    }
    func discoverCharacteristics(_ uuids: [CBUUID]?, for service: CBService) {}
    func read(_ characteristic: CBCharacteristic) { storage.withValue { $0.reads.append(characteristic.uuid) } }
    func write(_ data: Data, to characteristic: CBCharacteristic, type: CBCharacteristicWriteType) {
        storage.withValue { $0.writes.append(data) }
        onWrite?(data)
        if autoWrite && type == .withResponse { bridge.completedWrite(uuid: identifier, characteristic: characteristic, error: nil) }
    }
    func notify(_ enabled: Bool, for characteristic: CBCharacteristic) {
        storage.withValue { $0.notifications += 1 }
        if autoNotify { bridge.notificationReady(uuid: identifier, characteristic: characteristic, error: nil, isNotifying: enabled) }
    }
    func emit(_ data: Data, on characteristic: CBCharacteristic) {
        bridge.updatedValue(uuid: identifier, characteristic: characteristic, value: data, error: nil)
    }
}

func testCharacteristic(_ uuid: String = "2A37") -> CBMutableCharacteristic {
    CBMutableCharacteristic(type: CBUUID(string: uuid), properties: [.read, .write, .writeWithoutResponse, .notify], value: nil, permissions: [.readable, .writeable])
}

func testConnection() -> (Connection, FakeTransport, DelegateBridge) {
    let bridge = DelegateBridge()
    let transport = FakeTransport(bridge: bridge)
    return (Connection(transport: transport, bridge: bridge), transport, bridge)
}
