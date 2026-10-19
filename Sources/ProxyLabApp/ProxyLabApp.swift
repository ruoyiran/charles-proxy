import SwiftUI

@main
struct ProxyLabApp: App {
    @StateObject private var model = AppModel()

    var body: some Scene {
        WindowGroup("ProxyLab") {
            ContentView()
                .environmentObject(model)
                .frame(minWidth: 980, minHeight: 640)
                .task { await model.start() }
                .onReceive(NotificationCenter.default.publisher(for: NSApplication.willTerminateNotification)) { _ in
                    model.restoreSystemProxyOnExit()
                }
        }
        .windowStyle(.titleBar)
    }
}
