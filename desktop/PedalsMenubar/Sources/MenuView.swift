import AppKit
import SwiftUI

struct MenuView: View {
    @EnvironmentObject private var model: AppModel
    @State private var showingPairingCode = false

    var body: some View {
        Group {
            if model.hasCompletedOnboarding {
                dashboard
            } else {
                DesktopOnboardingView()
            }
        }
        .tint(PedalsTheme.content)
        .task {
            await model.pollWhileOpen()
        }
        .onDisappear {
            showingPairingCode = false
            model.clearPairingCode()
        }
    }

    private var dashboard: some View {
        VStack(alignment: .leading, spacing: 0) {
            header
            Divider()
            sessionList
            if showingPairingCode {
                Divider()
                pairingSection
            }
            if let error = model.lastError {
                Divider()
                Label(error, systemImage: "exclamationmark.triangle")
                    .font(.caption)
                    .foregroundStyle(PedalsTheme.critical)
                    .lineLimit(2)
                    .padding(.horizontal, 12)
                    .padding(.vertical, 8)
            }
            Divider()
            footer
        }
        .frame(width: 360)
    }

    // MARK: Header

    private var header: some View {
        HStack(spacing: 8) {
            Circle()
                .fill(PedalsTheme.content.opacity(model.relayState.indicatorOpacity))
                .frame(width: 9, height: 9)
            VStack(alignment: .leading, spacing: 1) {
                Text("Pedals")
                    .font(.headline)
                Text(statusLine)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            Spacer()
            SettingsLink {
                Image(systemName: "gearshape")
            }
            .buttonStyle(.borderless)
            .help("Settings")
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 10)
    }

    private var statusLine: String {
        guard model.daemonReachable else { return RelayState.daemonNotRunning.label }
        var parts = [model.relayState.label]
        if model.clientConnected { parts.append("client connected") }
        return parts.joined(separator: " · ")
    }

    // MARK: Sessions

    private var sessionList: some View {
        VStack(alignment: .leading, spacing: 0) {
            if model.sessions.isEmpty {
                Text(model.daemonReachable ? "No sessions" : "Start the daemon to manage sessions")
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity, alignment: .center)
                    .padding(.vertical, 14)
            } else {
                ForEach(model.sessions) { session in
                    SessionRow(session: session) {
                        model.closeSession(session.id)
                    }
                }
            }
            Divider()
            HStack(spacing: 12) {
                Button {
                    model.newSession()
                } label: {
                    Label("New Session", systemImage: "plus")
                }
                Button {
                    showingPairingCode.toggle()
                    if showingPairingCode {
                        model.fetchPairingCode()
                    } else {
                        model.clearPairingCode()
                    }
                } label: {
                    Label(showingPairingCode ? "Hide Connection Code" : "Connect iPhone", systemImage: "number")
                }
                Spacer()
            }
            .buttonStyle(.borderless)
            .controlSize(.small)
            .disabled(!model.daemonReachable)
            .padding(.horizontal, 12)
            .padding(.vertical, 8)
        }
    }

    // MARK: Pairing

    private var pairingSection: some View {
        DesktopPairingPanel(
            code: model.pairingCode,
            expiresAt: model.pairingExpiresAt,
            isLoading: model.isLoadingPairingCode,
            onRefresh: model.fetchPairingCode
        )
        .padding(12)
    }

    // MARK: Footer

    private var footer: some View {
        HStack {
            if model.managesDaemon {
                Button("Stop Daemon") { model.stopDaemon() }
            } else if !model.daemonReachable {
                Button("Start Daemon") { model.startDaemon() }
            } else {
                Text("Daemon running")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            Spacer()
            Button("Quit") { NSApplication.shared.terminate(nil) }
                .keyboardShortcut("q")
        }
        .buttonStyle(.borderless)
        .controlSize(.small)
        .padding(.horizontal, 12)
        .padding(.vertical, 10)
    }
}

private struct SessionRow: View {
    let session: SessionInfo
    let onClose: () -> Void
    @State private var hovering = false

    var body: some View {
        HStack(spacing: 8) {
            Image(systemName: "terminal")
                .foregroundStyle(session.alive ? .primary : .tertiary)
                .frame(width: 16)
            VStack(alignment: .leading, spacing: 1) {
                Text(session.title)
                    .font(.body)
                    .lineLimit(1)
                Text(subtitle)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }
            Spacer()
            Button {
                onClose()
            } label: {
                Image(systemName: "xmark.circle.fill")
                    .foregroundStyle(.secondary)
            }
            .buttonStyle(.borderless)
            .opacity(hovering ? 1 : 0.35)
            .help("Close session")
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 5)
        .contentShape(Rectangle())
        .onHover { hovering = $0 }
    }

    private var subtitle: String {
        var parts: [String] = []
        if let cwd = session.cwd, !cwd.isEmpty {
            parts.append((cwd as NSString).abbreviatingWithTildeInPath)
        }
        if !session.alive { parts.append("exited") }
        return parts.isEmpty ? "session \(session.id)" : parts.joined(separator: " · ")
    }
}
