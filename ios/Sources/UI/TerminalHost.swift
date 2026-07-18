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
    /// Grid size changes (view layout / font size), to be sent as `resize` frames.
    var onResize: ((_ cols: UInt16, _ rows: UInt16) -> Void)?

    private(set) var cols: UInt16?
    private(set) var rows: UInt16?

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
        cols = viewport.columns
        rows = viewport.rows
        onResize?(viewport.columns, viewport.rows)
    }
}

/// `UIResponder.inputView` is read-only by default. A terminal responder that
/// wants an app-specific keyboard redeclares it through a mutable backing view,
/// then asks UIKit to reload the responder's input views when the mode changes.
final class PedalsTerminalView: TerminalView {
    private var replacementInputView: UIView?

    override var inputView: UIView? { replacementInputView }

    func setReplacementInputView(_ inputView: UIView?) {
        replacementInputView = inputView
    }
}
