import Foundation
@preconcurrency import CoreBluetooth

/// BLE 管理器——库的主入口（Actor 保证线程安全）
///
/// 使用方式：
/// ```swift
/// let ble = LEBLEManager()
/// try await ble.waitUntilReady()
///
/// // 扫描
/// let result = try await ble.scan(for: .nameContains("Sensor"), timeout: 30)
///
/// // 或者扫描 + 连接一条龙
/// let conn = try await ble.scanAndConnect(for: .nameContains("Sensor"))
///
/// // 已知设备 UUID 直接连接
/// let conn = try await ble.connect(to: uuid, timeout: 10, services: nil)
/// ```
public actor LEBLEManager {

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

    // MARK: - 内部

    private let central: CBCentralManager
    private let bridge: DelegateBridge
    private let scanQueue = ScanQueue()
    private var activeConnections: [UUID: Connection] = [:]

    public init() {
        let br = DelegateBridge()
        self.bridge = br
        self.central = CBCentralManager(delegate: br, queue: nil)

        // 将 delegate 回调桥接到 actor 方法
        br.onStateUpdate = { [weak self] s in
            Task { await self?.handleStateUpdate(s) }
        }
        br.onDiscovery = { [weak self] p, adv, rssi in
            Task { await self?.handleDiscovery(p, adv, rssi) }
        }
        br.onWriteReady = { [weak self] id in Task { await self?.writeReady(id) } }
        br.onStreamOverflow = { [weak self] id in Task { await self?.overflow(id) } }
        br.onFailConnect = { [weak self] p, _ in
            Task { await self?.handleFailedConnection(p) }
        }
        br.onDisconnect = { [weak self] p, e in
            Task { await self?.handleDisconnect(p, e) }
        }
    }

    private func writeReady(_ id: UUID) async { await activeConnections[id]?.writeReady() }
    private func overflow(_ id: UUID) async { await activeConnections[id]?.disconnect() }

    private func handleStateUpdate(_ s: CBManagerState) {
        state = s
        states.update(s)
        readiness.update(s)
        if s != .poweredOn {
            central.stopScan()
            scanQueue.cancelAll()
            scanQueue.clearDiscovered()
        }
    }

    /// 收到广播 → 交给扫描队列匹配
    private func handleDiscovery(_ peripheral: CBPeripheral,
                                  _ advertisementData: [String: Any],
                                  _ rssi: NSNumber) {
        let result = ScanResult(
            id: peripheral.identifier,
            name: peripheral.name ?? (advertisementData[CBAdvertisementDataLocalNameKey] as? String),
            rssi: rssi.intValue,
            advertisementData: advertisementData
        )
        scanQueue.checkAndResolve(result)
        stopScanIfIdle()
    }

    /// 设备断开 → 转发给对应的 Connection
    private func handleDisconnect(_ peripheral: CBPeripheral, _ error: Error?) {
        if let conn = activeConnections[peripheral.identifier] {
            Task { await conn.handleDisconnect(error) }
        }
    }

    private func handleFailedConnection(_ peripheral: CBPeripheral) async {
        await activeConnections[peripheral.identifier]?.handleFailedConnection()
    }

    // MARK: - 扫描

    /// 扫描符合规则的设备
    /// - Parameters:
    ///   - rule: 匹配规则
    ///   - timeout: 该任务的超时（秒，默认 30）
    /// - Returns: 第一个匹配的 ScanResult
    public func scan(
        for rule: ConnectionRule,
        timeout: TimeInterval = 30
    ) async throws -> ScanResult {
        guard state == .poweredOn else { throw LEBLEError.scanningNotReady }

        let nanos = try timeoutNanoseconds(timeout)
        try Task.checkCancellation()
        let id = UUID()
        let timer = Task { [weak self] in
            do { try await Task.sleep(nanoseconds: nanos) } catch { return }
            await self?.finishScan(id: id, error: LEBLEError.scanTimeout)
        }
        defer { timer.cancel() }
        return try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { cont in
                let task = ScanQueue.Task(id: id, rule: rule, timeout: timeout, continuation: cont)
                if scanQueue.add(task) { startScanIfNeeded() }
            }
        } onCancel: {
            Task { await self.finishScan(id: id, error: CancellationError()) }
        }
    }

    /// 扫描 + 连接一条龙（包含服务发现）
    /// - Parameters:
    ///   - rule: 匹配规则
    ///   - timeout: 扫描超时（秒）
    ///   - services: 连接后要发现的服务 UUIDs（nil = 全部）
    /// - Returns: 已连接的 Connection（状态为 .connected，services 已填充）
    public func scanAndConnect(
        for rule: ConnectionRule,
        timeout: TimeInterval = 30,
        services: [CBUUID]? = nil
    ) async throws -> Connection {
        let result = try await scan(for: rule, timeout: timeout)
        return try await connect(to: result, timeout: 10, services: services)
    }

    /// 连接已知 ScanResult
    public func connect(
        to scanResult: ScanResult,
        timeout: TimeInterval = 10,
        services: [CBUUID]? = nil
    ) async throws -> Connection {
        try await connect(to: scanResult.id, timeout: timeout, services: services)
    }

    /// 通过 UUID 直接连接已知设备
    public func connect(
        to uuid: UUID,
        timeout: TimeInterval = 10,
        services: [CBUUID]? = nil
    ) async throws -> Connection {
        guard state == .poweredOn else { throw LEBLEError.scanningNotReady }

        guard activeConnections[uuid] == nil else { throw LEBLEError.operationInProgress }
        guard let peripheral = central.retrievePeripherals(withIdentifiers: [uuid]).first else {
            throw LEBLEError.connectionFailed(underlying: nil)
        }

        let connection = Connection(
            peripheral: peripheral,
            central: central,
            bridge: bridge,
            manager: self
        )
        activeConnections[uuid] = connection

        do {
            try await connection.connect(timeout: timeout, services: services)
            return connection
        } catch {
            await connection.disconnect()
            throw error
        }
    }

    /// 清理扫描发现缓存（不影响正在进行的扫描任务）
    public func clearDiscoveryCache() {
        scanQueue.clearDiscovered()
    }

    // MARK: - 内部扫描逻辑

    private func startScanIfNeeded() {
        guard !central.isScanning else { return }
        central.scanForPeripherals(withServices: nil, options: [
            CBCentralManagerScanOptionAllowDuplicatesKey: true
        ])
    }

    private func finishScan(id: UUID, error: Error) {
        scanQueue.remove(id: id, error: error)
        stopScanIfIdle()
    }

    private func stopScanIfIdle() {
        if !scanQueue.hasPendingTasks { central.stopScan() }
    }

    func removeConnection(_ uuid: UUID, connection: Connection) {
        if activeConnections[uuid] === connection { activeConnections[uuid] = nil }
    }
}
