import AppKit
import SwiftUI

struct SettingsView: View {
    @EnvironmentObject private var updaterModel: UpdaterModel
    @EnvironmentObject private var permissions: PermissionsModel
    @State private var automaticallyChecksForUpdates = true
    @State private var automaticallyDownloadsUpdates = true

    var body: some View {
        Form {
            Section("Remote Session Permissions") {
                Text(Self.permissionsExplanation)
                    .foregroundStyle(PedalsTheme.secondaryContent)

                ForEach(RemotePermission.allCases) { permission in
                    PermissionRow(
                        permission: permission,
                        granted: permissions.isGranted(permission)
                    ) {
                        permissions.request(permission)
                    }
                }

                Text(Self.permissionsFootnote)
                    .font(.caption)
                    .foregroundStyle(PedalsTheme.secondaryContent)
            }

            Section("Updates") {
                Toggle("Automatically check for updates", isOn: $automaticallyChecksForUpdates)
                Toggle("Download and install updates automatically", isOn: $automaticallyDownloadsUpdates)
                    .disabled(!automaticallyChecksForUpdates)
                Button("Check for Updates…") {
                    updaterModel.checkForUpdates()
                }
                .disabled(!updaterModel.canCheckForUpdates)
            }

            Section("About") {
                LabeledContent("Version", value: version)
                Text("Pedals stays available while its menu bar icon is visible.")
                    .foregroundStyle(PedalsTheme.secondaryContent)
            }
        }
        .formStyle(.grouped)
        .tint(PedalsTheme.content)
        .frame(width: 420)
        .fixedSize(horizontal: false, vertical: true)
        .onAppear {
            NSApp.activate(ignoringOtherApps: true)
            automaticallyChecksForUpdates = updaterModel.updater.automaticallyChecksForUpdates
            automaticallyDownloadsUpdates = updaterModel.updater.automaticallyDownloadsUpdates
            permissions.refresh()
            permissions.startLivePolling()
        }
        .onDisappear {
            permissions.stopLivePolling()
        }
        .onChange(of: automaticallyChecksForUpdates) { _, value in
            updaterModel.updater.automaticallyChecksForUpdates = value
        }
        .onChange(of: automaticallyDownloadsUpdates) { _, value in
            updaterModel.updater.automaticallyDownloadsUpdates = value
        }
    }

    private static let permissionsExplanation = """
        Pedals asks for these up front so programs running in remote terminal \
        sessions can use them without approval prompts appearing on this Mac \
        while you're away. Pedals itself never reads your files, controls \
        your Mac, or records your screen.
        """

    private static let permissionsFootnote = """
        Grants apply to new sessions. macOS may ask to relaunch Pedals after \
        screen recording is enabled.
        """

    private struct PermissionRow: View {
        let permission: RemotePermission
        let granted: Bool
        let onGrant: () -> Void

        var body: some View {
            HStack(spacing: 10) {
                Image(systemName: permission.symbolName)
                    .frame(width: 22)
                    .foregroundStyle(PedalsTheme.secondaryContent)
                VStack(alignment: .leading, spacing: 2) {
                    Text(permission.title)
                    Text(permission.detail)
                        .font(.caption)
                        .foregroundStyle(PedalsTheme.secondaryContent)
                }
                Spacer()
                if granted {
                    Label("Granted", systemImage: "checkmark.circle.fill")
                        .foregroundStyle(.green)
                } else {
                    Button("Grant…") {
                        onGrant()
                    }
                }
            }
        }
    }

    private var version: String {
        let marketing = Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString")
            as? String ?? "—"
        let build = Bundle.main.object(forInfoDictionaryKey: "CFBundleVersion")
            as? String ?? "—"
        return "\(marketing) (\(build))"
    }
}
