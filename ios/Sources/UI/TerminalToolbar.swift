import UIKit

/// Persistent bottom input bar (Safari-toolbar style): Esc · Ctrl (sticky) ·
/// Tab · arrows · paste. Emits raw stdin bytes via `onBytes`; the sticky Ctrl
/// transform is applied by TerminalHost on the next keyboard byte.
final class TerminalToolbar: UIView {
    var onBytes: ((Data) -> Void)?
    /// Toggled by the Ctrl key; MainViewController mirrors it into the host.
    var onStickyCtrl: ((Bool) -> Void)?

    static let height: CGFloat = 48

    private let glass = GlassView()
    private let stack = UIStackView()
    private var ctrlButton: UIButton!
    private(set) var ctrlArmed = false {
        didSet {
            ctrlButton.tintColor = ctrlArmed ? PedalsTheme.uiContent : .label
            ctrlButton.backgroundColor = ctrlArmed
                ? PedalsTheme.uiSelection : .clear
            onStickyCtrl?(ctrlArmed)
        }
    }

    override init(frame: CGRect) {
        super.init(frame: frame)

        glass.frame = bounds
        glass.autoresizingMask = [.flexibleWidth, .flexibleHeight]
        addSubview(glass)

        stack.axis = .horizontal
        stack.distribution = .fillEqually
        stack.alignment = .fill
        glass.contentView.addSubview(stack)

        stack.addArrangedSubview(key(title: "esc", bytes: Data([0x1b])))
        ctrlButton = key(title: "ctrl", bytes: nil)
        ctrlButton.addAction(
            UIAction { [weak self] _ in
                guard let self else { return }
                ctrlArmed.toggle()
            }, for: .touchUpInside
        )
        stack.addArrangedSubview(ctrlButton)
        stack.addArrangedSubview(key(title: "tab", bytes: Data([0x09])))
        stack.addArrangedSubview(key(symbol: "arrow.left", bytes: Data([0x1b, 0x5b, 0x44])))
        stack.addArrangedSubview(key(symbol: "arrow.up", bytes: Data([0x1b, 0x5b, 0x41])))
        stack.addArrangedSubview(key(symbol: "arrow.down", bytes: Data([0x1b, 0x5b, 0x42])))
        stack.addArrangedSubview(key(symbol: "arrow.right", bytes: Data([0x1b, 0x5b, 0x43])))

        let paste = key(symbol: "doc.on.clipboard", bytes: nil)
        paste.addAction(
            UIAction { [weak self] _ in
                guard let text = UIPasteboard.general.string else { return }
                self?.onBytes?(Data(text.utf8))
            }, for: .touchUpInside
        )
        stack.addArrangedSubview(paste)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    override func layoutSubviews() {
        super.layoutSubviews()
        stack.frame = glass.contentView.bounds.insetBy(dx: 6, dy: 4)
    }

    /// The host consumed the armed Ctrl; reset the toggle UI.
    func consumeStickyCtrl() {
        if ctrlArmed { ctrlArmed = false }
    }

    private func key(title: String? = nil, symbol: String? = nil, bytes: Data?) -> UIButton {
        let button = UIButton(type: .system)
        if let title {
            button.setTitle(title, for: .normal)
            button.titleLabel?.font = .monospacedSystemFont(ofSize: 14, weight: .medium)
        }
        if let symbol {
            button.setImage(
                UIImage(
                    systemName: symbol,
                    withConfiguration: UIImage.SymbolConfiguration(pointSize: 13, weight: .semibold)
                ),
                for: .normal
            )
        }
        button.tintColor = .label
        button.layer.cornerRadius = 8
        button.layer.cornerCurve = .continuous
        if let bytes {
            button.addAction(
                UIAction { [weak self] _ in self?.onBytes?(bytes) }, for: .touchUpInside
            )
        }
        return button
    }
}
