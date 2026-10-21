import SwiftUI
import CoreBluetooth

// MARK: - 点击空白收起键盘
extension View {
    func dismissKeyboardOnTap() -> some View {
        self.onTapGesture {
            UIApplication.shared.sendAction(#selector(UIResponder.resignFirstResponder), to: nil, from: nil, for: nil)
        }
    }
}

/// 运行模式
enum DemoMode: String, CaseIterable {
    case central = "Central"
    case peripheral = "Peripheral"
}

struct ContentView: View {
    @EnvironmentObject var vm: DeviceViewModel
    @EnvironmentObject var pvm: PeripheralViewModel
    @State private var mode: DemoMode = .central

    var body: some View {
        NavigationView {
            VStack(spacing: 0) {
                Picker("Mode", selection: $mode.animation(.none)) {
                    ForEach(DemoMode.allCases, id: \.self) { m in
                        Text(m.rawValue).tag(m)
                    }
                }
                .pickerStyle(.segmented)
                .padding()

                if mode == .central {
                    centralContent
                } else {
                    PeripheralView()
                }
            }
            .navigationTitle("LEBLEKit Demo")
            .navigationBarTitleDisplayMode(.inline)
            .onAppear {
                let appearance = UINavigationBarAppearance()
                appearance.configureWithOpaqueBackground()
                appearance.backgroundColor = .white
                UINavigationBar.appearance().standardAppearance = appearance
                UINavigationBar.appearance().scrollEdgeAppearance = appearance
            }
        }
    }

    // MARK: - Central Content

    private var centralContent: some View {
        VStack(spacing: 0) {
            statusBar

            if vm.connectedDeviceName == nil {
                deviceList
            } else {
                connectedView
            }

            logView(log: vm.log)
        }
    }

    // MARK: - Status Bar

    private var statusBar: some View {
        HStack {
            Circle()
                .fill(vm.state == .poweredOn ? Color.green : Color.red)
                .frame(width: 10, height: 10)
            Text("BLE: \(vm.state == .poweredOn ? "ON" : vm.state == .unauthorized ? "Unauthorized" : "OFF")")
                .font(.caption)
            Spacer()
            Button("Scan") { vm.startScan() }
                .buttonStyle(.borderedProminent)
                .disabled(vm.state != .poweredOn || vm.isScanning)
        }
        .padding(.horizontal)
        .padding(.vertical, 8)
        .background(Color(.systemGray6))
    }

    // MARK: - Device List

    private var deviceList: some View {
        List {
            if vm.discoveredDevices.isEmpty {
                Text("No devices found. Tap Scan to start.")
                    .foregroundColor(.secondary)
            }
            ForEach(vm.discoveredDevices) { device in
                Button {
                    vm.connect(to: device)
                } label: {
                    VStack(alignment: .leading) {
                        Text(device.name ?? "Unknown")
                            .font(.headline)
                        Text("RSSI: \(device.rssi) dBm — \(device.id.uuidString)")
                            .font(.caption)
                            .foregroundColor(.secondary)
                    }
                }
            }
        }
    }

    // MARK: - Connected View

    private var connectedView: some View {
        VStack(spacing: 12) {
            HStack {
                Text("Connected: \(vm.connectedDeviceName ?? "")")
                    .font(.headline)
                Spacer()
                Button("Disconnect", role: .destructive) {
                    vm.disconnect()
                }
                .buttonStyle(.bordered)
            }
            .padding(.horizontal)

            // Quick actions
            VStack(spacing: 8) {
                actionRow(label: "Read FFF1", action: { vm.readCharacteristic("FFF1") })
                actionRow(label: "Write 0102 to FFF2", action: { vm.writeData("01 02", to: "FFF2") })
                actionRow(label: "Subscribe FFF3", action: { vm.subscribeNotifications("FFF3") })
            }
            .padding(.horizontal)

            if !vm.lastReceivedData.isEmpty {
                Text("Last data: \(vm.lastReceivedData)")
                    .font(.caption)
                    .padding(.horizontal)
            }

            Spacer()
        }
        .padding(.top)
    }

    private func actionRow(label: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            HStack {
                Text(label).font(.caption)
                Spacer()
                Image(systemName: "arrow.right.circle")
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 8)
            .background(Color(.systemGray5))
            .cornerRadius(8)
        }
    }

    // MARK: - Log View

    private func logView(log: [String]) -> some View {
        VStack(alignment: .leading, spacing: 0) {
            Divider()
            Text("Log")
                .font(.caption)
                .foregroundColor(.secondary)
                .padding(.horizontal)
                .padding(.top, 4)
            ScrollViewReader { proxy in
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: 2) {
                        ForEach(Array(log.enumerated()), id: \.offset) { _, entry in
                            Text(entry)
                                .font(.system(size: 10, design: .monospaced))
                                .textSelection(.enabled)
                        }
                    }
                    .padding(.horizontal)
                    .padding(.bottom, 4)
                }
                .frame(maxHeight: 150)
                .onChange(of: log.count) { _ in
                    if !log.isEmpty {
                        proxy.scrollTo(log.count - 1, anchor: .bottom)
                    }
                }
            }
        }
    }
}
