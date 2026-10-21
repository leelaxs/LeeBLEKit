import XCTest
import CoreBluetooth
@testable import LEBLEKit

final class ConnectionRuleTests: XCTestCase {

    private func makeResult(
        name: String? = nil,
        rssi: Int = -50,
        services: [CBUUID]? = nil,
        manufacturer: Data? = nil
    ) -> ScanResult {
        var advData: [String: Any] = [:]
        if let services = services {
            advData[CBAdvertisementDataServiceUUIDsKey] = services
        }
        if let manufacturer = manufacturer {
            advData[CBAdvertisementDataManufacturerDataKey] = manufacturer
        }
        return ScanResult(
            id: UUID(),
            name: name,
            rssi: rssi,
            advertisementData: advData
        )
    }

    // MARK: - nameContains

    func test_nameContains_match() {
        let rule = ConnectionRule.nameContains("Sensor")
        XCTAssertTrue(rule.matches(makeResult(name: "MySensor")))
    }

    func test_nameContains_caseInsensitive() {
        let rule = ConnectionRule.nameContains("sensor")
        XCTAssertTrue(rule.matches(makeResult(name: "MYSENSOR")))
    }

    func test_nameContains_noMatch() {
        let rule = ConnectionRule.nameContains("ABC")
        XCTAssertFalse(rule.matches(makeResult(name: "XYZ")))
    }

    func test_nameContains_nilName() {
        let rule = ConnectionRule.nameContains("ABC")
        XCTAssertFalse(rule.matches(makeResult(name: nil)))
    }

    // MARK: - nameIs

    func test_nameIs_match() {
        let rule = ConnectionRule.nameIs("MyDevice")
        XCTAssertTrue(rule.matches(makeResult(name: "MyDevice")))
    }

    func test_nameIs_caseInsensitive() {
        let rule = ConnectionRule.nameIs("mydevice")
        XCTAssertTrue(rule.matches(makeResult(name: "MyDevice")))
    }

    func test_nameIs_noMatch() {
        let rule = ConnectionRule.nameIs("MyDevice")
        XCTAssertFalse(rule.matches(makeResult(name: "OtherDevice")))
    }

    // MARK: - serviceUUIDs

    func test_serviceUUIDs_match() {
        let target = [CBUUID(string: "180D"), CBUUID(string: "180A")]
        let rule = ConnectionRule.serviceUUIDs(target)
        XCTAssertTrue(rule.matches(makeResult(services: target)))
    }

    func test_serviceUUIDs_subset() {
        let rule = ConnectionRule.serviceUUIDs([CBUUID(string: "180D")])
        XCTAssertTrue(rule.matches(makeResult(services: [CBUUID(string: "180D"), CBUUID(string: "180A")])))
    }

    func test_serviceUUIDs_missing() {
        let rule = ConnectionRule.serviceUUIDs([CBUUID(string: "FFFF")])
        XCTAssertFalse(rule.matches(makeResult(services: [CBUUID(string: "180D")])))
    }

    func test_serviceUUIDs_nilServices() {
        let rule = ConnectionRule.serviceUUIDs([CBUUID(string: "180D")])
        XCTAssertFalse(rule.matches(makeResult(services: nil)))
    }

    // MARK: - rssiGreaterThan

    func test_rssiGreaterThan_pass() {
        let rule = ConnectionRule.rssiGreaterThan(-70)
        XCTAssertTrue(rule.matches(makeResult(rssi: -50)))
    }

    func test_rssiGreaterThan_fail() {
        let rule = ConnectionRule.rssiGreaterThan(-70)
        XCTAssertFalse(rule.matches(makeResult(rssi: -80)))
    }

    func test_rssiGreaterThan_equal() {
        let rule = ConnectionRule.rssiGreaterThan(-70)
        XCTAssertFalse(rule.matches(makeResult(rssi: -70)))
    }

    // MARK: - manufacturerData

    func test_manufacturerData_match() {
        let data = Data([0x01, 0x02, 0x03, 0x04])
        let rule = ConnectionRule.manufacturerData(prefix: Data([0x02, 0x03]), at: 1)
        XCTAssertTrue(rule.matches(makeResult(manufacturer: data)))
    }

