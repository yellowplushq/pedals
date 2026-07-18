import PedalsKit
import UIKit

/// The sole iPhone pairing surface. The 8-digit value is a short-lived server
/// rendezvous handle; the E2EE key exchange happens independently underneath.
@MainActor
final class PairingCodeViewController: UIViewController {
    var onPair: (@MainActor (PairingCode) async throws -> Void)?

    private let closeButton = UIButton(type: .system)
    private let titleLabel = UILabel()
    private let bodyLabel = UILabel()
    private let codeField = AEOTPTextField()
    private let statusLabel = UILabel()
    private let pairButton = UIButton(type: .system)
    private var pairingTask: Task<Void, Never>?
    private var digits = ""

    override func viewDidLoad() {
        super.viewDidLoad()
        view.backgroundColor = PedalsTheme.uiCanvas
        buildLayout()
        configureInput()
        codeChanged()
    }

    override func viewDidAppear(_ animated: Bool) {
        super.viewDidAppear(animated)
        codeField.becomeFirstResponder()
    }

    deinit {
        pairingTask?.cancel()
    }

    private func buildLayout() {
        closeButton.setImage(
            UIImage(
                systemName: "xmark",
                withConfiguration: UIImage.SymbolConfiguration(pointSize: 15, weight: .semibold)
            ),
            for: .normal
        )
        closeButton.tintColor = PedalsTheme.uiContent
        closeButton.backgroundColor = PedalsTheme.uiSurface
        closeButton.layer.cornerRadius = 22
        closeButton.layer.cornerCurve = .continuous
        closeButton.accessibilityLabel = "Cancel pairing"
        closeButton.accessibilityIdentifier = "pedals.pairing.cancel"
        closeButton.addAction(UIAction { [weak self] _ in
            self?.pairingTask?.cancel()
            self?.dismiss(animated: true)
        }, for: .touchUpInside)

        titleLabel.text = "Enter pairing code"
        titleLabel.font = PedalsTheme.uiEmphasizedTextFont
        titleLabel.textColor = PedalsTheme.uiContent
        titleLabel.textAlignment = .center

        bodyLabel.text = "Enter the 8-digit code shown by Pedals on your computer."
        bodyLabel.font = PedalsTheme.uiTextFont
        bodyLabel.textColor = PedalsTheme.uiSecondaryContent
        bodyLabel.textAlignment = .center
        bodyLabel.numberOfLines = 0

        statusLabel.font = PedalsTheme.uiTextFont
        statusLabel.textColor = PedalsTheme.uiTertiaryContent
        statusLabel.textAlignment = .center
        statusLabel.numberOfLines = 2
        statusLabel.accessibilityIdentifier = "pedals.pairing.status"

        var configuration = UIButton.Configuration.borderedProminent()
        configuration.title = "Connect"
        configuration.image = UIImage(
            systemName: "link",
            withConfiguration: UIImage.SymbolConfiguration(pointSize: 17, weight: .medium)
        )
        configuration.imagePadding = 9
        configuration.cornerStyle = .large
        configuration.contentInsets = NSDirectionalEdgeInsets(
            top: 14, leading: 18, bottom: 14, trailing: 18
        )
        configuration.baseBackgroundColor = PedalsTheme.uiContent
        configuration.baseForegroundColor = PedalsTheme.uiCanvas
        PedalsTheme.applyTextFont(to: &configuration, emphasized: true)
        pairButton.configuration = configuration
        pairButton.accessibilityIdentifier = "pedals.pairing.submit"
        pairButton.addAction(UIAction { [weak self] _ in self?.submit() }, for: .touchUpInside)

        let copy = UIStackView(arrangedSubviews: [titleLabel, bodyLabel])
        copy.axis = .vertical
        copy.spacing = 7

        let content = UIStackView(arrangedSubviews: [copy, codeField, statusLabel])
        content.axis = .vertical
        content.spacing = 18
        content.setCustomSpacing(32, after: copy)

        [closeButton, content, pairButton].forEach {
            $0.translatesAutoresizingMaskIntoConstraints = false
            view.addSubview($0)
        }

        NSLayoutConstraint.activate([
            closeButton.topAnchor.constraint(equalTo: view.safeAreaLayoutGuide.topAnchor, constant: 14),
            closeButton.leadingAnchor.constraint(equalTo: view.leadingAnchor, constant: 16),
            closeButton.widthAnchor.constraint(equalToConstant: 44),
            closeButton.heightAnchor.constraint(equalToConstant: 44),

            content.topAnchor.constraint(equalTo: closeButton.bottomAnchor, constant: 72),
            content.leadingAnchor.constraint(equalTo: view.leadingAnchor, constant: 24),
            content.trailingAnchor.constraint(equalTo: view.trailingAnchor, constant: -24),
            codeField.heightAnchor.constraint(equalToConstant: 52),

            pairButton.leadingAnchor.constraint(equalTo: view.leadingAnchor, constant: 32),
            pairButton.trailingAnchor.constraint(equalTo: view.trailingAnchor, constant: -32),
            pairButton.bottomAnchor.constraint(
                equalTo: view.keyboardLayoutGuide.topAnchor,
                constant: -16
            ),
            pairButton.heightAnchor.constraint(equalToConstant: 48),
            content.bottomAnchor.constraint(lessThanOrEqualTo: pairButton.topAnchor, constant: -16),
        ])
    }

