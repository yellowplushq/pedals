import SwiftUI

@main
struct PedalsMenubarApp: App {
    @StateObject private var model = AppModel()

    var body: some Scene {
        MenuBarExtra {
            MenuView()
                .environmentObject(model)
        } label: {
            Image(systemName: "terminal")
        }
        .menuBarExtraStyle(.window)

        Settings {
            SettingsView()
        }
    }
}
