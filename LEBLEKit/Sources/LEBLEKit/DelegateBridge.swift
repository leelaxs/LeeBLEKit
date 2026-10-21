import Foundation
@preconcurrency import CoreBluetooth

/// 委托桥接——将 CoreBluetooth 的 Delegate 回调桥接到 async/await 世界
///
/// 职责：
/// 1. 接收 CBCentralManagerDelegate 事件，转发给 LEBLEManager actor
/// 2. 管理各操作的 CheckedContinuation，在 delegate 回调中 resume
/// 3. 所有字典操作由 NSLock 保护，确保线程安全
///
/// 注意：此类型标注了 @unchecked Sendable，因为内部用 NSLock 保证线程安全，
/// 但持有的 CBCentralManager 等对象不是 Sendable 的。
final class DelegateBridge: NSObject, CBCentralManagerDelegate, CBPeripheralDelegate, @unchecked Sendable {

    // MARK: - Central 层回调（转发给 LEBLEManager actor）

    typealias StateHandler = @Sendable (CBManagerState) -> Void
    typealias DiscoveryHandler = @Sendable (CBPeripheral, [String: Any], NSNumber) -> Void
    typealias ConnectHandler = @Sendable (CBPeripheral) -> Void
    typealias FailConnectHandler = @Sendable (CBPeripheral, Error?) -> Void
    typealias DisconnectHandler = @Sendable (CBPeripheral, Error?) -> Void

    var onStateUpdate: StateHandler?
    var onDiscovery: DiscoveryHandler?
    var onConnect: ConnectHandler?
    var onFailConnect: FailConnectHandler?
    var onDisconnect: DisconnectHandler?
    var onWriteReady: (@Sendable (UUID) -> Void)?
    var onStreamOverflow: (@Sendable (UUID) -> Void)?

    // MARK: - CBCentralManagerDelegate

    func centralManagerDidUpdateState(_ central: CBCentralManager) {
        onStateUpdate?(central.state)
    }

    func centralManager(_ central: CBCentralManager,
                        didDiscover peripheral: CBPeripheral,
                        advertisementData: [String: Any],
                        rssi RSSI: NSNumber) {
        onDiscovery?(peripheral, advertisementData, RSSI)
    }

    func centralManager(_ central: CBCentralManager, didConnect peripheral: CBPeripheral) {
        completeConnect(uuid: peripheral.identifier, error: nil)
        onConnect?(peripheral)
    }

    func completeConnect(uuid: UUID, error: Error?) {
        lock.lock()
        let cont = connectConts[uuid]
        connectConts[uuid] = nil
        lock.unlock()
        if let error { cont?.resume(throwing: error) } else { cont?.resume() }
    }

    func centralManager(_ central: CBCentralManager,
                        didFailToConnect peripheral: CBPeripheral,
                        error: Error?) {
        completeConnect(uuid: peripheral.identifier, error: error ?? LEBLEError.connectionFailed(underlying: nil))
        onFailConnect?(peripheral, error)
    }

    func centralManager(_ central: CBCentralManager,
                        didDisconnectPeripheral peripheral: CBPeripheral,
                        error: Error?) {
        onDisconnect?(peripheral, error)
    }

    // MARK: - 各操作的挂起状态（key 为 peripheral UUID 或 "uuid:charUUID"）

    private let lock = NSLock()

    private var connectConts: [UUID: CheckedContinuation<Void, Error>] = [:]
    private var discoverConts: [UUID: CheckedContinuation<[CBService], Error>] = [:]
    private var charConts: [String: CheckedContinuation<[CBCharacteristic], Error>] = [:]
    private var readConts: [String: CheckedContinuation<Data, Error>] = [:]
    private var writeConts: [String: CheckedContinuation<Void, Error>] = [:]
    private var notifyConts: [String: [UUID: AsyncStream<Data>.Continuation]] = [:]
    private var notifyReadyConts: [String: CheckedContinuation<Void, Error>] = [:]

    // MARK: 注册 callback

    // A duplicate is rejected before issuing a second CoreBluetooth operation.
    private func register<K: Hashable, V>(_ c: CheckedContinuation<V, Error>,
                                          key: K, in table: inout [K: CheckedContinuation<V, Error>]) -> Bool {
        guard table[key] == nil else { return false }
        table[key] = c
        return true
    }

