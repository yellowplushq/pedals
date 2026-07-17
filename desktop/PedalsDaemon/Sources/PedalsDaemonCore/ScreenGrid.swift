import Foundation

/// A minimal VT100/xterm screen model — just enough to reconstruct the
/// *current visible screen* of a TUI from its raw PTY output.
///
/// Agent state detection needs to read the live bottom UI (spinner footer,
/// approval dialog), but agents like Claude Code repaint in place with cursor
/// positioning and never emit a screen-clear, so a raw byte tail accumulates
/// stale frames. A grid solves this: overwrites land on the same cells, so the
/// bottom rows always reflect what's on screen right now — immune to scrollback
/// history and to echoed user input (which lands where the cursor is, exactly
/// like the real terminal).
///
/// Scope is deliberately small: cursor motion, line/screen erase, alt-screen,
/// printable text. SGR/colors and unhandled sequences are skipped. Not a
/// conformant emulator — a detection aid.
final class ScreenGrid {
    private(set) var rows: Int
    private(set) var cols: Int
    private var grid: [[Character]]
    private var cursorRow = 0
    private var cursorCol = 0
    /// Saved main-screen cursor while in the alternate buffer.
    private var savedCursor: (Int, Int)?
    private var inAltScreen = false

    // Partial escape sequence carried across chunk boundaries.
    private var pending = [UInt8]()

    init(rows: Int = 50, cols: Int = 200) {
        self.rows = max(4, rows)
        self.cols = max(8, cols)
        grid = Self.blank(self.rows, self.cols)
    }

    private static func blank(_ r: Int, _ c: Int) -> [[Character]] {
        Array(repeating: Array(repeating: " ", count: c), count: r)
    }

    func resize(rows: Int, cols: Int) {
        let r = max(4, rows), c = max(8, cols)
        guard r != self.rows || c != self.cols else { return }
        self.rows = r
        self.cols = c
        grid = Self.blank(r, c)
        cursorRow = 0
        cursorCol = 0
    }

    /// The entire current viewport as text, lowercased. The grid only ever
    /// holds what's on screen now (scrolled-off lines are dropped in
    /// `lineFeed`), so this is the live screen — footer and dialogs included —
    /// with no stale history to cause false matches.
    func visibleText() -> String {
        grid.map { String($0) }.joined(separator: "\n").lowercased()
    }

    // MARK: - Feed

    func feed(_ data: Data) {
        var bytes = pending + [UInt8](data)
        pending.removeAll(keepingCapacity: true)
        var i = 0
        while i < bytes.count {
            let b = bytes[i]
            switch b {
            case 0x1b:
                let consumed = handleEscape(bytes, from: i)
                if consumed < 0 {
                    // Incomplete sequence at end of chunk; carry it over.
                    pending = Array(bytes[i...])
                    return
                }
                i += consumed
            case 0x0a: // LF
                lineFeed()
                i += 1
            case 0x0d: // CR
                cursorCol = 0
                i += 1
            case 0x08: // BS
                cursorCol = max(0, cursorCol - 1)
                i += 1
            case 0x09: // TAB
                cursorCol = min(cols - 1, (cursorCol / 8 + 1) * 8)
                i += 1
            case 0x07: // BEL — not screen content
                i += 1
            default:
                if b >= 0x20 {
                    i += putUTF8(bytes, from: i)
                } else {
                    i += 1
                }
            }
        }
        // Guard against an unterminated escape hoarding unbounded bytes.
        if pending.count > 256 { pending.removeAll(keepingCapacity: true) }
        _ = bytes // silence
    }

    // MARK: - Printable

    private func putUTF8(_ bytes: [UInt8], from i: Int) -> Int {
        // Determine UTF-8 length; if truncated at chunk end, defer.
        let b = bytes[i]
        let len = b < 0x80 ? 1 : b < 0xe0 ? 2 : b < 0xf0 ? 3 : 4
        guard i + len <= bytes.count else {
            pending = Array(bytes[i...])
            return bytes.count - i // consume the rest (deferred via pending)
        }
        let scalarBytes = bytes[i ..< i + len]
        let ch = String(decoding: scalarBytes, as: UTF8.self).first ?? " "
        if cursorCol >= cols {
            cursorCol = 0
            lineFeed()
        }
        if cursorRow < rows, cursorCol < cols {
            grid[cursorRow][cursorCol] = ch
        }
        cursorCol += 1
        return len
    }

    private func lineFeed() {
        if cursorRow >= rows - 1 {
            grid.removeFirst()
            grid.append(Array(repeating: " ", count: cols))
        } else {
            cursorRow += 1
        }
    }

    // MARK: - Escape handling

