import ActivityKit
import CryptoKit
import Foundation
import PedalsKit
import SwiftUI
import WidgetKit

struct TTYLiveActivityWidget: Widget {
    var body: some WidgetConfiguration {
        ActivityConfiguration(for: TTYActivityAttributes.self) { context in
            ActivityCard(state: context.state, stale: context.isStale)
                .padding(.horizontal, 16)
                .padding(.vertical, 12)
                .foregroundStyle(PedalsTheme.content)
                .activityBackgroundTint(PedalsTheme.canvas)
                .activitySystemActionForegroundColor(PedalsTheme.content)
        } dynamicIsland: { context in
            let state = context.state
            let agent = state.recentAgent
            return DynamicIsland {
                DynamicIslandExpandedRegion(.leading) {
                    ActivityIdentity(agent: agent)
                        .padding(.leading, 4)
                        .padding(.top, 2)
                }
                DynamicIslandExpandedRegion(.trailing) {
                    StatusPill(state: state, agent: agent)
                        .padding(.trailing, 4)
                        .padding(.top, 2)
                }
                DynamicIslandExpandedRegion(.bottom) {
                    ActivityBody(state: state, agent: agent, stale: context.isStale)
                        .padding(.horizontal, 6)
                        .padding(.bottom, 7)
                        .privacySensitive()
                }
            } compactLeading: {
                CompactMark(state: state, agent: agent)
            } compactTrailing: {
                CompactValue(state: state, agent: agent)
            } minimal: {
                CompactMark(state: state, agent: agent)
            }
            .keylineTint(ActivityStyle.color(for: agent?.state, state: state))
        }
    }
}

private struct ActivityCard: View {
    let state: TTYActivityAttributes.ContentState
    let stale: Bool

    var body: some View {
        let agent = state.recentAgent
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 10) {
                ActivityIdentity(agent: agent)
                Spacer(minLength: 8)
                StatusPill(state: state, agent: agent)
            }
            ActivityBody(state: state, agent: agent, stale: stale)
                .privacySensitive()
        }
    }
}

private struct ActivityIdentity: View {
    let agent: AgentActivity.Content?

    var body: some View {
        HStack(spacing: 8) {
            if let agent, let asset = ActivityStyle.asset(for: agent.agent) {
                Image(asset)
                    .resizable()
                    .renderingMode(.template)
                    .scaledToFit()
                    .frame(width: 20, height: 20)
            } else {
                Image(systemName: agent == nil ? "terminal.fill" : "sparkles")
                    .font(.system(size: 16, weight: .semibold))
            }
            Text(agent.map { AgentActivity.displayName(forAgent: $0.agent) } ?? "Pedals")
                .font(.subheadline.weight(.semibold))
                .lineLimit(1)
        }
    }
}

private struct StatusPill: View {
    let state: TTYActivityAttributes.ContentState
    let agent: AgentActivity.Content?

    var body: some View {
        HStack(spacing: 5) {
            Image(systemName: ActivityStyle.symbol(for: agent?.state, state: state))
            Text(ActivityStyle.label(for: agent?.state, state: state))
                .lineLimit(1)
        }
        .font(.caption2.weight(.bold))
        .foregroundStyle(ActivityStyle.color(for: agent?.state, state: state))
        .padding(.horizontal, 8)
        .padding(.vertical, 5)
        .background(.white.opacity(0.09), in: Capsule())
    }
}

private struct ActivityBody: View {
    let state: TTYActivityAttributes.ContentState
    let agent: AgentActivity.Content?
    let stale: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: 7) {
            if let agent {
                Text(agent.project ?? AgentActivity.displayName(forAgent: agent.agent))
                    .font(.headline)
                    .lineLimit(1)
                Text(ActivityStyle.detail(for: agent))
                    .font(.subheadline)
                    .foregroundStyle(PedalsTheme.secondaryContent)
                    .lineLimit(2)
            } else {
                Text(state.totalRunning == 1 ? "1 terminal active" : "\(state.totalRunning) terminals active")
                    .font(.headline)
                    .contentTransition(.numericText())
                Text("Remote sessions are ready when you are.")
                    .font(.subheadline)
                    .foregroundStyle(PedalsTheme.secondaryContent)
                    .lineLimit(1)
            }

            HStack(spacing: 8) {
                MetricChip(symbol: "terminal", text: "\(state.totalRunning) TTY")
                if state.totalAgents > 0 {
                    MetricChip(symbol: "sparkles", text: "\(state.totalAgents) agents")
                }
                if state.offlineComputerCount > 0 {
                    MetricChip(symbol: "wifi.slash", text: "\(state.offlineComputerCount) offline")
                }
                if stale {
                    MetricChip(symbol: "clock.badge.exclamationmark", text: "stale")
                }
            }
            .lineLimit(1)
        }
    }
}

private struct MetricChip: View {
    let symbol: String
    let text: String

