import Foundation

/// 帧解码结果
public enum DecodeResult: Sendable {
    /// 解码成功，携带 payload 数据
    case complete(Data)
    /// 数据尚未收完，需要等待更多字节
    case incomplete
    /// 帧格式错误（SOF 不匹配、CRC 校验失败等）
    case error(Error)
}

/// 帧协议接口——编码分包 / 解码组帧
///
/// 实现此协议即可自定义帧格式（包头、校验位等）。
public protocol FrameProtocol: Sendable {
    /// 将一段 payload 编码为若干帧（每帧不超过 MTU）
    /// - Parameters:
    ///   - payload: 待发送的完整数据
    ///   - mtu: BLE 通道单次最大写入长度
    /// - Returns: 编码后的帧数组
    func encode(_ payload: Data, mtu: Int) -> [Data]

    /// 解码一帧数据
    /// - Parameter frame: 接收到的原始帧字节
    /// - Returns: 解码结果（完整、不完整、错误）
    func decode(_ frame: Data) -> DecodeResult
}
