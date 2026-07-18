import SwiftUI

@main
struct PedalsMenubarApp: App {
    @StateObject private var model = AppModel()
    @StateObject private var updater = UpdaterModel()

    var body: some Scene {
        MenuBarExtra {
            MenuView()
                .environmentObject(model)
                .environmentObject(updater)
        } label: {
            Image(systemName: "terminal")
        }
        .menuBarExtraStyle(.window)

        Settings {
            SettingsView()
                .environmentObject(updater)
        }
    }
}
