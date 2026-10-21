import Foundation
@preconcurrency import CoreBluetooth

/// 外设委托桥接——将 CBPeripheralManagerDelegate 回调桥接到 async/await 世界
///
/// 职责：
/// 1. 接收 CBPeripheralManagerDelegate 事件，转发给 LEPeripheralManager actor
/// 2. 管理各操作的 CheckedContinuation，在 delegate 回调中 resume
/// 3. 所有 continuation 操作由 NSLock 保护，确保线程安全
///
/// 注意：此类型标注了 @unchecked Sendable，因为内部用 NSLock 保证线程安全，
/// 但持有的 CBPeripheralManager 等对象不是 Sendable 的。
final class PeripheralDelegateBridge: NSObject, CBPeripheralManagerDelegate, @unchecked Sendable {

    // MARK: - Peripheral 层回调（转发给 LEPeripheralManager actor）

    typealias StateHandler = @Sendable (CBManagerState) -> Void
    typealias ReadRequestHandler = @Sendable (CBCharacteristic) -> Data?
    typealias WriteRequestHandler = @Sendable (CBCharacteristic, Data) -> Void
    typealias SubscribeHandler = @Sendable (CBCentral, CBCharacteristic) -> Void

    var onStateUpdate: StateHandler?
    var onReadRequest: ReadRequestHandler?
    var onWriteRequest: WriteRequestHandler?
    var onSubscribe: SubscribeHandler?
    var onUnsubscribe: SubscribeHandler?

    // MARK: - CBPeripheralManagerDelegate

    func peripheralManagerDidUpdateState(_ peripheral: CBPeripheralManager) {
        onStateUpdate?(peripheral.state)

        if peripheral.state == .poweredOn {
            lock.lock()
            let cont = readyCont
            readyCont = nil
            lock.unlock()
            cont?.resume()
        }
    }

    func peripheralManagerDidStartAdvertising(_ peripheral: CBPeripheralManager, error: Error?) {
        lock.lock()
        let cont = startAdvertisingCont
        startAdvertisingCont = nil
        lock.unlock()
        if let error {
            cont?.resume(throwing: error)
        } else {
            cont?.resume()
        }
    }

    func peripheralManager(_ peripheral: CBPeripheralManager, didAdd service: CBService, error: Error?) {
        lock.lock()
        let cont = addServiceCont
        addServiceCont = nil
        lock.unlock()
        if let error {
            cont?.resume(throwing: error)
        } else {
            cont?.resume()
        }
    }

    func peripheralManager(_ peripheral: CBPeripheralManager, didReceiveRead request: CBATTRequest) {
        handleRead(characteristic: request.characteristic, offset: request.offset) { value, result in
            request.value = value
            peripheral.respond(to: request, withResult: result)
        }
    }

    func handleRead(characteristic: CBCharacteristic, offset: Int,
                    respond: (Data?, CBATTError.Code) -> Void) {
        guard let value = onReadRequest?(characteristic) else {
            respond(nil, .unlikelyError)
            return
        }
        guard offset >= 0, offset <= value.count else {
            respond(nil, .invalidOffset)
            return
        }
        respond(Data(value.dropFirst(offset)), .success)
    }

    struct WriteRequest {
        let characteristic: CBCharacteristic
        let value: Data?
        let offset: Int
    }

    func peripheralManager(_ peripheral: CBPeripheralManager, didReceiveWrite requests: [CBATTRequest]) {
        guard let first = requests.first else { return }
        handleWrites(requests.map { WriteRequest(characteristic: $0.characteristic, value: $0.value, offset: $0.offset) }) { result in
            peripheral.respond(to: first, withResult: result)
        }
    }

    func handleWrites(_ requests: [WriteRequest], respond: (CBATTError.Code) -> Void) {
        guard !requests.isEmpty else { return }
        guard let handler = onWriteRequest else { respond(.writeNotPermitted); return }
        // This API delivers complete values, so partial-offset writes are explicitly rejected.
        guard requests.allSatisfy({ $0.offset == 0 }) else { respond(.invalidOffset); return }
        guard requests.allSatisfy({ $0.value != nil }) else { respond(.invalidAttributeValueLength); return }
        for request in requests { handler(request.characteristic, request.value!) }
        respond(.success)
    }

    func peripheralManager(_ peripheral: CBPeripheralManager,
                           central: CBCentral,
                           didSubscribeTo characteristic: CBCharacteristic) {
        onSubscribe?(central, characteristic)
    }

    func peripheralManager(_ peripheral: CBPeripheralManager,
                           central: CBCentral,
                           didUnsubscribeFrom characteristic: CBCharacteristic) {
        onUnsubscribe?(central, characteristic)
    }

    func peripheralManagerIsReady(toUpdateSubscribers peripheral: CBPeripheralManager) {
        // 暂时空实现，后续可根据需要扩展
    }

    // MARK: - 各操作的挂起状态

    private let lock = NSLock()

    private var startAdvertisingCont: CheckedContinuation<Void, Error>?
    private var addServiceCont: CheckedContinuation<Void, Error>?
    private var readyCont: CheckedContinuation<Void, Error>?

    // MARK: 注册 callback

    func setStartAdvertisingCont(_ c: CheckedContinuation<Void, Error>) -> Bool {
        lock.lock()
        guard startAdvertisingCont == nil else {
            lock.unlock()
            c.resume(throwing: LEBLEError.operationInProgress)
            return false
        }
        startAdvertisingCont = c
        lock.unlock()
        return true
    }

    func setAddServiceCont(_ c: CheckedContinuation<Void, Error>) -> Bool {
        lock.lock()
        guard addServiceCont == nil else {
            lock.unlock()
            c.resume(throwing: LEBLEError.operationInProgress)
            return false
        }
        addServiceCont = c
        lock.unlock()
        return true
    }

    func setReadyCont(_ c: CheckedContinuation<Void, Error>) {
        lock.lock(); readyCont = c; lock.unlock()
    }
}
