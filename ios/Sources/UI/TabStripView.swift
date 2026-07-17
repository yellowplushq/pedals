import UIKit

/// Safari-style top tab strip: one pill per session, the active pill expanded
/// with settings/title/close, inactive pills collapsed to icons. Widths follow
/// Chrome's squeeze model (inactive tabs compress before the strip scrolls),
/// and `setSwitchProgress` lets a content-area pan drive the expand/collapse
/// interpolation so the strip follows the finger.
final class TabStripView: UIView {
    struct Tab: Equatable {
        let id: Int
        var title: String
        var alive: Bool
    }

    var onSelect: ((Int) -> Void)?
    var onClose: ((Int) -> Void)?
    var onSettings: (() -> Void)?
    var onCreate: (() -> Void)?

    static let height: CGFloat = 44
    private static let pillHeight: CGFloat = 40
    private static let spacing: CGFloat = 8
    private static let maxActiveWidth: CGFloat = 230
    private static let minActiveWidth: CGFloat = 150
    private static let maxInactiveWidth: CGFloat = 64
    private static let minInactiveWidth: CGFloat = 40

    private let scrollView = UIScrollView()
    private let plusButton = UIButton(type: .system)
    private let plusGlass = GlassView()
    private let settingsButton = UIButton(type: .system)
    private let settingsGlass = GlassView()

    private(set) var tabs: [Tab] = []
    private var activeIndex: Int?
    private var pills: [Int: TabPillView] = [:]

    /// Non-nil while a pan drives the strip: (fromIndex, toIndex, progress).
    private var transition: (from: Int, to: Int, progress: CGFloat)?

    override init(frame: CGRect) {
        super.init(frame: frame)

        scrollView.showsHorizontalScrollIndicator = false
        scrollView.alwaysBounceHorizontal = true
        // Scrolled pills must not bleed over the fixed settings/plus pills.
        scrollView.clipsToBounds = true
        addSubview(scrollView)

        plusGlass.contentView.addSubview(plusButton)
        plusButton.setImage(
            UIImage(
                systemName: "plus",
                withConfiguration: UIImage.SymbolConfiguration(pointSize: 15, weight: .semibold)
            ),
            for: .normal
        )
        plusButton.tintColor = .label
        plusButton.addAction(UIAction { [weak self] _ in self?.onCreate?() }, for: .touchUpInside)
        addSubview(plusGlass)

        // Settings lives as a permanent, un-closeable leftmost tab.
        settingsGlass.contentView.addSubview(settingsButton)
        settingsButton.setImage(
            UIImage(
                systemName: "gearshape.fill",
                withConfiguration: UIImage.SymbolConfiguration(pointSize: 14, weight: .semibold)
            ),
            for: .normal
        )
        settingsButton.tintColor = .label
        settingsButton.addAction(
            UIAction { [weak self] _ in self?.onSettings?() }, for: .touchUpInside
        )
        addSubview(settingsGlass)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    // MARK: - Model

    func update(tabs newTabs: [Tab], activeId: Int?) {
        let oldActive = activeIndex
        tabs = newTabs
        activeIndex = activeId.flatMap { id in tabs.firstIndex { $0.id == id } }

        var seen = Set<Int>()
        for tab in tabs {
            seen.insert(tab.id)
            if let pill = pills[tab.id] {
                pill.configure(tab: tab)
            } else {
                let pill = TabPillView()
                pill.configure(tab: tab)
                pill.onTap = { [weak self] in self?.onSelect?(tab.id) }
                pill.onClose = { [weak self] in self?.onClose?(tab.id) }
                pills[tab.id] = pill
                scrollView.addSubview(pill)
            }
        }
        for (id, pill) in pills where !seen.contains(id) {
            pills.removeValue(forKey: id)
            pill.removeFromSuperview()
        }

        transition = nil
        let animated = oldActive != activeIndex && window != nil
        if animated {
            UIView.animate(
                withDuration: 0.45, delay: 0,
                usingSpringWithDamping: 0.82, initialSpringVelocity: 0.4,
                options: [.allowUserInteraction]
            ) {
                self.layoutStrip()
            }
        } else {
            setNeedsLayout()
        }
    }

    // MARK: - Gesture-driven transition

    func setSwitchProgress(from: Int, to: Int, progress: CGFloat) {
        guard from != to, tabs.indices.contains(from), tabs.indices.contains(to) else { return }
        transition = (from, to, max(0, min(1, progress)))
        layoutStrip()
    }

    func cancelSwitchProgress() {
        guard transition != nil else { return }
        transition = nil
        UIView.animate(
            withDuration: 0.4, delay: 0,
            usingSpringWithDamping: 0.85, initialSpringVelocity: 0.3,
            options: [.allowUserInteraction]
        ) {
            self.layoutStrip()
        }
    }

    // MARK: - Layout

    override func layoutSubviews() {
        super.layoutSubviews()

        let pillSize: CGFloat = Self.pillHeight
        settingsGlass.frame = CGRect(
            x: 12,
            y: (bounds.height - pillSize) / 2,
            width: pillSize,
            height: pillSize
        )
        settingsButton.frame = settingsGlass.contentView.bounds

        plusGlass.frame = CGRect(
            x: bounds.width - pillSize - 12,
            y: (bounds.height - pillSize) / 2,
            width: pillSize,
            height: pillSize
        )
        plusButton.frame = plusGlass.contentView.bounds

        scrollView.frame = CGRect(
            x: settingsGlass.frame.maxX + Self.spacing, y: 0,
            width: plusGlass.frame.minX - settingsGlass.frame.maxX - Self.spacing * 2,
            height: bounds.height
        )
        layoutStrip()
    }

    /// Width for each tab index under the squeeze model, honoring an in-flight
    /// gesture transition by interpolating active widths.
    private func widths(available: CGFloat) -> [CGFloat] {
        guard !tabs.isEmpty else { return [] }
        let count = CGFloat(tabs.count)
        let spacingTotal = Self.spacing * (count - 1)

        // A lone tab claims the whole strip.
        guard tabs.count > 1 else { return [available] }

        var active = Self.maxActiveWidth
        var inactive = (available - spacingTotal - active) / (count - 1)
        if inactive < Self.maxInactiveWidth {
            // Squeeze: shrink inactive first, then the active pill, then scroll.
            inactive = max(Self.minInactiveWidth, inactive)
            let remaining = available - spacingTotal - inactive * (count - 1)
            active = max(Self.minActiveWidth, min(Self.maxActiveWidth, remaining))
        } else {
            inactive = min(Self.maxInactiveWidth, inactive)
        }

        let activeIdx = activeIndex ?? 0
        return tabs.indices.map { index in
            var expansion: CGFloat = index == activeIdx ? 1 : 0
            if let transition {
                if index == transition.from { expansion = 1 - transition.progress }
                if index == transition.to { expansion = transition.progress }
            }
            return inactive + (active - inactive) * expansion
        }
    }

    private func layoutStrip() {
        let widths = widths(available: scrollView.bounds.width)
        var x: CGFloat = 0
        for (index, tab) in tabs.enumerated() {
            guard let pill = pills[tab.id] else { continue }
            let width = widths[index]
            pill.frame = CGRect(
                x: x,
                y: (bounds.height - Self.pillHeight) / 2,
                width: width,
                height: Self.pillHeight
            )
            let expansion = expansionAmount(index: index, width: width)
            pill.setExpansion(expansion, isActive: index == activeIndex)
            x += width + Self.spacing
        }
        let contentWidth = max(0, x - Self.spacing)
        scrollView.contentSize = CGSize(width: contentWidth, height: bounds.height)
        scrollToActive()
    }

    private func expansionAmount(index: Int, width: CGFloat) -> CGFloat {
        let range = Self.minActiveWidth - Self.maxInactiveWidth
        return max(0, min(1, (width - Self.maxInactiveWidth) / range))
    }

    private func scrollToActive() {
        guard let activeIndex, let pill = pills[tabs[activeIndex].id],
              scrollView.contentSize.width > scrollView.bounds.width
        else { return }
        let target = pill.frame.insetBy(dx: -Self.spacing * 3, dy: 0)
        scrollView.scrollRectToVisible(target, animated: false)
    }
}

/// One tab pill. Expanded (active) it shows title · close; collapsed it shows
/// just the session glyph. `setExpansion` cross-fades between the two.
final class TabPillView: UIView {
    var onTap: (() -> Void)?
    var onClose: (() -> Void)?

