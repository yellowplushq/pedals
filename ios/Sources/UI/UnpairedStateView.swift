import UIKit

/// Centered card shown when no pairing exists: scan a QR (device) or paste the
/// pairing link (simulator-friendly).
@MainActor
final class UnpairedStateView: UIView {
    var onScan: (() -> Void)?
    var onPaste: (() -> Void)?

    override init(frame: CGRect) {
        super.init(frame: frame)

        let card = UIView()
        card.backgroundColor = .secondarySystemBackground
        card.layer.cornerRadius = 20
        card.layer.cornerCurve = .continuous
        card.translatesAutoresizingMaskIntoConstraints = false
        addSubview(card)

        let icon = UIImageView(
            image: UIImage(
                systemName: "terminal",
                withConfiguration: UIImage.SymbolConfiguration(pointSize: 40, weight: .light)
            )
        )
        icon.tintColor = .secondaryLabel

        let title = UILabel()
        title.text = "Pair with your Mac"
        title.font = UIFont.systemFont(
            ofSize: UIFont.preferredFont(forTextStyle: .title2).pointSize, weight: .bold
        )
        title.adjustsFontForContentSizeCategory = true
        title.textAlignment = .center

        let body = UILabel()
        body.text = "Run “pedals pair” on your Mac, then scan the QR code or paste the pairing link."
        body.font = .preferredFont(forTextStyle: .subheadline)
        body.adjustsFontForContentSizeCategory = true
        body.textColor = .secondaryLabel
        body.textAlignment = .center
        body.numberOfLines = 0

        var scanConfig = UIButton.Configuration.borderedProminent()
        scanConfig.title = "Scan QR"
        scanConfig.image = UIImage(systemName: "qrcode.viewfinder")
        scanConfig.imagePadding = 8
        scanConfig.buttonSize = .large
        let scanButton = UIButton(configuration: scanConfig)
        scanButton.addAction(UIAction { [weak self] _ in self?.onScan?() }, for: .touchUpInside)

        var pasteConfig = UIButton.Configuration.gray()
        pasteConfig.title = "Paste Pairing Link"
        pasteConfig.image = UIImage(systemName: "doc.on.clipboard")
        pasteConfig.imagePadding = 8
        pasteConfig.buttonSize = .large
        let pasteButton = UIButton(configuration: pasteConfig)
        pasteButton.addAction(UIAction { [weak self] _ in self?.onPaste?() }, for: .touchUpInside)

        let stack = UIStackView(arrangedSubviews: [icon, title, body, scanButton, pasteButton])
        stack.axis = .vertical
        stack.alignment = .center
        stack.spacing = 12
        stack.setCustomSpacing(20, after: body)
        stack.translatesAutoresizingMaskIntoConstraints = false
        card.addSubview(stack)

        NSLayoutConstraint.activate([
            card.centerXAnchor.constraint(equalTo: centerXAnchor),
            card.centerYAnchor.constraint(equalTo: centerYAnchor),
            card.widthAnchor.constraint(lessThanOrEqualToConstant: 360),
            card.leadingAnchor.constraint(
                greaterThanOrEqualTo: safeAreaLayoutGuide.leadingAnchor, constant: 24
            ),
            card.trailingAnchor.constraint(
                lessThanOrEqualTo: safeAreaLayoutGuide.trailingAnchor, constant: -24
            ),

            stack.topAnchor.constraint(equalTo: card.topAnchor, constant: 28),
            stack.bottomAnchor.constraint(equalTo: card.bottomAnchor, constant: -28),
            stack.leadingAnchor.constraint(equalTo: card.leadingAnchor, constant: 24),
            stack.trailingAnchor.constraint(equalTo: card.trailingAnchor, constant: -24),

            scanButton.widthAnchor.constraint(equalTo: stack.widthAnchor),
            pasteButton.widthAnchor.constraint(equalTo: stack.widthAnchor),
        ])
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }
}
