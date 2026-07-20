import Foundation
import GhosttyTerminal
import UIKit

/// One live Ghostty emulator + view for a single remote session. Instances stay
/// in the view hierarchy (hidden when inactive) so switching sessions is instant
/// and scrollback survives.
@MainActor
final class TerminalHost {
    let view: PedalsTerminalView
    /// Each host owns its controller — see AppServices.makeTerminalController.
    let controller: TerminalController

    /// Keyboard/accessory-bar input bytes, to be sent as `stdin` frames.
    var onInput: ((Data) -> Void)?
    /// Mirrors libghostty's sticky Ctrl/Alt state into Pedals' custom toolbar.
    var onModifierStateChange: ((TerminalModifierState) -> Void)?
    /// Focus follows UIKit's first responder state, including a terminal tap
    /// that dismisses either the system or Pedals keyboard.
    var onFocusChange: ((Bool) -> Void)?
    /// Grid size changes (view layout / font size), to be sent as `resize` frames.
    var onResize: ((_ cols: UInt16, _ rows: UInt16) -> Void)?
    private(set) var cols: UInt16?
    private(set) var rows: UInt16?
    private var viewport: InMemoryTerminalViewport?
    private weak var selectionOverlay: TerminalSelectionOverlay?
    private var selectionStartedWithFirstResponder = false

    var isTextSelectionActive: Bool { selectionOverlay != nil }

    /// While a replay snapshot is being digested, the emulator re-answers any
    /// terminal queries (DA, DECRQM, …) contained in the replayed history.
    /// Those auto-responses — all ESC-prefixed control sequences — must not
    /// reach the PTY (the host answered them long ago) or the shell echoes them
    /// as garbage. Only ESC-prefixed writes are muted, so keystrokes the user
    /// types right after a reconnect/replay still go through.
    private var muteInputUntil: Date?

    private let session: InMemoryTerminalSession

    /// Weak trampoline so the `@Sendable` emulator callbacks (fired off-main)
    /// can reach the main-actor host without a retain cycle.
    private final class Relay: @unchecked Sendable {
        weak var host: TerminalHost?
    }

    init(controller: TerminalController) {
        self.controller = controller

        let relay = Relay()
        session = InMemoryTerminalSession(
            write: { data in
                Task { @MainActor in relay.host?.handleInput(data) }
            },
            resize: { viewport in
                Task { @MainActor in relay.host?.handleResize(viewport) }
            }
        )

        view = PedalsTerminalView(frame: .zero)
        view.configuration = TerminalSurfaceOptions(backend: .inMemory(session))
        view.controller = controller
        view.delegate = self
        view.backgroundColor = .clear
        view.isOpaque = false
        view.translatesAutoresizingMaskIntoConstraints = false
        // The app docks its own persistent toolbar; drop the keyboard accessory.
        view.inputAccessoryItems = []

        relay.host = self
        view.setStickyModifierChangeHandler { [weak self] in
            guard let self else { return }
            onModifierStateChange?(modifierState)
        }
        view.focusChangeHandler = { [weak self] focused in
            self?.onFocusChange?(focused)
        }
    }

    var modifierState: TerminalModifierState {
        TerminalModifierState(
            ctrl: view.stickyActivation(for: .ctrl) != .inactive,
            alt: view.stickyActivation(for: .alt) != .inactive
        )
    }

    func toggleModifier(_ modifier: TerminalModifier) {
        switch modifier {
        case .ctrl: view.toggleStickyModifier(.ctrl)
        case .alt: view.toggleStickyModifier(.alt)
        }
    }

