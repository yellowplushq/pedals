import Combine
import SwiftUI

struct WatchStatusView: View {
    @State private var snapshot = StatusSharedStore.snapshot()
    @State private var refreshing = false

    var body: some View {
        ScrollView {
            VStack(spacing: 8) {
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
            }
            .frame(maxWidth: .infinity)
        }
        .foregroundStyle(PedalsTheme.content)
        .tint(PedalsTheme.content)
        .navigationTitle("Pedals")
        .task { await refresh() }
        .onReceive(NotificationCenter.default.publisher(for: StatusSharedStore.didChange)) { _ in
            snapshot = StatusSharedStore.snapshot()
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
