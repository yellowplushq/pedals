import SwiftUI

@main
struct PedalsWatchApp: App {
    @WKApplicationDelegateAdaptor(WatchAppDelegate.self) private var appDelegate

    var body: some Scene {
        WindowGroup {
            WatchStatusView()
        }
    }
}
