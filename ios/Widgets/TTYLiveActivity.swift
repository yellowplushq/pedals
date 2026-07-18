import ActivityKit
import SwiftUI
import WidgetKit

struct TTYLiveActivityWidget: Widget {
    var body: some WidgetConfiguration {
        ActivityConfiguration(for: TTYActivityAttributes.self) { context in
            HStack(spacing: 10) {
                Text(context.state.totalRunning, format: .number)
                    .font(.title2.bold())
                    .monospacedDigit()
                    .contentTransition(.numericText())
                Text(context.state.totalRunning == 1 ? "TTY running" : "TTYs running")
                    .font(.subheadline)
                    .foregroundStyle(PedalsTheme.secondaryContent)
                Spacer()
                if context.state.offlineComputerCount > 0 {
                    Image(systemName: "wifi.slash")
                        .font(.caption)
                        .foregroundStyle(PedalsTheme.warning)
                        .accessibilityLabel("\(context.state.offlineComputerCount) offline")
                }
            }
            .padding(.horizontal)
            .foregroundStyle(PedalsTheme.content)
            .activityBackgroundTint(PedalsTheme.canvas)
            .activitySystemActionForegroundColor(PedalsTheme.content)
        } dynamicIsland: { context in
            DynamicIsland {
                DynamicIslandExpandedRegion(.leading) {
                    Image(systemName: "terminal.fill")
                        .foregroundStyle(PedalsTheme.content)
                        .accessibilityLabel("Pedals")
                }
                DynamicIslandExpandedRegion(.trailing) {
                    Text(context.state.totalRunning, format: .number)
                        .font(.title2.bold())
                        .monospacedDigit()
                        .foregroundStyle(PedalsTheme.content)
                        .contentTransition(.numericText())
                }
                DynamicIslandExpandedRegion(.bottom) {
                    if context.state.offlineComputerCount > 0 {
                        Label(
                            "\(context.state.offlineComputerCount) offline",
                            systemImage: "wifi.slash"
                        )
                        .foregroundStyle(PedalsTheme.warning)
                        .font(.caption)
                    }
                }
            } compactLeading: {
                Image(systemName: "terminal.fill")
                    .foregroundStyle(PedalsTheme.content)
            } compactTrailing: {
                Text(context.state.totalRunning, format: .number)
                    .fontWeight(.bold)
                    .monospacedDigit()
                    .foregroundStyle(PedalsTheme.content)
                    .contentTransition(.numericText())
            } minimal: {
                Text(context.state.totalRunning, format: .number)
                    .fontWeight(.bold)
                    .monospacedDigit()
                    .foregroundStyle(PedalsTheme.content)
            }
            .keylineTint(PedalsTheme.content)
        }
    }
}
