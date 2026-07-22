import ActivityKit
import SwiftUI
import WidgetKit

/// The aggregate Pedals activity. Content is count-only by construction
/// (AGENT_MONITORING_DESIGN.md §6): the Worker composes the push from D1
/// counts (running/waiting agents next to the TTY count) and never sees
/// agent names or messages. Waiting is the one state that justifies color
/// under the black/white rule — the island turns orange while any agent
/// waits on the user.
struct TTYLiveActivityWidget: Widget {
    var body: some WidgetConfiguration {
        ActivityConfiguration(for: TTYActivityAttributes.self) { context in
            LockScreenBanner(state: context.state)
                .padding(.horizontal)
                .padding(.vertical, 2)
                .foregroundStyle(PedalsTheme.content)
                .activityBackgroundTint(PedalsTheme.canvas)
                .activitySystemActionForegroundColor(PedalsTheme.content)
        } dynamicIsland: { context in
            let state = context.state
            return DynamicIsland {
                DynamicIslandExpandedRegion(.leading) {
                    HStack(spacing: 5) {
                        Image(systemName: "terminal.fill")
                            .foregroundStyle(PedalsTheme.content)
                        Text(state.totalRunning, format: .number)
                            .font(.title3.bold())
                            .monospacedDigit()
                            .foregroundStyle(PedalsTheme.content)
                            .contentTransition(.numericText())
                        Text("TTY")
                            .font(.caption)
                            .foregroundStyle(PedalsTheme.secondaryContent)
                    }
                    .accessibilityLabel("\(state.totalRunning) terminals")
                    .padding(.leading, 4)
                    .padding(.top, 2)
                }
                DynamicIslandExpandedRegion(.trailing) {
                    if state.totalAgents > 0 {
                        HStack(spacing: 5) {
                            Image(systemName: "sparkles")
                                .foregroundStyle(
                                    state.agentsWaiting > 0
                                        ? PedalsTheme.warning : PedalsTheme.content
                                )
                            Text(state.totalAgents, format: .number)
                                .font(.title3.bold())
                                .monospacedDigit()
                                .foregroundStyle(PedalsTheme.content)
                                .contentTransition(.numericText())
                            Text(state.totalAgents == 1 ? "agent" : "agents")
                                .font(.caption)
                                .foregroundStyle(PedalsTheme.secondaryContent)
                        }
                        .accessibilityLabel("\(state.totalAgents) agents")
                        .padding(.trailing, 4)
                        .padding(.top, 2)
                    }
                }
                DynamicIslandExpandedRegion(.bottom) {
                    VStack(alignment: .leading, spacing: 5) {
                        AgentStateBreakdown(state: state)
                        if state.offlineComputerCount > 0 {
                            Label(
                                "\(state.offlineComputerCount) offline",
                                systemImage: "wifi.slash"
                            )
                            .foregroundStyle(PedalsTheme.warning)
                            .font(.caption)
                        }
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                    // Inset from the island's large corner radius: content at
                    // the region edge gets clipped by the capsule mask (the
                    // breakdown row's leading dot loses a bite otherwise).
                    .padding(.leading, 6)
                    .padding(.bottom, 6)
                }
            } compactLeading: {
                // Attention first: an orange sparkle marks "needs you"; a
                // plain sparkle marks agents at work; otherwise the terminal.
                if state.agentsWaiting > 0 {
                    Image(systemName: "sparkles")
                        .foregroundStyle(PedalsTheme.warning)
                } else if state.agentsRunning > 0 {
                    Image(systemName: "sparkles")
                        .foregroundStyle(PedalsTheme.content)
                } else {
                    Image(systemName: "terminal.fill")
                        .foregroundStyle(PedalsTheme.content)
                }
            } compactTrailing: {
                // One number, most urgent first: waiting agents (orange),
                // then working agents, then TTYs.
                Text(state.compactCount, format: .number)
                    .fontWeight(.bold)
                    .monospacedDigit()
                    .foregroundStyle(
                        state.agentsWaiting > 0 ? PedalsTheme.warning : PedalsTheme.content
                    )
                    .contentTransition(.numericText())
            } minimal: {
                Text(state.compactCount, format: .number)
                    .fontWeight(.bold)
                    .monospacedDigit()
                    .foregroundStyle(
                        state.agentsWaiting > 0 ? PedalsTheme.warning : PedalsTheme.content
                    )
            }
            .keylineTint(state.agentsWaiting > 0 ? PedalsTheme.warning : PedalsTheme.content)
        }
    }
}

/// Colored-dot per-state row: `● 2 running · ● 1 waiting`. Only non-zero
/// states appear; nothing renders while no agents are active.
private struct AgentStateBreakdown: View {
    let state: TTYActivityAttributes.ContentState

    var body: some View {
        if state.totalAgents > 0 {
            HStack(spacing: 12) {
                if state.agentsRunning > 0 {
                    stat(
                        count: state.agentsRunning, label: "running",
                        color: PedalsTheme.content
                    )
                }
                if state.agentsWaiting > 0 {
                    stat(
                        count: state.agentsWaiting, label: "waiting",
                        color: PedalsTheme.warning, emphasized: true
                    )
                }
            }
            .font(.caption)
        }
    }

    private func stat(
        count: Int, label: String, color: Color, emphasized: Bool = false
    ) -> some View {
        HStack(spacing: 4) {
            Circle()
                .fill(color)
                .frame(width: 6, height: 6)
            Text("\(count) \(label)")
                .fontWeight(emphasized ? .semibold : .regular)
                .foregroundStyle(emphasized ? color : PedalsTheme.secondaryContent)
                .monospacedDigit()
                .contentTransition(.numericText())
        }
    }
}

/// Lock-screen banner: identity row (TTYs · agents) over the state breakdown.
private struct LockScreenBanner: View {
    let state: TTYActivityAttributes.ContentState

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack(spacing: 10) {
                Image(systemName: "terminal.fill")
                Text(headline)
                    .font(.headline)
                    .contentTransition(.numericText())
                Spacer()
                if state.offlineComputerCount > 0 {
                    Image(systemName: "wifi.slash")
                        .font(.caption)
                        .foregroundStyle(PedalsTheme.warning)
                        .accessibilityLabel("\(state.offlineComputerCount) offline")
                }
            }
            AgentStateBreakdown(state: state)
        }
    }

    private var headline: String {
        let ttys = state.totalRunning == 1 ? "1 TTY" : "\(state.totalRunning) TTYs"
        guard state.totalAgents > 0 else { return ttys }
        let agents = state.totalAgents == 1 ? "1 agent" : "\(state.totalAgents) agents"
        return "\(ttys) · \(agents)"
    }
}

private extension TTYActivityAttributes.ContentState {
    var totalAgents: Int { agentsRunning + agentsWaiting }

    /// The one number the compact/minimal slot can carry, most urgent first:
    /// waiting agents, then working agents, then TTYs.
    var compactCount: Int {
        if agentsWaiting > 0 { return agentsWaiting }
        if agentsRunning > 0 { return agentsRunning }
        return totalRunning
    }
}