    func setConnectCont(_ c: CheckedContinuation<Void, Error>, for uuid: UUID) -> Bool {
        lock.lock()
        let registered = register(c, key: uuid, in: &connectConts)
        lock.unlock()
        if !registered { c.resume(throwing: LEBLEError.operationInProgress) }
        return registered
    }
    func setDiscoverCont(_ c: CheckedContinuation<[CBService], Error>, for uuid: UUID) -> Bool {
        lock.lock()
        let registered = register(c, key: uuid, in: &discoverConts)
        lock.unlock()
        if !registered { c.resume(throwing: LEBLEError.operationInProgress) }
        return registered
    }
    func setCharCont(_ c: CheckedContinuation<[CBCharacteristic], Error>, for uuid: UUID, service: CBService) -> Bool {
        lock.lock()
        let registered = register(c, key: key(uuid, service), in: &charConts)
        lock.unlock()
        if !registered { c.resume(throwing: LEBLEError.operationInProgress) }
        return registered
    }
    func setReadCont(_ c: CheckedContinuation<Data, Error>, for uuid: UUID, characteristic: CBCharacteristic) -> Bool {
        lock.lock()
        let registered = register(c, key: key(uuid, characteristic), in: &readConts)
        lock.unlock()
        if !registered { c.resume(throwing: LEBLEError.operationInProgress) }
        return registered
    }
    func setWriteCont(_ c: CheckedContinuation<Void, Error>, for uuid: UUID, characteristic: CBCharacteristic) -> Bool {
        lock.lock()
        let registered = register(c, key: key(uuid, characteristic), in: &writeConts)
        lock.unlock()
        if !registered { c.resume(throwing: LEBLEError.operationInProgress) }
        return registered
    }
    func setNotifyReadyCont(_ c: CheckedContinuation<Void, Error>, for uuid: UUID, characteristic: CBCharacteristic) -> Bool {
        lock.lock()
        let registered = register(c, key: key(uuid, characteristic), in: &notifyReadyConts)
        lock.unlock()
        if !registered { c.resume(throwing: LEBLEError.operationInProgress) }
        return registered
    }

    func setNotifyCont(_ c: AsyncStream<Data>.Continuation, for uuid: UUID, characteristic: CBCharacteristic, subscription: UUID) {
        lock.lock(); notifyConts[key(uuid, characteristic), default: [:]][subscription] = c; lock.unlock()
    }

    func removeNotifyCont(for uuid: UUID, characteristic: CBCharacteristic, subscription: UUID) {
        lock.lock()
        let k = key(uuid, characteristic)
        let continuation = notifyConts[k]?.removeValue(forKey: subscription)
        if notifyConts[k]?.isEmpty == true { notifyConts[k] = nil }
        lock.unlock()
        continuation?.finish()
    }

    /// Remove under lock, then resume outside it (stream termination reenters the bridge).
    func cleanup(uuid: UUID, error: Error = LEBLEError.disconnected(underlying: nil)) {
        lock.lock()
        let connect = connectConts.removeValue(forKey: uuid)
        let discover = discoverConts.removeValue(forKey: uuid)
        let prefix = uuid.uuidString + ":"
        let chars = charConts.filter { $0.key.hasPrefix(prefix) }
        let reads = readConts.filter { $0.key.hasPrefix(prefix) }
        let writes = writeConts.filter { $0.key.hasPrefix(prefix) }
        let ready = notifyReadyConts.filter { $0.key.hasPrefix(prefix) }
        let notifications = notifyConts.filter { $0.key.hasPrefix(prefix) }
        for k in chars.keys { charConts[k] = nil }
        for k in reads.keys { readConts[k] = nil }
        for k in writes.keys { writeConts[k] = nil }
        for k in ready.keys { notifyReadyConts[k] = nil }
        for k in notifications.keys { notifyConts[k] = nil }
        lock.unlock()
        connect?.resume(throwing: error)
        discover?.resume(throwing: error)
        chars.values.forEach { $0.resume(throwing: error) }
        reads.values.forEach { $0.resume(throwing: error) }
        writes.values.forEach { $0.resume(throwing: error) }
        ready.values.forEach { $0.resume(throwing: error) }
        notifications.values.forEach { $0.values.forEach { $0.finish() } }
    }

