import Foundation
import WatchKit

final class WatchAppDelegate: NSObject, WKApplicationDelegate {
    func applicationDidFinishLaunching() {
        WatchStatusBridge.shared.activate()
        Task {
            await PushEndpointRegistrar.flushPending()
            _ = try? await PedalsStatusRuntime.refreshState()
        }
    }

    func applicationDidBecomeActive() {
        PushEndpointRegistrar.requestFlush()
        Task {
            _ = try? await PedalsStatusRuntime.refreshState()
        }
    }
}
