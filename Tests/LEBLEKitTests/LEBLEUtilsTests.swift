import XCTest
@testable import LEBLEKit

final class LEBLEUtilsTests: XCTestCase {

    // MARK: - Hex String

    func test_hexString_defaultSeparator() {
        let data = Data([0xAA, 0x0B, 0x1C])
        XCTAssertEqual(LEBLEUtils.hexString(from: data), "AA 0B 1C")
    }

    func test_hexString_noSeparator() {
        let data = Data([0xAA, 0xBB, 0xCC])
        XCTAssertEqual(LEBLEUtils.hexString(from: data, separator: ""), "AABBCC")
    }

    func test_dataFromHex_uppercase() {
        let result = LEBLEUtils.data(hex: "AA 0B 1C")
        XCTAssertEqual(result, Data([0xAA, 0x0B, 0x1C]))
    }

    func test_dataFromHex_lowercase() {
        let result = LEBLEUtils.data(hex: "aa bb cc")
        XCTAssertEqual(result, Data([0xAA, 0xBB, 0xCC]))
    }

    func test_dataFromHex_noSeparator() {
        let result = LEBLEUtils.data(hex: "AABBCC")
        XCTAssertEqual(result, Data([0xAA, 0xBB, 0xCC]))
    }

    func test_dataFromHex_mixedDelimiters() {
        let result = LEBLEUtils.data(hex: "AA-BB_CC DD")
        XCTAssertEqual(result, Data([0xAA, 0xBB, 0xCC, 0xDD]))
    }

    func test_dataFromHex_oddLength() {
        XCTAssertNil(LEBLEUtils.data(hex: "AAB"))
    }

    func test_dataFromHex_invalidChars() {
        XCTAssertNil(LEBLEUtils.data(hex: "GG HH"))
    }

    func test_dataFromHex_empty() {
        XCTAssertEqual(LEBLEUtils.data(hex: ""), Data())
    }

    // MARK: - String Conversion

    func test_stringDataRoundtrip() {
        let original = "Hello BLE"
        let data = LEBLEUtils.data(from: original)
        let restored = LEBLEUtils.string(from: data)
        XCTAssertEqual(restored, original)
    }

    // MARK: - Subdata

    func test_subdata_range_normal() {
        let data = Data([0x01, 0x02, 0x03, 0x04, 0x05])
        let sub = LEBLEUtils.subdata(of: data, range: 1..<4)
        XCTAssertEqual(sub, Data([0x02, 0x03, 0x04]))
    }

    func test_subdata_range_clampedUpper() {
        let data = Data([0x01, 0x02, 0x03])
        let sub = LEBLEUtils.subdata(of: data, range: 1..<10)
        XCTAssertEqual(sub, Data([0x02, 0x03]))
    }

    func test_subdata_range_clampedLower() {
        let data = Data([0x01, 0x02, 0x03])
        let sub = LEBLEUtils.subdata(of: data, range: -2..<2)
        XCTAssertEqual(sub, Data([0x01, 0x02]))
    }

    func test_subdata_fromOffset_length() {
        let data = Data([0x01, 0x02, 0x03, 0x04])
        let sub = LEBLEUtils.subdata(of: data, from: 1, length: 2)
        XCTAssertEqual(sub, Data([0x02, 0x03]))
    }

    func test_subdata_fromOffset_toEnd() {
        let data = Data([0x01, 0x02, 0x03, 0x04])
        let sub = LEBLEUtils.subdata(of: data, from: 2)
        XCTAssertEqual(sub, Data([0x03, 0x04]))
    }

    func test_subdata_outOfRange_returnsEmpty() {
        let data = Data([0x01, 0x02])
        let sub = LEBLEUtils.subdata(of: data, range: 5..<10)
        XCTAssertEqual(sub, Data())
    }

    // MARK: - Single-Byte Reads

    func test_readUInt8() {
        let data = Data([0xAB, 0xCD])
        XCTAssertEqual(LEBLEUtils.readUInt8(from: data, at: 0), 0xAB)
        XCTAssertEqual(LEBLEUtils.readUInt8(from: data, at: 1), 0xCD)
        XCTAssertNil(LEBLEUtils.readUInt8(from: data, at: 2))
    }

