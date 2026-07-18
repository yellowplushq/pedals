import Foundation
import XCTest

@testable import PedalsDaemonCore

/// Hermetic shell for tests: plain /bin/sh, no rc files, no login shell.
private func testOptions() -> SessionManager.Options {
    SessionManager.Options(shell: "/bin/sh", shellArguments: [], extraEnvironment: ["PS1": "$ "])
}

final class SessionManagerTests: XCTestCase {
    func testSpawnEchoAndReadOutput() throws {
        let manager = SessionManager(options: testOptions())
        defer { manager.closeAll() }

        let collected = OutputCollector()
        manager.onEvent = { event in
            if case .output(_, let data, _) = event { collected.append(data) }
        }

        let id = try manager.create(cwd: nil, cols: 80, rows: 24)
        XCTAssertEqual(id, 1)

        manager.write(id: id, data: Data("printf 'pedals-%s\\n' hi\n".utf8))
        try collected.wait(for: "pedals-hi", timeout: 10)

        let sessions = manager.list()
        XCTAssertEqual(sessions.count, 1)
        XCTAssertEqual(sessions[0].id, id)
        XCTAssertTrue(sessions[0].alive)
        XCTAssertEqual(sessions[0].cols, 80)
        XCTAssertEqual(sessions[0].rows, 24)
    }

    func testPromptEndMarkerIsAlwaysEmpty() throws {
        var options = testOptions()
        options.extraEnvironment["PROMPT_EOL_MARK"] = "visible"
        let manager = SessionManager(options: options)
        defer { manager.closeAll() }

        let collected = OutputCollector()
        manager.onEvent = { event in
            if case .output(_, let data, _) = event { collected.append(data) }
        }

        let id = try manager.create(cwd: nil, cols: 80, rows: 24)
        manager.write(
            id: id,
            data: Data("printf 'prompt-eol-length=%s\\n' \"${#PROMPT_EOL_MARK}\"\n".utf8)
        )
        try collected.wait(for: "prompt-eol-length=0", timeout: 10)
    }

    func testSessionIdsStartAtConfiguredHighWaterMark() throws {
        // Session-channel keys are derived from (secret, sid); a restarted
        // daemon must never hand out an old sid (PROTOCOL.md §3).
        var options = testOptions()
        options.firstSessionId = 7
        let allocated = LockedBox<Int>()
        options.onIdAllocated = { allocated.value = $0 }
        let manager = SessionManager(options: options)
        defer { manager.closeAll() }

        let id = try manager.create(cwd: nil, cols: 80, rows: 24)
        XCTAssertEqual(id, 7)
        XCTAssertEqual(allocated.value, 7)
        XCTAssertEqual(try manager.create(cwd: nil, cols: 80, rows: 24), 8)
        XCTAssertEqual(allocated.value, 8)
    }

    func testReplaySnapshotContainsPastOutput() throws {
        let manager = SessionManager(options: testOptions())
        defer { manager.closeAll() }

        let collected = OutputCollector()
        manager.onEvent = { event in
            if case .output(_, let data, _) = event { collected.append(data) }
        }

        let id = try manager.create(cwd: nil, cols: 80, rows: 24)
        manager.write(id: id, data: Data("printf 'replay-%s\\n' me\n".utf8))
        try collected.wait(for: "replay-me", timeout: 10)

        let snapshot = try XCTUnwrap(manager.replaySnapshot(id: id))
        let text = String(decoding: snapshot.data, as: UTF8.self)
        XCTAssertTrue(text.contains("replay-me"), "ring buffer must hold past output")
        XCTAssertEqual(snapshot.coversUpTo, UInt64(snapshot.data.count))
    }

    func testLiveCwdFollowsShellChdir() throws {
        let manager = SessionManager(options: testOptions())
        defer { manager.closeAll() }

        let collected = OutputCollector()
        manager.onEvent = { event in
            if case .output(_, let data, _) = event { collected.append(data) }
        }

        let id = try manager.create(cwd: nil, cols: 80, rows: 24)
        manager.write(id: id, data: Data("cd /private/var && printf 'moved-%s\\n' ok\n".utf8))
        try collected.wait(for: "moved-ok", timeout: 10)

        // The cwd poll runs every 2 s; give it two cycles.
        let deadline = Date().addingTimeInterval(6)
        while Date() < deadline {
            if manager.list().first?.cwd == "/private/var" { return }
            Thread.sleep(forTimeInterval: 0.2)
        }
        XCTFail("cwd never updated to /private/var, got \(manager.list().first?.cwd ?? "nil")")
    }

    func testExitReportsEventAndMarksDead() throws {
        let manager = SessionManager(options: testOptions())
        defer { manager.closeAll() }

        let exited = expectation(description: "exit event")
        let exitCode = LockedBox<Int>()
        manager.onEvent = { event in
            if case .exit(_, let code) = event {
                exitCode.value = code
                exited.fulfill()
            }
        }

        let id = try manager.create(cwd: nil, cols: 80, rows: 24)
        manager.write(id: id, data: Data("exit 3\n".utf8))
        wait(for: [exited], timeout: 10)

        XCTAssertEqual(exitCode.value, 3)
        let sessions = manager.list()
        XCTAssertEqual(sessions.count, 1)
        XCTAssertFalse(sessions[0].alive)
    }

    func testCloseKillsAndRemoves() throws {
        let manager = SessionManager(options: testOptions())
        defer { manager.closeAll() }

        let id = try manager.create(cwd: nil, cols: 80, rows: 24)
        XCTAssertTrue(manager.close(id: id))
        XCTAssertFalse(manager.close(id: id), "double close reports failure")
        XCTAssertTrue(manager.list().isEmpty)
    }

    func testOSCTitleUpdatesSessionInfo() throws {
        let manager = SessionManager(options: testOptions())
        defer { manager.closeAll() }

        let titled = expectation(description: "title event")
        let title = LockedBox<String>()
        manager.onEvent = { event in
            if case .title(_, let value) = event, value == "pedals-title" {
                title.value = value
                titled.fulfill()
            }
        }

        let id = try manager.create(cwd: nil, cols: 80, rows: 24)
        manager.write(id: id, data: Data("printf '\\033]2;pedals-title\\007'\n".utf8))
        wait(for: [titled], timeout: 10)

        XCTAssertEqual(title.value, "pedals-title")
        XCTAssertEqual(manager.list().first?.title, "pedals-title")
    }
}

// MARK: - helpers

final class OutputCollector: @unchecked Sendable {
    private let lock = NSLock()
    private var data = Data()

    func append(_ chunk: Data) {
        lock.lock()
        data.append(chunk)
        lock.unlock()
    }

    var text: String {
        lock.lock()
        defer { lock.unlock() }
        return String(decoding: data, as: UTF8.self)
    }

    func wait(for needle: String, timeout: TimeInterval) throws {
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            if text.contains(needle) { return }
            Thread.sleep(forTimeInterval: 0.05)
        }
        throw NSError(
            domain: "OutputCollector", code: 1,
            userInfo: [NSLocalizedDescriptionKey: "timed out waiting for \(needle); got: \(text)"]
        )
    }
}

final class LockedBox<Value>: @unchecked Sendable {
    private let lock = NSLock()
    private var stored: Value?

    var value: Value? {
        get {
            lock.lock()
            defer { lock.unlock() }
            return stored
        }
        set {
            lock.lock()
            stored = newValue
            lock.unlock()
        }
    }
}