    func sendToolbarKey(_ key: TerminalInputKey) {
        switch key {
        case .text(let text):
            // Use libghostty's text path so sticky Ctrl/Alt and IME state are
            // consumed by the same machinery as the system keyboard.
            view.insertText(text)
        case .paste:
            if let text = UIPasteboard.general.string, !text.isEmpty {
                onInput?(Data(text.utf8))
            }
            view.resetStickyModifiers()
        case .dismissKeyboard:
            // UIKit may immediately restore the responder while dispatching a
            // control event from inside its inputView. End editing on the next
            // run-loop turn, after the key tap has fully completed.
            DispatchQueue.main.async { [weak view] in
                view?.window?.endEditing(true)
            }
        default:
            let modifiers = activeKeyModifiers
            if let bytes = key.bytes(modifiers: modifiers) {
                onInput?(bytes)
            }
            // Special keys bypass libghostty's text path, so consume the
            // sticky state explicitly after encoding it into the sequence.
            if !modifiers.isEmpty {
                view.resetStickyModifiers()
            }
        }
    }

    func setReplacementInputView(_ inputView: UIView?) {
        view.setReplacementInputView(inputView)
        if view.isFirstResponder {
            view.reloadInputViews()
        }
    }

    private var activeKeyModifiers: TerminalKeyModifiers {
        var modifiers: TerminalKeyModifiers = []
        if view.stickyActivation(for: .ctrl) != .inactive { modifiers.insert(.ctrl) }
        if view.stickyActivation(for: .alt) != .inactive { modifiers.insert(.alt) }
        if view.stickyActivation(for: .command) != .inactive { modifiers.insert(.command) }
        return modifiers
    }

    /// Feed live remote `stdout` bytes into the emulator.
    func feed(_ data: Data) {
        session.receive(data)
        kickRender()
    }

    /// Feed a `replay` snapshot: reset the emulator first (RIS + erase
    /// scrollback) so a reconnect replay doesn't duplicate earlier output.
    func feedReplay(_ data: Data) {
        muteInputUntil = Date().addingTimeInterval(0.5)
        session.receive(Data("\u{1b}c\u{1b}[3J".utf8))
        session.receive(data)
        kickRender()
    }

    /// Surface the remote process exit inside the emulator.
    func markExited(code: Int) {
        session.finish(exitCode: UInt32(clamping: max(0, code)), runtimeMilliseconds: 0)
        kickRender()
    }

    /// This libghostty build never emits GHOSTTY_ACTION_RENDER for
    /// host-managed writes, so nothing schedules a redraw when remote bytes
    /// land (verified via TerminalDebugLog: writes reach the surface, zero
    /// render callbacks follow). fitToSize() ends in requestImmediateTick,
    /// making "remote data → one render pass" deterministic. The emulator
    /// digests writes on a serial queue; the async hop orders the kick after
    /// the enqueue without blocking the feed path.
    func kickRender() {
        DispatchQueue.main.async { [weak view] in
            guard let view else { return }
            view.fitToSize()
            if ProcessInfo.processInfo.environment["PEDALS_GHOSTTY_DEBUG"] != nil {
                let layers = (view.layer.sublayers ?? []).map {
                    "\(type(of: $0)) f=\($0.frame) hid=\($0.isHidden) op=\($0.opacity)"
                }
                print("[pedals-dbg] view f=\(view.frame) hid=\(view.isHidden) win=\(view.window != nil) sublayers=\(layers)")
            }
        }
    }

    private func handleInput(_ data: Data) {
        if let until = muteInputUntil {
            if Date() < until {
                // Drop only the emulator's query replies. Keyboard input can
                // start with ESC too (bare Esc, arrow keys, Alt+letter) and
                // must pass through even inside the mute window.
                if Self.isEmulatorQueryReply(data) { return }
            } else {
                muteInputUntil = nil
            }
        }
        // Software-key input is consumed by libghostty's sticky path before it
        // reaches this callback. A hardware keyboard, including Simulator's
        // Mac keyboard bridge, bypasses `insertText` and arrives here as one
        // unmodified byte while the sticky state is still armed. Cover that
        // path without touching multi-byte text/paste or emulator replies.
        if data.count == 1,
           let byte = data.first,
           !activeKeyModifiers.isEmpty,
           let modified = activeKeyModifiers.applying(toUnmodifiedByte: byte)
        {
            onInput?(modified)
            view.resetStickyModifiers()
            return
        }

        onInput?(data)
    }

