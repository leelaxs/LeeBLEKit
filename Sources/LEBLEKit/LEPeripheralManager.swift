import Foundation
@preconcurrency import CoreBluetooth

/// BLE 外设管理器——外设角色的入口（Actor 保证线程安全）
///
/// 使用方式：
/// ```swift
/// let peripheral = LEPeripheralManager()
/// try await peripheral.waitUntilReady()
///
/// // 添加服务
/// try await peripheral.addService(uuid: serviceUUID, characteristics: [...])
///
/// // 开始广播
/// try await peripheral.startAdvertising(localName: "MyDevice", serviceUUIDs: [serviceUUID])
///
/// // 收到读取请求时返回数据
/// peripheral.onReadRequest = { characteristic in
///     return someData
/// }
///
/// // 收到写入请求时处理数据
/// peripheral.onWriteRequest = { characteristic, data in
///     // 处理写入的数据
/// }
///
/// // 通知订阅的 Central
/// try await peripheral.notify(data: someData, for: characteristicUUID)
/// ```
public actor LEPeripheralManager {

    // MARK: - 状态

    /// 当前蓝牙状态
    public private(set) var state: CBManagerState = .unknown

    private let states = StateBroadcast<CBManagerState>(.unknown)
    private let readiness = Readiness()
    public var stateStream: AsyncStream<CBManagerState> { states.stream() }

    /// 等待蓝牙上电；超时及任务取消均会结束本次等待。
    public func waitUntilReady(timeout: TimeInterval = 10) async throws {
        try await readiness.wait(timeout: timeout)
    }

    private nonisolated let callbacks = PeripheralCallbacks()

    // MARK: - 数据交互回调

    /// 收到读取请求时的回调——返回要发送给 Central 的数据；返回 nil 则回复 ATT 错误
    public nonisolated var onReadRequest: (@Sendable (CBCharacteristic) -> Data?)? {
        get { callbacks.access { $0.read } }
        set { callbacks.access { $0.read = newValue } }
    }

    /// 收到写入请求时的回调
    public nonisolated var onWriteRequest: (@Sendable (CBCharacteristic, Data) -> Void)? {
        get { callbacks.access { $0.write } }
        set { callbacks.access { $0.write = newValue } }
    }

    /// Central 订阅了某个特征值时的回调
    public nonisolated var onSubscribe: (@Sendable (CBCentral, CBCharacteristic) -> Void)? {
        get { callbacks.access { $0.subscribe } }
        set { callbacks.access { $0.subscribe = newValue } }
    }

    /// Central 取消订阅时的回调
    public nonisolated var onUnsubscribe: (@Sendable (CBCentral, CBCharacteristic) -> Void)? {
        get { callbacks.access { $0.unsubscribe } }
        set { callbacks.access { $0.unsubscribe = newValue } }
    }

    // MARK: - 内部

    private let peripheralManager: CBPeripheralManager
    private let bridge: PeripheralDelegateBridge
    private var services: [CBMutableService] = []
    private var characteristics: [CBUUID: [CBMutableCharacteristic]] = [:]

    public init() {
        let br = PeripheralDelegateBridge()
        self.bridge = br
        self.peripheralManager = CBPeripheralManager(delegate: br, queue: nil)

        // 将 delegate 回调桥接到 actor 方法
        br.onStateUpdate = { [weak self] s in
            Task { await self?.handleStateUpdate(s) }
        }
        br.onReadRequest = { [weak self] char in
            self?.callbacks.read(char)
        }
        br.onWriteRequest = { [weak self] char, data in
            self?.onWriteRequest?(char, data)
        }
        br.onSubscribe = { [weak self] central, char in
            self?.onSubscribe?(central, char)
        }
        br.onUnsubscribe = { [weak self] central, char in
            self?.onUnsubscribe?(central, char)
        }
    }

    private func handleStateUpdate(_ s: CBManagerState) {
        state = s
        states.update(s)
        readiness.update(s)
    }

    // MARK: - 服务管理

    /// 添加一个包含若干特征值的服务
    /// - Parameters:
    ///   - uuid: 服务 UUID
    ///   - characteristics: 特征值配置列表
    public func addService(uuid: CBUUID, characteristics configs: [CharacteristicConfig]) async throws {
        guard state == .poweredOn else { throw LEBLEError.scanningNotReady }

        let service = CBMutableService(type: uuid, primary: true)
        var chars: [CBMutableCharacteristic] = []
        for config in configs {
            let char = config.makeCharacteristic()
            chars.append(char)
        }
        service.characteristics = chars

        try await withCheckedThrowingContinuation { (cont: CheckedContinuation<Void, Error>) in
            if bridge.setAddServiceCont(cont) { peripheralManager.add(service) }
        }
        self.services.append(service)
        for (char, config) in zip(chars, configs) {
            self.characteristics[char.uuid, default: []].append(char)
            if let initial = config.initialValue { callbacks.access { $0.values[ObjectIdentifier(char)] = initial } }
        }
    }

    /// 移除所有已注册的服务
    public func removeAllServices() {
        peripheralManager.removeAllServices()
        services.removeAll()
        characteristics.removeAll()
        callbacks.access { $0.values.removeAll() }
    }

    // MARK: - 广播

    /// 开始广播
    /// - Parameters:
    ///   - localName: 设备本地名称（可选，会出现在广播数据中）
    ///   - serviceUUIDs: 要广播的服务 UUIDs（可选）
    public func startAdvertising(localName: String? = nil, serviceUUIDs: [CBUUID]? = nil) async throws {
        guard !peripheralManager.isAdvertising else { return }
        guard state == .poweredOn else { throw LEBLEError.scanningNotReady }

        var advertisementData: [String: Any] = [:]
        if let localName {
            advertisementData[CBAdvertisementDataLocalNameKey] = localName
        }
        if let serviceUUIDs {
            advertisementData[CBAdvertisementDataServiceUUIDsKey] = serviceUUIDs
        }

        try await withCheckedThrowingContinuation { (cont: CheckedContinuation<Void, Error>) in
            if bridge.setStartAdvertisingCont(cont) { peripheralManager.startAdvertising(advertisementData) }
        }
    }

    /// 停止广播
    public func stopAdvertising() {
        peripheralManager.stopAdvertising()
    }

    // MARK: - 通知

    /// 向订阅了指定特征值的 Central 发送通知
    /// - Parameters:
    ///   - data: 要发送的数据
    ///   - characteristicUUID: 特征值 UUID
    public func notify(data: Data, for characteristicUUID: CBUUID) async throws {
        guard let candidates = characteristics[characteristicUUID] else {
            throw LEBLEError.characteristicNotFound(characteristicUUID)
        }
        guard candidates.count == 1, let characteristic = candidates.first else { throw LEBLEError.invalidData }
        guard state == .poweredOn else { throw LEBLEError.scanningNotReady }
        let success = peripheralManager.updateValue(data, for: characteristic, onSubscribedCentrals: nil)
        if !success {
            throw LEBLEError.transportError(underlying: nil)
        }
    }
}
