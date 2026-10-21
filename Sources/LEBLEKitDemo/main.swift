import Foundation
import LEBLEKit

// MARK: - BLEKit CLI Demo (macOS)

print("BLEKit Demo — macOS CLI Tester")
print("===============================\n")

let ble = LEBLEManager()

// Wait for Bluetooth to be ready
print("Waiting for Bluetooth to power on...")
do {
    try await ble.waitUntilReady(timeout: 5)
    print("✓ Bluetooth is powered on\n")
} catch {
    print("✗ Bluetooth not available: \(error)")
    exit(1)
}

// Track state changes
Task {
    for await state in await ble.stateStream {
        print("[State] Powered on: \(state == .poweredOn)")
    }
}

// MARK: - Test 1: Scan

print("--- Test 1: Scan for devices (10s) ---")

Task {
    var found = false
    do {
        let result = try await ble.scan(
            for: .rssiGreaterThan(-100),
            timeout: 10
        )
        if !found {
            found = true
            print("\n  First device found:")
            print("    Name: \(result.name ?? "Unknown")")
            print("    RSSI: \(result.rssi) dBm")
            print("    ID: \(result.id)")
        }
    } catch {
        if !found {
            print("  No devices found in 10s (error: \(error))")
        }
    }
}

try? await Task.sleep(nanoseconds: 12_000_000_000)

// MARK: - Test 2: LEBLEUtils

print("\n--- Test 2: LEBLEUtils ---")
let testData = Data([0xAA, 0xBB, 0xCC, 0xDD])
print("hex: \(LEBLEUtils.hexString(from: testData))")
print("data(hex: \"AABBCCDD\"): \(LEBLEUtils.hexString(from: LEBLEUtils.data(hex: "AABBCCDD") ?? Data()))")
print("crc16(\"123456789\"): 0x\(String(LEBLEUtils.crc16("123456789".data(using: .utf8)!), radix: 16, uppercase: true))")
print("binary(0xAA): \(LEBLEUtils.binaryString(from: 0xAA))")
print("subdata(1..<3): \(LEBLEUtils.hexString(from: LEBLEUtils.subdata(of: testData, range: 1..<3)))")

// MARK: - Test 3: ConnectionRule

print("\n--- Test 3: ConnectionRule ---")
let rule = ConnectionRule.all([
    .nameContains("Magic"),
    .rssiGreaterThan(-70)
])
let mockResult = ScanResult(id: UUID(), name: "MagicDevice", rssi: -50, advertisementData: [:])
print("Rule matches 'MagicDevice' @ -50dBm: \(rule.matches(mockResult))")

// MARK: - Summary

print("\n===============================")
print("BLEKit library loaded and functional.")
print("Run swift test --package-path LEBLEKit to verify the library tests.")
print("See Tests/ directory for detailed test coverage.")
print("For iOS testing: open BLEKitDemo.xcodeproj in Xcode")
exit(0)