    /// True for the auto-replies the emulator emits while digesting a replay:
    /// CSI reports terminating in `c` (DA), `n` (DSR), `y` (DECRQM), `R` (CPR),
    /// and DCS/OSC responses. Keyboard sequences are different shapes — bare
    /// ESC, `ESC [ A…D` arrows, `ESC O …`, Alt+letter — and all return false.
    private static func isEmulatorQueryReply(_ data: Data) -> Bool {
        guard data.count >= 3, data.first == 0x1b, let last = data.last
        else { return false }
        switch data[data.index(data.startIndex, offsetBy: 1)] {
        case UInt8(ascii: "["):
            return [
                UInt8(ascii: "c"), UInt8(ascii: "n"),
                UInt8(ascii: "y"), UInt8(ascii: "R"),
            ].contains(last)
        case UInt8(ascii: "P"), UInt8(ascii: "]"):
            return true // DCS / OSC response; never keyboard input
        default:
            return false
        }
    }

    private func handleResize(_ viewport: InMemoryTerminalViewport) {
        guard viewport.columns > 0, viewport.rows > 0 else { return }

        let previous = self.viewport
        self.viewport = viewport

        // A selection is tied to the exact Ghostty grid that produced its
        // snapshot. Reflowing it onto a different grid would make the boxes
        // drift from the glyphs, so end only genuinely geometry-changing
        // selections. An identical session resize callback is harmless.
        if let previous,
           previous.columns != viewport.columns
            || previous.rows != viewport.rows
            || previous.cellWidthPixels != viewport.cellWidthPixels
            || previous.cellHeightPixels != viewport.cellHeightPixels
        {
            selectionOverlay?.finish()
        }

        guard cols != viewport.columns || rows != viewport.rows else { return }
        cols = viewport.columns
        rows = viewport.rows
        onResize?(viewport.columns, viewport.rows)
    }

    private func beginTextSelection(_ request: TerminalTextSelectionRequest) {
        selectionOverlay?.finish()
        selectionStartedWithFirstResponder = view.wasFirstResponderBeforeCurrentTouch
        view.setPreservesFirstResponderDuringSelection(true)

        let metrics = viewport ?? InMemoryTerminalViewport(
            columns: cols ?? 1,
            rows: rows ?? 1
        )
        let overlay = TerminalSelectionOverlay(
            viewportText: request.text,
            anchorRange: request.anchorRange,
            sourcePoint: request.sourcePoint,
            viewport: metrics,
            viewportSize: view.bounds.size,
            displayScale: view.window?.screen.nativeScale
                ?? max(1, view.traitCollection.displayScale)
        )
        overlay.frame = view.bounds
        overlay.autoresizingMask = [.flexibleWidth, .flexibleHeight]
        overlay.onScrollRequest = { [weak self] direction, completion in
            self?.scrollSelectionViewport(direction: direction, completion: completion)
        }
        overlay.onFinish = { [weak self, weak overlay] in
            overlay?.removeFromSuperview()
            self?.selectionOverlay = nil
            self?.view.setTouchScrollGestureEnabled(true)
            self?.view.setPreservesFirstResponderDuringSelection(false)
            if self?.selectionStartedWithFirstResponder == false {
                self?.view.resignFirstResponder()
            }
        }
        view.setTouchScrollGestureEnabled(false)
        view.addSubview(overlay)
        selectionOverlay = overlay
        overlay.activate()
    }

