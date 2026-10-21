import Foundation
@preconcurrency import CoreBluetooth

/// Synchronizes callback replacement and initial dynamic values. Callbacks run outside the lock.
final class PeripheralCallbacks: @unchecked Sendable {
    struct Storage {
        var read: (@Sendable (CBCharacteristic) -> Data?)?
        var write: (@Sendable (CBCharacteristic, Data) -> Void)?
        var subscribe: (@Sendable (CBCentral, CBCharacteristic) -> Void)?
        var unsubscribe: (@Sendable (CBCentral, CBCharacteristic) -> Void)?
        var values: [ObjectIdentifier: Data] = [:]
    }
    private let lock = NSLock()
    private var storage = Storage()
    func access<T>(_ body: (inout Storage) -> T) -> T {
        lock.lock(); defer { lock.unlock() }
        return body(&storage)
    }
    func read(_ char: CBCharacteristic) -> Data? {
        let (handler, value) = access { ($0.read, $0.values[ObjectIdentifier(char)]) }
        if let handler { return handler(char) }
        return value
    }
}
