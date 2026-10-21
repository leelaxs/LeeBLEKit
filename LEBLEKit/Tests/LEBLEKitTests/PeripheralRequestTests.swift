import XCTest
import CoreBluetooth
@testable import LEBLEKit

final class PeripheralRequestTests: XCTestCase {
    func testWriteBatchAcknowledgedExactlyOnceAfterDelivery() {
        let bridge = PeripheralDelegateBridge()
        let delivered = Locked<[Data]>([])
        bridge.onWriteRequest = { _, value in delivered.withValue { $0.append(value) } }
        let char = testCharacteristic()
        var responses: [CBATTError.Code] = []
        bridge.handleWrites([.init(characteristic: char, value: Data([1]), offset: 0),
                             .init(characteristic: char, value: Data([2]), offset: 0)]) { result in
            XCTAssertEqual(delivered.snapshot, [Data([1]), Data([2])])
            responses.append(result)
        }
        XCTAssertEqual(responses, [.success])
    }

    func testInvalidWriteBatchHasNoPartialSideEffects() {
        let bridge = PeripheralDelegateBridge()
        let delivered = Locked(0)
        bridge.onWriteRequest = { _, _ in delivered.withValue { $0 += 1 } }
        let char = testCharacteristic()
        var responses: [CBATTError.Code] = []
        bridge.handleWrites([.init(characteristic: char, value: Data([1]), offset: 0),
                             .init(characteristic: char, value: Data([2]), offset: 1)]) { responses.append($0) }
        XCTAssertEqual(delivered.snapshot, 0)
        XCTAssertEqual(responses, [.invalidOffset])
    }

    func testMissingWriteHandlerReturnsError() {
        let bridge = PeripheralDelegateBridge()
        var responses: [CBATTError.Code] = []
        bridge.handleWrites([.init(characteristic: testCharacteristic(), value: Data(), offset: 0)]) { responses.append($0) }
        XCTAssertEqual(responses, [.writeNotPermitted])
    }

    func testReadRespectsOffsetAndRepliesAtEnd() {
        let bridge = PeripheralDelegateBridge()
        bridge.onReadRequest = { _ in Data([10, 11, 12]) }
        let char = testCharacteristic()
        for (offset, expected) in [(0, Data([10, 11, 12])), (1, Data([11, 12])), (3, Data())] {
            var responses = 0
            bridge.handleRead(characteristic: char, offset: offset) { value, code in
                responses += 1
                XCTAssertEqual(value, expected); XCTAssertEqual(code, .success)
            }
            XCTAssertEqual(responses, 1)
        }
    }

    func testReadInvalidOffsetAndMissingValueReplyWithErrors() {
        let bridge = PeripheralDelegateBridge()
        let char = testCharacteristic()
        bridge.onReadRequest = { _ in Data([1]) }
        bridge.handleRead(characteristic: char, offset: 2) { value, code in
            XCTAssertNil(value); XCTAssertEqual(code, .invalidOffset)
        }
        bridge.onReadRequest = { _ in nil }
        bridge.handleRead(characteristic: char, offset: 0) { value, code in
            XCTAssertNil(value); XCTAssertEqual(code, .unlikelyError)
        }
    }
}
