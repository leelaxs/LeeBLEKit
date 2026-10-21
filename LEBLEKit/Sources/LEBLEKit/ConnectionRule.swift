import Foundation
@preconcurrency import CoreBluetooth

/// 连接规则——支持组合（AND/OR/NOT）匹配扫描结果
///
/// ```swift
/// // 名称包含 "Sensor" 且 RSSI > -60
/// let rule = ConnectionRule.all([
///     .nameContains("Sensor"),
///     .rssiGreaterThan(-60)
/// ])
/// ```
public struct ConnectionRule: Sendable {

    /// 规则算子——使用 indirect 支持递归组合
    indirect enum Operator: Sendable {
        /// 名称包含指定字符串（不区分大小写）
        case nameContains(String)
        /// 名称完全匹配（不区分大小写）
        case nameIs(String)
        /// 广播的 Service UUIDs 包含所有指定 UUID
        case serviceUUIDs([CBUUID])
        /// 信号强度大于指定值
        case rssiGreaterThan(Int)
        /// 厂商自定义数据前缀匹配（可选偏移）
        case manufacturerData(prefix: Data, at: Int?)
        /// 自定义匹配闭包
        case custom(@Sendable (ScanResult) -> Bool)
        /// AND 组合——所有子规则均满足
        case all([ConnectionRule])
        /// OR 组合——任一子规则满足
        case any([ConnectionRule])
        /// NOT 取反
        case not(ConnectionRule)
    }

    let op: Operator

    init(_ op: Operator) {
        self.op = op
    }

    /// 评测一个扫描结果是否匹配此规则
    public func matches(_ result: ScanResult) -> Bool {
        switch op {
        case .nameContains(let s):
            return result.name?.localizedCaseInsensitiveContains(s) ?? false
        case .nameIs(let s):
            return result.name?.caseInsensitiveCompare(s) == .orderedSame
        case .serviceUUIDs(let uuids):
            guard let advUUIDs = result.serviceUUIDs else { return false }
            return uuids.allSatisfy { advUUIDs.contains($0) }
        case .rssiGreaterThan(let dbm):
            return result.rssi > dbm
        case .manufacturerData(let prefix, let offset):
            guard let data = result.manufacturerData else { return false }
            let start = max(0, offset ?? 0)
            guard start <= data.count, prefix.count <= data.count - start else { return false }
            return Data(data.dropFirst(start).prefix(prefix.count)) == prefix
        case .custom(let predicate):
            return predicate(result)
        case .all(let rules):
            return rules.allSatisfy { $0.matches(result) }
        case .any(let rules):
            return rules.contains { $0.matches(result) }
        case .not(let rule):
            return !rule.matches(result)
        }
    }
}

// MARK: - 工厂方法

extension ConnectionRule {

    public static func nameContains(_ s: String) -> ConnectionRule {
        ConnectionRule(.nameContains(s))
    }

    public static func nameIs(_ s: String) -> ConnectionRule {
        ConnectionRule(.nameIs(s))
    }

    public static func serviceUUIDs(_ uuids: [CBUUID]) -> ConnectionRule {
        ConnectionRule(.serviceUUIDs(uuids))
    }

    public static func rssiGreaterThan(_ dbm: Int) -> ConnectionRule {
        ConnectionRule(.rssiGreaterThan(dbm))
    }

    public static func manufacturerData(prefix: Data, at offset: Int? = nil) -> ConnectionRule {
        ConnectionRule(.manufacturerData(prefix: prefix, at: offset))
    }

    public static func custom(_ predicate: @escaping @Sendable (ScanResult) -> Bool) -> ConnectionRule {
        ConnectionRule(.custom(predicate))
    }

    /// AND 组合——所有子规则都满足才算匹配
    public static func all(_ rules: [ConnectionRule]) -> ConnectionRule {
        ConnectionRule(.all(rules))
    }

    /// OR 组合——任一子规则满足即匹配
    public static func any(_ rules: [ConnectionRule]) -> ConnectionRule {
        ConnectionRule(.any(rules))
    }

    /// NOT 取反
    public static func not(_ rule: ConnectionRule) -> ConnectionRule {
        ConnectionRule(.not(rule))
    }
}