    func test_readUInt16LE() {
        let data = Data([0xCD, 0xAB]) // LE: 0xABCD
        XCTAssertEqual(LEBLEUtils.readUInt16LE(from: data, at: 0), 0xABCD)
        XCTAssertNil(LEBLEUtils.readUInt16LE(from: data, at: 1))
    }

    func test_readUInt16BE() {
        let data = Data([0xAB, 0xCD]) // BE: 0xABCD
        XCTAssertEqual(LEBLEUtils.readUInt16BE(from: data, at: 0), 0xABCD)
    }

    func test_readUInt32LE() {
        let data = Data([0xDD, 0xCC, 0xBB, 0xAA]) // LE: 0xAABBCCDD
        XCTAssertEqual(LEBLEUtils.readUInt32LE(from: data, at: 0), 0xAABBCCDD)
        XCTAssertNil(LEBLEUtils.readUInt32LE(from: data, at: 1))
    }

    func test_readUInt32BE() {
        let data = Data([0xAA, 0xBB, 0xCC, 0xDD]) // BE: 0xAABBCCDD
        XCTAssertEqual(LEBLEUtils.readUInt32BE(from: data, at: 0), 0xAABBCCDD)
    }

    func test_read_negativeOffset() {
        let data = Data([0x01])
        XCTAssertNil(LEBLEUtils.readUInt8(from: data, at: -1))
    }

    // MARK: - Binary String

    func test_binaryString_byte() {
        XCTAssertEqual(LEBLEUtils.binaryString(from: 0x00), "00000000")
        XCTAssertEqual(LEBLEUtils.binaryString(from: 0xFF), "11111111")
        XCTAssertEqual(LEBLEUtils.binaryString(from: 0x01), "00000001")
        XCTAssertEqual(LEBLEUtils.binaryString(from: 0x80), "10000000")
    }

    func test_binaryString_data() {
        let data = Data([0xAA, 0x55])
        XCTAssertEqual(LEBLEUtils.binaryString(from: data), "10101010 01010101")
    }

    func test_binaryString_data_noSeparator() {
        let data = Data([0xAA, 0x55])
        XCTAssertEqual(LEBLEUtils.binaryString(from: data, separator: ""), "1010101001010101")
    }

    // MARK: - CRC

    func test_crc16_knownValue() {
        // CRC-16/Modbus for "123456789" = 0x4B37
        let data = "123456789".data(using: .utf8)!
        let crc = LEBLEUtils.crc16(data)
        XCTAssertEqual(crc, 0x4B37)
    }

    func test_crc16_empty() {
        let crc = LEBLEUtils.crc16(Data())
        XCTAssertEqual(crc, 0xFFFF)
    }

    func test_crc8_knownValue() {
        let data = Data([0x01, 0x02, 0x03])
        _ = LEBLEUtils.crc8(data)
    }

    // MARK: - XOR Checksum

    func test_xorChecksum() {
        let data = Data([0x55, 0x66, 0x77])
        XCTAssertEqual(LEBLEUtils.xorChecksum(data), 0x55 ^ 0x66 ^ 0x77)
    }

    func test_xorChecksum_empty() {
        XCTAssertEqual(LEBLEUtils.xorChecksum(Data()), 0)
    }
}

extension LEBLEUtilsTests {
    func test_subdataInvalidOffsetsAndLengthsDoNotTrap() {
        let data = Data([1, 2])
        XCTAssertEqual(LEBLEUtils.subdata(of: data, from: 3), Data())
        XCTAssertEqual(LEBLEUtils.subdata(of: data, from: 1, length: -1), Data())
        XCTAssertEqual(LEBLEUtils.subdata(of: data, from: Int.max, length: 1), Data())
        XCTAssertNil(LEBLEUtils.readUInt16LE(from: data, at: Int.max))
        XCTAssertNil(LEBLEUtils.readUInt32BE(from: data, at: Int.max))
    }

    func test_dataSlicesUseLogicalOffsets() {
        let slice = Data([99, 1, 2, 3, 4]).dropFirst()
        XCTAssertEqual(LEBLEUtils.readUInt8(from: slice, at: 0), 1)
        XCTAssertEqual(LEBLEUtils.readUInt16BE(from: slice, at: 0), 0x0102)
        XCTAssertEqual(LEBLEUtils.readUInt32LE(from: slice, at: 0), 0x04030201)
        XCTAssertEqual(LEBLEUtils.subdata(of: slice, from: 1, length: 2), Data([2, 3]))
    }
}
