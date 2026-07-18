import Foundation
import WidgetKit

struct WatchWidgetPushHandler: WidgetPushHandler {
    init() {}

    func pushTokenDidChange(_ pushInfo: WidgetPushInfo, widgets: [WidgetInfo]) {
        StatusSharedStore.saveWidgetPushObservation(
            .init(surface: .watchWidget, token: pushInfo.token.pedalsHexString),
            hasConfiguredWidgets: !widgets.isEmpty
        )
        PushEndpointRegistrar.requestFlush()
    }
}
