import SwiftUI
@preconcurrency import WidgetKit

struct TTYStatusEntry: TimelineEntry, Sendable {
    let date: Date
    let snapshot: TTYStatusSnapshot
}

struct TTYStatusProvider: TimelineProvider {
    func placeholder(in context: Context) -> TTYStatusEntry {
        .init(
            date: .now,
            snapshot: .init(
                totalRunning: 3,
                computers: [
                    .init(
                        id: "preview",
                        name: "Computer",
                        runningTTYCount: 3,
                        online: true,
                        updatedAt: .now
                    ),
                ],
                updatedAt: .now,
                sequence: 1
            )
        )
    }

    func getSnapshot(
        in context: Context,
        completion: @escaping @Sendable (TTYStatusEntry) -> Void
    ) {
        if context.isPreview {
            completion(placeholder(in: context))
            return
        }
        completion(.init(date: .now, snapshot: StatusSharedStore.snapshot()))
    }

    func getTimeline(
        in context: Context,
        completion: @escaping @Sendable (Timeline<TTYStatusEntry>) -> Void
    ) {
        StatusSharedStore.activateObservedWidgetPushEndpoint(.iOSWidget)
        PushEndpointRegistrar.requestFlush()
        Task {
            let snapshot = await loadSnapshot()
            completion(
                Timeline(
                    entries: [.init(date: .now, snapshot: snapshot)],
                    policy: .after(.now.addingTimeInterval(15 * 60))
                )
            )
        }
    }

    private func loadSnapshot() async -> TTYStatusSnapshot {
        do {
            return try await PedalsStatusRuntime.refreshState()
        } catch {
            var cached = StatusSharedStore.snapshot()
            cached.stale = true
            return cached
        }
    }
}

struct TTYCountWidget: Widget {
    var body: some WidgetConfiguration {
        StaticConfiguration(
            kind: PedalsStatusConstants.phoneWidgetKind,
            provider: TTYStatusProvider()
        ) { entry in
            TTYCountWidgetView(entry: entry)
                .foregroundStyle(PedalsTheme.content)
                .tint(PedalsTheme.content)
                .widgetAccentable(false)
                .containerBackground(PedalsTheme.canvas, for: .widget)
        }
        .configurationDisplayName("Running TTYs")
        .description("The number of terminals running across your paired computers.")
        .supportedFamilies([
            .systemSmall,
            .systemMedium,
            .accessoryCircular,
            .accessoryRectangular,
            .accessoryInline,
        ])
        .pushHandler(IOSWidgetPushHandler.self)
    }
}

private struct TTYCountWidgetView: View {
    @Environment(\.widgetFamily) private var family
    let entry: TTYStatusEntry

    var body: some View {
        switch family {
        case .accessoryCircular:
            ZStack {
                AccessoryWidgetBackground()
                Text(entry.snapshot.totalRunning, format: .number)
                    .font(.title3.bold())
                    .monospacedDigit()
                    .minimumScaleFactor(0.7)
            }

        case .accessoryRectangular:
            HStack(spacing: 8) {
                Text(entry.snapshot.totalRunning, format: .number)
                    .font(.title2.bold())
                    .monospacedDigit()
                    .contentTransition(.numericText())
                VStack(alignment: .leading, spacing: 1) {
                    Text("TTY")
                        .font(.caption2)
                        .foregroundStyle(PedalsTheme.secondaryContent)
                    agentsLabel
                    alertLabel
                }
                Spacer(minLength: 0)
            }

        case .accessoryInline:
            Text(inlineLabel)

        case .systemMedium:
            HStack(spacing: 16) {
                count(size: 56)
                VStack(alignment: .leading, spacing: 4) {
                    Text(unitLabel)
                        .font(.headline)
                    agentsLabel
                    alertLabel
                }
                Spacer(minLength: 0)
            }

        default:
            VStack(alignment: .leading, spacing: 2) {
                Spacer(minLength: 0)
                count(size: 52)
                Text(unitLabel)
                    .font(.caption)
                    .foregroundStyle(PedalsTheme.secondaryContent)
                agentsLabel
                alertLabel
            }
        }
    }

    private var unitLabel: String {
        entry.snapshot.totalRunning == 1 ? "TTY running" : "TTYs running"
    }

    private var inlineLabel: String {
        var value = "\(entry.snapshot.totalRunning) TTY"
        if entry.snapshot.agentsWaiting > 0 {
            value += " · \(entry.snapshot.agentsWaiting) waiting"
        } else if entry.snapshot.agentsRunning > 0 {
            value += " · \(entry.snapshot.agentsRunning) agents"
        }
        guard let alert else { return value }
        return "\(value) · \(alert.text.lowercased())"
    }

    /// Coding-agent aggregate line ("2 running · 1 waiting"). Waiting is the
    /// one state that justifies color under the black/white rule.
    private var agentsLine: (text: String, needsYou: Bool)? {
        let running = entry.snapshot.agentsRunning
        let waiting = entry.snapshot.agentsWaiting
        guard running > 0 || waiting > 0 else { return nil }
        var parts: [String] = []
        if running > 0 { parts.append("\(running) running") }
        if waiting > 0 { parts.append("\(waiting) waiting") }
        return (parts.joined(separator: " · "), waiting > 0)
    }

    @ViewBuilder
    private var agentsLabel: some View {
        if let line = agentsLine {
            Label(line.text, systemImage: "sparkles")
                .font(.caption2)
                .foregroundStyle(
                    line.needsYou ? PedalsTheme.warning : PedalsTheme.secondaryContent
                )
                .lineLimit(1)
        }
    }

    private var alert: (symbol: String, text: String)? {
        if entry.snapshot.stale {
            return ("exclamationmark.triangle.fill", "Waiting for update")
        }
        let offline = entry.snapshot.offlineComputerCount
        if offline > 0 {
            return ("wifi.slash", "\(offline) offline")
        }
        return nil
    }

    private func count(size: CGFloat) -> some View {
        Text(entry.snapshot.totalRunning, format: .number)
            .font(.system(size: size, weight: .bold, design: .rounded))
            .monospacedDigit()
            .minimumScaleFactor(0.5)
            .contentTransition(.numericText())
    }

    @ViewBuilder
    private var alertLabel: some View {
        if let alert {
            Label(alert.text, systemImage: alert.symbol)
                .font(.caption2)
                .foregroundStyle(PedalsTheme.warning)
                .lineLimit(1)
        }
    }

}
