# LEBLEKit

LEBLEKit 是基于 CoreBluetooth 的 Swift 低功耗蓝牙（BLE）库，使用 `actor`、`async/await` 和 `AsyncStream` 管理扫描、连接、数据读写与通知订阅，同时支持中心设备（Central）和外设（Peripheral）两种角色。

## 功能

- **设备扫描与连接**：按名称、广播服务 UUID、RSSI、厂商数据或自定义条件匹配设备，支持 AND、OR、NOT 组合规则。
- **异步数据交互**：发现服务与特征值，读取数据，执行带应答或不带应答的写入，通过异步流接收通知。
- **连接管理**：监听蓝牙及连接状态，处理超时与任务取消，配置固定间隔或指数退避重连。
- **外设模式**：注册服务与特征值，发布广播，处理读写请求，向订阅的中心设备发送通知。
- **分包与可靠传输**：提供长度前缀分包、帧编解码，以及带序号、ACK/NACK、重传与 CRC16 校验的可靠传输实现。
- **数据工具**：提供十六进制转换、字节读取、数据切片、CRC 和异或校验等工具。

## 环境要求

| 项目 | 要求 |
| --- | --- |
| Swift 工具链 | 5.9 及以上 |
| 库支持的平台 | iOS 13.0 及以上、macOS 10.15 及以上 |

## 安装与集成

### 在 Xcode 中通过 GitHub 地址添加

1. 打开 **File → Add Package Dependencies…**，输入仓库地址：

   ```text
   https://github.com/leelaxs/LeeBLEKit.git
   ```

2. 将依赖规则设为 **Up to Next Major Version**，最低版本填写 `0.1.0`。

3. 添加包后，选择 **LEBLEKit** 库产品，并关联到应用目标。

### 在 Package.swift 中声明远程依赖

以下示例可用于另一个 Swift Package；请将 `YourTarget` 替换为实际目标名称：

```swift
// swift-tools-version: 5.9
import PackageDescription

let package = Package(
    name: "YourPackage",
    platforms: [
        .iOS(.v13),
        .macOS(.v10_15)
    ],
    dependencies: [
        .package(
            url: "https://github.com/leelaxs/LeeBLEKit.git",
            from: "0.1.0"
        )
    ],
    targets: [
        .target(
            name: "YourTarget",
            dependencies: [
                .product(name: "LEBLEKit", package: "LeeBLEKit")
            ]
        )
    ]
)
```



## 快速开始

### 扫描、连接与读取

下面的示例等待蓝牙就绪，扫描名称中包含 `Sensor` 的设备，连接后读取 `FFF0` 服务中的 `FFF1` 特征值，并在结束时断开连接。

```swift
import Foundation
import CoreBluetooth
import LEBLEKit

@MainActor
func readSensor() async throws -> Data {
    let ble = LEBLEManager()
    try await ble.waitUntilReady(timeout: 10)

    let serviceUUID = CBUUID(string: "FFF0")
    let readUUID = CBUUID(string: "FFF1")
    let connection = try await ble.scanAndConnect(
        for: .nameContains("Sensor"),
        timeout: 15,
        services: [serviceUUID]
    )

    do {
        let services = await connection.services
        guard let service = services.first(where: { $0.uuid == serviceUUID }) else {
            throw LEBLEError.serviceNotFound(serviceUUID)
        }
        let characteristics = try await connection.discoverCharacteristics(
            [readUUID], for: service
        )
        guard let characteristic = characteristics.first(where: { $0.uuid == readUUID }) else {
            throw LEBLEError.characteristicNotFound(readUUID)
        }

        let data = try await connection.read(characteristic)
        await connection.disconnect()
        return data
    } catch {
        await connection.disconnect()
        throw error
    }
}
```

`scan(for:timeout:)` 返回首个匹配的扫描结果。`scanAndConnect` 的 `timeout` 参数控制扫描阶段，随后使用 10 秒连接超时；需要单独配置连接超时时，可先扫描，再调用 `connect(to:timeout:services:)`。

需要长期保持连接时，应由业务对象持有 `LEBLEManager` 和 `Connection`，在结束使用时调用 `await connection.disconnect()`。

### 写入与订阅通知

发现设备的特征值后，可将对应的 `CBCharacteristic` 传入以下方法。写入特征值需支持 `.write`，通知特征值需支持 `.notify` 或 `.indicate`。

```swift
@MainActor
func sendCommand(connection: Connection, characteristic: CBCharacteristic) async throws {
    try await connection.write(Data([0x01, 0x02]), to: characteristic)
}

@MainActor
func receiveNotifications(connection: Connection, characteristic: CBCharacteristic) async {
    let stream = await connection.subscribe(characteristic)
    for await data in stream {
        print(LEBLEUtils.hexString(from: data))
    }
}
```

### 组合规则与重连

```swift
let rule = ConnectionRule.all([
    .nameContains("Sensor"),
    .rssiGreaterThan(-70),
    .serviceUUIDs([CBUUID(string: "FFF0")])
])

@MainActor
func enableReconnect(on connection: Connection) async {
    await connection.setRetryPolicy(
        ExponentialRetryPolicy(initial: 1, max: 30, maxAttempts: 5)
    )
}
```

默认策略为不重连。配置重连策略后，连接因错误断开时会按策略尝试恢复；主动调用 `disconnect()` 会终止重连。也可使用 `FixedRetryPolicy(interval:maxAttempts:)` 设置固定重试间隔。

## 外设模式

以下示例注册一个只读特征值，并发布本地广播。调用方需要持续持有返回的管理器；完成使用后调用 `stopAdvertising()`，必要时调用 `removeAllServices()`。

```swift
@MainActor
func startPeripheral() async throws -> LEPeripheralManager {
    let peripheral = LEPeripheralManager()
    try await peripheral.waitUntilReady(timeout: 10)

    let serviceUUID = CBUUID(string: "FFF0")
    try await peripheral.addService(
        uuid: serviceUUID,
        characteristics: [
            .readOnly(uuid: CBUUID(string: "FFF1"), value: Data([0x01]))
        ]
    )
    try await peripheral.startAdvertising(
        localName: "LEBLEKitDemo",
        serviceUUIDs: [serviceUUID]
    )
    return peripheral
}
```

## 分包与可靠传输

| 类型 | 协议与用途 |
| --- | --- |
| `Packetizer` | 使用 2 字节大端长度前缀，按最大写入长度拆分并重组消息，单条消息最长为 65,535 字节。 |
| `ReliableTransport` | 使用带序号的帧和 ACK/NACK，支持超时重传与完整消息接收，当前窗口大小为 1。 |
| `DefaultFrameProtocol` | 默认可靠帧格式，包含帧头、序号、类型、长度、负载与 CRC16，并使用结束帧标记消息边界。 |
| `FrameProtocol` / `ReliableFrameProtocol` | 用于实现自定义编解码；可靠传输层要求实现 `ReliableFrameProtocol`。 |

通信两端需实现一致的应用层协议。`Packetizer` 的长度前缀协议与 `ReliableTransport` 的可靠帧协议应按设备固件能力选择，单次 CoreBluetooth 写入应答也不等同于应用层 ACK。
