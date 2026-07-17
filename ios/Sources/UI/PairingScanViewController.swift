import AVFoundation
import PedalsKit
import UIKit

/// AVFoundation QR scanner with a manual paste field (camera is unavailable in
/// the simulator, so the field is always present).
@MainActor
final class PairingScanViewController: UIViewController {
    var onPaired: ((PairingInfo) -> Void)?

    /// Lets the non-Sendable capture session cross onto the session queue;
    /// start/stop only ever happen there.
    private struct SessionBox: @unchecked Sendable {
        let session: AVCaptureSession
    }

    private let captureSession = AVCaptureSession()
    private let sessionQueue = DispatchQueue(label: "app.yellowplus.pedals.scanner")
    private var previewLayer: AVCaptureVideoPreviewLayer?
    private let fallbackLabel = UILabel()
    private let linkField = UITextField()
    private var didFinish = false

    override func viewDidLoad() {
        super.viewDidLoad()
        overrideUserInterfaceStyle = .dark
        view.backgroundColor = .black
        buildOverlay()
        configureCamera()
    }

    override func viewWillDisappear(_ animated: Bool) {
        super.viewWillDisappear(animated)
        let box = SessionBox(session: captureSession)
        sessionQueue.async {
            if box.session.isRunning { box.session.stopRunning() }
        }
    }

    override func viewDidLayoutSubviews() {
        super.viewDidLayoutSubviews()
        previewLayer?.frame = view.bounds
    }

    // MARK: - UI

    private func buildOverlay() {
        fallbackLabel.text = "Camera unavailable.\nPaste the pairing link below."
        fallbackLabel.font = .preferredFont(forTextStyle: .subheadline)
        fallbackLabel.textColor = .secondaryLabel
        fallbackLabel.textAlignment = .center
        fallbackLabel.numberOfLines = 0
        fallbackLabel.isHidden = true
        fallbackLabel.translatesAutoresizingMaskIntoConstraints = false
        view.addSubview(fallbackLabel)

        let title = UILabel()
        title.text = "Scan Pairing QR"
        title.font = .preferredFont(forTextStyle: .headline)
        title.textColor = .white
        title.translatesAutoresizingMaskIntoConstraints = false
        view.addSubview(title)

        var closeConfig = UIButton.Configuration.plain()
        closeConfig.image = UIImage(
            systemName: "xmark.circle.fill",
            withConfiguration: UIImage.SymbolConfiguration(pointSize: 26)
        )
        closeConfig.baseForegroundColor = .secondaryLabel
        let closeButton = UIButton(configuration: closeConfig)
        closeButton.accessibilityLabel = "Cancel"
        closeButton.addAction(
            UIAction { [weak self] _ in self?.dismiss(animated: true) }, for: .touchUpInside
        )
        closeButton.translatesAutoresizingMaskIntoConstraints = false
        view.addSubview(closeButton)

        // Bottom card: manual paste entry.
        let card = UIVisualEffectView(effect: UIBlurEffect(style: .systemThickMaterial))
        card.layer.cornerRadius = 16
        card.layer.cornerCurve = .continuous
        card.clipsToBounds = true
        card.translatesAutoresizingMaskIntoConstraints = false
        view.addSubview(card)

        linkField.placeholder = "pedals://pair?…"
        linkField.font = .preferredFont(forTextStyle: .footnote)
        linkField.autocorrectionType = .no
        linkField.autocapitalizationType = .none
        linkField.keyboardType = .URL
        linkField.returnKeyType = .go
        linkField.delegate = self
        linkField.borderStyle = .roundedRect

        var connectConfig = UIButton.Configuration.borderedProminent()
        connectConfig.title = "Connect"
        let connectButton = UIButton(configuration: connectConfig)
        connectButton.addAction(
            UIAction { [weak self] _ in self?.submitPastedLink() }, for: .touchUpInside
        )

        let row = UIStackView(arrangedSubviews: [linkField, connectButton])
        row.axis = .horizontal
        row.spacing = 8
        row.translatesAutoresizingMaskIntoConstraints = false
        card.contentView.addSubview(row)

        NSLayoutConstraint.activate([
            closeButton.topAnchor.constraint(
                equalTo: view.safeAreaLayoutGuide.topAnchor, constant: 8
            ),
            closeButton.leadingAnchor.constraint(
                equalTo: view.safeAreaLayoutGuide.leadingAnchor, constant: 8
            ),
            title.centerYAnchor.constraint(equalTo: closeButton.centerYAnchor),
            title.centerXAnchor.constraint(equalTo: view.centerXAnchor),

            fallbackLabel.centerXAnchor.constraint(equalTo: view.centerXAnchor),
            fallbackLabel.centerYAnchor.constraint(equalTo: view.centerYAnchor),
            fallbackLabel.leadingAnchor.constraint(
                greaterThanOrEqualTo: view.leadingAnchor, constant: 24
            ),

            card.leadingAnchor.constraint(
                equalTo: view.safeAreaLayoutGuide.leadingAnchor, constant: 16
            ),
            card.trailingAnchor.constraint(
                equalTo: view.safeAreaLayoutGuide.trailingAnchor, constant: -16
            ),
            card.bottomAnchor.constraint(
                equalTo: view.keyboardLayoutGuide.topAnchor, constant: -16
            ),

            row.topAnchor.constraint(equalTo: card.contentView.topAnchor, constant: 12),
            row.bottomAnchor.constraint(equalTo: card.contentView.bottomAnchor, constant: -12),
            row.leadingAnchor.constraint(equalTo: card.contentView.leadingAnchor, constant: 12),
            row.trailingAnchor.constraint(equalTo: card.contentView.trailingAnchor, constant: -12),
        ])
    }

