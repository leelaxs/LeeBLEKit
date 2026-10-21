import SwiftUI
import LEBLEKit

@main
struct BLEKitDemoApp: App {
    @StateObject private var vm = DeviceViewModel()
    @StateObject private var pvm = PeripheralViewModel()

    var body: some Scene {
        WindowGroup {
            ContentView()
                .environmentObject(vm)
                .environmentObject(pvm)
        }
    }
}
