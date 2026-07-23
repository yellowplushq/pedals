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
            let presentation = ActivityPresentation(state: state)
            return DynamicIsland {
                DynamicIslandExpandedRegion(.leading) {
                    Group {
                        if presentation.showsAgent {
                            AgentIdentity(presentation: presentation)
                        } else {
                            TerminalIdentity()
                        }
                    }
                    .padding(.leading, 4)
                    .padding(.top, 2)
                }
                DynamicIslandExpandedRegion(.trailing) {
                    ActivityStateLabel(presentation: presentation)
                        .padding(.trailing, 4)
                        .padding(.top, 2)
                }
                DynamicIslandExpandedRegion(.bottom) {
                    ActivityBody(
                        state: state, presentation: presentation, stale: context.isStale
                    )
                        .padding(.horizontal, 6)
                        .padding(.bottom, 7)
                        .privacySensitive()
                }
            } compactLeading: {
                CompactMark(presentation: presentation)
            } compactTrailing: {
                CompactValue(state: state, presentation: presentation)
            } minimal: {
                CompactMark(presentation: presentation)
            }
            .keylineTint(ActivityStyle.color(for: presentation))
        }
    }
}

private struct ActivityCard: View {
    let state: TTYActivityAttributes.ContentState
    let stale: Bool

    var body: some View {
        let presentation = ActivityPresentation(state: state)
        Group {
            if presentation.showsAgent {
                AgentActivityRow(
                    state: state, presentation: presentation, stale: stale
                )
            } else {
                TerminalActivityCard(state: state, stale: stale)
            }
        }
    }
}

private struct ActivityPresentation {
    let agent: AgentActivity.Content?
    let agentState: AgentState?

    init(state: TTYActivityAttributes.ContentState) {
        let fallbackState = state.displayedAgentState
        let decodedAgent = fallbackState == nil ? nil : state.recentAgent
        agent = decodedAgent
        agentState = decodedAgent?.state ?? fallbackState
    }

    var showsAgent: Bool { agentState != nil }

    var agentName: String {
        guard let agent else { return "Agent" }
        return AgentActivity.displayName(forAgent: agent.agent)
    }

    var agentContent: AgentActivity.Presentation? {
        agent.map { AgentActivity.Presentation(content: $0) }
    }
}

/// The same visual anchor as a Home agent row: the real agent mark with its
/// current state sitting on the mark's top-right corner.
private struct AgentMark: View {
    let presentation: ActivityPresentation
    var size: CGFloat = 22

    var body: some View {
        let badgeSize: CGFloat = size >= 22 ? 10 : 8
        ZStack(alignment: .topLeading) {
            if let agent = presentation.agent,
               let asset = ActivityStyle.asset(for: agent.agent)
            {
                Image(asset)
                    .resizable()
                    .scaledToFit()
                    .frame(width: size, height: size)
                    .offset(y: 4)
            } else {
                Image(systemName: "sparkles")
                    .font(.system(size: size * 0.72, weight: .semibold))
                    .frame(width: size, height: size)
                    .offset(y: 4)
            }

            if let agentState = presentation.agentState, agentState != .done {
                Circle()
                    .fill(ActivityStyle.color(for: presentation))
                    .frame(width: badgeSize, height: badgeSize)
                    .overlay {
                        Circle()
                            .stroke(PedalsTheme.canvas, lineWidth: size >= 22 ? 2 : 1.5)
                    }
                    .offset(x: size - badgeSize / 2 - 1)
                    .accessibilityHidden(true)
            }
        }
        .frame(width: size + 4, height: size + 4, alignment: .topLeading)
        .foregroundStyle(PedalsTheme.content)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(
            "\(presentation.agentName), \(ActivityStyle.label(for: presentation))"
        )
    }
}

private struct AgentIdentity: View {
    let presentation: ActivityPresentation

    var body: some View {
        HStack(spacing: 7) {
            AgentMark(presentation: presentation)
                .accessibilityHidden(true)
            Text(presentation.agentName)
                .font(.subheadline.weight(.semibold))
                .lineLimit(1)
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(
            "\(presentation.agentName), \(ActivityStyle.label(for: presentation))"
        )
    }
}

private struct TerminalIdentity: View {
    var body: some View {
        Label("Pedals", systemImage: "terminal.fill")
            .font(.subheadline.weight(.semibold))
            .lineLimit(1)
    }
}

/// Text instead of a filled capsule keeps the expanded island at the same
/// visual weight as Home's trailing relative time.
private struct ActivityStateLabel: View {
    let presentation: ActivityPresentation

    var body: some View {
        Text(ActivityStyle.label(for: presentation))
            .font(.caption2.weight(.semibold))
            .foregroundStyle(ActivityStyle.color(for: presentation))
            .lineLimit(1)
    }
}

private struct ActivityBody: View {
    let state: TTYActivityAttributes.ContentState
    let presentation: ActivityPresentation
    let stale: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: 7) {
            if presentation.showsAgent {
                Text(ActivityStyle.primary(for: presentation, state: state))
                    .font(.headline)
                    .lineLimit(1)
                Text(ActivityStyle.detail(for: presentation))
                    .font(.subheadline)
                    .foregroundStyle(ActivityStyle.color(for: presentation))
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

            ActivityMetrics(state: state, stale: stale)
        }
        .privacySensitive()
    }
}

/// Lock Screen form of the Home agent list item: icon and state badge leading,
/// session name over the latest output/action, metadata trailing.
private struct AgentActivityRow: View {
    let state: TTYActivityAttributes.ContentState
    let presentation: ActivityPresentation
    let stale: Bool

