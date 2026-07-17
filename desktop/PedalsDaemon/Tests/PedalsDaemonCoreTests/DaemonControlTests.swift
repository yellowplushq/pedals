import Foundation
import PedalsKit
import XCTest

@testable import PedalsDaemonCore

/// Full daemon against its unix control socket (PROTOCOL.md §5): ls / new /
/// kill / pair / status. The relay URL points at a closed port; the relay
/// client just keeps retrying, which the control plane must not depend on.
final class DaemonControlTests: XCTestCase {
    private var home: PedalsHome!
    private var daemon: Daemon!

    override func setUpWithError() throws {
        // sockaddr_un.sun_path caps unix socket paths at 104 bytes, so the
        // test home must live somewhere short — not NSTemporaryDirectory().
        let directory = URL(fileURLWithPath: "/tmp", isDirectory: true)
            .appendingPathComponent(
                "pedals-t-\(UUID().uuidString.prefix(8))", isDirectory: true
            )
        home = PedalsHome(directory: directory)
        try home.save(config: .init(relay: "ws://127.0.0.1:1"))
        daemon = try Daemon(
            home: home,
            sessionOptions: SessionManager.Options(shell: "/bin/sh", shellArguments: [])
        )
        try daemon.start()
    }

    override func tearDownWithError() throws {
        daemon?.shutdown()
        if let home { try? FileManager.default.removeItem(at: home.directory) }
    }

    private func send(_ request: [String: Any]) throws -> [String: Any] {
        try ControlClient.roundTrip(socketPath: home.socketPath, request: request)
    }

    func testLsNewKillRoundTrip() throws {
        var reply = try send(["cmd": "ls"])
        XCTAssertEqual(reply["ok"] as? Bool, true)
        XCTAssertEqual((reply["sessions"] as? [Any])?.count, 0)
        XCTAssertEqual(reply["client"] as? String, "none")
        XCTAssertEqual(reply["relay"] as? String, "ws://127.0.0.1:1")

        reply = try send(["cmd": "new"])
        XCTAssertEqual(reply["ok"] as? Bool, true)
        let id = try XCTUnwrap(reply["id"] as? Int)

        reply = try send(["cmd": "ls"])
        let sessions = try XCTUnwrap(reply["sessions"] as? [[String: Any]])
        XCTAssertEqual(sessions.count, 1)
        XCTAssertEqual(sessions[0]["id"] as? Int, id)
        XCTAssertEqual(sessions[0]["alive"] as? Bool, true)
        XCTAssertEqual(sessions[0]["cols"] as? Int, 120)
        XCTAssertEqual(sessions[0]["rows"] as? Int, 40)

        reply = try send(["cmd": "kill", "id": id])
        XCTAssertEqual(reply["ok"] as? Bool, true)

        reply = try send(["cmd": "ls"])
        XCTAssertEqual((reply["sessions"] as? [Any])?.count, 0)

        reply = try send(["cmd": "kill", "id": id])
        XCTAssertEqual(reply["ok"] as? Bool, false)
        XCTAssertNotNil(reply["err"])
    }

    func testPairReturnsURLAndResetRotatesRoom() throws {
        let first = try send(["cmd": "pair"])
        XCTAssertEqual(first["ok"] as? Bool, true)
        let firstInfo = try PairingInfo(urlString: try XCTUnwrap(first["url"] as? String))

        let unchanged = try send(["cmd": "pair"])
        XCTAssertEqual(unchanged["url"] as? String, first["url"] as? String)

        let reset = try send(["cmd": "pair", "reset": true])
        let resetInfo = try PairingInfo(urlString: try XCTUnwrap(reset["url"] as? String))
        XCTAssertNotEqual(resetInfo.roomId, firstInfo.roomId)
        XCTAssertNotEqual(resetInfo.secret, firstInfo.secret)

        // The rotated pairing must be persisted for the next daemon start.
        XCTAssertEqual(home.loadPairing()?.roomId, resetInfo.roomId)
    }

    func testStatusShape() throws {
        let reply = try send(["cmd": "status"])
        XCTAssertEqual(reply["ok"] as? Bool, true)
        XCTAssertEqual(reply["relay"] as? String, "ws://127.0.0.1:1")
        XCTAssertEqual(reply["client"] as? String, "none")
        XCTAssertEqual((reply["room"] as? String)?.count, 32)
        XCTAssertNotNil(reply["uptime"])
        XCTAssertTrue(["connected", "connecting"].contains(reply["state"] as? String ?? ""))
    }

    func testUnknownAndMalformedCommands() throws {
        let unknown = try send(["cmd": "frobnicate"])
        XCTAssertEqual(unknown["ok"] as? Bool, false)

        let missingId = try send(["cmd": "kill"])
        XCTAssertEqual(missingId["ok"] as? Bool, false)
    }
}
