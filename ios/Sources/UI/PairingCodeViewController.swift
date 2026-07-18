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
    private let downloadGuide = PairingDownloadGuideView()
    private let codeField = AEOTPTextField()
    private let statusLabel = UILabel()
    private let pairButton = UIButton(type: .system)
    private var downloadGuideHeightConstraint: NSLayoutConstraint?
    private var pairButtonKeyboardConstraint: NSLayoutConstraint?
    private var pairButtonFrozenConstraint: NSLayoutConstraint?
    private var dismissalSnapshot: UIImageView?
    private var pairingTask: Task<Void, Never>?
    private var digits = ""
    private var isDismissing = false

    override func viewDidLoad() {
        super.viewDidLoad()
        view.backgroundColor = PedalsTheme.uiCanvas
        // UIKit's full-screen dismissal temporarily moves this view past its
        // bounds. Keep keyboard-driven controls from drawing over the
        // presenting settings sheet during that transition.
        view.clipsToBounds = true
        buildLayout()
        configureInput()
        observeKeyboard()
        codeChanged()
    }

    deinit {
        pairingTask?.cancel()
        NotificationCenter.default.removeObserver(self)
    }

    private func buildLayout() {
        closeButton.setImage(
            UIImage(
                systemName: "chevron.left",
                withConfiguration: UIImage.SymbolConfiguration(pointSize: 15, weight: .semibold)
            ),
            for: .normal
        )
        closeButton.tintColor = PedalsTheme.uiContent
        closeButton.backgroundColor = .clear
        closeButton.accessibilityLabel = "Cancel pairing"
        closeButton.accessibilityIdentifier = "pedals.pairing.cancel"
        closeButton.addAction(UIAction { [weak self] _ in
            self?.dismissPairing(cancelPairing: true)
        }, for: .touchUpInside)

        titleLabel.text = "Connect"
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

        let input = UIStackView(arrangedSubviews: [bodyLabel, codeField, statusLabel])
        input.axis = .vertical
        input.spacing = 10
        input.setCustomSpacing(18, after: bodyLabel)

        [closeButton, titleLabel, downloadGuide, input, pairButton].forEach {
            $0.translatesAutoresizingMaskIntoConstraints = false
            view.addSubview($0)
        }

        let downloadGuideHeightConstraint = downloadGuide.heightAnchor.constraint(
            equalToConstant: 160
        )
        self.downloadGuideHeightConstraint = downloadGuideHeightConstraint

        let inputBelowGuide = input.topAnchor.constraint(
            greaterThanOrEqualTo: downloadGuide.bottomAnchor,
            constant: 28
        )
        inputBelowGuide.priority = .defaultHigh

        let inputCentered = input.centerYAnchor.constraint(equalTo: view.centerYAnchor)
        inputCentered.priority = .defaultHigh

        let pairButtonKeyboardConstraint = pairButton.bottomAnchor.constraint(
            equalTo: view.keyboardLayoutGuide.topAnchor,
            constant: -16
        )
        self.pairButtonKeyboardConstraint = pairButtonKeyboardConstraint

        NSLayoutConstraint.activate([
            closeButton.topAnchor.constraint(equalTo: view.safeAreaLayoutGuide.topAnchor, constant: 14),
            closeButton.leadingAnchor.constraint(equalTo: view.leadingAnchor, constant: 16),
            closeButton.widthAnchor.constraint(equalToConstant: 44),
            closeButton.heightAnchor.constraint(equalToConstant: 44),

            titleLabel.centerXAnchor.constraint(equalTo: view.centerXAnchor),
            titleLabel.centerYAnchor.constraint(equalTo: closeButton.centerYAnchor),
            titleLabel.leadingAnchor.constraint(
                greaterThanOrEqualTo: closeButton.trailingAnchor,
                constant: 12
            ),
            titleLabel.trailingAnchor.constraint(
                lessThanOrEqualTo: view.trailingAnchor,
                constant: -60
            ),

            downloadGuide.topAnchor.constraint(equalTo: closeButton.bottomAnchor, constant: 18),
            downloadGuide.leadingAnchor.constraint(equalTo: view.leadingAnchor, constant: 16),
            downloadGuide.trailingAnchor.constraint(equalTo: view.trailingAnchor, constant: -16),
            downloadGuideHeightConstraint,

            input.leadingAnchor.constraint(equalTo: view.leadingAnchor, constant: 24),
            input.trailingAnchor.constraint(equalTo: view.trailingAnchor, constant: -24),
            input.bottomAnchor.constraint(lessThanOrEqualTo: pairButton.topAnchor, constant: -20),
            inputBelowGuide,
            inputCentered,
            codeField.heightAnchor.constraint(equalToConstant: 52),

            pairButton.leadingAnchor.constraint(equalTo: view.leadingAnchor, constant: 32),
            pairButton.trailingAnchor.constraint(equalTo: view.trailingAnchor, constant: -32),
            pairButtonKeyboardConstraint,
            pairButton.heightAnchor.constraint(equalToConstant: 48),
        ])
    }

    private func observeKeyboard() {
        NotificationCenter.default.addObserver(
            self,
            selector: #selector(keyboardWillShow(_:)),
            name: UIResponder.keyboardWillShowNotification,
            object: nil
        )
        NotificationCenter.default.addObserver(
            self,
            selector: #selector(keyboardWillHide(_:)),
            name: UIResponder.keyboardWillHideNotification,
            object: nil
        )
    }

    @objc
    private func keyboardWillShow(_ notification: Notification) {
        guard !isDismissing else { return }
        setDownloadGuideVisible(false, notification: notification)
    }

    @objc
    private func keyboardWillHide(_ notification: Notification) {
        guard !isDismissing else { return }
        setDownloadGuideVisible(true, notification: notification)
    }

    /// Dismissal overlaps two system animations: the full-screen controller
    /// slides away while the keyboard layout guide moves back to the bottom.
    /// Flatten the current page into one clipped layer and freeze the button's
    /// keyboard-dependent position before either animation starts, so no child
    /// view can take an independent path across the presenting controller.
    private func dismissPairing(cancelPairing: Bool) {
        guard !isDismissing else { return }
        isDismissing = true
        if cancelPairing {
            pairingTask?.cancel()
            pairingTask = nil
        }

        view.layoutIfNeeded()
        installDismissalSnapshot()
        freezeKeyboardDependentLayout()
        NotificationCenter.default.removeObserver(self)

        UIView.performWithoutAnimation {
            self.view.endEditing(true)
            self.view.layoutIfNeeded()
        }
        dismiss(animated: true)
    }

    private func installDismissalSnapshot() {
        guard dismissalSnapshot == nil, view.window != nil else { return }

        let format = UIGraphicsImageRendererFormat.preferred()
        format.opaque = true
        let renderer = UIGraphicsImageRenderer(bounds: view.bounds, format: format)
        let image = renderer.image { _ in
            view.drawHierarchy(in: view.bounds, afterScreenUpdates: false)
        }
        let snapshot = UIImageView(image: image)
        snapshot.frame = view.bounds
        snapshot.autoresizingMask = [.flexibleWidth, .flexibleHeight]
        snapshot.isUserInteractionEnabled = false
        view.addSubview(snapshot)
        dismissalSnapshot = snapshot
    }

    private func freezeKeyboardDependentLayout() {
        let buttonTop = pairButton.frame.minY
        pairButtonKeyboardConstraint?.isActive = false
        let frozen = pairButton.topAnchor.constraint(equalTo: view.topAnchor, constant: buttonTop)
        frozen.isActive = true
        pairButtonFrozenConstraint = frozen

        downloadGuide.layer.removeAllAnimations()
        view.isUserInteractionEnabled = false
    }

    private func setDownloadGuideVisible(_ visible: Bool, notification: Notification) {
        guard downloadGuideHeightConstraint?.constant != (visible ? 160 : 0) else { return }
        view.layoutIfNeeded()
        if visible {
            downloadGuide.isHidden = false
        }
        downloadGuideHeightConstraint?.constant = visible ? 160 : 0

        let duration = notification.userInfo?[UIResponder.keyboardAnimationDurationUserInfoKey]
            as? TimeInterval ?? 0.25
        let rawCurve = (
            notification.userInfo?[UIResponder.keyboardAnimationCurveUserInfoKey] as? NSNumber
        )?.uintValue ?? 7
        UIView.animate(
            withDuration: duration,
            delay: 0,
            options: UIView.AnimationOptions(rawValue: rawCurve << 16)
                .union(.beginFromCurrentState)
        ) {
            self.downloadGuide.alpha = visible ? 1 : 0
            self.view.layoutIfNeeded()
        } completion: { _ in
            self.downloadGuide.isHidden = !visible
        }
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
                dismissPairing(cancelPairing: false)
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

/// Compact setup guidance shown above the pairing code. The desktop download
/// destination intentionally stays on the product website so it can route to
/// the correct platform without changing the app.
@MainActor
private final class PairingDownloadGuideView: UIView {
    private static let websiteURL = URL(string: "https://pedals.air.build")!

    override init(frame: CGRect) {
        super.init(frame: frame)
        backgroundColor = PedalsTheme.uiSurface
        layer.cornerRadius = 18
        layer.cornerCurve = .continuous
        accessibilityIdentifier = "pedals.pairing.download"
        configureLayout()
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    private func configureLayout() {
        let symbolConfiguration = UIImage.SymbolConfiguration(pointSize: 34, weight: .light)
        let phone = UIImageView(
            image: UIImage(systemName: "iphone", withConfiguration: symbolConfiguration)
        )
        let computer = UIImageView(
            image: UIImage(systemName: "laptopcomputer", withConfiguration: symbolConfiguration)
        )
        [phone, computer].forEach {
            $0.tintColor = PedalsTheme.uiSecondaryContent
            $0.contentMode = .scaleAspectFit
        }

        let route = UILabel()
        route.text = "• • • •"
        route.font = .monospacedSystemFont(ofSize: 9, weight: .medium)
        route.textColor = PedalsTheme.uiTertiaryContent
        route.textAlignment = .center

        let icons = UIStackView(arrangedSubviews: [phone, route, computer])
        icons.axis = .horizontal
        icons.alignment = .center
        icons.distribution = .fillEqually
        icons.spacing = 14

        let caption = UILabel()
        caption.text = "Download Pedals for your computer at"
        caption.font = PedalsTheme.uiTextFont
        caption.textColor = PedalsTheme.uiSecondaryContent
        caption.textAlignment = .center

        var linkConfiguration = UIButton.Configuration.plain()
        linkConfiguration.title = "pedals.air.build"
        linkConfiguration.baseForegroundColor = PedalsTheme.uiContent
        linkConfiguration.contentInsets = .zero
        PedalsTheme.applyTextFont(to: &linkConfiguration, emphasized: true)
        let link = UIButton(configuration: linkConfiguration)
        link.accessibilityLabel = "Download Pedals from pedals.air.build"
        link.accessibilityHint = "Opens the Pedals website"
        link.addAction(UIAction { _ in
            UIApplication.shared.open(Self.websiteURL)
        }, for: .touchUpInside)

        let text = UIStackView(arrangedSubviews: [caption, link])
        text.axis = .vertical
        text.alignment = .center
        text.spacing = 1

        let stack = UIStackView(arrangedSubviews: [icons, text])
        stack.axis = .vertical
        stack.alignment = .fill
        stack.spacing = 12
        stack.translatesAutoresizingMaskIntoConstraints = false
        addSubview(stack)

        NSLayoutConstraint.activate([
            stack.topAnchor.constraint(equalTo: topAnchor, constant: 20),
            stack.bottomAnchor.constraint(equalTo: bottomAnchor, constant: -16),
            stack.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 28),
            stack.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -28),
            icons.heightAnchor.constraint(equalToConstant: 58),
        ])
    }
}
