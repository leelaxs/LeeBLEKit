import XCTest
import CoreBluetooth
@testable import LEBLEKit

final class LEBLEErrorTests: XCTestCase {

    func test_allErrorCasesExist() {
        _ = LEBLEError.bluetoothUnavailable
        _ = LEBLEError.scanningNotReady
        _ = LEBLEError.scanTimeout
        _ = LEBLEError.connectionFailed(underlying: nil)
        _ = LEBLEError.connectionTimeout
        _ = LEBLEError.disconnected(underlying: nil)
        _ = LEBLEError.invalidData
        _ = LEBLEError.transportError(underlying: nil)
    }

    func test_serviceNotFound_carriesUUID() {
        let uuid = CBUUID(string: "180D")
        let error = LEBLEError.serviceNotFound(uuid)
        switch error {
        case .serviceNotFound(let id):
            XCTAssertEqual(id, uuid)
        default:
            XCTFail("Expected serviceNotFound")
        }
    }

    func test_characteristicNotFound_carriesUUID() {
        let uuid = CBUUID(string: "2A37")
        let error = LEBLEError.characteristicNotFound(uuid)
        switch error {
        case .characteristicNotFound(let id):
            XCTAssertEqual(id, uuid)
        default:
            XCTFail("Expected characteristicNotFound")
        }
    }
}
