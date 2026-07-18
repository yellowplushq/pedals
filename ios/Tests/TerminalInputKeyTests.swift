import UIKit
import XCTest

@testable import Pedals

final class TerminalInputKeyTests: XCTestCase {
    func testHardwareTextFallbackAppliesControlAndAlt() {
        XCTAssertEqual(
            TerminalKeyModifiers.ctrl.applying(toUnmodifiedByte: UInt8(ascii: "c")),
            Data([0x03])
        )
        XCTAssertEqual(
            TerminalKeyModifiers.alt.applying(toUnmodifiedByte: UInt8(ascii: "x")),
            Data([0x1b, UInt8(ascii: "x")])
        )
        XCTAssertEqual(
            TerminalKeyModifiers.ctrl.union(.alt)
                .applying(toUnmodifiedByte: UInt8(ascii: "[")),
            Data([0x1b, 0x1b])
        )
    }

    func testCursorAndNavigationSequences() {
        XCTAssertEqual(TerminalInputKey.arrow(.up).bytes(), bytes("\u{1b}[A"))
        XCTAssertEqual(
            TerminalInputKey.arrow(.left).bytes(modifiers: [.ctrl]),
            bytes("\u{1b}[1;5D")
        )
        XCTAssertEqual(
            TerminalInputKey.pageDown.bytes(modifiers: [.ctrl, .alt]),
            bytes("\u{1b}[6;7~")
        )
        XCTAssertEqual(TerminalInputKey.home.bytes(), bytes("\u{1b}[H"))
        XCTAssertEqual(TerminalInputKey.end.bytes(), bytes("\u{1b}[F"))
        XCTAssertEqual(TerminalInputKey.shiftTab.bytes(), bytes("\u{1b}[Z"))
    }

    func testFunctionKeySequences() {
        XCTAssertEqual(TerminalInputKey.function(1).bytes(), bytes("\u{1b}OP"))
        XCTAssertEqual(
            TerminalInputKey.function(4).bytes(modifiers: [.ctrl]),
            bytes("\u{1b}[1;5S")
        )
        XCTAssertEqual(TerminalInputKey.function(5).bytes(), bytes("\u{1b}[15~"))
        XCTAssertEqual(
            TerminalInputKey.function(12).bytes(modifiers: [.alt]),
            bytes("\u{1b}[24;3~")
        )
        XCTAssertNil(TerminalInputKey.function(13).bytes())
    }

    func testEditingAndAppOnlyKeys() {
        XCTAssertEqual(TerminalInputKey.escape.bytes(), Data([0x1b]))
        XCTAssertEqual(TerminalInputKey.backspace.bytes(), Data([0x7f]))
        XCTAssertEqual(
            TerminalInputKey.backspace.bytes(modifiers: [.ctrl]),
            Data([0x08])
        )
        XCTAssertEqual(TerminalInputKey.deleteForward.bytes(), bytes("\u{1b}[3~"))
        XCTAssertEqual(TerminalInputKey.clearScreen.bytes(), Data([0x0c]))
        XCTAssertNil(TerminalInputKey.text("|").bytes())
        XCTAssertNil(TerminalInputKey.paste.bytes())
        XCTAssertNil(TerminalInputKey.dismissKeyboard.bytes())
    }

    private func bytes(_ text: String) -> Data {
        Data(text.utf8)
    }
}

@MainActor
final class TerminalInputSurfaceTests: XCTestCase {
    func testCompactToolbarActuallyHasHorizontalOverflow() throws {
        let toolbar = TerminalToolbar(
            frame: CGRect(x: 0, y: 0, width: 344, height: TerminalToolbar.height)
        )
        toolbar.layoutIfNeeded()

        let scroll = try XCTUnwrap(
            findSubview(in: toolbar, identifier: "terminal-toolbar-scroll") as? UIScrollView
        )
        XCTAssertGreaterThan(scroll.contentSize.width, scroll.bounds.width)
    }

    func testExpandedKeyboardContainsFunctionAndDismissKeys() {
        let keyboard = TerminalKeyboardView()
        keyboard.layoutIfNeeded()

        XCTAssertNotNil(findSubview(in: keyboard, identifier: "terminal-key-f12"))
        XCTAssertNotNil(findSubview(in: keyboard, identifier: "terminal-key-hide-keyboard"))
        XCTAssertGreaterThan(keyboard.intrinsicContentSize.height, 0)
    }

    private func findSubview(in root: UIView, identifier: String) -> UIView? {
        if root.accessibilityIdentifier == identifier { return root }
        for subview in root.subviews {
            if let match = findSubview(in: subview, identifier: identifier) {
                return match
            }
        }
        return nil
    }
}