    /// Returns bytes consumed, or -1 if the sequence is incomplete.
    private func handleEscape(_ bytes: [UInt8], from start: Int) -> Int {
        guard start + 1 < bytes.count else { return -1 }
        let second = bytes[start + 1]
        switch second {
        case 0x5b: // CSI
            return handleCSI(bytes, from: start)
        case 0x5d: // OSC — consume up to BEL or ST (title handled elsewhere)
            var j = start + 2
            while j < bytes.count {
                if bytes[j] == 0x07 { return j - start + 1 }
                if bytes[j] == 0x1b, j + 1 < bytes.count, bytes[j + 1] == 0x5c {
                    return j - start + 2
                }
                j += 1
            }
            return -1
        case 0x63: // ESC c — RIS
            grid = Self.blank(rows, cols)
            cursorRow = 0
            cursorCol = 0
            return 2
        case 0x37: savedCursor = (cursorRow, cursorCol); return 2 // ESC 7
        case 0x38: // ESC 8
            if let (r, c) = savedCursor { cursorRow = r; cursorCol = c }
            return 2
        default:
            return 2 // skip other two-byte escapes
        }
    }

    private func handleCSI(_ bytes: [UInt8], from start: Int) -> Int {
        var j = start + 2
        var params = [UInt8]()
        while j < bytes.count, !(0x40 ... 0x7e).contains(bytes[j]) {
            params.append(bytes[j])
            j += 1
        }
        guard j < bytes.count else { return -1 }
        let final = bytes[j]
        let consumed = j - start + 1
        let paramStr = String(decoding: params, as: UTF8.self)
        let isPrivate = params.first == 0x3f // '?'
        let nums = paramStr
            .trimmingCharacters(in: CharacterSet(charactersIn: "?"))
            .split(separator: ";", omittingEmptySubsequences: false)
            .map { Int($0) }

        func p(_ idx: Int, _ def: Int) -> Int { nums.count > idx ? (nums[idx] ?? def) : def }

        switch final {
        case 0x41: cursorRow = max(0, cursorRow - max(1, p(0, 1)))              // CUU
        case 0x42: cursorRow = min(rows - 1, cursorRow + max(1, p(0, 1)))       // CUD
        case 0x43: cursorCol = min(cols - 1, cursorCol + max(1, p(0, 1)))       // CUF
        case 0x44: cursorCol = max(0, cursorCol - max(1, p(0, 1)))              // CUB
        case 0x47: cursorCol = clampCol(p(0, 1) - 1)                            // CHA
        case 0x64: cursorRow = clampRow(p(0, 1) - 1)                            // VPA
        case 0x48, 0x66:                                                        // CUP/HVP
            cursorRow = clampRow(p(0, 1) - 1)
            cursorCol = clampCol(p(1, 1) - 1)
        case 0x4a: eraseDisplay(mode: p(0, 0))                                  // ED
        case 0x4b: eraseLine(mode: p(0, 0))                                     // EL
        case 0x68 where isPrivate && paramStr.contains("1049"):                 // alt on
            if !inAltScreen {
                inAltScreen = true
                savedCursor = (cursorRow, cursorCol)
                grid = Self.blank(rows, cols)
                cursorRow = 0; cursorCol = 0
            }
        case 0x6c where isPrivate && paramStr.contains("1049"):                 // alt off
            if inAltScreen {
                inAltScreen = false
                grid = Self.blank(rows, cols)
                if let (r, c) = savedCursor { cursorRow = r; cursorCol = c }
            }
        default: break // SGR, modes, etc.
        }
        return consumed
    }

    private func clampRow(_ r: Int) -> Int { min(max(0, r), rows - 1) }
    private func clampCol(_ c: Int) -> Int { min(max(0, c), cols - 1) }

    private func eraseDisplay(mode: Int) {
        switch mode {
        case 0: // cursor → end
            for c in cursorCol ..< cols { grid[cursorRow][c] = " " }
            for r in (cursorRow + 1) ..< rows { grid[r] = Array(repeating: " ", count: cols) }
        case 1: // start → cursor
            for r in 0 ..< cursorRow { grid[r] = Array(repeating: " ", count: cols) }
            for c in 0 ... min(cursorCol, cols - 1) { grid[cursorRow][c] = " " }
        default: // 2 / 3 — whole screen
            grid = Self.blank(rows, cols)
        }
    }

    private func eraseLine(mode: Int) {
        switch mode {
        case 0: for c in cursorCol ..< cols { grid[cursorRow][c] = " " }
        case 1: for c in 0 ... min(cursorCol, cols - 1) { grid[cursorRow][c] = " " }
        default: grid[cursorRow] = Array(repeating: " ", count: cols)
        }
    }
}