    private func configureInput() {
        codeField.otpDefaultCharacter = ""
        codeField.otpBackgroundColor = PedalsTheme.uiSurface
        codeField.otpFilledBackgroundColor = PedalsTheme.uiSurface
        codeField.otpCornerRadius = 12
        codeField.otpDefaultBorderColor = PedalsTheme.uiSeparator
        codeField.otpFilledBorderColor = PedalsTheme.uiContent
        codeField.otpDefaultBorderWidth = 1
        codeField.otpFilledBorderWidth = 1.5
        codeField.otpTextColor = PedalsTheme.uiContent
        codeField.otpFont = UIFont.monospacedDigitSystemFont(ofSize: 18, weight: .semibold)
        codeField.otpDelegate = self
        codeField.configure(with: PairingCode.digitCount)
        codeField.accessibilityLabel = "8-digit pairing code"
        codeField.accessibilityHint = "Each digit appears in its own box"
        codeField.accessibilityIdentifier = "pedals.pairing.code"
        codeField.addTarget(self, action: #selector(codeChanged), for: .editingChanged)
    }

    @objc
    private func codeChanged() {
        digits = String(
            (codeField.text ?? "")
                .filter { "0123456789".contains($0) }
                .prefix(PairingCode.digitCount)
        )
        statusLabel.text = digits.isEmpty
            ? "The code expires after 15 minutes."
            : "\(digits.count) of 8 digits"
        updateInputState()
    }

    private func updateInputState() {
        pairButton.isEnabled = digits.count == PairingCode.digitCount && pairingTask == nil
        pairButton.alpha = pairButton.isEnabled ? 1 : 0.42
    }

    private func submit() {
        guard pairingTask == nil,
              let code = try? PairingCode(digits),
              let onPair
        else { return }

        codeField.resignFirstResponder()
        codeField.isEnabled = false
        pairButton.configuration?.showsActivityIndicator = true
        pairButton.configuration?.image = nil
        pairButton.configuration?.title = "Connecting…"
        statusLabel.text = "Securely exchanging keys with your computer…"
        statusLabel.textColor = PedalsTheme.uiSecondaryContent
        updateInputState()

        pairingTask = Task { [weak self] in
            guard let self else { return }
            do {
                try await onPair(code)
                guard !Task.isCancelled else { return }
                pairButton.configuration?.showsActivityIndicator = false
                pairButton.configuration?.image = UIImage(systemName: "checkmark")
                pairButton.configuration?.title = "Connected"
                statusLabel.text = "The one-time code has been used and is no longer valid."
                statusLabel.textColor = PedalsTheme.uiContent
                try? await Task.sleep(for: .milliseconds(750))
                guard !Task.isCancelled else { return }
                dismiss(animated: true)
            } catch {
                guard !Task.isCancelled else { return }
                pairingTask = nil
                codeField.isEnabled = true
                pairButton.configuration?.showsActivityIndicator = false
                pairButton.configuration?.image = UIImage(systemName: "arrow.clockwise")
                pairButton.configuration?.title = "Try Again"
                statusLabel.text = "Code expired or couldn’t be used. Request a new code on your computer."
                statusLabel.textColor = PedalsTheme.uiCritical
                updateInputState()
                codeField.becomeFirstResponder()
            }
        }
    }
}

extension PairingCodeViewController: AEOTPTextFieldDelegate {
    func didUserFinishEnter(the code: String) {
        digits = code
        UIImpactFeedbackGenerator(style: .light).impactOccurred()
        updateInputState()
    }
}
