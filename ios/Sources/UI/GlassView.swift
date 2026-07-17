import UIKit

/// A capsule (or rounded-rect) Liquid Glass surface with a graceful fallback
/// to system materials before iOS 26. Content goes into `contentView`.
final class GlassView: UIView {
    let contentView = UIView()
    private let effectView: UIVisualEffectView

    /// Corner radius applied to the glass. `nil` means capsule (height / 2).
    var cornerRadius: CGFloat? {
        didSet { setNeedsLayout() }
    }

    init(interactive: Bool = true) {
        if #available(iOS 26.0, *) {
            let glass = UIGlassEffect()
            glass.isInteractive = interactive
            effectView = UIVisualEffectView(effect: glass)
        } else {
            effectView = UIVisualEffectView(
                effect: UIBlurEffect(style: .systemChromeMaterialDark)
            )
        }
        super.init(frame: .zero)

        effectView.frame = bounds
        effectView.autoresizingMask = [.flexibleWidth, .flexibleHeight]
        addSubview(effectView)

        contentView.frame = bounds
        contentView.autoresizingMask = [.flexibleWidth, .flexibleHeight]
        addSubview(contentView)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    override func layoutSubviews() {
        super.layoutSubviews()
        let radius = cornerRadius ?? bounds.height / 2
        layer.cornerRadius = radius
        layer.cornerCurve = .continuous
        layer.masksToBounds = true
        effectView.layer.cornerRadius = radius
        effectView.layer.cornerCurve = .continuous
        effectView.clipsToBounds = true
    }
}
