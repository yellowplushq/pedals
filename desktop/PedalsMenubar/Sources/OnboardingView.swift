import AppKit
import SwiftUI

/// First-run flow for the menu-bar host. Its stages are derived from the
/// daemon and relay rather than mirrored in a second state machine.
struct DesktopOnboardingView: View {
    @EnvironmentObject private var model: AppModel

    private var pairingReady: Bool {
        model.daemonReachable && model.relayState == .connected && !model.clientConnected
    }

    var body: some View {
        VStack(spacing: 0) {
            OnboardingHeader()
            Divider()

            Group {
                if !model.daemonReachable {
                    welcome
                } else if model.relayState != .connected {
                    connecting
                } else if model.clientConnected {
                    success
                } else {
                    pairing
                }
            }
            .padding(18)

            if let error = model.lastError {
                Divider()
                ErrorBanner(message: error)
                    .padding(12)
            }
        }
        .frame(width: 360)
        .font(PedalsTheme.text)
        .background(PedalsTheme.canvas)
        .task(id: pairingReady) {
            if pairingReady, model.pairingCode == nil, !model.isLoadingPairingCode {
                model.fetchPairingCode()
            }
        }
        .onDisappear {
            if !model.hasCompletedOnboarding { model.clearPairingCode() }
        }
    }

    private var welcome: some View {
        VStack(spacing: 18) {
            DeviceRelayGraphic(relayActive: false)

            VStack(spacing: 7) {
                Text("Your computer, within reach")
                    .font(PedalsTheme.emphasizedText)
                    .foregroundStyle(PedalsTheme.content)
                Text("Control this computer from iPhone through Pedals—even away from your local network.")
                    .foregroundStyle(PedalsTheme.secondaryContent)
                    .multilineTextAlignment(.center)
                    .fixedSize(horizontal: false, vertical: true)
            }

            VStack(spacing: 9) {
                OnboardingFact(
                    icon: "lock.shield",
                    title: "End-to-end encrypted",
                    detail: "Terminal content stays on your devices."
                )
                OnboardingFact(
                    icon: "bolt.horizontal",
                    title: "Available away from home",
                    detail: "Both devices connect outward to pedals.air.build."
                )
            }

            Button {
                model.startDaemon()
            } label: {
                HStack(spacing: 8) {
                    if model.isStartingDaemon {
                        ProgressView()
                            .controlSize(.small)
                    } else {
                        Image(systemName: "play.fill")
                    }
                    Text(model.isStartingDaemon ? "Starting Pedals…" : "Set Up This Computer")
                        .font(PedalsTheme.emphasizedText)
                }
                .frame(maxWidth: .infinity)
            }
            .buttonStyle(MonochromeProminentButtonStyle())
            .disabled(model.isStartingDaemon)

            SettingsLink {
                Label("Daemon settings", systemImage: "gearshape")
            }
            .buttonStyle(.borderless)
            .foregroundStyle(PedalsTheme.secondaryContent)
        }
    }

    private var connecting: some View {
        VStack(spacing: 18) {
            DeviceRelayGraphic(relayActive: true)

            ProgressView()
                .controlSize(.small)

            VStack(spacing: 6) {
                Text("Connecting this computer")
                    .font(PedalsTheme.emphasizedText)
                    .foregroundStyle(PedalsTheme.content)
                Text("Registering with pedals.air.build. Your pairing code will appear shortly.")
                    .foregroundStyle(PedalsTheme.secondaryContent)
                    .multilineTextAlignment(.center)
                    .fixedSize(horizontal: false, vertical: true)
            }

            StatusPill(text: model.relayState.label, systemImage: "arrow.triangle.2.circlepath")
        }
        .padding(.vertical, 18)
    }

    private var pairing: some View {
        VStack(spacing: 14) {
            DesktopPairingPanel(
                code: model.pairingCode,
                expiresAt: model.pairingExpiresAt,
                isLoading: model.isLoadingPairingCode,
                onRefresh: model.fetchPairingCode
            )
            StatusPill(text: "Waiting for iPhone", systemImage: "iphone.radiowaves.left.and.right")
        }
    }

