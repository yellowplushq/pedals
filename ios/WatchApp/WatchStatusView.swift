import Combine
import SwiftUI

struct WatchStatusView: View {
    let openTerminal: (WatchTerminalDescriptor) -> Void

    @Environment(WatchTerminalStore.self) private var terminalStore
    @State private var snapshot = StatusSharedStore.snapshot()
    @State private var refreshing = false

    var body: some View {
        ScrollView {
            LazyVStack(spacing: 8) {
                Image(systemName: "terminal.fill")
                    .font(.title2)
                    .foregroundStyle(PedalsTheme.content)

                Text(snapshot.totalRunning, format: .number)
                    .font(.system(size: 44, weight: .bold, design: .rounded))
                    .contentTransition(.numericText())

                Text(snapshot.totalRunning == 1 ? "TTY running" : "TTYs running")
                    .font(.headline)

                HStack(spacing: 10) {
                    Label("\(snapshot.onlineComputerCount)", systemImage: "desktopcomputer")
                    if snapshot.offlineComputerCount > 0 {
                        Label("\(snapshot.offlineComputerCount)", systemImage: "wifi.slash")
                            .foregroundStyle(PedalsTheme.warning)
                    }
                }
                .font(.caption)
                .foregroundStyle(PedalsTheme.secondaryContent)

                if snapshot.stale {
                    Text("Waiting for an update")
                        .font(.caption2)
                        .foregroundStyle(PedalsTheme.warning)
                } else {
                    Text(snapshot.updatedAt, style: .relative)
                        .font(.caption2)
                        .foregroundStyle(PedalsTheme.secondaryContent)
                }

                terminalLinks
            }
            .frame(maxWidth: .infinity)
        }
        .foregroundStyle(PedalsTheme.content)
        .tint(PedalsTheme.content)
        .navigationTitle("Pedals")
        .task {
            terminalStore.retryConnections()
            WatchStatusBridge.shared.requestCurrentContext()
            await refresh()
        }
        .onReceive(NotificationCenter.default.publisher(for: StatusSharedStore.didChange)) { _ in
            snapshot = StatusSharedStore.snapshot()
        }
    }

    @ViewBuilder
    private var terminalLinks: some View {
        Divider()
            .padding(.vertical, 4)

        if !terminalStore.hasCredentials {
            Label("Open Pedals on iPhone", systemImage: "iphone.and.arrow.forward")
                .font(.caption)
                .foregroundStyle(PedalsTheme.secondaryContent)
                .multilineTextAlignment(.center)
        } else if terminalStore.computers.allSatisfy({ $0.terminals.isEmpty }) {
            Text("No terminals available")
                .font(.caption)
                .foregroundStyle(PedalsTheme.secondaryContent)
        } else {
            ForEach(terminalStore.computers) { computer in
                if !computer.terminals.isEmpty {
                    Text(computer.name)
                        .font(.caption2.weight(.semibold))
                        .foregroundStyle(PedalsTheme.secondaryContent)
                        .frame(maxWidth: .infinity, alignment: .leading)

                    ForEach(computer.terminals) { terminal in
                        Button {
                            openTerminal(terminal)
                        } label: {
                            HStack(spacing: 6) {
                                Image(systemName: terminal.alive ? "terminal.fill" : "xmark.circle")
                                Text(terminal.title)
                                    .lineLimit(2)
                                    .frame(maxWidth: .infinity, alignment: .leading)
                            }
                            .font(.caption)
                        }
                        .accessibilityLabel("Open terminal \(terminal.title) on \(computer.name)")
                    }
                }
            }
        }
    }

    private func refresh() async {
        guard !refreshing else { return }
        refreshing = true
        defer { refreshing = false }
        if let fresh = try? await PedalsStatusRuntime.refreshState() {
            snapshot = fresh
        } else {
            snapshot = StatusSharedStore.snapshot()
        }
    }
}
