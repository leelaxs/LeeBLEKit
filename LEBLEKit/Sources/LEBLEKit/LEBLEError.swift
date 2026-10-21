import Foundation
import CoreBluetooth

/// BLE 操作错误类型
public enum LEBLEError: Error {
    case operationTimeout
    case bufferOverflow
    case unsupportedProtocol
    /// 相同设备/特征值已有同类操作，调用方应等待完成后重试
    case operationInProgress
    /// 蓝牙不可用（硬件不支持或系统关闭了蓝牙）
    case bluetoothUnavailable
    /// 扫描未就绪（蓝牙未上电，或未授权）
    case scanningNotReady
    /// 扫描超时（在指定时间内未发现匹配设备）
    case scanTimeout
    /// 连接失败，可附带底层错误
    case connectionFailed(underlying: Error?)
    /// 连接超时
    case connectionTimeout
    /// 已断开，可附带底层错误（nil 表示主动断开）
    case disconnected(underlying: Error?)
    /// 未找到指定服务
    case serviceNotFound(CBUUID)
    /// 未找到指定特征值
    case characteristicNotFound(CBUUID)
    /// 数据格式无效（帧校验失败、hex 解析失败等）
    case invalidData
    /// 可靠传输层错误，可附带底层错误
    case transportError(underlying: Error?)
}