    private var success: some View {
        VStack(spacing: 18) {
            ZStack {
                Circle()
                    .fill(PedalsTheme.content)
                    .frame(width: 76, height: 76)
                Image(systemName: "checkmark")
                    .font(.system(size: 31, weight: .bold))
                    .foregroundStyle(PedalsTheme.canvas)
            }

            VStack(spacing: 7) {
                Text("iPhone connected")
                    .font(PedalsTheme.emphasizedText)
                    .foregroundStyle(PedalsTheme.content)
                Text("The service approved this device. Your encrypted connection is ready.")
                    .foregroundStyle(PedalsTheme.secondaryContent)
                    .multilineTextAlignment(.center)
                    .fixedSize(horizontal: false, vertical: true)
            }

            Button("Continue") {
                model.completeOnboarding()
            }
            .font(PedalsTheme.emphasizedText)
            .buttonStyle(MonochromeProminentButtonStyle())
            .frame(maxWidth: .infinity)
        }
        .padding(.vertical, 28)
    }
}

/// The reusable pairing surface used for first run and for adding another
/// phone later from the normal menu.
struct DesktopPairingPanel: View {
    let code: String?
    let expiresAt: Date?
    let isLoading: Bool
    let onRefresh: () -> Void

    var body: some View {
        VStack(spacing: 14) {
            VStack(spacing: 5) {
                Text("Connect")
                    .font(PedalsTheme.emphasizedText)
                    .foregroundStyle(PedalsTheme.content)
                Text("Enter this code on your iPhone to connect.")
                    .foregroundStyle(PedalsTheme.secondaryContent)
                    .multilineTextAlignment(.center)
            }

            RoundedRectangle(cornerRadius: 14, style: .continuous)
                .fill(PedalsTheme.canvas)
                .frame(height: 76)
                .overlay {
                    if let code {
                        Text(formatted(code))
                            .font(PedalsTheme.emphasizedText.monospaced())
                            .tracking(3)
                            .foregroundStyle(PedalsTheme.content)
                            .accessibilityLabel("Pairing code \(code)")
                    } else if isLoading {
                        ProgressView().controlSize(.small)
                    } else {
                        Text("Code unavailable")
                            .foregroundStyle(PedalsTheme.tertiaryContent)
                    }
                }
                .overlay {
                    RoundedRectangle(cornerRadius: 14, style: .continuous)
                        .stroke(PedalsTheme.separator, lineWidth: 1)
                }

            HStack(spacing: 10) {
                Button {
                    copy(code)
                } label: {
                    Label("Copy Code", systemImage: "doc.on.doc")
                }
                .disabled(code == nil)

                Button(action: onRefresh) {
                    Label("New Code", systemImage: "arrow.clockwise")
                }
                .disabled(isLoading)
            }
            .buttonStyle(.borderless)
            .controlSize(.small)

            VStack(spacing: 5) {
                if let expiresAt {
                    TimelineView(.periodic(from: .now, by: 1)) { context in
                        Label(remaining(until: expiresAt, now: context.date), systemImage: "clock")
                    }
                } else {
                    Label("Single-use · valid for 15 minutes", systemImage: "clock")
                }
                Label("Approved by pedals.air.build", systemImage: "lock.shield")
            }
            .foregroundStyle(PedalsTheme.tertiaryContent)
        }
        .frame(maxWidth: .infinity)
        .font(PedalsTheme.text)
        .padding(16)
        .background(PedalsTheme.surface, in: RoundedRectangle(cornerRadius: 18))
        .overlay {
            RoundedRectangle(cornerRadius: 18)
                .stroke(PedalsTheme.separator, lineWidth: 1)
        }
    }

    private func copy(_ value: String?) {
        guard let value else { return }
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(value, forType: .string)
    }

    private func formatted(_ value: String) -> String {
        guard value.count == 8 else { return value }
        return "\(value.prefix(4))  \(value.suffix(4))"
    }

    private func remaining(until expiry: Date, now: Date) -> String {
        let seconds = max(0, Int(expiry.timeIntervalSince(now)))
        return String(format: "Expires in %02d:%02d", seconds / 60, seconds % 60)
    }
}

