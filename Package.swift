// swift-tools-version: 5.9

import PackageDescription

let package = Package(
    name: "LEBLEKit",
    platforms: [
        .iOS(.v13),
        .macOS(.v10_15)
    ],
    products: [
        .library(name: "LEBLEKit", targets: ["LEBLEKit"])
    ],
    targets: [
        .target(name: "LEBLEKit"),
        .testTarget(
            name: "LEBLEKitTests",
            dependencies: ["LEBLEKit"]
        )
    ]
)
