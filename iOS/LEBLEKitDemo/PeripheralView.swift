import SwiftUI
import CoreBluetooth

struct PeripheralView: View {
    @EnvironmentObject var vm: PeripheralViewModel
    @State private var notifyHexData: String = "AA BB"

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            statusBar
            configSection
            actionSection
            receivedSection
            Spacer()
            logView
        }
        .contentShape(Rectangle())
        .onTapGesture {
            UIApplication.shared.sendAction(#selector(UIResponder.resignFirstResponder), to: nil, from: nil, for: nil)
        }
    }

    // MARK: - Status Bar

    private var statusBar: some View {
        HStack {
            Circle()
                .fill(vm.state == .poweredOn ? Color.green : Color.red)
                .frame(width: 10, height: 10)
            Text(vm.connectedCount > 0 ? "已连接(\(vm.connectedCount))" : "BLE: \(vm.state == .poweredOn ? "ON" : "OFF")")
                .font(.caption)
            Spacer()
            Button(vm.isAdvertising ? "Stop" : "Start Advertising") {
                vm.isAdvertising ? vm.stopAdvertising() : vm.startAdvertising()
            }
            .buttonStyle(.borderedProminent)
            .tint(vm.isAdvertising ? .red : .accentColor)
            .disabled(vm.state != .poweredOn || vm.isStarting)
        }
        .padding(.horizontal)
        .padding(.vertical, 8)
        .background(Color(.systemGray6))
    }

    // MARK: - Config Section

    private var configSection: some View {
        VStack(spacing: 8) {
            configRow(label: "Service UUID:", placeholder: "FFF0", text: $vm.serviceUUID)
            configRow(label: "Read UUID:", placeholder: "FFF1", text: $vm.readCharUUID)
            configRow(label: "Write UUID:", placeholder: "FFF2", text: $vm.writeCharUUID)
            configRow(label: "Notify UUID:", placeholder: "FFF3", text: $vm.notifyCharUUID)
            configRow(label: "Read Reply Hex:", placeholder: "01 02 03", text: $vm.readReplyHex)
        }
        .padding(.horizontal)
        .padding(.vertical, 8)
        .disabled(vm.isAdvertising)
    }

    private func configRow(label: String, placeholder: String, text: Binding<String>) -> some View {
        HStack {
            Text(label)
                .font(.caption)
                .frame(width: 120, alignment: .leading)
            TextField(placeholder, text: text)
                .textFieldStyle(.roundedBorder)
        }
    }

    // MARK: - Action Section

    private var actionSection: some View {
        VStack(spacing: 8) {
            HStack {
                TextField("Notify Hex Data", text: $notifyHexData)
                    .textFieldStyle(.roundedBorder)
                Button("Send Notify") {
                    vm.sendNotify(notifyHexData)
                }
                .buttonStyle(.bordered)
                .disabled(!vm.isAdvertising)
            }
        }
        .padding(.horizontal)
        .padding(.vertical, 8)
    }

    // MARK: - Received Section

    private var receivedSection: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack {
                Text("Last Write:")
                    .font(.caption)
                    .foregroundColor(.secondary)
                Text(vm.lastWrittenData.isEmpty ? "None" : vm.lastWrittenData)
                    .font(.system(.caption, design: .monospaced))
                    .textSelection(.enabled)
            }
        }
        .padding(.horizontal)
        .padding(.vertical, 8)
    }

    // MARK: - Log View

    private var logView: some View {
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
                        ForEach(Array(vm.log.enumerated()), id: \.offset) { _, entry in
                            Text(entry)
                                .font(.system(size: 10, design: .monospaced))
                                .textSelection(.enabled)
                        }
                    }
                    .padding(.horizontal)
                    .padding(.bottom, 4)
                }
                .frame(height: 150)
                .onChange(of: vm.log.count) { _ in
                    if let _ = vm.log.last {
                        proxy.scrollTo(vm.log.count - 1, anchor: .bottom)
                    }
                }
                
            }
        }
    }
}
