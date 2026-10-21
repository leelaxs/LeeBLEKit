import Foundation
@preconcurrency import CoreBluetooth

/// BLE 外设特征值配置——纯值类型，描述一个 GATT Characteristic 的元数据
public struct CharacteristicConfig: Sendable {

	/// 特征值 UUID
	public let uuid: CBUUID
	/// 特征值属性（read / write / notify 等）
	public let properties: CBCharacteristicProperties
	/// 特征值权限（readable / writeable 等）
	public let permissions: CBAttributePermissions
	/// 初始值，nil 表示无初始值
	public let initialValue: Data?

	public init(
		uuid: CBUUID,
		properties: CBCharacteristicProperties,
		permissions: CBAttributePermissions,
		initialValue: Data? = nil
	) {
		self.uuid = uuid
		self.properties = properties
		self.permissions = permissions
		self.initialValue = initialValue
	}
    /// CoreBluetooth caches non-nil values as static read-only characteristics.
    func makeCharacteristic() -> CBMutableCharacteristic {
        let dynamic = properties != .read
        return CBMutableCharacteristic(type: uuid, properties: properties,
            value: dynamic ? nil : initialValue, permissions: permissions)
    }

}

// MARK: - 便捷工厂方法

extension CharacteristicConfig {

	/// 只读特征值：read 属性 + readable 权限
	public static func readOnly(uuid: CBUUID, value: Data? = nil) -> Self {
		Self(
			uuid: uuid,
			properties: .read,
			permissions: .readable,
			initialValue: value
		)
	}

	/// 可写特征值：write 属性 + writeable 权限
	public static func writable(uuid: CBUUID) -> Self {
		Self(
			uuid: uuid,
			properties: .write,
			permissions: .writeable,
			initialValue: nil
		)
	}

	/// 仅通知特征值：notify 属性 + readable 权限（notify 需要 readable 权限）
	public static func notifyOnly(uuid: CBUUID) -> Self {
		Self(
			uuid: uuid,
			properties: .notify,
			permissions: .readable,
			initialValue: nil
		)
	}

	/// 读写通知特征值：read + write + notify 属性，readable + writeable 权限
	public static func readWriteNotify(uuid: CBUUID, value: Data? = nil) -> Self {
		Self(
			uuid: uuid,
			properties: [.read, .write, .notify],
			permissions: [.readable, .writeable],
			initialValue: value
		)
	}
}