    var body: some View {
        Label(text, systemImage: symbol)
            .font(.caption2.weight(.medium))
            .foregroundStyle(PedalsTheme.secondaryContent)
            .padding(.horizontal, 7)
            .padding(.vertical, 4)
            .background(.white.opacity(0.07), in: Capsule())
    }
}

private struct CompactMark: View {
    let state: TTYActivityAttributes.ContentState
    let agent: AgentActivity.Content?

    var body: some View {
        Group {
            if let agent, let asset = ActivityStyle.asset(for: agent.agent) {
                Image(asset).resizable().renderingMode(.template).scaledToFit()
            } else {
                Image(systemName: ActivityStyle.symbol(for: agent?.state, state: state))
            }
        }
        .frame(width: 17, height: 17)
        .foregroundStyle(ActivityStyle.color(for: agent?.state, state: state))
        .accessibilityLabel(ActivityStyle.label(for: agent?.state, state: state))
    }
}

private struct CompactValue: View {
    let state: TTYActivityAttributes.ContentState
    let agent: AgentActivity.Content?

    var body: some View {
        HStack(spacing: 3) {
            if let agent {
                Image(systemName: ActivityStyle.symbol(for: agent.state, state: state))
                    .font(.caption2.bold())
            }
            Text(state.compactCount, format: .number)
                .fontWeight(.bold)
                .monospacedDigit()
                .contentTransition(.numericText())
        }
        .foregroundStyle(ActivityStyle.color(for: agent?.state, state: state))
    }
}

private enum ActivityStyle {
    static func symbol(
        for agentState: AgentState?, state: TTYActivityAttributes.ContentState
    ) -> String {
        switch agentState {
        case .waiting: "questionmark"
        case .error: "exclamationmark"
        case .done: "checkmark"
        case .running: "ellipsis"
        case nil: state.agentsWaiting > 0 ? "questionmark" : "terminal.fill"
        }
    }

    static func label(
        for agentState: AgentState?, state: TTYActivityAttributes.ContentState
    ) -> String {
        switch agentState {
        case .waiting: "Needs you"
        case .error: "Error"
        case .done: "Finished"
        case .running: "Working"
        case nil: state.agentsWaiting > 0 ? "Needs you" : "Live"
        }
    }

    static func color(
        for agentState: AgentState?, state: TTYActivityAttributes.ContentState
    ) -> Color {
        switch agentState {
        case .waiting: PedalsTheme.warning
        case .error: .red
        case .done: .green
        case .running: PedalsTheme.content
        case nil: state.agentsWaiting > 0 ? PedalsTheme.warning : PedalsTheme.content
        }
    }

    static func detail(for agent: AgentActivity.Content) -> String {
        switch agent.state {
        case .running: agent.action ?? agent.prompt ?? "Working…"
        case .waiting: agent.message ?? agent.prompt ?? "Waiting for your input"
        case .error: agent.message ?? "The agent stopped with an error"
        case .done: agent.message ?? "Task completed"
        }
    }

    static func asset(for slug: String) -> String? {
        switch slug {
        case "claude": "claude-code-mark"
        case "codex": "codex-mark"
        case "copilot": "copilot-mark"
        case "grok": "grok-mark"
        case "hermes": "hermes-mark"
        case "kimi": "kimi-mark"
        case "kiro": "kiro-mark"
        case "omp": "omp-mark"
        case "opencode": "opencode-mark"
        case "pi": "pi-mark"
        default: nil
        }
    }
}

private extension TTYActivityAttributes.ContentState {
    var recentAgent: AgentActivity.Content? {
        #if DEBUG
        if recentAgentComputerID == "fixture", recentAgentSealed == "fixture",
           let state = recentAgentState.flatMap(AgentState.init(rawValue:))
        {
            return .init(
                id: "fixture", agent: "codex", state: state, project: "pedals",
                prompt: "Review the Live Activity experience",
                action: "Build: PedalsWidgets",
                message: state == .done ? "Live Activity is ready" : "Choose how to continue",
                sessionId: 1,
                updatedAt: recentAgentUpdatedAt?.timeIntervalSince1970 ?? Date.now.timeIntervalSince1970
            )
        }
        #endif
        guard let computerID = recentAgentComputerID,
              let sealedText = recentAgentSealed,
              let sealed = Data(base64Encoded: sealedText),
              let keyData = AgentActivityKeyStore.key(forComputer: computerID)
        else { return nil }
        return try? AgentActivity.open(
            sealed,
            key: SymmetricKey(data: keyData),
            computerID: computerID
        )
    }

    var totalAgents: Int { agentsRunning + agentsWaiting + agentsDone }

    var compactCount: Int {
        if agentsWaiting > 0 { return agentsWaiting }
        if agentsDone > 0 { return agentsDone }
        if agentsRunning > 0 { return agentsRunning }
        return totalRunning
    }
}
