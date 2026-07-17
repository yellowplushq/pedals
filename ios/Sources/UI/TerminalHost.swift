import Foundation
import GhosttyTerminal
import UIKit

/// One live Ghostty emulator + view for a single remote session. Instances stay
/// in the view hierarchy (hidden when inactive) so switching sessions is instant
/// and scrollback survives.
@MainActor
final class TerminalHost {
    let sessionId: Int
    let view: TerminalView
    /// Each host owns its controller — see AppServices.makeTerminalController.
    let controller: TerminalController

    /// Keyboard/accessory-bar input bytes, to be sent as `stdin` frames.
    var onInput: ((Data) -> Void)?
    /// Armed by the toolbar's Ctrl key: the next keyboard byte is transformed
    /// into its control code (a → ^A). Cleared after one use.
    var stickyCtrl = false
    var onStickyCtrlConsumed: (() -> Void)?
    /// Grid size changes (view layout / font size), to be sent as `resize` frames.
    var onResize: ((_ cols: UInt16, _ rows: UInt16) -> Void)?

    private(set) var cols: UInt16?
    private(set) var rows: UInt16?

    /// While a replay snapshot is being digested, the emulator re-answers any
    /// terminal queries (DA, DECRQM, …) contained in the replayed history.
    /// Those responses must not reach the PTY — the host answered them long
    /// ago — or the shell echoes them as garbage at the prompt.
    private var muteInputUntil: Date?

    private let session: InMemoryTerminalSession

    /// Weak trampoline so the `@Sendable` emulator callbacks (fired off-main)
    /// can reach the main-actor host without a retain cycle.
    private final class Relay: @unchecked Sendable {
        weak var host: TerminalHost?
    }

    init(sessionId: Int, controller: TerminalController) {
        self.sessionId = sessionId
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

        view = TerminalView(frame: .zero)
        view.configuration = TerminalSurfaceOptions(backend: .inMemory(session))
        view.controller = controller
        view.backgroundColor = .clear
        view.isOpaque = false
        view.translatesAutoresizingMaskIntoConstraints = false
        // The app docks its own persistent toolbar; drop the keyboard accessory.
        view.inputAccessoryItems = []

        relay.host = self
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
            if Date() < until { return }
            muteInputUntil = nil
        }
        var data = data
        if stickyCtrl, data.count == 1, let byte = data.first,
           (0x3f ... 0x7e).contains(byte)
        {
            data = Data([byte & 0x1f])
            stickyCtrl = false
            onStickyCtrlConsumed?()
        }
        onInput?(data)
    }

    private func handleResize(_ viewport: InMemoryTerminalViewport) {
        guard viewport.columns > 0, viewport.rows > 0 else { return }
        cols = viewport.columns
        rows = viewport.rows
        onResize?(viewport.columns, viewport.rows)
    }
}
