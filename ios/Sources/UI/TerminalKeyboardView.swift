import UIKit

/// App-specific terminal keyboard shown in place of the system keyboard. It
/// focuses on keys absent from iOS rather than duplicating the alphabetic
/// layout; the pinned toolbar button switches back to the system keyboard.
final class TerminalKeyboardView: UIInputView, UIInputViewAudioFeedback {
    var onKey: ((TerminalInputKey) -> Void)?

    private static let preferredHeight: CGFloat = 266
    private let glass = GlassView()
    private let rows = UIStackView()

    var enableInputClicksWhenVisible: Bool { true }

    init() {
        super.init(frame: CGRect(x: 0, y: 0, width: 0, height: Self.preferredHeight), inputViewStyle: .keyboard)

        allowsSelfSizing = true
        autoresizingMask = [.flexibleWidth]
        backgroundColor = PedalsTheme.uiCanvas
        accessibilityIdentifier = "terminal-expanded-keyboard"

        glass.translatesAutoresizingMaskIntoConstraints = false
        glass.cornerRadius = 22
        addSubview(glass)

        rows.translatesAutoresizingMaskIntoConstraints = false
        rows.axis = .vertical
        rows.alignment = .fill
        rows.distribution = .fillEqually
        rows.spacing = 6
        glass.contentView.addSubview(rows)

        NSLayoutConstraint.activate([
            heightAnchor.constraint(equalToConstant: Self.preferredHeight),

            glass.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 8),
            glass.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -8),
            glass.topAnchor.constraint(equalTo: topAnchor, constant: 6),
            glass.bottomAnchor.constraint(equalTo: bottomAnchor, constant: -8),

            rows.leadingAnchor.constraint(equalTo: glass.contentView.leadingAnchor, constant: 8),
            rows.trailingAnchor.constraint(equalTo: glass.contentView.trailingAnchor, constant: -8),
            rows.topAnchor.constraint(equalTo: glass.contentView.topAnchor, constant: 9),
            rows.bottomAnchor.constraint(equalTo: glass.contentView.bottomAnchor, constant: -9),
        ])

        buildRows()
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    override var intrinsicContentSize: CGSize {
        CGSize(width: UIView.noIntrinsicMetric, height: Self.preferredHeight)
    }

    private func buildRows() {
        addRow([
            .text("esc", .escape, "Escape"),
            .text("F1", .function(1), "F1"),
            .text("F2", .function(2), "F2"),
            .text("F3", .function(3), "F3"),
            .text("F4", .function(4), "F4"),
            .text("F5", .function(5), "F5"),
            .text("F6", .function(6), "F6"),
        ])

        addRow([
            .text("F7", .function(7), "F7"),
            .text("F8", .function(8), "F8"),
            .text("F9", .function(9), "F9"),
            .text("F10", .function(10), "F10"),
            .text("F11", .function(11), "F11"),
            .text("F12", .function(12), "F12"),
            .text("clear", .clearScreen, "Clear Screen"),
        ])

        addRow([
            .text("home", .home, "Home"),
            .text("pg↑", .pageUp, "Page Up"),
            .symbol("arrow.up", .arrow(.up), "Up"),
            .text("pg↓", .pageDown, "Page Down"),
            .text("end", .end, "End"),
        ])

        addRow([
            .symbol("arrow.left", .arrow(.left), "Left"),
            .symbol("arrow.down", .arrow(.down), "Down"),
            .symbol("arrow.right", .arrow(.right), "Right"),
            .text("ins", .insert, "Insert"),
            .text("del", .deleteForward, "Forward Delete"),
        ])

        addRow([
            .symbol("keyboard.chevron.compact.down", .dismissKeyboard, "Hide Keyboard"),
            .text("⇧tab", .shiftTab, "Shift Tab"),
            .text("tab", .tab, "Tab"),
            .symbol("delete.left", .backspace, "Backspace"),
            .symbol("return.left", .enter, "Return"),
        ])
    }

    private func addRow(_ keys: [KeyDescription]) {
        let row = UIStackView()
        row.axis = .horizontal
        row.alignment = .fill
        row.distribution = .fillEqually
        row.spacing = 6

        for key in keys {
            let button = TerminalKeyboardButton()
            button.accessibilityLabel = key.accessibilityLabel
            button.accessibilityIdentifier = key.identifier

            switch key.content {
            case .title(let title):
                button.setTitle(title, for: .normal)
                button.titleLabel?.font = .monospacedSystemFont(ofSize: 12, weight: .medium)
                button.titleLabel?.adjustsFontSizeToFitWidth = true
                button.titleLabel?.minimumScaleFactor = 0.68
            case .symbol(let symbol):
                button.setImage(
                    UIImage(
                        systemName: symbol,
                        withConfiguration: UIImage.SymbolConfiguration(
                            pointSize: 13, weight: .semibold
                        )
                    ),
                    for: .normal
                )
            }

            button.addAction(
                UIAction { [weak self] _ in
                    UIDevice.current.playInputClick()
                    self?.onKey?(key.key)
                },
                for: .touchUpInside
            )
            row.addArrangedSubview(button)
        }

        rows.addArrangedSubview(row)
    }
}

private struct KeyDescription {
    enum Content {
        case title(String)
        case symbol(String)
    }

    let content: Content
    let key: TerminalInputKey
    let accessibilityLabel: String

    var identifier: String {
        "terminal-key-" + accessibilityLabel
            .lowercased()
            .replacingOccurrences(of: " ", with: "-")
    }

    static func text(
        _ title: String,
        _ key: TerminalInputKey,
        _ accessibilityLabel: String
    ) -> Self {
        Self(content: .title(title), key: key, accessibilityLabel: accessibilityLabel)
    }

    static func symbol(
        _ symbol: String,
        _ key: TerminalInputKey,
        _ accessibilityLabel: String
    ) -> Self {
        Self(content: .symbol(symbol), key: key, accessibilityLabel: accessibilityLabel)
    }
}

private final class TerminalKeyboardButton: UIButton {
    override var isHighlighted: Bool {
        didSet {
            backgroundColor = isHighlighted
                ? PedalsTheme.uiSelection
                : PedalsTheme.uiSurface
        }
    }

    init() {
        super.init(frame: .zero)
        tintColor = PedalsTheme.uiContent
        setTitleColor(PedalsTheme.uiContent, for: .normal)
        backgroundColor = PedalsTheme.uiSurface
        layer.cornerRadius = 10
        layer.cornerCurve = .continuous
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }
}
