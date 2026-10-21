// swift-tools-version: 5.7

import PackageDescription

let package = Package(
    name: "LEBLEKitDemo",
    platforms: [
        .macOS(.v10_15),
        .iOS(.v13)
    ],
    dependencies: [
        .package(path: "LEBLEKit")
    ],
    targets: [
        .executableTarget(
            name: "LEBLEKitDemo",
            dependencies: [
                .product(name: "LEBLEKit", package: "LEBLEKit")
            ],
            path: "Sources/LEBLEKitDemo"
        )
    ]
)
