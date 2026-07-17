import XCTest
@testable import PedalsKit

final class PairingInfoTests: XCTestCase {
    private let roomId = "0123456789abcdef0123456789abcdef"
    private let secret = Data(repeating: 0x42, count: 32)

    func testBuildURLMatchesSpecShape() throws {
        let info = try PairingInfo(
            relay: URL(string: "wss://relay.example.com")!,
            roomId: roomId,
            secret: secret
        )
        XCTAssertEqual(
            info.url.absoluteString,
            "pedals://pair?v=1&relay=wss%3A%2F%2Frelay.example.com"
                + "&room=0123456789abcdef0123456789abcdef"
                + "&s=QkJCQkJCQkJCQkJCQkJCQkJCQkJCQkJCQkJCQkJCQkI"
        )
    }

    func testURLRoundTrip() throws {
        let info = try PairingInfo(
            relay: URL(string: "wss://pedals-relay-abc123-an.a.run.app")!,
            roomId: roomId,
            secret: secret
        )
        XCTAssertEqual(try PairingInfo(url: info.url), info)
    }

    func testGenerateRoundTripsAndIsValid() throws {
        let info = try PairingInfo.generate(relay: URL(string: "ws://localhost:8787")!)
        XCTAssertEqual(info.roomId.count, 32)
        XCTAssertTrue(info.roomId.allSatisfy(\.isHexDigit))
        XCTAssertEqual(info.secret.count, 32)
        XCTAssertEqual(try PairingInfo(url: info.url), info)
        // Two generations must not collide.
        let other = try PairingInfo.generate(relay: URL(string: "ws://localhost:8787")!)
        XCTAssertNotEqual(info.roomId, other.roomId)
        XCTAssertNotEqual(info.secret, other.secret)
    }

    func testParseAcceptsPaddedBase64url() throws {
        let url = "pedals://pair?v=1&relay=wss%3A%2F%2Fr.example&room=\(roomId)"
            + "&s=QkJCQkJCQkJCQkJCQkJCQkJCQkJCQkJCQkJCQkJCQkI="
        XCTAssertEqual(try PairingInfo(urlString: url).secret, secret)
    }

    func testParseRejectsWrongScheme() {
        XCTAssertThrowsError(try PairingInfo(urlString: "https://pair?v=1")) { error in
            XCTAssertEqual(error as? PairingInfo.ParseError, .invalidURL)
        }
    }

    func testParseRejectsWrongVersion() {
        let url = "pedals://pair?v=2&relay=wss%3A%2F%2Fr.example&room=\(roomId)"
            + "&s=\(secret.base64URLEncodedString())"
        XCTAssertThrowsError(try PairingInfo(urlString: url)) { error in
            XCTAssertEqual(error as? PairingInfo.ParseError, .unsupportedVersion("2"))
        }
    }

    func testParseRejectsMissingParameters() throws {
        let full = try PairingInfo(
            relay: URL(string: "wss://r.example")!, roomId: roomId, secret: secret
        ).url.absoluteString
        for param in ["v", "relay", "room", "s"] {
            let stripped = full
                .replacingOccurrences(
                    of: #"[&?]\#(param)=[^&]*"#,
                    with: "?",
                    options: .regularExpression
                )
            XCTAssertThrowsError(try PairingInfo(urlString: stripped), "missing \(param) accepted")
        }
    }

    func testParseRejectsBadRoomId() {
        for room in ["short", "0123456789abcdef0123456789abcdeg",
                     "0123456789abcdef0123456789abcdef00"] {
            let url = "pedals://pair?v=1&relay=wss%3A%2F%2Fr.example&room=\(room)"
                + "&s=\(secret.base64URLEncodedString())"
            XCTAssertThrowsError(try PairingInfo(urlString: url)) { error in
                XCTAssertEqual(error as? PairingInfo.ParseError, .invalidRoomId(room))
            }
        }
    }

    func testParseRejectsBadSecret() {
        // 31 bytes instead of 32
        let short = Data(repeating: 0x42, count: 31).base64URLEncodedString()
        let url = "pedals://pair?v=1&relay=wss%3A%2F%2Fr.example&room=\(roomId)&s=\(short)"
        XCTAssertThrowsError(try PairingInfo(urlString: url)) { error in
            XCTAssertEqual(error as? PairingInfo.ParseError, .invalidSecret)
        }
    }

    func testParseRejectsNonWebSocketRelay() {
        let url = "pedals://pair?v=1&relay=https%3A%2F%2Fr.example&room=\(roomId)"
            + "&s=\(secret.base64URLEncodedString())"
        XCTAssertThrowsError(try PairingInfo(urlString: url)) { error in
            XCTAssertEqual(error as? PairingInfo.ParseError, .invalidRelay("https://r.example"))
        }
    }

    func testRoomIdNormalizedToLowercase() throws {
        let info = try PairingInfo(
            relay: URL(string: "wss://r.example")!,
            roomId: "0123456789ABCDEF0123456789ABCDEF",
            secret: secret
        )
        XCTAssertEqual(info.roomId, roomId)
    }
}