    private let glass = GlassView()
    private let glyphLabel = UILabel()
    private let titleLabel = UILabel()
    private let closeButton = UIButton(type: .system)

    override init(frame: CGRect) {
        super.init(frame: frame)

        glass.frame = bounds
        glass.autoresizingMask = [.flexibleWidth, .flexibleHeight]
        addSubview(glass)

        glyphLabel.font = .monospacedSystemFont(ofSize: 15, weight: .semibold)
        glyphLabel.textColor = .secondaryLabel
        glyphLabel.textAlignment = .center
        glass.contentView.addSubview(glyphLabel)

        titleLabel.font = .systemFont(ofSize: 13, weight: .semibold)
        titleLabel.textColor = .label
        titleLabel.textAlignment = .center
        titleLabel.lineBreakMode = .byTruncatingTail
        glass.contentView.addSubview(titleLabel)

        let symbolConfig = UIImage.SymbolConfiguration(pointSize: 11, weight: .bold)
        closeButton.setImage(
            UIImage(systemName: "xmark", withConfiguration: symbolConfig), for: .normal
        )
        closeButton.tintColor = .secondaryLabel
        closeButton.addAction(
            UIAction { [weak self] _ in self?.onClose?() }, for: .touchUpInside
        )
        glass.contentView.addSubview(closeButton)

        addGestureRecognizer(UITapGestureRecognizer(target: self, action: #selector(didTap)))
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    func configure(tab: TabStripView.Tab) {
        titleLabel.text = tab.title
        let glyph = tab.title.first.map { String($0).lowercased() } ?? ">"
        glyphLabel.text = tab.alive ? glyph : "×"
        glyphLabel.textColor = tab.alive ? .secondaryLabel : .systemRed
        titleLabel.textColor = tab.alive ? .label : .secondaryLabel
    }

    /// 0 = collapsed icon pill, 1 = fully expanded active pill.
    func setExpansion(_ amount: CGFloat, isActive: Bool) {
        titleLabel.alpha = amount
        closeButton.alpha = amount
        glyphLabel.alpha = 1 - amount
        closeButton.isUserInteractionEnabled = isActive && amount > 0.5
        setNeedsLayout()
    }

    @objc private func didTap() {
        onTap?()
    }

    override func layoutSubviews() {
        super.layoutSubviews()
        let bounds = glass.contentView.bounds
        glyphLabel.frame = bounds
        let side: CGFloat = 30
        closeButton.frame = CGRect(
            x: bounds.width - side - 6, y: (bounds.height - side) / 2, width: side, height: side
        )
        // Keep the title optically centered by mirroring the close button's
        // footprint on the leading side.
        let inset = bounds.width - closeButton.frame.minX + 2
        titleLabel.frame = CGRect(
            x: inset,
            y: 0,
            width: max(0, bounds.width - inset * 2),
            height: bounds.height
        )
    }
}
