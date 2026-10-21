import Foundation
@preconcurrency import CoreBluetooth

/// 连接——封装单个 BLE 设备连接的生命周期
///
/// 使用方式：
/// ```swift
/// let conn = try await bleManager.scanAndConnect(for: .nameContains("Target"))
/// let svcs = try await conn.discoverServices(nil)
/// let data = try await conn.read(someChar)
/// try await conn.write(data, to: someChar)
/// let stream = conn.subscribe(notifyChar)
/// conn.disconnect()
/// ```
public actor Connection {

    /// 连接状态
    public enum State: Sendable {
        case connecting
        case connected
        case disconnecting
        case disconnected(Error?)  // nil = 主动断开
    }

    public private(set) var state: State = .disconnected(nil)
    public private(set) var identifier: UUID
    public private(set) var name: String?
    public private(set) var services: [CBService] = []

    /// 重连策略，默认不重连
    public var retryPolicy: RetryPolicy = FixedRetryPolicy.noRetry()

    // MARK: - 内部属性

    private let transport: any ConnectionTransport
    private let bridge: DelegateBridge
    private weak var manager: LEBLEManager?
    private var connectServices: [CBUUID]?
    private var retryAttempt = 0
    private var reconnectTask: Task<Void, Never>?
    private var connectTimer: Task<Void, Never>?
    private var generation = UUID()
    private var manuallyDisconnected = false
    private var operations: Set<UUID> = []
    private var writeReadyWaiters: [UUID: OneShot<Void>] = [:]
    private var withoutResponseWriting = false
    var operationTimeout: TimeInterval = 10
    private let states = StateBroadcast<State>(.disconnected(nil))
    public var stateStream: AsyncStream<State> { states.stream() }

    init(peripheral: CBPeripheral, central: CBCentralManager,
         bridge: DelegateBridge, manager: LEBLEManager) {
        self.transport = CoreBluetoothTransport(peripheral: peripheral, central: central)
        self.bridge = bridge
        self.manager = manager
        self.identifier = peripheral.identifier
        self.name = peripheral.name
        peripheral.delegate = bridge
    }

    init(transport: any ConnectionTransport, bridge: DelegateBridge) {
        self.transport = transport
        self.bridge = bridge
        self.identifier = transport.identifier
        self.name = transport.name
    }

    public func setRetryPolicy(_ policy: any RetryPolicy) { retryPolicy = policy }

    // MARK: - 连接

    /// 建立连接并（可选）发现服务
    func connect(timeout: TimeInterval = 10,
                 services: [CBUUID]? = nil) async throws {
        let nanos = try timeoutNanoseconds(timeout)
        try Task.checkCancellation()
        guard case .disconnected = state else { throw LEBLEError.operationInProgress }
        guard !manuallyDisconnected else { throw LEBLEError.disconnected(underlying: nil) }
        connectServices = services
        let token = UUID()
        generation = token
        setState(.connecting)
        connectTimer = Task { [weak self] in
            do { try await Task.sleep(nanoseconds: nanos) } catch { return }
            await self?.expireConnect(token)
        }
        defer { connectTimer?.cancel(); connectTimer = nil }
        do {
            try await withTaskCancellationHandler {
                try await withCheckedThrowingContinuation { (cont: CheckedContinuation<Void, Error>) in
                    if bridge.setConnectCont(cont, for: identifier) { transport.connect() }
                }
                try Task.checkCancellation()
                self.services = try await discoverServices(services)
                try Task.checkCancellation()
                guard generation == token, !manuallyDisconnected else {
                    throw LEBLEError.disconnected(underlying: nil)
                }
                self.name = transport.name ?? name
                setState(.connected)
                retryAttempt = 0
            } onCancel: {
                Task { await self.cancelConnect(token) }
            }
        } catch {
            if generation == token {
                bridge.cleanup(uuid: identifier, error: error)
                transport.cancel()
                setState(.disconnected(error))
            }
            throw error
        }
    }

    private func expireConnect(_ token: UUID) {
        guard generation == token, case .connecting = state else { return }
        bridge.cleanup(uuid: identifier, error: LEBLEError.connectionTimeout)
        transport.cancel()
    }

    private func cancelConnect(_ token: UUID) {
        guard generation == token, case .connecting = state else { return }
        bridge.cleanup(uuid: identifier, error: CancellationError())
        transport.cancel()
    }

    private func requireConnected() throws {
        guard transport.isConnected, !manuallyDisconnected else {
            throw LEBLEError.disconnected(underlying: nil)
        }
    }

    /// CoreBluetooth cannot cancel an individual ATT request. End the connection on
    /// cancellation/timeout so a late callback cannot complete a subsequent request.
    private func operation<T>(_ body: (CheckedContinuation<T, Error>) -> Void) async throws -> T {
        try Task.checkCancellation()
        let nanos = try timeoutNanoseconds(operationTimeout)
        let token = UUID()
        operations.insert(token)
        let timer = Task { [weak self] in
            do { try await Task.sleep(nanoseconds: nanos) } catch { return }
            await self?.abortOperation(token, error: LEBLEError.operationTimeout)
        }
        defer { timer.cancel(); operations.remove(token) }
        return try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation(body)
        } onCancel: {
            Task { await self.abortOperation(token, error: CancellationError()) }
        }
    }

    private func abortOperation(_ token: UUID, error: Error) {
        guard operations.contains(token) else { return }
        bridge.cleanup(uuid: identifier, error: error)
        failWriteWaiters(error)
        disconnect()
    }

    func writeReady() {
        guard transport.canSendWithoutResponse else { return }
        let waiters = writeReadyWaiters.values
        writeReadyWaiters.removeAll()
        waiters.forEach { $0.resolve(.success(())) }
    }

    private func failWriteWaiters(_ error: Error) {
        let waiters = writeReadyWaiters.values
        writeReadyWaiters.removeAll()
        waiters.forEach { $0.resolve(.failure(error)) }
    }

    // MARK: - 服务发现

    /// 发现服务
    public func discoverServices(_ uuids: [CBUUID]?) async throws -> [CBService] {
        try requireConnected()
        return try await operation { cont in
            if bridge.setDiscoverCont(cont, for: identifier) { transport.discoverServices(uuids) }
        }
    }

    /// 发现指定服务下的特征值
    public func discoverCharacteristics(
        _ uuids: [CBUUID]?,
        for service: CBService
    ) async throws -> [CBCharacteristic] {
        try requireConnected()
        return try await operation { cont in
            if bridge.setCharCont(cont, for: identifier, service: service) {
                transport.discoverCharacteristics(uuids, for: service)
            }
        }
    }

    // MARK: - 读写

    /// 读取特征值
    public func read(_ characteristic: CBCharacteristic) async throws -> Data {
        try requireConnected()
        guard characteristic.properties.contains(.read) else { throw LEBLEError.invalidData }
        return try await operation { cont in
            if bridge.setReadCont(cont, for: identifier, characteristic: characteristic) { transport.read(characteristic) }
        }
    }

    /// 写入特征值
    /// - Parameter type: 默认 .withResponse 即带应答写入
    public func write(
        _ data: Data,
        to characteristic: CBCharacteristic,
        type: CBCharacteristicWriteType = .withResponse
    ) async throws {
        try requireConnected()
        try Task.checkCancellation()
        let required: CBCharacteristicProperties = type == .withResponse ? .write : .writeWithoutResponse
        guard characteristic.properties.contains(required),
              data.count <= transport.maximumWriteLength(for: type) else { throw LEBLEError.invalidData }
        if type == .withoutResponse {
            guard !withoutResponseWriting else { throw LEBLEError.operationInProgress }
            withoutResponseWriting = true
            defer { withoutResponseWriting = false }
            if !transport.canSendWithoutResponse {
                let id = UUID()
                let waiter = OneShot<Void>()
                writeReadyWaiters[id] = waiter
                defer { writeReadyWaiters[id] = nil }
                try await operation { waiter.install($0) }
            }
            try requireConnected()
            try Task.checkCancellation()
            transport.write(data, to: characteristic, type: .withoutResponse)
        } else {
            try await operation { (cont: CheckedContinuation<Void, Error>) in
                if bridge.setWriteCont(cont, for: identifier, characteristic: characteristic) {
                    transport.write(data, to: characteristic, type: .withResponse)
                }
            }
        }
    }

    // MARK: - 通知订阅

    /// 订阅特征值的通知（返回 AsyncStream 持续接收）
    public func subscribe(
        _ characteristic: CBCharacteristic
    ) -> AsyncStream<Data> {
        guard transport.isConnected, !manuallyDisconnected else {
            return AsyncStream { $0.finish() }
        }
        let (stream, _) = notificationStream(characteristic)
        transport.notify(true, for: characteristic)
        return stream
    }

    private func notificationStream(_ characteristic: CBCharacteristic) -> (AsyncStream<Data>, UUID) {
        let id = identifier
        let br = bridge
        let subscription = UUID()
        let stream = AsyncStream<Data>(bufferingPolicy: .bufferingOldest(64)) { continuation in
            br.setNotifyCont(continuation, for: id, characteristic: characteristic, subscription: subscription)
            continuation.onTermination = { _ in
                br.removeNotifyCont(for: id, characteristic: characteristic, subscription: subscription)
            }
        }
        return (stream, subscription)
    }

    /// Used by Packetizer: notification acknowledgement precedes the first write.
    func subscribeReady(_ characteristic: CBCharacteristic) async throws -> AsyncStream<Data> {
        try requireConnected()
        guard !characteristic.properties.intersection([.notify, .indicate]).isEmpty else { throw LEBLEError.invalidData }
        let (stream, subscription) = notificationStream(characteristic)
        do {
            if !characteristic.isNotifying {
                try await operation { (cont: CheckedContinuation<Void, Error>) in
                    if bridge.setNotifyReadyCont(cont, for: identifier, characteristic: characteristic) {
                        transport.notify(true, for: characteristic)
                    }
                }
            }
            return stream
        } catch {
            bridge.removeNotifyCont(for: identifier, characteristic: characteristic, subscription: subscription)
            throw error
        }
    }

    // MARK: - MTU

    /// 最大写入长度（withResponse 模式）
    public var maximumWriteLength: Int {
        transport.maximumWriteLength
    }

    // MARK: - 断开连接

    /// 主动断开
    public func disconnect() {
        manuallyDisconnected = true
        generation = UUID()
        reconnectTask?.cancel()
        reconnectTask = nil
        connectTimer?.cancel()
        bridge.cleanup(uuid: identifier)
        failWriteWaiters(LEBLEError.disconnected(underlying: nil))
        services = []
        setState(.disconnecting)
        transport.cancel()
        setState(.disconnected(nil))
        // Keep the manager entry until CoreBluetooth acknowledges cancellation.
        if transport.isDisconnected { cleanup() }
    }

    private func setState(_ newState: State) {
        state = newState
        states.update(newState)
    }

    func handleDisconnect(_ error: Error?) {
        let wasConnecting: Bool
        if case .connecting = state { wasConnecting = true } else { wasConnecting = false }
        bridge.cleanup(uuid: identifier, error: LEBLEError.disconnected(underlying: error))
        failWriteWaiters(LEBLEError.disconnected(underlying: error))
        services = []
        setState(.disconnected(error))
        // A connect in progress handles its own failure and retry scheduling.
        if wasConnecting && !manuallyDisconnected { return }
        guard !manuallyDisconnected, error != nil else { cleanup(); return }
        scheduleReconnect()
    }

    /// A cancelled pending connection may finish with didFailToConnect instead of didDisconnect.
    func handleFailedConnection() {
        if manuallyDisconnected { cleanup() }
    }

    private func cleanup() {
        bridge.cleanup(uuid: identifier)
        Task { await manager?.removeConnection(identifier, connection: self) }
    }

    private func scheduleReconnect() {
        guard !manuallyDisconnected,
              let delay = retryPolicy.nextDelay(afterAttempt: retryAttempt),
              let nanos = try? timeoutNanoseconds(delay) else { cleanup(); return }
        retryAttempt += 1
        reconnectTask?.cancel()
        let token = UUID()
        generation = token
        reconnectTask = Task { [weak self] in
            do { try await Task.sleep(nanoseconds: nanos) } catch { return }
            await self?.attemptReconnect(token)
        }
    }

    private func attemptReconnect(_ token: UUID) async {
        guard generation == token, !manuallyDisconnected, !Task.isCancelled else { return }
        do {
            try await connect(timeout: 10, services: connectServices)
        } catch {
            if !manuallyDisconnected && !Task.isCancelled { scheduleReconnect() }
        }
    }
}