private struct OnboardingHeader: View {
    var body: some View {
        HStack(spacing: 10) {
            ZStack {
                RoundedRectangle(cornerRadius: 8, style: .continuous)
                    .fill(PedalsTheme.content)
                Image(systemName: "terminal")
                    .font(.system(size: 14, weight: .bold))
                    .foregroundStyle(PedalsTheme.canvas)
            }
            .frame(width: 30, height: 30)

            Text("Pedals")
                .font(PedalsTheme.emphasizedText)
                .foregroundStyle(PedalsTheme.content)
            Spacer()
            Text("Remote terminal")
                .foregroundStyle(PedalsTheme.secondaryContent)
            SettingsLink {
                Image(systemName: "gearshape")
            }
            .buttonStyle(.borderless)
            .help("Settings")
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 11)
    }
}

private struct DeviceRelayGraphic: View {
    let relayActive: Bool

    var body: some View {
        HStack(spacing: 8) {
            DeviceGlyph(systemImage: "desktopcomputer", label: "Computer")
            DottedLink()
            VStack(spacing: 5) {
                ZStack {
                    Circle()
                        .fill(relayActive ? PedalsTheme.content : PedalsTheme.surface)
                    Image(systemName: "lock.shield")
                        .font(.system(size: 16, weight: .medium))
                        .foregroundStyle(
                            relayActive ? PedalsTheme.canvas : PedalsTheme.secondaryContent
                        )
                }
                .frame(width: 42, height: 42)
                Text("Pedals service")
                    .foregroundStyle(PedalsTheme.secondaryContent)
            }
            DottedLink()
            DeviceGlyph(systemImage: "iphone", label: "iPhone")
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 8)
    }
}

private struct DeviceGlyph: View {
    let systemImage: String
    let label: String

    var body: some View {
        VStack(spacing: 5) {
            Image(systemName: systemImage)
                .font(.system(size: 30, weight: .light))
                .frame(width: 48, height: 42)
            Text(label)
                .foregroundStyle(PedalsTheme.secondaryContent)
        }
    }
}

private struct DottedLink: View {
    var body: some View {
        HStack(spacing: 4) {
            ForEach(0..<4, id: \.self) { _ in
                Circle()
                    .fill(PedalsTheme.tertiaryContent)
                    .frame(width: 3, height: 3)
            }
        }
    }
}

private struct OnboardingFact: View {
    let icon: String
    let title: String
    let detail: String

    var body: some View {
        HStack(spacing: 10) {
            Image(systemName: icon)
                .font(.system(size: 15, weight: .medium))
                .frame(width: 28, height: 28)
                .background(PedalsTheme.surface, in: RoundedRectangle(cornerRadius: 8))
            VStack(alignment: .leading, spacing: 1) {
                Text(title)
                    .font(PedalsTheme.emphasizedText)
                    .foregroundStyle(PedalsTheme.content)
                Text(detail)
                    .foregroundStyle(PedalsTheme.secondaryContent)
                    .fixedSize(horizontal: false, vertical: true)
            }
            Spacer(minLength: 0)
        }
    }
}

private struct StatusPill: View {
    let text: String
    let systemImage: String

    var body: some View {
        Label(text, systemImage: systemImage)
            .foregroundStyle(PedalsTheme.tertiaryContent)
            .padding(.horizontal, 10)
            .padding(.vertical, 6)
            .background(PedalsTheme.surface, in: Capsule())
    }
}

private struct ErrorBanner: View {
    let message: String

    var body: some View {
        HStack(alignment: .top, spacing: 8) {
            Image(systemName: "exclamationmark.triangle")
                .foregroundStyle(PedalsTheme.critical)
            Text(message)
                .foregroundStyle(PedalsTheme.secondaryContent)
                .lineLimit(3)
            Spacer(minLength: 0)
        }
        .padding(10)
        .background(PedalsTheme.surface, in: RoundedRectangle(cornerRadius: 10))
    }
}

private struct MonochromeProminentButtonStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(PedalsTheme.emphasizedText)
            .foregroundStyle(PedalsTheme.canvas)
            .padding(.horizontal, 14)
            .frame(maxWidth: .infinity, minHeight: 36)
            .background(
                PedalsTheme.content.opacity(configuration.isPressed ? 0.72 : 1),
                in: RoundedRectangle(cornerRadius: 9, style: .continuous)
            )
    }
}