    // MARK: - Camera

    private func configureCamera() {
        switch AVCaptureDevice.authorizationStatus(for: .video) {
        case .authorized:
            startCamera()
        case .notDetermined:
            AVCaptureDevice.requestAccess(for: .video) { granted in
                Task { @MainActor [weak self] in
                    if granted {
                        self?.startCamera()
                    } else {
                        self?.fallbackLabel.isHidden = false
                    }
                }
            }
        default:
            fallbackLabel.isHidden = false
        }
    }

    private func startCamera() {
        guard let device = AVCaptureDevice.default(for: .video),
              let input = try? AVCaptureDeviceInput(device: device)
        else {
            fallbackLabel.isHidden = false
            return
        }

        let output = AVCaptureMetadataOutput()
        let session = captureSession
        guard session.canAddInput(input), session.canAddOutput(output) else {
            fallbackLabel.isHidden = false
            return
        }
        session.addInput(input)
        session.addOutput(output)
        output.setMetadataObjectsDelegate(self, queue: .main)
        output.metadataObjectTypes = [.qr]

        let preview = AVCaptureVideoPreviewLayer(session: session)
        preview.videoGravity = .resizeAspectFill
        preview.frame = view.bounds
        view.layer.insertSublayer(preview, at: 0)
        previewLayer = preview

        let box = SessionBox(session: session)
        sessionQueue.async {
            box.session.startRunning()
        }
    }

    // MARK: - Result handling

    private func submitPastedLink() {
        finish(with: linkField.text ?? "")
    }

    private func finish(with urlString: String) {
        guard !didFinish else { return }
        let trimmed = urlString.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let info = try? PairingInfo(urlString: trimmed) else {
            linkField.layer.borderColor = UIColor.systemRed.cgColor
            linkField.layer.borderWidth = 1
            linkField.layer.cornerRadius = 5
            UINotificationFeedbackGenerator().notificationOccurred(.error)
            return
        }
        didFinish = true
        UINotificationFeedbackGenerator().notificationOccurred(.success)
        dismiss(animated: true)
        onPaired?(info)
    }
}

// MARK: - QR metadata

extension PairingScanViewController: AVCaptureMetadataOutputObjectsDelegate {
    nonisolated func metadataOutput(
        _ output: AVCaptureMetadataOutput,
        didOutput metadataObjects: [AVMetadataObject],
        from connection: AVCaptureConnection
    ) {
        let payload = metadataObjects
            .compactMap { ($0 as? AVMetadataMachineReadableCodeObject)?.stringValue }
            .first { $0.hasPrefix("pedals://") }
        guard let payload else { return }
        Task { @MainActor [weak self] in
            self?.finish(with: payload)
        }
    }
}

// MARK: - Text field

extension PairingScanViewController: UITextFieldDelegate {
    func textFieldShouldReturn(_ textField: UITextField) -> Bool {
        submitPastedLink()
        return true
    }
}
