import AppKit
import SwiftUI

struct SettingsView: View {
    @EnvironmentObject private var updaterModel: UpdaterModel
    @AppStorage(AppModel.daemonPathKey) private var daemonPath = AppModel.defaultDaemonPath
    @State private var automaticallyChecksForUpdates = true
    @State private var automaticallyDownloadsUpdates = true

    var body: some View {
        Form {
            Section("Updates") {
                Toggle("Automatically check for updates", isOn: $automaticallyChecksForUpdates)
                Toggle("Download and install updates automatically", isOn: $automaticallyDownloadsUpdates)
                    .disabled(!automaticallyChecksForUpdates)
                Button("Check for Updates…") {
                    updaterModel.checkForUpdates()
                }
                .disabled(!updaterModel.canCheckForUpdates)
            }

            Section {
                TextField("Daemon binary", text: $daemonPath)
                    .font(.body.monospaced())
                HStack {
                    Button("Choose…") { choose() }
                    Button("Reset to Default") { daemonPath = AppModel.defaultDaemonPath }
                        .disabled(daemonPath == AppModel.defaultDaemonPath)
                }
            } footer: {
                Text("Used by “Start Daemon” to launch `pedals serve`.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
        .formStyle(.grouped)
        .tint(PedalsTheme.content)
        .frame(width: 480)
        .fixedSize(horizontal: false, vertical: true)
        .onAppear {
            NSApp.activate(ignoringOtherApps: true)
            automaticallyChecksForUpdates = updaterModel.updater.automaticallyChecksForUpdates
            automaticallyDownloadsUpdates = updaterModel.updater.automaticallyDownloadsUpdates
        }
        .onChange(of: automaticallyChecksForUpdates) { _, value in
            updaterModel.updater.automaticallyChecksForUpdates = value
        }
        .onChange(of: automaticallyDownloadsUpdates) { _, value in
            updaterModel.updater.automaticallyDownloadsUpdates = value
        }
    }

    private func choose() {
        let panel = NSOpenPanel()
        panel.canChooseFiles = true
        panel.canChooseDirectories = false
        panel.allowsMultipleSelection = false
        panel.directoryURL = URL(fileURLWithPath: daemonPath).deletingLastPathComponent()
        if panel.runModal() == .OK, let url = panel.url {
            daemonPath = url.path
        }
    }
}
