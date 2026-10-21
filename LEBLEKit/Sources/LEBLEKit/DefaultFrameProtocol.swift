import Foundation

/// SOF(AA), sequence(BE16), kind(8), length(BE16), payload, CRC16(BE).
/// kind 4 marks the final fragment, including an empty message. Both peers must
/// support this marker to preserve message boundaries across multiple frames.
public struct DefaultFrameProtocol: ReliableFrameProtocol {
    public static let sof: UInt8 = 0xAA
    public typealias FrameType = ReliableFrame.Kind
    public init() {}

    public func maximumPayload(mtu: Int) throws -> Int {
        guard mtu > 8 else { throw LEBLEError.invalidData }
        return min(mtu - 8, Int(UInt16.max))
    }

    public func encodeFrame(_ frame: ReliableFrame, mtu: Int) throws -> Data {
        let capacity = try maximumPayload(mtu: mtu)
        guard frame.payload.count <= capacity,
              frame.kind == .data || frame.kind == .end || frame.payload.isEmpty else { throw LEBLEError.invalidData }
        let count = UInt16(frame.payload.count)
        var bytes = Data([Self.sof, UInt8(frame.sequence >> 8), UInt8(frame.sequence & 255), frame.kind.rawValue,
                          UInt8(count >> 8), UInt8(count & 255)])
        bytes.append(frame.payload)
        let crc = LEBLEUtils.crc16(bytes)
        bytes.append(contentsOf: [UInt8(crc >> 8), UInt8(crc & 255)])
        return bytes
    }

    public func decodeFrame(_ data: Data) throws -> ReliableFrame {
        let bytes = [UInt8](data)
        guard bytes.count >= 8, bytes[0] == Self.sof,
              let kind = ReliableFrame.Kind(rawValue: bytes[3]) else { throw LEBLEError.invalidData }
        let length = Int(bytes[4]) << 8 | Int(bytes[5])
        guard bytes.count == length + 8 else { throw LEBLEError.invalidData }
        let crc = UInt16(bytes[bytes.count - 2]) << 8 | UInt16(bytes[bytes.count - 1])
        guard LEBLEUtils.crc16(Data(bytes.dropLast(2))) == crc,
              kind == .data || kind == .end || length == 0 else { throw LEBLEError.invalidData }
        return ReliableFrame(sequence: UInt16(bytes[1]) << 8 | UInt16(bytes[2]), kind: kind,
                             payload: Data(bytes[6..<(6 + length)]))
    }

    /// Legacy nonthrowing interface: invalid MTU returns no frames; reliable users
    /// use the checked codec methods above. Empty messages still produce one frame.
    public func encode(_ payload: Data, mtu: Int) -> [Data] {
        guard let capacity = try? maximumPayload(mtu: mtu) else { return [] }
        let data = Data(payload)
        var result: [Data] = []
        var offset = 0
        var sequence: UInt16 = 0
        repeat {
            let end = offset + min(capacity, data.count - offset)
            let frame = ReliableFrame(sequence: sequence, kind: end == data.count ? .end : .data,
                                      payload: data.subdata(in: offset..<end))
            guard let encoded = try? encodeFrame(frame, mtu: mtu) else { return [] }
            result.append(encoded)
            offset = end; sequence &+= 1
        } while offset < data.count
        return result
    }

    public func decode(_ frame: Data) -> DecodeResult {
        let data = Data(frame)
        guard data.count >= 8 else { return .incomplete }
        let size = 8 + (Int(data[4]) << 8 | Int(data[5]))
        guard data.count >= size else { return .incomplete }
        do { return .complete(try decodeFrame(data).payload) }
        catch { return .error(error) }
    }
}
