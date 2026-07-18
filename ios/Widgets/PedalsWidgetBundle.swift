import SwiftUI
import WidgetKit

@main
struct PedalsWidgetBundle: WidgetBundle {
    var body: some Widget {
        TTYCountWidget()
        TTYLiveActivityWidget()
    }
}