    func test_manufacturerData_matchFromStart() {
        let data = Data([0xAA, 0xBB])
        let rule = ConnectionRule.manufacturerData(prefix: Data([0xAA]))
        XCTAssertTrue(rule.matches(makeResult(manufacturer: data)))
    }

    func test_manufacturerData_noMatch() {
        let data = Data([0x01, 0x02])
        let rule = ConnectionRule.manufacturerData(prefix: Data([0x03]), at: 1)
        XCTAssertFalse(rule.matches(makeResult(manufacturer: data)))
    }

    func test_manufacturerData_outOfBounds() {
        let data = Data([0x01])
        let rule = ConnectionRule.manufacturerData(prefix: Data([0x02]), at: 5)
        XCTAssertFalse(rule.matches(makeResult(manufacturer: data)))
    }

    func test_manufacturerData_nilData() {
        let rule = ConnectionRule.manufacturerData(prefix: Data([0x01]))
        XCTAssertFalse(rule.matches(makeResult(manufacturer: nil)))
    }

    // MARK: - custom

    func test_custom_match() {
        let rule = ConnectionRule.custom { $0.rssi > -60 && $0.name == "Target" }
        XCTAssertTrue(rule.matches(makeResult(name: "Target", rssi: -50)))
    }

    func test_custom_noMatch() {
        let rule = ConnectionRule.custom { $0.rssi > -60 }
        XCTAssertFalse(rule.matches(makeResult(rssi: -80)))
    }

    // MARK: - all (AND)

    func test_all_match() {
        let rule = ConnectionRule.all([
            .nameContains("Sensor"),
            .rssiGreaterThan(-70)
        ])
        XCTAssertTrue(rule.matches(makeResult(name: "Sensor-A", rssi: -50)))
    }

    func test_all_oneFails() {
        let rule = ConnectionRule.all([
            .nameContains("Sensor"),
            .rssiGreaterThan(-70)
        ])
        XCTAssertFalse(rule.matches(makeResult(name: "Sensor-A", rssi: -80)))
    }

    func test_all_empty() {
        let rule = ConnectionRule.all([])
        XCTAssertTrue(rule.matches(makeResult()))
    }

    // MARK: - any (OR)

    func test_any_bothMatch() {
        let rule = ConnectionRule.any([
            .nameContains("A"),
            .nameContains("B")
        ])
        XCTAssertTrue(rule.matches(makeResult(name: "A-Device")))
    }

    func test_any_oneMatches() {
        let rule = ConnectionRule.any([
            .nameContains("A"),
            .nameContains("B")
        ])
        XCTAssertTrue(rule.matches(makeResult(name: "B-Device")))
    }

    func test_any_noneMatch() {
        let rule = ConnectionRule.any([
            .nameContains("A"),
            .nameContains("B")
        ])
        XCTAssertFalse(rule.matches(makeResult(name: "C-Device")))
    }

    func test_any_empty() {
        let rule = ConnectionRule.any([])
        XCTAssertFalse(rule.matches(makeResult()))
    }

    // MARK: - not

    func test_not_invertsTrue() {
        let rule = ConnectionRule.not(.nameContains("A"))
        XCTAssertTrue(rule.matches(makeResult(name: "B-Device")))
    }

    func test_not_invertsFalse() {
        let rule = ConnectionRule.not(.nameContains("A"))
        XCTAssertFalse(rule.matches(makeResult(name: "A-Device")))
    }

    // MARK: - nested composition

    func test_nested_allInsideAny() {
        let rule = ConnectionRule.any([
            .all([.nameContains("Sensor"), .rssiGreaterThan(-70)]),
            .nameIs("Fallback")
        ])
        XCTAssertTrue(rule.matches(makeResult(name: "Sensor-X", rssi: -60)))
        XCTAssertTrue(rule.matches(makeResult(name: "Fallback", rssi: -90)))
        XCTAssertFalse(rule.matches(makeResult(name: "Other", rssi: -80)))
    }
}
