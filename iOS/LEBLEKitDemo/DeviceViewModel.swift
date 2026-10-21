import SwiftUI
import CoreBluetooth
import LEBLEKit

@MainActor
final class DeviceViewModel: ObservableObject {
    @Published var state: CBManagerState = .unknown
    @Published var discoveredDevices: [ScanResult] = []
    @Published var connectedDeviceName: String?
    @Published var lastReceivedData: String = ""
    @Published var log: [String] = []

    @Published private(set) var isConnecting = false
    @Published private(set) var isScanning = false
    private let ble = LEBLEManager()
    private var stateTask: Task<Void, Never>?
    private var connectTask: Task<Void, Never>?
    private var scanTask: Task<Void, Never>?
    private var connectionStateTask: Task<Void, Never>?
    private var notifications: [String: Task<Void, Never>] = [:]
    private var connection: Connection?
    private var packetizer: Packetizer?

    init() {
        stateTask = Task { [weak self, ble] in
            for await s in await ble.stateStream {
                guard !Task.isCancelled else { return }
                self?.state = s
                self?.addLog("Bluetooth: \(s == .poweredOn ? "ON" : "OFF")")
            }
        }
    }

    deinit {
        stateTask?.cancel(); scanTask?.cancel(); connectTask?.cancel(); connectionStateTask?.cancel()
        notifications.values.forEach { $0.cancel() }
    }

    func startScan() {
        guard !isScanning else { return }
        isScanning = true
        scanTask = Task {
            defer { isScanning = false }
            await ble.clearDiscoveryCache()
            let deadline = Date().addingTimeInterval(10)
            do {
                while !Task.isCancelled {
                    let remaining = deadline.timeIntervalSinceNow
                    guard remaining > 0 else { break }
                    let excluded = Set(discoveredDevices.map(\.id))
                    let result = try await ble.scan(for: .all([
                        .rssiGreaterThan(-100), .custom { !excluded.contains($0.id) }
                    ]), timeout: remaining)
                    discoveredDevices.append(result)
                    addLog("Found: \(result.name ?? "Unknown") RSSI:\(result.rssi)")
                }
            } catch LEBLEError.scanTimeout { addLog("Scan finished") }
            catch is CancellationError {}
            catch { addLog("Scan error: \(error)") }
        }
    }

    func connect(to device: ScanResult) {
        guard !isConnecting, connection == nil else { return }
        isConnecting = true
        connectTask = Task {
            defer { isConnecting = false }
            addLog("Connecting to \(device.name ?? "Unknown")...")
            do {
                let conn = try await ble.connect(to: device)
                guard !Task.isCancelled else { await conn.disconnect(); return }
                connection = conn
                connectedDeviceName = device.name ?? "Unknown"
                let svcs = await conn.services
                addLog("✓ Connected: \(svcs.count) services")
                addLog("Services: \(svcs.map { $0.uuid.uuidString })")

                connectionStateTask?.cancel()
                connectionStateTask = Task { [weak self] in
                    for await s in await conn.stateStream {
                        guard !Task.isCancelled, let self, self.connection === conn else { return }
                        if case .disconnected(let err) = s {
                            self.addLog("Disconnected: \(err?.localizedDescription ?? "manual")")
                            self.connectedDeviceName = nil
                            self.connection = nil
                            self.packetizer = nil
                            self.notifications.values.forEach { $0.cancel() }
                            self.notifications.removeAll()
                            return
                        }
                    }
                }
            } catch {
                addLog("✗ Connect failed: \(error)")
            }
        }
    }

    func disconnect() {
        connectTask?.cancel()
        Task {
            await connection?.disconnect()
        }
    }

    func readCharacteristic(_ uuid: String) {
        Task {
            guard let conn = connection else { return }
            let cuuid = CBUUID(string: uuid)
            do {
                // Find characteristic in services
                for service in await conn.services {
                    let chars = try await conn.discoverCharacteristics(nil, for: service)
                    if let char = chars.first(where: { $0.uuid == cuuid }) {
                        let data = try await conn.read(char)
                        let hex = LEBLEUtils.hexString(from: data)
                        lastReceivedData = hex
                        addLog("Read \(uuid): \(hex)")
                        return
                    }
                }
                addLog("Characteristic \(uuid) not found")
            } catch {
                addLog("Read error: \(error)")
            }
        }
    }

    func writeData(_ hex: String, to uuid: String) {
        Task {
            guard let conn = connection,
                  let data = LEBLEUtils.data(hex: hex) else {
                addLog("Invalid hex data")
                return
            }
            let cuuid = CBUUID(string: uuid)
            do {
                for service in await conn.services {
                    let chars = try await conn.discoverCharacteristics(nil, for: service)
                    if let char = chars.first(where: { $0.uuid == cuuid }) {
                        try await conn.write(data, to: char)
                        addLog("Write \(uuid): \(hex)")
                        return
                    }
                }
                addLog("Characteristic \(uuid) not found")
            } catch {
                addLog("Write error: \(error)")
            }
        }
    }

    func subscribeNotifications(_ uuid: String) {
        Task {
            guard let conn = connection else { return }
            let cuuid = CBUUID(string: uuid)
            do {
                for service in await conn.services {
                    let chars = try await conn.discoverCharacteristics(nil, for: service)
                    if let char = chars.first(where: { $0.uuid == cuuid }) {
                        let stream = await conn.subscribe(char)
                        addLog("Subscribed to \(uuid)")
                        notifications[uuid]?.cancel()
                        notifications[uuid] = Task { [weak self] in
                            for await data in stream {
                                guard !Task.isCancelled, let self, self.connection === conn else { return }
                                let hex = LEBLEUtils.hexString(from: data)
                                self.lastReceivedData = hex
                                self.addLog("Notify \(uuid): \(hex)")
                            }
                        }
                        return
                    }
                }
                addLog("Characteristic \(uuid) not found")
            } catch {
                addLog("Subscribe error: \(error)")
            }
        }
    }

    private func addLog(_ msg: String) {
        log.append("[\(DateFormatter.localizedString(from: Date(), dateStyle: .none, timeStyle: .medium))] \(msg)")
        if log.count > 100 { log.removeFirst() }
    }
}
