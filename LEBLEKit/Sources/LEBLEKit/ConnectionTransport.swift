import Foundation
@preconcurrency import CoreBluetooth

/// Internal hardware boundary. Tests drive the real Connection and DelegateBridge
/// through this interface without constructing system-owned CBPeripheral objects.
protocol ConnectionTransport: AnyObject, Sendable {
    var identifier: UUID { get }
    var name: String? { get }
    var isConnected: Bool { get }
    var isDisconnected: Bool { get }
    var maximumWriteLength: Int { get }
    var canSendWithoutResponse: Bool { get }
    func maximumWriteLength(for type: CBCharacteristicWriteType) -> Int
    func connect()
    func cancel()
    func discoverServices(_ uuids: [CBUUID]?)
    func discoverCharacteristics(_ uuids: [CBUUID]?, for service: CBService)
    func read(_ characteristic: CBCharacteristic)
    func write(_ data: Data, to characteristic: CBCharacteristic, type: CBCharacteristicWriteType)
    func notify(_ enabled: Bool, for characteristic: CBCharacteristic)
}

final class CoreBluetoothTransport: ConnectionTransport, @unchecked Sendable {
    let peripheral: CBPeripheral
    let central: CBCentralManager
    init(peripheral: CBPeripheral, central: CBCentralManager) {
        self.peripheral = peripheral
        self.central = central
    }
    var identifier: UUID { peripheral.identifier }
    var name: String? { peripheral.name }
    var isConnected: Bool { peripheral.state == .connected }
    var isDisconnected: Bool { peripheral.state == .disconnected }
    var maximumWriteLength: Int { peripheral.maximumWriteValueLength(for: .withResponse) }
    var canSendWithoutResponse: Bool { peripheral.canSendWriteWithoutResponse }
    func maximumWriteLength(for type: CBCharacteristicWriteType) -> Int { peripheral.maximumWriteValueLength(for: type) }
    func connect() { central.connect(peripheral, options: nil) }
    func cancel() { central.cancelPeripheralConnection(peripheral) }
    func discoverServices(_ uuids: [CBUUID]?) { peripheral.discoverServices(uuids) }
    func discoverCharacteristics(_ uuids: [CBUUID]?, for service: CBService) {
        peripheral.discoverCharacteristics(uuids, for: service)
    }
    func read(_ characteristic: CBCharacteristic) { peripheral.readValue(for: characteristic) }
    func write(_ data: Data, to characteristic: CBCharacteristic, type: CBCharacteristicWriteType) {
        peripheral.writeValue(data, for: characteristic, type: type)
    }
    func notify(_ enabled: Bool, for characteristic: CBCharacteristic) {
        peripheral.setNotifyValue(enabled, for: characteristic)
    }
}