    private func scrollSelectionViewport(
        direction: Int,
        completion: @escaping (String?) -> Void
    ) {
        guard direction != 0 else {
            completion(session.readViewportText())
            return
        }
        guard view.performBindingAction("scroll_page_lines:\(direction)") else {
            completion(nil)
            return
        }

        // The binding mutates Ghostty immediately, while its Metal layer draws
        // on the next main-loop pass. Update the selection in that same pass so
        // it cannot get one frame ahead of the terminal framebuffer.
        DispatchQueue.main.async { [weak self] in
            guard let self else {
                completion(nil)
                return
            }
            view.fitToSize()
            completion(session.readViewportText())
        }
    }
}

extension TerminalHost: TerminalSurfaceGridResizeDelegate,
    TerminalSurfaceTextSelectionRequestDelegate
{
    func terminalDidResize(_ size: TerminalGridMetrics) {
        // Unlike the in-memory session callback (which hops through Task), the
        // delegate receives the surface's current metrics synchronously. This
        // prevents a long press during keyboard/layout animation from starting
        // against a stale grid.
        handleResize(InMemoryTerminalViewport(
            columns: size.columns,
            rows: size.rows,
            widthPixels: size.widthPixels,
            heightPixels: size.heightPixels,
            cellWidthPixels: size.cellWidthPixels,
            cellHeightPixels: size.cellHeightPixels
        ))
    }

    func terminalDidRequestTextSelection(_ request: TerminalTextSelectionRequest) {
        beginTextSelection(request)
    }
}

/// `UIResponder.inputView` is read-only by default. A terminal responder that
/// wants an app-specific keyboard redeclares it through a mutable backing view,
/// then asks UIKit to reload the responder's input views when the mode changes.
final class PedalsTerminalView: TerminalView {
    private var replacementInputView: UIView?
    private var preservesFirstResponderDuringSelection = false
    private(set) var wasFirstResponderBeforeCurrentTouch = false
    private weak var focusTouch: UITouch?
    private var focusTouchStartPoint: CGPoint?
    private var focusTouchStartTimestamp: TimeInterval?
    private var focusTouchMaximumMovement: CGFloat = 0
    private var focusTouchIsEligible = false
    var focusChangeHandler: ((Bool) -> Void)?

    override var inputView: UIView? { replacementInputView }

    override func insertText(_ text: String) {
        // UIKit delivers the software keyboard's Return key as LF. Sending it
        // through Ghostty as ordinary text makes TUIs treat it as a literal
        // newline instead of the terminal Enter key (CR). Only normalize the
        // standalone Return event so multiline paste remains byte-for-byte.
        super.insertText(TerminalSystemTextInput.normalized(text))
    }

    @discardableResult
    override func becomeFirstResponder() -> Bool {
        let result = super.becomeFirstResponder()
        if result {
            focusChangeHandler?(true)
        }
        return result
    }

    override func touchesBegan(_ touches: Set<UITouch>, with event: UIEvent?) {
        guard let touch = touches.first(where: { $0.type == .direct }) else {
            super.touchesBegan(touches, with: event)
            return
        }

        // Ghostty normally focuses on touch-down, before its pan and long-press
        // recognizers know what the user intended. Defer focus until a short,
        // stationary touch ends so scrolling and selection never summon the
        // keyboard. Gesture recognizers still receive this touch independently.
        wasFirstResponderBeforeCurrentTouch = isFirstResponder
        focusTouch = touch
        focusTouchStartPoint = touch.location(in: self)
        focusTouchStartTimestamp = touch.timestamp
        focusTouchMaximumMovement = 0
        focusTouchIsEligible = event?.allTouches?.filter { $0.type == .direct }.count == 1
    }

    override func touchesMoved(_ touches: Set<UITouch>, with event: UIEvent?) {
        guard let touch = touches.first(where: { $0 === focusTouch }),
              let startPoint = focusTouchStartPoint
        else {
            if !touches.contains(where: { $0.type == .direct }) {
                super.touchesMoved(touches, with: event)
            }
            return
        }

        let point = touch.location(in: self)
        focusTouchMaximumMovement = max(
            focusTouchMaximumMovement,
            hypot(point.x - startPoint.x, point.y - startPoint.y)
        )
        if focusTouchMaximumMovement > TerminalFocusTapIntent.maximumMovement {
            focusTouchIsEligible = false
        }
    }

