import GhosttyTheme
import UIKit

/// Picks a Ghostty color theme from the bundled catalog (dark themes first).
@MainActor
final class ThemePickerViewController: UITableViewController {
    private let services: AppServices
    private let darkThemes: [GhosttyThemeDefinition]
    private let lightThemes: [GhosttyThemeDefinition]

    init(services: AppServices) {
        self.services = services
        let all = GhosttyThemeCatalog.allThemes.sorted {
            $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending
        }
        darkThemes = all.filter(\.isDark)
        lightThemes = all.filter { !$0.isDark }
        super.init(style: .insetGrouped)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    override func viewDidLoad() {
        super.viewDidLoad()
        title = "Theme"
        tableView.register(UITableViewCell.self, forCellReuseIdentifier: "theme")
    }

    private func themes(in section: Int) -> [GhosttyThemeDefinition] {
        section == 0 ? darkThemes : lightThemes
    }

    override func numberOfSections(in tableView: UITableView) -> Int { 2 }

    override func tableView(
        _ tableView: UITableView, titleForHeaderInSection section: Int
    ) -> String? {
        section == 0 ? "Dark" : "Light"
    }

    override func tableView(_ tableView: UITableView, numberOfRowsInSection section: Int) -> Int {
        themes(in: section).count
    }

    override func tableView(
        _ tableView: UITableView, cellForRowAt indexPath: IndexPath
    ) -> UITableViewCell {
        let cell = tableView.dequeueReusableCell(withIdentifier: "theme", for: indexPath)
        let theme = themes(in: indexPath.section)[indexPath.row]

        var content = cell.defaultContentConfiguration()
        content.text = theme.name
        content.image = UIImage(systemName: "circle.fill")
        content.imageProperties.tintColor = UIColor(hex: theme.background)
        content.imageProperties.maximumSize = CGSize(width: 18, height: 18)
        cell.contentConfiguration = content
        cell.accessoryType =
            theme.name == services.preferences.themeName ? .checkmark : .none
        return cell
    }

    override func tableView(_ tableView: UITableView, didSelectRowAt indexPath: IndexPath) {
        tableView.deselectRow(at: indexPath, animated: true)
        services.preferences.themeName = themes(in: indexPath.section)[indexPath.row].name
        services.applyTerminalAppearance()
        tableView.reloadData()
    }
}

extension UIColor {
    /// Parses "RRGGBB" / "#RRGGBB"; used for theme swatches.
    convenience init?(hex: String) {
        let hex = hex.hasPrefix("#") ? String(hex.dropFirst()) : hex
        guard hex.count == 6,
              let r = UInt8(hex.prefix(2), radix: 16),
              let g = UInt8(hex.dropFirst(2).prefix(2), radix: 16),
              let b = UInt8(hex.dropFirst(4).prefix(2), radix: 16)
        else { return nil }
        self.init(
            red: CGFloat(r) / 255,
            green: CGFloat(g) / 255,
            blue: CGFloat(b) / 255,
            alpha: 1
        )
    }
}
