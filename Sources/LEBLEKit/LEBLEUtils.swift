import Foundation

/// BLE 工具类——hex 转换 / 字符串与 Data 互转 / 字节截取 / 进制转换 / 校验和
public enum LEBLEUtils {

    // MARK: - Hex 转换

    /// Data → Hex 字符串
    /// - Parameters:
    ///   - data: 原始数据
    ///   - separator: 分隔符（默认空格）
    /// - Returns: 如 "AA BB CC"
    public static func hexString(from data: Data, separator: String = " ") -> String {
        data.map { String(format: "%02X", $0) }.joined(separator: separator)
    }

    /// Hex 字符串 → Data
    /// - Parameter hex: 支持空格、横线、下划线分隔
    /// - Returns: 解析失败返回 nil
    public static func data(hex: String) -> Data? {
        let hex = hex.replacingOccurrences(of: " ", with: "")
                         .replacingOccurrences(of: "-", with: "")
                         .replacingOccurrences(of: "_", with: "")
        guard hex.count % 2 == 0 else { return nil }
        var bytes = [UInt8]()
        var index = hex.startIndex
        while index < hex.endIndex {
            let next = hex.index(index, offsetBy: 2)
            guard let byte = UInt8(hex[index..<next], radix: 16) else { return nil }
            bytes.append(byte)
            index = next
        }
        return Data(bytes)
    }

    // MARK: - 字符串转换

    /// String → Data
    public static func data(from string: String, encoding: String.Encoding = .utf8) -> Data {
        string.data(using: encoding) ?? Data()
    }

    /// Data → String
    public static func string(from data: Data, encoding: String.Encoding = .utf8) -> String? {
        String(data: data, encoding: encoding)
    }

    // MARK: - 字节截取

    /// 按范围截取 Data
    public static func subdata(of data: Data, range: Range<Int>) -> Data {
        let lower = max(0, range.lowerBound)
        let upper = min(data.count, range.upperBound)
        guard lower < upper else { return Data() }
        return data.subdata(in: (data.startIndex + lower)..<(data.startIndex + upper))
    }

    /// 按偏移 + 长度截取 Data
    public static func subdata(of data: Data, from offset: Int, length: Int) -> Data {
        guard length >= 0 else { return Data() }
        let (end, overflow) = offset.addingReportingOverflow(length)
        guard !overflow else { return Data() }
        return subdata(of: data, range: offset..<end)
    }

    /// 从偏移量截取到末尾
    public static func subdata(of data: Data, from offset: Int) -> Data {
        guard offset <= data.count else { return Data() }
        return subdata(of: data, range: offset..<data.count)
    }

    // MARK: - 字节读取（边界安全）

    /// 读取 UInt8
    public static func readUInt8(from data: Data, at offset: Int) -> UInt8? {
        guard offset >= 0, offset < data.count else { return nil }
        return data[data.startIndex + offset]
    }

    /// 读取 UInt16（小端）
    public static func readUInt16LE(from data: Data, at offset: Int) -> UInt16? {
        guard offset >= 0, data.count > 1, offset < data.count - 1 else { return nil }
        return UInt16(data[data.startIndex + offset]) | (UInt16(data[data.startIndex + offset + 1]) << 8)
    }

    /// 读取 UInt16（大端）
    public static func readUInt16BE(from data: Data, at offset: Int) -> UInt16? {
        guard offset >= 0, data.count > 1, offset < data.count - 1 else { return nil }
        return (UInt16(data[data.startIndex + offset]) << 8) | UInt16(data[data.startIndex + offset + 1])
    }

    /// 读取 UInt32（小端）
    public static func readUInt32LE(from data: Data, at offset: Int) -> UInt32? {
        guard offset >= 0, data.count > 3, offset < data.count - 3 else { return nil }
        return UInt32(data[data.startIndex + offset])
            | (UInt32(data[data.startIndex + offset + 1]) << 8)
            | (UInt32(data[data.startIndex + offset + 2]) << 16)
            | (UInt32(data[data.startIndex + offset + 3]) << 24)
    }

    /// 读取 UInt32（大端）
    public static func readUInt32BE(from data: Data, at offset: Int) -> UInt32? {
        guard offset >= 0, data.count > 3, offset < data.count - 3 else { return nil }
        return (UInt32(data[data.startIndex + offset]) << 24)
            | (UInt32(data[data.startIndex + offset + 1]) << 16)
            | (UInt32(data[data.startIndex + offset + 2]) << 8)
            | UInt32(data[data.startIndex + offset + 3])
    }

    // MARK: - 二进制字符串

    /// 单字节 → 8 位二进制字符串
    public static func binaryString(from byte: UInt8) -> String {
        let raw = String(byte, radix: 2)
        let padded = String(repeating: "0", count: max(0, 8 - raw.count)) + raw
        return padded
    }

    /// Data → 二进制字符串
    public static func binaryString(from data: Data, separator: String = " ") -> String {
        data.map { binaryString(from: $0) }.joined(separator: separator)
    }

    // MARK: - 校验

    /// Modbus CRC-16
    public static func crc16(_ data: Data) -> UInt16 {
        var crc: UInt16 = 0xFFFF
        for byte in data {
            crc ^= UInt16(byte)
            for _ in 0..<8 {
                if (crc & 0x0001) != 0 {
                    crc = (crc >> 1) ^ 0xA001
                } else {
                    crc >>= 1
                }
            }
        }
        return crc
    }

    /// CRC-8
    public static func crc8(_ data: Data) -> UInt8 {
        var crc: UInt8 = 0x00
        for byte in data {
            crc ^= byte
            for _ in 0..<8 {
                if (crc & 0x80) != 0 {
                    crc = (crc << 1) ^ 0x07
                } else {
                    crc <<= 1
                }
            }
        }
        return crc
    }

    /// XOR 校验和
    public static func xorChecksum(_ data: Data) -> UInt8 {
        data.reduce(0) { $0 ^ $1 }
    }
}