    override func touchesEnded(_ touches: Set<UITouch>, with event: UIEvent?) {
        guard let touch = touches.first(where: { $0 === focusTouch }) else {
            if !touches.contains(where: { $0.type == .direct }) {
                super.touchesEnded(touches, with: event)
            }
            return
        }

        if let startPoint = focusTouchStartPoint,
           let startTimestamp = focusTouchStartTimestamp
        {
            let point = touch.location(in: self)
            let maximumMovement = max(
                focusTouchMaximumMovement,
                hypot(point.x - startPoint.x, point.y - startPoint.y)
            )
            let shouldToggle = focusTouchIsEligible
                && TerminalFocusTapIntent.shouldToggle(
                    duration: touch.timestamp - startTimestamp,
                    maximumMovement: maximumMovement
                )
            resetFocusTouch()

            if shouldToggle {
                if wasFirstResponderBeforeCurrentTouch {
                    resignFirstResponder()
                } else {
                    becomeFirstResponder()
                }
            }
        } else {
            resetFocusTouch()
        }
    }

    override func touchesCancelled(_ touches: Set<UITouch>, with event: UIEvent?) {
        if touches.contains(where: { $0 === focusTouch }) {
            resetFocusTouch()
            return
        }
        if !touches.contains(where: { $0.type == .direct }) {
            super.touchesCancelled(touches, with: event)
        }
    }

    @discardableResult
    override func resignFirstResponder() -> Bool {
        guard !preservesFirstResponderDuringSelection else { return false }
        let result = super.resignFirstResponder()
        if result {
            focusChangeHandler?(false)
        }
        return result
    }

    override func didMoveToWindow() {
        super.didMoveToWindow()
        guard window != nil else { return }

        // A deliberate hold should select; even a small scroll should not.
        // Keep Ghostty's recognizer, but tighten its movement tolerance so the
        // vertical pan wins quickly when the finger is actually travelling.
        for case let gesture as UILongPressGestureRecognizer in gestureRecognizers ?? []
        where gesture.delegate === self {
            gesture.minimumPressDuration = 0.58
            gesture.allowableMovement = 7
        }
    }

    func setReplacementInputView(_ inputView: UIView?) {
        replacementInputView = inputView
    }

    func setPreservesFirstResponderDuringSelection(_ preserves: Bool) {
        preservesFirstResponderDuringSelection = preserves
    }

    func setTouchScrollGestureEnabled(_ enabled: Bool) {
        for case let gesture as UIPanGestureRecognizer in gestureRecognizers ?? []
        where gesture.allowedTouchTypes.contains(
            NSNumber(value: UITouch.TouchType.direct.rawValue)
        ) {
            gesture.isEnabled = enabled
        }
    }

    private func resetFocusTouch() {
        focusTouch = nil
        focusTouchStartPoint = nil
        focusTouchStartTimestamp = nil
        focusTouchMaximumMovement = 0
        focusTouchIsEligible = false
    }
}

/// A terminal focus change is deliberately stricter than UIKit's long-press
/// threshold. Anything slow or mobile belongs to selection/scroll gestures.
enum TerminalFocusTapIntent {
    static let maximumDuration: TimeInterval = 0.3
    static let maximumMovement: CGFloat = 8

    static func shouldToggle(duration: TimeInterval, maximumMovement: CGFloat) -> Bool {
        duration >= 0
            && duration <= maximumDuration
            && maximumMovement <= Self.maximumMovement
    }
}

enum TerminalSystemTextInput {
    static func normalized(_ text: String) -> String {
        text == "\n" ? "\r" : text
    }
}
