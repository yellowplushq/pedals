import SwiftUI

@main
struct PedalsWatchApp: App {
    @WKApplicationDelegateAdaptor(WatchAppDelegate.self) private var appDelegate
    @Environment(\.scenePhase) private var scenePhase

    var body: some Scene {
        WindowGroup {
            WatchRootView()
                .environment(WatchTerminalStore.shared)
                .task { WatchTerminalStore.shared.start() }
                .onChange(of: scenePhase) { _, phase in
                    switch phase {
                    case .active:
                        WatchTerminalStore.shared.start()
                    case .inactive, .background:
                        WatchTerminalStore.shared.stop()
                    @unknown default:
                        WatchTerminalStore.shared.stop()
                    }
                }
        }
    }
}
