import AppKit
import SwiftUI

struct SettingsView: View {
    @AppStorage(AppModel.daemonPathKey) private var daemonPath = AppModel.defaultDaemonPath

    var body: some View {
        Form {
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
