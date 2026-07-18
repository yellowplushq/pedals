import AppKit
import SwiftUI

struct SettingsView: View {
    @EnvironmentObject private var updaterModel: UpdaterModel
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
        }
        .onChange(of: automaticallyChecksForUpdates) { _, value in
            updaterModel.updater.automaticallyChecksForUpdates = value
        }
        .onChange(of: automaticallyDownloadsUpdates) { _, value in
            updaterModel.updater.automaticallyDownloadsUpdates = value
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
