@testable import GhosttyTerminal
import Foundation
import GhosttyKit
import Testing

struct InMemoryTerminalSynchronousReceiveTests {
    @Test
    func `attaching a surface arms in-band size reports`() {
        let events = LockedValues<String>()
        let session = InMemoryTerminalSession(
            write: { _ in },
            resize: { _ in },
            surfaceWrite: { _, data in
                events.append(String(decoding: data, as: UTF8.self))
            }
        )
        session.setSurface(testSurface(1))

        #expect(events.values == ["\u{1b}[?2048h"])
    }

    @Test
    func `synchronous receive finishes parsing before returning`() {
        let events = LockedValues<String>()
        let session = InMemoryTerminalSession(
            write: { _ in },
            resize: { _ in },
            surfaceWrite: { _, data in
                events.append(String(decoding: data, as: UTF8.self))
            }
        )
        session.setSurface(testSurface(1))

        session.receiveSynchronously(Data("frame".utf8))

        #expect(events.values == ["\u{1b}[?2048h", "frame"])
    }
}

struct InMemoryTerminalSizeReportTests {
    @Test
    func `extracts an applied size report and derives cell metrics`() {
        let (passthrough, reports) = InMemoryTerminalSizeReport.extract(
            from: Data("\u{1b}[48;37;48;2010;1206t".utf8)
        )

        #expect(passthrough.isEmpty)
        #expect(reports.map(\.viewport) == [
            InMemoryTerminalViewport(
                columns: 48,
                rows: 37,
                widthPixels: 1206,
                heightPixels: 2010,
                cellWidthPixels: 25,
                cellHeightPixels: 54
            ),
        ])
    }

    @Test
    func `passes surrounding host input through unchanged`() {
        let (passthrough, reports) = InMemoryTerminalSizeReport.extract(
            from: Data("abc\u{1b}[48;21;48;1134;1206tdef".utf8)
        )

        #expect(String(decoding: passthrough, as: UTF8.self) == "abcdef")
        #expect(reports.count == 1)
        #expect(reports.first?.rows == 21)
        #expect(reports.first?.columns == 48)
    }

    @Test
    func `leaves other escape sequences untouched`() {
        let inputs = [
            "\u{1b}[A",             // arrow key
            "\u{1b}[48;1t",         // too few fields
            "\u{1b}[48;1;2;3;4;5t", // too many fields
            "\u{1b}[8;37;48t",      // XTWINOPS, not mode 2048
            "\u{1b}[48;37;48;2010;1206x", // wrong terminator
            "\u{1b}",               // bare ESC at end of chunk
        ]

        for input in inputs {
            let (passthrough, reports) = InMemoryTerminalSizeReport.extract(
                from: Data(input.utf8)
            )
            #expect(String(decoding: passthrough, as: UTF8.self) == input)
            #expect(reports.isEmpty)
        }
    }

    @Test
    func `extracts consecutive reports`() {
        let (passthrough, reports) = InMemoryTerminalSizeReport.extract(
            from: Data("\u{1b}[48;21;48;1134;1206t\u{1b}[48;37;48;2010;1206t".utf8)
        )

        #expect(passthrough.isEmpty)
        #expect(reports.map(\.rows) == [21, 37])
    }
}

private func testSurface(_ address: Int) -> ghostty_surface_t {
    UnsafeMutableRawPointer(bitPattern: address)!
}

private final class LockedValues<Value: Sendable>: @unchecked Sendable {
    private let lock = NSLock()
    private var storage: [Value] = []

    var values: [Value] {
        lock.lock()
        defer { lock.unlock() }
        return storage
    }

    func append(_ value: Value) {
        lock.lock()
        storage.append(value)
        lock.unlock()
    }
}
