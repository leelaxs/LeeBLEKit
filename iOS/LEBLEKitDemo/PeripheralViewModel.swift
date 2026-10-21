import SwiftUI
import CoreBluetooth
import LEBLEKit

@MainActor
final class PeripheralViewModel: ObservableObject {
	// MARK: - 可配置 UUID
	@Published var serviceUUID: String = "FFF0"
	@Published var readCharUUID: String = "FFF1"
	@Published var writeCharUUID: String = "FFF2"
	@Published var notifyCharUUID: String = "FFF3"

	// MARK: - 可配置行为
	@Published var readReplyHex: String = "01 02 03"

	// MARK: - 状态
	@Published var state: CBManagerState = .unknown
	@Published var isAdvertising = false
	@Published var connectedCount: Int = 0
	@Published var lastWrittenData: String = ""
	@Published var log: [String] = []

	private let peripheral = LEPeripheralManager()

    @Published private(set) var isStarting = false
    private var subscribedCentrals: Set<UUID> = []
    private var stateTask: Task<Void, Never>?

    init() {
        stateTask = Task { [weak self, peripheral] in
            for await s in await peripheral.stateStream {
                self?.state = s
                if s != .poweredOn {
                    self?.isAdvertising = false
                    self?.subscribedCentrals.removeAll()
                    self?.connectedCount = 0
                }
            }
        }
    }
    deinit { stateTask?.cancel() }

	// MARK: - 广播控制
	func startAdvertising() {
        guard !isStarting else { return }
        isStarting = true
		Task {
            defer { isStarting = false }
			addLog("开始广播...")

			let serviceCBUUID = CBUUID(string: serviceUUID)
			let readCBUUID = CBUUID(string: readCharUUID)
			let writeCBUUID = CBUUID(string: writeCharUUID)
			let notifyCBUUID = CBUUID(string: notifyCharUUID)

			do {
                await peripheral.stopAdvertising()
				await peripheral.removeAllServices()

				let characteristics: [CharacteristicConfig] = [
					.readOnly(uuid: readCBUUID),
					.writable(uuid: writeCBUUID),
					.notifyOnly(uuid: notifyCBUUID)
				]

				try await peripheral.addService(uuid: serviceCBUUID, characteristics: characteristics)

                let reply = LEBLEUtils.data(hex: readReplyHex)
                peripheral.onReadRequest = { [weak self] char in
                    let uuid = char.uuid.uuidString
                    Task { @MainActor in self?.addLog("读请求: \(uuid)") }
                    return reply
                }
                peripheral.onWriteRequest = { [weak self] char, data in
                    let uuid = char.uuid.uuidString
                    let hex = LEBLEUtils.hexString(from: data)
                    Task { @MainActor in
                        self?.lastWrittenData = hex
                        self?.addLog("写请求 \(uuid): \(hex)")
                    }
                }
                peripheral.onSubscribe = { [weak self] central, _ in
                    let id = central.identifier
                    Task { @MainActor in
                        self?.subscribedCentrals.insert(id)
                        self?.connectedCount = self?.subscribedCentrals.count ?? 0
                    }
                }
                peripheral.onUnsubscribe = { [weak self] central, _ in
                    let id = central.identifier
                    Task { @MainActor in
                        self?.subscribedCentrals.remove(id)
                        self?.connectedCount = self?.subscribedCentrals.count ?? 0
                    }
                }

				try await peripheral.startAdvertising(localName: "LEBLEKitDemo", serviceUUIDs: [serviceCBUUID])
				isAdvertising = true
				addLog("✓ 广播已开始")
			} catch {
				addLog("✗ 广播失败: \(error)")
			}
		}
	}

	func stopAdvertising() {
		Task {
			await peripheral.stopAdvertising()
			isAdvertising = false
			addLog("广播已停止")
		}
	}

	// MARK: - 数据通知
	func sendNotify(_ hex: String) {
		Task {
			let notifyCBUUID = CBUUID(string: notifyCharUUID)
			guard let data = LEBLEUtils.data(hex: hex) else {
				addLog("无效的十六进制数据")
				return
			}
			do {
				try await peripheral.notify(data: data, for: notifyCBUUID)
				addLog("通知 \(notifyCharUUID): \(hex)")
			} catch {
				addLog("通知发送失败: \(error)")
			}
		}
	}

	// MARK: - 日志
	private func addLog(_ msg: String) {
		log.append("[\(DateFormatter.localizedString(from: Date(), dateStyle: .none, timeStyle: .medium))] \(msg)")
		if log.count > 100 { log.removeFirst() }
	}
}
