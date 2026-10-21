import Foundation
@preconcurrency import CoreBluetooth

/// 扫描结果：封装一条广播数据，支持 Identifiable 用于 SwiftUI List
public struct ScanResult: @unchecked Sendable, Identifiable {
    /// 设备唯一标识（对应 CBPeripheral.identifier）
    public let id: UUID
    /// 设备名称，优先使用 peripheral.name
    public let name: String?
    /// 信号强度 (dBm)，越接近 0 越强
    public let rssi: Int
    /// 原始广播数据字典
    public let advertisementData: [String: Any]

    /// 从广播数据中提取 Service UUIDs
    public var serviceUUIDs: [CBUUID]? {
        advertisementData[CBAdvertisementDataServiceUUIDsKey] as? [CBUUID]
    }

    /// 从广播数据中提取厂商自定义数据
    public var manufacturerData: Data? {
        guard let raw = advertisementData[CBAdvertisementDataManufacturerDataKey] as? Data else {
            return nil
        }
        return raw
    }

    public init(id: UUID, name: String?, rssi: Int, advertisementData: [String: Any]) {
        self.id = id
        self.name = name
        self.rssi = rssi
        self.advertisementData = advertisementData
    }
}
