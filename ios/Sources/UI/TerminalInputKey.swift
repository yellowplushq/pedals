import Foundation

struct TerminalKeyModifiers: OptionSet, Equatable {
    let rawValue: UInt8

    static let ctrl = Self(rawValue: 1 << 0)
    static let alt = Self(rawValue: 1 << 1)
    static let command = Self(rawValue: 1 << 2)

    /// Xterm's modifier parameter is one plus Shift/Alt/Ctrl/Super bit values.
    var xtermParameter: Int {
        1
            + (contains(.alt) ? 2 : 0)
            + (contains(.ctrl) ? 4 : 0)
            + (contains(.command) ? 8 : 0)
    }

    /// Applies terminal Ctrl/Alt semantics to a single printable byte. This is
    /// a fallback for hardware-key delivery: UIKit sends those presses through
    /// `pressesBegan` instead of `insertText`, so libghostty's sticky modifier
    /// state is still armed when the unmodified byte reaches our in-memory
    /// session.
    func applying(toUnmodifiedByte byte: UInt8) -> Data? {
        guard (0x20 ... 0x7e).contains(byte) else { return nil }

        var output = byte
        if contains(.ctrl) {
            guard let controlByte = Self.controlByte(for: byte) else { return nil }
            output = controlByte
        }

        var data = Data()
        if contains(.alt) { data.append(0x1b) }
        data.append(output)
        return data
    }

    private static func controlByte(for byte: UInt8) -> UInt8? {
        switch byte {
        case UInt8(ascii: "a") ... UInt8(ascii: "z"):
            byte & 0x1f
        case UInt8(ascii: "A") ... UInt8(ascii: "Z"):
            byte & 0x1f
        case UInt8(ascii: "@"), UInt8(ascii: " "), UInt8(ascii: "`"):
            0x00
        case UInt8(ascii: "["), UInt8(ascii: "{"):
            0x1b
        case UInt8(ascii: "\\"), UInt8(ascii: "|"):
            0x1c
        case UInt8(ascii: "]"), UInt8(ascii: "}"):
            0x1d
        case UInt8(ascii: "^"), UInt8(ascii: "~"):
            0x1e
        case UInt8(ascii: "_"):
            0x1f
        case UInt8(ascii: "?"):
            0x7f
        default:
            nil
        }
    }
}

enum TerminalModifier: Equatable {
    case ctrl
    case alt
}

struct TerminalModifierState: Equatable {
    var ctrl = false
    var alt = false
}

/// Semantic keys shared by the compact toolbar and the expanded terminal
/// keyboard. Text and paste travel through their dedicated input paths; every
/// other case maps to terminal bytes here so both surfaces behave identically.
enum TerminalInputKey: Equatable {
    enum Arrow: Equatable {
        case left
        case up
        case down
        case right
    }

    case escape
    case tab
    case shiftTab
    case backspace
    case deleteForward
    case enter
    case arrow(Arrow)
    case home
    case end
    case pageUp
    case pageDown
    case insert
    case function(Int)
    case clearScreen
    case text(String)
    case paste
    case dismissKeyboard

    func bytes(modifiers: TerminalKeyModifiers = []) -> Data? {
        switch self {
        case .escape:
            return Data([0x1b])
        case .tab:
            return prefixedForAlt(Data([0x09]), modifiers: modifiers)
        case .shiftTab:
            return Data("\u{1b}[Z".utf8)
        case .backspace:
            let byte: UInt8 = modifiers.contains(.ctrl) ? 0x08 : 0x7f
            return prefixedForAlt(Data([byte]), modifiers: modifiers)
        case .deleteForward:
            return tildeSequence(code: 3, modifiers: modifiers)
        case .enter:
            return prefixedForAlt(Data([0x0d]), modifiers: modifiers)
        case .arrow(let arrow):
            let final: Character = switch arrow {
            case .left: "D"
            case .up: "A"
            case .down: "B"
            case .right: "C"
            }
            return cursorSequence(final: final, modifiers: modifiers)
        case .home:
            return cursorSequence(final: "H", modifiers: modifiers)
        case .end:
            return cursorSequence(final: "F", modifiers: modifiers)
        case .pageUp:
            return tildeSequence(code: 5, modifiers: modifiers)
        case .pageDown:
            return tildeSequence(code: 6, modifiers: modifiers)
        case .insert:
            return tildeSequence(code: 2, modifiers: modifiers)
        case .function(let number):
            return functionSequence(number: number, modifiers: modifiers)
        case .clearScreen:
            return Data([0x0c])
        case .text, .paste, .dismissKeyboard:
            return nil
        }
    }

    private func cursorSequence(
        final: Character,
        modifiers: TerminalKeyModifiers
    ) -> Data {
        if modifiers.isEmpty {
            return Data("\u{1b}[\(final)".utf8)
        }
        return Data("\u{1b}[1;\(modifiers.xtermParameter)\(final)".utf8)
    }

    private func tildeSequence(
        code: Int,
        modifiers: TerminalKeyModifiers
    ) -> Data {
        if modifiers.isEmpty {
            return Data("\u{1b}[\(code)~".utf8)
        }
        return Data("\u{1b}[\(code);\(modifiers.xtermParameter)~".utf8)
    }

    private func functionSequence(
        number: Int,
        modifiers: TerminalKeyModifiers
    ) -> Data? {
        if (1 ... 4).contains(number) {
            let final = ["P", "Q", "R", "S"][number - 1]
            if modifiers.isEmpty {
                return Data("\u{1b}O\(final)".utf8)
            }
            return Data("\u{1b}[1;\(modifiers.xtermParameter)\(final)".utf8)
        }

        let codes = [5: 15, 6: 17, 7: 18, 8: 19, 9: 20, 10: 21, 11: 23, 12: 24]
        guard let code = codes[number] else { return nil }
        return tildeSequence(code: code, modifiers: modifiers)
    }

    private func prefixedForAlt(
        _ data: Data,
        modifiers: TerminalKeyModifiers
    ) -> Data {
        guard modifiers.contains(.alt) else { return data }
        return Data([0x1b]) + data
    }
}
