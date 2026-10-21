import Foundation

public struct ReliableFrame: Sendable {
    public enum Kind: UInt8, Sendable { case data = 1, ack = 2, nack = 3, end = 4 }
    public let sequence: UInt16
    public let kind: Kind
    public let payload: Data
    public init(sequence: UInt16, kind: Kind, payload: Data = Data()) {
        self.sequence = sequence; self.kind = kind; self.payload = payload
    }
}

/// A reliable codec must expose sequence and control metadata, not just payload.
public protocol ReliableFrameProtocol: FrameProtocol {
    func maximumPayload(mtu: Int) throws -> Int
    func encodeFrame(_ frame: ReliableFrame, mtu: Int) throws -> Data
    func decodeFrame(_ data: Data) throws -> ReliableFrame
}