    var body: some View {
        HStack(alignment: .top, spacing: 10) {
            AgentMark(presentation: presentation)
                .accessibilityHidden(true)

            VStack(alignment: .leading, spacing: 5) {
                HStack(alignment: .firstTextBaseline, spacing: 8) {
                    Text(ActivityStyle.primary(for: presentation, state: state))
                        .font(.headline)
                        .lineLimit(1)
                    Spacer(minLength: 8)
                    ActivityStateLabel(presentation: presentation)
                }
                Text(ActivityStyle.detail(for: presentation))
                    .font(.subheadline)
                    .foregroundStyle(ActivityStyle.color(for: presentation))
                    .lineLimit(2)
                ActivityMetrics(state: state, stale: stale)
            }
            .privacySensitive()
        }
        .accessibilityElement(children: .combine)
        .accessibilityLabel(presentation.agentName)
        .accessibilityValue(
            "\(ActivityStyle.label(for: presentation)), "
                + "\(ActivityStyle.primary(for: presentation, state: state)), "
                + ActivityStyle.detail(for: presentation)
        )
    }
}

private struct TerminalActivityCard: View {
    let state: TTYActivityAttributes.ContentState
    let stale: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                TerminalIdentity()
                Spacer(minLength: 8)
                Text("Live")
                    .font(.caption2.weight(.semibold))
            }
            ActivityBody(
                state: state, presentation: ActivityPresentation(state: state), stale: stale
            )
        }
    }
}

private struct ActivityMetrics: View {
    let state: TTYActivityAttributes.ContentState
    let stale: Bool

    var body: some View {
        HStack(spacing: 6) {
            if state.totalAgents > 0 {
                MetricChip(
                    text: state.totalAgents == 1 ? "1 agent" : "\(state.totalAgents) agents"
                )
            }
            MetricChip(text: "\(state.totalRunning) TTY")
            if state.offlineComputerCount > 0 {
                MetricChip(text: "\(state.offlineComputerCount) offline")
            }
            if stale {
                MetricChip(text: "stale")
            }
        }
        .lineLimit(1)
    }
}

/// Home uses one-pixel outline chips rather than filled metric pills.
private struct MetricChip: View {
    let text: String

    var body: some View {
        Text(text)
            .font(.caption2)
            .foregroundStyle(PedalsTheme.secondaryContent)
            .padding(.horizontal, 7)
            .padding(.vertical, 3)
            .overlay {
                Capsule().stroke(PedalsTheme.separator, lineWidth: 1)
            }
    }
}

private struct CompactMark: View {
    let presentation: ActivityPresentation

    var body: some View {
        Group {
            if presentation.showsAgent {
                AgentMark(presentation: presentation, size: 17)
            } else {
                Image(systemName: "terminal.fill")
                    .frame(width: 17, height: 17)
            }
        }
        .foregroundStyle(PedalsTheme.content)
        .accessibilityLabel(ActivityStyle.label(for: presentation))
    }
}

private struct CompactValue: View {
    let state: TTYActivityAttributes.ContentState
    let presentation: ActivityPresentation

    var body: some View {
        Group {
            if presentation.showsAgent {
                Text(ActivityStyle.compactLabel(for: presentation))
                    .font(.caption2.weight(.bold))
            } else {
                Text(state.totalRunning, format: .number)
                .fontWeight(.bold)
                .monospacedDigit()
                .contentTransition(.numericText())
            }
        }
        .foregroundStyle(ActivityStyle.color(for: presentation))
        .accessibilityLabel(ActivityStyle.label(for: presentation))
    }
}

private enum ActivityStyle {
    static func label(for presentation: ActivityPresentation) -> String {
        switch presentation.agentState {
        case .waiting: "Needs you"
        case .error: "Error"
        case .done: "Finished"
        case .running: "Working"
        case nil: "Live"
        }
    }

    static func compactLabel(for presentation: ActivityPresentation) -> String {
        switch presentation.agentState {
        case .waiting: "Needs you"
        case .error: "Error"
        case .done: "Done"
        case .running: "Working"
        case nil: "Live"
        }
    }

    static func color(for presentation: ActivityPresentation) -> Color {
        switch presentation.agentState {
        case .waiting: PedalsTheme.warning
        case .error: PedalsTheme.critical
        case .done: PedalsTheme.success
        case .running: PedalsTheme.content
        case nil: PedalsTheme.content
        }
    }

    static func primary(
        for presentation: ActivityPresentation,
        state: TTYActivityAttributes.ContentState
    ) -> String {
        guard let agent = presentation.agent else {
            return state.totalAgents == 1
                ? "1 agent active" : "\(state.totalAgents) agents active"
        }
        return presentation.agentContent?.title
            ?? AgentActivity.displayName(forAgent: agent.agent)
    }

    static func detail(for presentation: ActivityPresentation) -> String {
        guard presentation.agent != nil else {
            return fallbackDetail(for: presentation.agentState)
        }
        return presentation.agentContent?.detail
            ?? fallbackDetail(for: presentation.agentState)
    }

    private static func fallbackDetail(for state: AgentState?) -> String {
        switch state {
        case .running: "Working…"
        case .waiting: "Waiting for your input"
        case .error: "Agent hit an error"
        case .done: "Task completed"
        case nil: "Agent activity is updating…"
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
                id: "fixture", agent: "codex", state: state,
                sessionName: "Polish agent monitoring", project: "pedals",
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

}
