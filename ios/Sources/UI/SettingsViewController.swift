import Combine
import UIKit

/// Grouped inset settings: connection info, re-pair, font size, theme, about.
@MainActor
final class SettingsViewController: UITableViewController {
    private enum Section: Int, CaseIterable {
        case connection
        case pairing
        case appearance
        case about
    }

    private let services: AppServices
    private var cancellables: Set<AnyCancellable> = []

    init(services: AppServices) {
        self.services = services
        super.init(style: .insetGrouped)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    override func viewDidLoad() {
        super.viewDidLoad()
        title = "Settings"
        navigationItem.rightBarButtonItem = UIBarButtonItem(
            systemItem: .done,
            primaryAction: UIAction { [weak self] _ in self?.dismiss(animated: true) }
        )

        let connection = services.connection
        connection.$state
            .combineLatest(connection.$hostOnline, connection.$roundTripTime)
            .receive(on: DispatchQueue.main)
            .sink { [weak self] _, _, _ in
                guard let self, isViewLoaded else { return }
                tableView.reloadSections(
                    IndexSet([Section.connection.rawValue, Section.pairing.rawValue]),
                    with: .none
                )
            }
            .store(in: &cancellables)
    }

    private var isPaired: Bool { services.connection.pairing != nil }

    // MARK: - Table structure

    override func numberOfSections(in tableView: UITableView) -> Int {
        Section.allCases.count
    }

    override func tableView(
        _ tableView: UITableView, titleForHeaderInSection section: Int
    ) -> String? {
        switch Section(rawValue: section)! {
        case .connection: "Connection"
        case .pairing: "Pairing"
        case .appearance: "Terminal"
        case .about: "About"
        }
    }

    override func tableView(_ tableView: UITableView, numberOfRowsInSection section: Int) -> Int {
        switch Section(rawValue: section)! {
        case .connection: isPaired ? 4 : 1
        case .pairing: isPaired ? 2 : 1
        case .appearance: 3
        case .about: 1
        }
    }

    override func tableView(
        _ tableView: UITableView, cellForRowAt indexPath: IndexPath
    ) -> UITableViewCell {
        switch Section(rawValue: indexPath.section)! {
        case .connection: connectionCell(row: indexPath.row)
        case .pairing: pairingCell(row: indexPath.row)
        case .appearance: appearanceCell(row: indexPath.row)
        case .about: aboutCell()
        }
    }

    // MARK: - Cells

    private func valueCell(_ text: String, _ detail: String?) -> UITableViewCell {
        let cell = UITableViewCell(style: .value1, reuseIdentifier: nil)
        var content = UIListContentConfiguration.valueCell()
        content.text = text
        content.secondaryText = detail
        cell.contentConfiguration = content
        cell.selectionStyle = .none
        return cell
    }

    private func connectionCell(row: Int) -> UITableViewCell {
        guard let pairing = services.connection.pairing else {
            return valueCell("Status", "Not paired")
        }
        switch row {
        case 0:
            let status: String = switch services.connection.state {
            case .unpaired: "Not paired"
            case .connecting: "Connecting…"
            case let .reconnecting(attempt): "Reconnecting (attempt \(attempt))…"
            case .connected:
                services.connection.hostOnline ? "Connected · E2EE" : "Waiting for host…"
            }
            return valueCell("Status", status)
        case 1:
            return valueCell("Relay", pairing.relay.host ?? pairing.relay.absoluteString)
        case 2:
            return valueCell("Room", String(pairing.roomId.prefix(8)) + "…")
        default:
            let rtt = services.connection.roundTripTime
            return valueCell("Ping", rtt.map { "\(Int(($0 * 1000).rounded())) ms" } ?? "—")
        }
    }

    private func pairingCell(row: Int) -> UITableViewCell {
        let cell = UITableViewCell(style: .default, reuseIdentifier: nil)
        var content = cell.defaultContentConfiguration()
        if !isPaired || row == 0 {
            content.text = isPaired ? "Re-pair…" : "Pair…"
            content.textProperties.color = view.tintColor
            content.image = UIImage(systemName: "qrcode.viewfinder")
            content.imageProperties.tintColor = view.tintColor
        } else {
            content.text = "Forget Pairing"
            content.textProperties.color = .systemRed
            content.image = UIImage(systemName: "trash")
            content.imageProperties.tintColor = .systemRed
        }
        cell.contentConfiguration = content
        return cell
    }

    private func appearanceCell(row: Int) -> UITableViewCell {
        if row == 0 {
            let cell = valueCell(
                "Font Size", "\(Int(services.preferences.fontSize)) pt"
            )
            let stepper = UIStepper()
            stepper.minimumValue = Double(TerminalPreferences.fontSizeRange.lowerBound)
            stepper.maximumValue = Double(TerminalPreferences.fontSizeRange.upperBound)
            stepper.stepValue = 1
            stepper.value = Double(services.preferences.fontSize)
            stepper.addAction(
                UIAction { [weak self, weak stepper] _ in
                    guard let self, let stepper else { return }
                    services.preferences.fontSize = Float(stepper.value)
                    services.applyTerminalAppearance()
                    tableView.reloadRows(
                        at: [IndexPath(row: 0, section: Section.appearance.rawValue)],
                        with: .none
                    )
                },
                for: .valueChanged
            )
            cell.accessoryView = stepper
            return cell
        }
        if row == 1 {
            let cell = valueCell("Theme", services.preferences.themeName)
            cell.accessoryType = .disclosureIndicator
            cell.selectionStyle = .default
            return cell
        }
        let hex = services.preferences.backgroundHex
        let label = switch hex {
        case nil: "Theme"
        case "#000000": "Black"
        case let .some(value): value.uppercased()
        }
        let cell = valueCell("Background", label)
        let swatch = UIView(frame: CGRect(x: 0, y: 0, width: 22, height: 22))
        swatch.backgroundColor = services.preferences.backgroundColor
        swatch.layer.cornerRadius = 11
        swatch.layer.borderWidth = 1
        swatch.layer.borderColor = UIColor.separator.cgColor
        cell.accessoryView = swatch
        cell.selectionStyle = .default
        return cell
    }

    private func aboutCell() -> UITableViewCell {
        let version = Bundle.main.object(
            forInfoDictionaryKey: "CFBundleShortVersionString"
        ) as? String
        return valueCell("Version", version ?? "1.0")
    }

    // MARK: - Selection

    override func tableView(_ tableView: UITableView, didSelectRowAt indexPath: IndexPath) {
        tableView.deselectRow(at: indexPath, animated: true)
        switch Section(rawValue: indexPath.section)! {
        case .pairing:
            if !isPaired || indexPath.row == 0 {
                presentScanner()
            } else {
                confirmForgetPairing()
            }
        case .appearance where indexPath.row == 1:
            navigationController?.pushViewController(
                ThemePickerViewController(services: services), animated: true
            )
        case .appearance where indexPath.row == 2:
            presentBackgroundOptions()
        case .connection, .appearance, .about:
            break
        }
    }

    // MARK: - Terminal background

    private func presentBackgroundOptions() {
        let sheet = UIAlertController(
            title: "Terminal Background", message: nil, preferredStyle: .actionSheet
        )
        sheet.addAction(UIAlertAction(title: "Black", style: .default) { [weak self] _ in
            self?.setBackground("#000000")
        })
        sheet.addAction(UIAlertAction(title: "Theme Default", style: .default) { [weak self] _ in
            self?.setBackground(nil)
        })
        sheet.addAction(UIAlertAction(title: "Custom Color…", style: .default) { [weak self] _ in
            self?.presentColorPicker()
        })
        sheet.addAction(UIAlertAction(title: "Cancel", style: .cancel))
        present(sheet, animated: true)
    }

    private func presentColorPicker() {
        let picker = UIColorPickerViewController()
        picker.title = "Terminal Background"
        picker.supportsAlpha = false
        picker.selectedColor = services.preferences.backgroundColor
        picker.delegate = self
        present(picker, animated: true)
    }

    private func setBackground(_ hex: String?) {
        services.preferences.backgroundHex = hex
        services.applyTerminalAppearance()
        tableView.reloadRows(
            at: [IndexPath(row: 2, section: Section.appearance.rawValue)], with: .none
        )
    }

    private func presentScanner() {
        let scanner = PairingScanViewController()
        scanner.onPaired = { [weak self] info in
            self?.services.connection.pair(with: info)
            self?.tableView.reloadData()
        }
        scanner.modalPresentationStyle = .fullScreen
        present(scanner, animated: true)
    }

    // MARK: - Pairing

    private func confirmForgetPairing() {
        let alert = UIAlertController(
            title: "Forget Pairing?",
            message: "This disconnects from your Mac and removes the stored key.",
            preferredStyle: .alert
        )
        alert.addAction(UIAlertAction(title: "Cancel", style: .cancel))
        alert.addAction(UIAlertAction(title: "Forget", style: .destructive) { [weak self] _ in
            self?.services.connection.unpair()
            self?.tableView.reloadData()
        })
        present(alert, animated: true)
    }
}

extension SettingsViewController: UIColorPickerViewControllerDelegate {
    func colorPickerViewControllerDidFinish(_ viewController: UIColorPickerViewController) {
        setBackground(viewController.selectedColor.pedalsHexString)
    }
}

private extension UIColor {
    /// "#RRGGBB" of the color's sRGB components.
    var pedalsHexString: String {
        var red: CGFloat = 0, green: CGFloat = 0, blue: CGFloat = 0
        getRed(&red, green: &green, blue: &blue, alpha: nil)
        return String(
            format: "#%02X%02X%02X",
            Int(round(red * 255)), Int(round(green * 255)), Int(round(blue * 255))
        )
    }
}
