# LEBLEKit

LEBLEKit 是基于 CoreBluetooth 的 Swift 低功耗蓝牙（BLE）库，使用 `actor`、`async/await` 和 `AsyncStream` 管理扫描、连接、数据读写与通知订阅，同时支持中心设备（Central）和外设（Peripheral）两种角色。

仓库名为 **LeeBLEKit**，Swift 库产品与导入模块名为 **LEBLEKit**。

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
| Swift 工具链 | 5.9 及以上，以根目录的 `Package.swift` 为准 |
| 库支持的平台 | iOS 13.0 及以上、macOS 10.15 及以上 |
| iOS 示例工程 | 当前部署目标为 iOS 15.0 |
| 蓝牙功能调试 | 支持 BLE 的设备，并开启蓝牙、授予应用蓝牙权限 |

库使用系统框架 `CoreBluetooth` 和 `Foundation`，没有第三方包依赖。

## 安装与集成

仓库根目录是可直接引用的 Swift Package，提供 `LEBLEKit` 库产品。

### 在 Xcode 中通过 GitHub 地址添加

1. 打开 **File → Add Package Dependencies…**，输入仓库地址：

   ```text
   https://github.com/leelaxs/LeeBLEKit.git
   ```

2. 将依赖规则设为 **Up to Next Major Version**，最低版本填写 `0.1.0`。
3. 添加包后，选择 **LEBLEKit** 库产品，并关联到应用目标。

当前版本标签为 `0.1.0`。私有仓库需要在 Xcode 中配置具有仓库读取权限的 GitHub 账号。

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

这里的 `package: "LeeBLEKit"` 对应 GitHub 仓库名，产品与导入模块名均为 `LEBLEKit`。在应用代码中使用：

```swift
import LEBLEKit
```

Swift Package 的产品与依赖配置可参考 [SwiftPM 官方文档](https://docs.swift.org/package-manager/PackageDescription/PackageDescription.html)。

### 本地开发与迁移

需要修改库源码或运行示例时，可克隆仓库：

```bash
git clone https://github.com/leelaxs/LeeBLEKit.git
cd LeeBLEKit
```

在 Xcode 中添加本地 Swift Package 时，选择仓库根目录。已有本地集成需将原来的 `LeeBLEKit/LEBLEKit` 子目录引用改为 `LeeBLEKit` 根目录，随后重新解析依赖；`import LEBLEKit` 和公共 API 的用法保持不变。

应用需配置蓝牙权限说明。例如，本仓库 iOS Demo 已在 Xcode 构建设置中配置 `NSBluetoothAlwaysUsageDescription`；接入自己的应用时，请提供符合实际用途的说明文字。

## 快速开始

### 扫描、连接与读取

下面的示例等待蓝牙就绪，扫描名称中包含 `Sensor` 的设备，连接后读取 `FFF0` 服务中的 `FFF1` 特征值，并在结束时断开连接。请按设备协议替换名称与 UUID。

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

写入默认使用 `.withResponse`。使用 `.withoutResponse` 时，特征值需支持 `.writeWithoutResponse`。直接写入的数据需满足对应写入类型的单次长度限制；较长消息可按设备协议选择分包方式。

通知流会持续等待新数据，可在独立 `Task` 中消费，并在结束使用时取消任务。连接断开后，需根据新的连接和服务发现结果重新建立订阅。

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

将 `rule` 传给扫描方法即可使用组合条件。`serviceUUIDs` 匹配广播中的服务 UUID；设备只在连接后提供的服务，不会用于这项广播匹配。

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

动态读写可通过 `onReadRequest`、`onWriteRequest` 配置处理逻辑，订阅变化通过 `onSubscribe`、`onUnsubscribe` 接收。需要发送通知时，注册支持通知的特征值，再调用 `notify(data:for:)`。这些回调使用 `@Sendable` 闭包；更新 UI 时应切换到 `MainActor`。

## 分包与可靠传输

| 类型 | 协议与用途 |
| --- | --- |
| `Packetizer` | 使用 2 字节大端长度前缀，按最大写入长度拆分并重组消息，单条消息最长为 65,535 字节。 |
| `ReliableTransport` | 使用带序号的帧和 ACK/NACK，支持超时重传与完整消息接收，当前窗口大小为 1。 |
| `DefaultFrameProtocol` | 默认可靠帧格式，包含帧头、序号、类型、长度、负载与 CRC16，并使用结束帧标记消息边界。 |
| `FrameProtocol` / `ReliableFrameProtocol` | 用于实现自定义编解码；可靠传输层要求实现 `ReliableFrameProtocol`。 |

通信两端需实现一致的应用层协议。`Packetizer` 的长度前缀协议与 `ReliableTransport` 的可靠帧协议应按设备固件能力选择，单次 CoreBluetooth 写入应答也不等同于应用层 ACK。

## 运行示例与测试

在仓库根目录执行：

```bash
# 编译库
swift build --target LEBLEKit

# 运行库的单元测试
swift test
```

iOS 示例位于 `iOS/LEBLEKitDemo.xcodeproj`，可在 Xcode 中打开，配置开发团队后使用真机调试。示例包含中心设备与外设模式界面，其本地包引用 `..` 指向仓库根目录，便于同步调试库源码。

单元测试覆盖扫描规则、就绪状态与超时、连接读写与取消、分包、可靠传输、外设请求处理及数据工具。测试中的传输替身用于验证逻辑；实际设备的扫描、连接与通信仍需真机验证。

## 项目结构

```text
LeeBLEKit/
├── README.md                      # 项目说明
├── Package.swift                  # 库与测试的统一包定义
├── Sources/LEBLEKit/              # 蓝牙库源码
├── Tests/LEBLEKitTests/            # 单元测试
├── LEBLEKit.podspec                # CocoaPods 配置草稿
└── iOS/                           # iOS 示例工程与源码
```

`LEBLEKit.podspec` 中的仓库地址和作者信息仍为占位配置，使用前需补全。当前推荐通过 Swift Package Manager 集成。
