import UIKit

/// Persistent Safari-style input bar. The compact key order is intentionally
/// optimized for shell editing and remains horizontally scrollable. The pinned
/// keyboard button swaps the system keyboard for Pedals' expanded terminal
/// keyboard without changing the surrounding layout.
final class TerminalToolbar: UIView {
    var onKey: ((TerminalInputKey) -> Void)?
    var onModifierToggle: ((TerminalModifier) -> Void)?
    var onKeyboardToggle: (() -> Void)?

    static let height: CGFloat = 48

    private let glass = GlassView()
    private let scrollView = UIScrollView()
    private let stack = UIStackView()
    private let divider = UIView()
    private let keyboardButton = TerminalToolbarButton()
    private let ctrlButton = TerminalToolbarButton()
    private let altButton = TerminalToolbarButton()

    override init(frame: CGRect) {
        super.init(frame: frame)

        accessibilityIdentifier = "terminal-toolbar"

        glass.frame = bounds
        glass.autoresizingMask = [.flexibleWidth, .flexibleHeight]
        addSubview(glass)

        scrollView.translatesAutoresizingMaskIntoConstraints = false
        scrollView.showsHorizontalScrollIndicator = false
        scrollView.alwaysBounceHorizontal = true
        scrollView.isDirectionalLockEnabled = true
        scrollView.contentInsetAdjustmentBehavior = .never
        scrollView.accessibilityIdentifier = "terminal-toolbar-scroll"
        glass.contentView.addSubview(scrollView)

        stack.translatesAutoresizingMaskIntoConstraints = false
        stack.axis = .horizontal
        stack.alignment = .fill
        stack.distribution = .fill
        stack.spacing = 0
        scrollView.addSubview(stack)

        divider.translatesAutoresizingMaskIntoConstraints = false
        divider.backgroundColor = PedalsTheme.uiSeparator
        glass.contentView.addSubview(divider)

        configureKeyboardButton()
        keyboardButton.translatesAutoresizingMaskIntoConstraints = false
        glass.contentView.addSubview(keyboardButton)

        NSLayoutConstraint.activate([
            scrollView.leadingAnchor.constraint(equalTo: glass.contentView.leadingAnchor, constant: 6),
            scrollView.topAnchor.constraint(equalTo: glass.contentView.topAnchor, constant: 4),
            scrollView.bottomAnchor.constraint(equalTo: glass.contentView.bottomAnchor, constant: -4),
            scrollView.trailingAnchor.constraint(equalTo: divider.leadingAnchor, constant: -3),

            stack.leadingAnchor.constraint(equalTo: scrollView.contentLayoutGuide.leadingAnchor),
            stack.trailingAnchor.constraint(equalTo: scrollView.contentLayoutGuide.trailingAnchor),
            stack.topAnchor.constraint(equalTo: scrollView.contentLayoutGuide.topAnchor),
            stack.bottomAnchor.constraint(equalTo: scrollView.contentLayoutGuide.bottomAnchor),
            stack.heightAnchor.constraint(equalTo: scrollView.frameLayoutGuide.heightAnchor),

            divider.centerYAnchor.constraint(equalTo: glass.contentView.centerYAnchor),
            divider.widthAnchor.constraint(equalToConstant: 1),
            divider.heightAnchor.constraint(equalToConstant: 22),
            divider.trailingAnchor.constraint(equalTo: keyboardButton.leadingAnchor, constant: -3),

            keyboardButton.trailingAnchor.constraint(
                equalTo: glass.contentView.trailingAnchor, constant: -4
            ),
            keyboardButton.topAnchor.constraint(equalTo: glass.contentView.topAnchor, constant: 4),
            keyboardButton.bottomAnchor.constraint(
                equalTo: glass.contentView.bottomAnchor, constant: -4
            ),
        ])

        buildKeys()
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    func setModifierState(_ state: TerminalModifierState) {
        ctrlButton.isSelected = state.ctrl
        altButton.isSelected = state.alt
    }

    func setTerminalKeyboardEnabled(_ enabled: Bool) {
        keyboardButton.isSelected = enabled
        keyboardButton.accessibilityLabel = enabled
            ? "Show system keyboard"
            : "Show terminal keyboard"
    }

    private func buildKeys() {
        configureModifierButton(
            ctrlButton, title: "CTRL", modifier: .ctrl, accessibilityLabel: "Control"
        )
        stack.addArrangedSubview(ctrlButton)

        appendKey(title: "TAB", key: .tab, accessibilityLabel: "Tab")
        appendKey(title: "-", key: .text("-"), accessibilityLabel: "Hyphen")
        appendKey(title: "/", key: .text("/"), accessibilityLabel: "Slash")
        appendKey(title: "⇧TAB", key: .shiftTab, accessibilityLabel: "Shift Tab")
        appendKey(title: "ESC", key: .escape, accessibilityLabel: "Escape")
        appendKey(symbol: "arrow.up", key: .arrow(.up), accessibilityLabel: "Up")
        appendKey(symbol: "arrow.down", key: .arrow(.down), accessibilityLabel: "Down")

        #if targetEnvironment(macCatalyst)
        let altTitle = "OPT"
        #else
        let altTitle = "ALT"
        #endif
        configureModifierButton(
            altButton, title: altTitle, modifier: .alt, accessibilityLabel: "Alt"
        )
        stack.addArrangedSubview(altButton)

        appendKey(symbol: "arrow.left", key: .arrow(.left), accessibilityLabel: "Left")
        appendKey(symbol: "arrow.right", key: .arrow(.right), accessibilityLabel: "Right")
    }

    private func configureKeyboardButton() {
        configure(
            keyboardButton,
            symbol: "keyboard",
            accessibilityLabel: "Show terminal keyboard"
        )
        keyboardButton.accessibilityIdentifier = "terminal-keyboard-toggle"
        keyboardButton.addAction(
            UIAction { [weak self] _ in self?.onKeyboardToggle?() },
            for: .touchUpInside
        )
    }

    private func configureModifierButton(
        _ button: TerminalToolbarButton,
        title: String,
        modifier: TerminalModifier,
        accessibilityLabel: String? = nil
    ) {
        configure(
            button,
            title: title,
            accessibilityLabel: accessibilityLabel ?? title.capitalized
        )
        button.addAction(
            UIAction { [weak self] _ in self?.onModifierToggle?(modifier) },
            for: .touchUpInside
        )
    }

    private func appendKey(
        title: String? = nil,
        symbol: String? = nil,
        key: TerminalInputKey,
        accessibilityLabel: String
    ) {
        let button = TerminalToolbarButton()
        configure(button, title: title, symbol: symbol, accessibilityLabel: accessibilityLabel)
        button.addAction(
            UIAction { [weak self] _ in self?.onKey?(key) },
            for: .touchUpInside
        )
        stack.addArrangedSubview(button)
    }

    private func configure(
        _ button: TerminalToolbarButton,
        title: String? = nil,
        symbol: String? = nil,
        accessibilityLabel: String
    ) {
        button.translatesAutoresizingMaskIntoConstraints = false
        button.widthAnchor.constraint(equalToConstant: 42).isActive = true
        button.accessibilityLabel = accessibilityLabel
        button.accessibilityIdentifier = "terminal-toolbar-" + accessibilityLabel
            .lowercased()
            .replacingOccurrences(of: " ", with: "-")

        if let title {
            button.setTitle(title, for: .normal)
            button.titleLabel?.font = .monospacedSystemFont(ofSize: 13, weight: .medium)
            button.titleLabel?.adjustsFontSizeToFitWidth = true
            button.titleLabel?.minimumScaleFactor = 0.72
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
    }
}

private final class TerminalToolbarButton: UIButton {
    override var isHighlighted: Bool {
        didSet { updateAppearance() }
    }

    override var isSelected: Bool {
        didSet { updateAppearance() }
    }

    init() {
        super.init(frame: .zero)
        tintColor = PedalsTheme.uiContent
        setTitleColor(PedalsTheme.uiContent, for: .normal)
        layer.cornerRadius = 8
        layer.cornerCurve = .continuous
        updateAppearance()
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    private func updateAppearance() {
        backgroundColor = if isSelected {
            PedalsTheme.uiSelection
        } else if isHighlighted {
            PedalsTheme.uiSurface
        } else {
            .clear
        }
        layer.borderWidth = isSelected ? 1 : 0
        layer.borderColor = PedalsTheme.uiContent.withAlphaComponent(0.92).cgColor
    }
}