    /// 组合 key: "peripheralUUID:charUUID"
    private func key(_ uuid: UUID, _ attribute: AnyObject) -> String {
        "\(uuid.uuidString):\(ObjectIdentifier(attribute))"
    }

    // MARK: - CBPeripheralDelegate

    func peripheral(_ peripheral: CBPeripheral, didDiscoverServices error: Error?) {
        discoveredServices(uuid: peripheral.identifier, services: peripheral.services ?? [], error: error)
    }

    func discoveredServices(uuid: UUID, services: [CBService], error: Error?) {
        lock.lock()
        let cont = discoverConts[uuid]
        discoverConts[uuid] = nil
        lock.unlock()
        if let error {
            cont?.resume(throwing: error)
        } else {
            cont?.resume(returning: services)
        }
    }

    func peripheral(_ peripheral: CBPeripheral,
                    didDiscoverCharacteristicsFor service: CBService,
                    error: Error?) {
        lock.lock()
        let cont = charConts[key(peripheral.identifier, service)]
        charConts[key(peripheral.identifier, service)] = nil
        lock.unlock()
        if let error {
            cont?.resume(throwing: error)
        } else {
            cont?.resume(returning: service.characteristics ?? [])
        }
    }

    func peripheral(_ peripheral: CBPeripheral,
                    didUpdateValueFor characteristic: CBCharacteristic,
                    error: Error?) {
        updatedValue(uuid: peripheral.identifier, characteristic: characteristic, value: characteristic.value, error: error)
    }

    func updatedValue(uuid: UUID, characteristic: CBCharacteristic, value: Data?, error: Error?) {
        let k = key(uuid, characteristic)
        lock.lock()
        let readCont = readConts[k]
        readConts[k] = nil
        let notifyCont = Array(notifyConts[k, default: [:]].values)
        lock.unlock()

        if let error {
            readCont?.resume(throwing: error)
        } else if let value {
            readCont?.resume(returning: value)
            for cont in notifyCont {
                if case .dropped = cont.yield(value) {
                    cont.finish()
                    onStreamOverflow?(uuid)
                }
            }
        } else {
            readCont?.resume(throwing: LEBLEError.invalidData)
        }
    }

    func peripheral(_ peripheral: CBPeripheral,
                    didWriteValueFor characteristic: CBCharacteristic,
                    error: Error?) {
        completedWrite(uuid: peripheral.identifier, characteristic: characteristic, error: error)
    }

    func completedWrite(uuid: UUID, characteristic: CBCharacteristic, error: Error?) {
        lock.lock()
        let cont = writeConts[key(uuid, characteristic)]
        writeConts[key(uuid, characteristic)] = nil
        lock.unlock()
        if let error {
            cont?.resume(throwing: error)
        } else {
            cont?.resume()
        }
    }

    func peripheral(_ peripheral: CBPeripheral,
                    didUpdateNotificationStateFor characteristic: CBCharacteristic,
                    error: Error?) {
        notificationReady(uuid: peripheral.identifier, characteristic: characteristic,
                          error: error, isNotifying: characteristic.isNotifying)
    }
    func notificationReady(uuid: UUID, characteristic: CBCharacteristic, error: Error?, isNotifying: Bool) {
        let k = key(uuid, characteristic)
        lock.lock()
        let cont = notifyReadyConts.removeValue(forKey: k)
        let streams = (error != nil || !isNotifying) ? notifyConts.removeValue(forKey: k) : nil
        lock.unlock()
        if let error { cont?.resume(throwing: error) }
        else if !isNotifying { cont?.resume(throwing: LEBLEError.transportError(underlying: nil)) }
        else { cont?.resume() }
        streams?.values.forEach { $0.finish() }
    }

    func peripheralIsReady(toSendWriteWithoutResponse peripheral: CBPeripheral) {
        onWriteReady?(peripheral.identifier)
    }

}
