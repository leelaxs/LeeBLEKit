Pod::Spec.new do |s|
  s.name         = "LEBLEKit"
  s.version      = "0.1.0"
  s.summary      = "Pure Swift BLE library with async/await API, composable connection rules, and pluggable frame protocol."
  s.description  = <<-DESC
    LEBLEKit is a pure Swift Bluetooth Low Energy library for iOS 13+.
    It provides a high-level async/await API wrapping CoreBluetooth, with:
    - Composable connection rules (name, MAC, RSSI, service UUID filtering)
    - Shared scan queue with discovery cache
    - Per-device Connection with read/write/notify
    - Packetizer for pure data fragmentation
    - Pluggable FrameProtocol with optional reliable transport
    - Configurable reconnection policies (fixed, exponential backoff)
    - Data utilities (hex, CRC, byte-level operations)
  DESC
  s.homepage     = "https://github.com/example/LEBLEKit"
  s.license      = { :type => "MIT", :file => "LICENSE" }
  s.author       = { "Author" => "" }
  s.source       = { :git => "https://github.com/example/LEBLEKit.git", :tag => "#{s.version}" }
  s.ios.deployment_target = "13.0"
  s.swift_version = "5.7"
  s.source_files = "Sources/LEBLEKit/**/*.swift"
  s.frameworks   = "CoreBluetooth", "Foundation"
end
