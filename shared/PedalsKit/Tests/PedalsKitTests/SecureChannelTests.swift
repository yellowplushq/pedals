import XCTest
@testable import PedalsKit

final class SecureChannelTests: XCTestCase {
    private let secret = Data(repeating: 0x42, count: 32)

    private func pair() -> (host: SecureChannel, client: SecureChannel) {
        (SecureChannel(secret: secret, role: .host),
         SecureChannel(secret: secret, role: .client))
    }

    func testSealOpenRoundTripBothDirections() throws {
        var (host, client) = pair()
        let h2c = Data("host says hi".utf8)
        let c2h = Data("client says hi".utf8)
        XCTAssertEqual(try client.open(try host.seal(h2c)), h2c)
        XCTAssertEqual(try host.open(try client.seal(c2h)), c2h)
    }

    func testFrameConvenienceRoundTrip() throws {
        var (host, client) = pair()
        let frame = try Frame.control(.hello(who: .host, connEpoch: 123, ver: 1))
        XCTAssertEqual(try client.openFrame(try host.seal(frame)), frame)
    }

    func testSeqStartsAtOneAndIncrements() throws {
        var (host, _) = pair()
        XCTAssertEqual(host.nextSendSeq, 1)
        for expected in UInt64(1)...3 {
            let message = try host.seal(Data("x".utf8))
            XCTAssertEqual(message.uint64LE(at: message.startIndex), expected)
        }
    }

    func testReplayIsRejected() throws {
        var (host, client) = pair()
        let message = try host.seal(Data("once".utf8))
        _ = try client.open(message)
        XCTAssertThrowsError(try client.open(message)) { error in
            XCTAssertEqual(
                error as? SecureChannel.ChannelError,
                .staleSequence(received: 1, lastAccepted: 1)
            )
        }
    }

    func testOutOfOrderSeqIsRejected() throws {
        var (host, client) = pair()
        let first = try host.seal(Data("1".utf8))
        let second = try host.seal(Data("2".utf8))
        _ = try client.open(second)
        XCTAssertThrowsError(try client.open(first)) { error in
            XCTAssertEqual(
                error as? SecureChannel.ChannelError,
                .staleSequence(received: 1, lastAccepted: 2)
            )
        }
    }

    func testSeqGapsAreAccepted() throws {
        // Relay drops messages when the peer is absent, so gaps are legal.
        var (host, client) = pair()
        _ = try host.seal(Data("dropped".utf8))
        let message = try host.seal(Data("arrives".utf8))
        XCTAssertEqual(try client.open(message), Data("arrives".utf8))
    }

    func testFailedDecryptDoesNotAdvanceReceiveSeq() throws {
        var (host, client) = pair()
        var tampered = try host.seal(Data("payload".utf8))
        tampered[tampered.count - 1] ^= 0xFF
        XCTAssertThrowsError(try client.open(tampered)) { error in
            XCTAssertEqual(error as? SecureChannel.ChannelError, .decryptionFailed)
        }
        // A clean retransmit of seq 1 must still be acceptable.
        var freshHost = SecureChannel(secret: secret, role: .host)
        XCTAssertEqual(try client.open(try freshHost.seal(Data("payload".utf8))), Data("payload".utf8))
    }

    func testTamperedSeqFailsAuthentication() throws {
        var (host, client) = pair()
        var message = try host.seal(Data("payload".utf8))
        // Bump seq (AAD) without re-sealing: passes the monotonic check, fails the tag.
        message[message.startIndex] = 2
        XCTAssertThrowsError(try client.open(message)) { error in
            XCTAssertEqual(error as? SecureChannel.ChannelError, .decryptionFailed)
        }
    }

    func testWrongDirectionKeyFailsDecryption() throws {
        var (host, _) = pair()
        var otherHost = SecureChannel(secret: secret, role: .host)
        let message = try host.seal(Data("payload".utf8))
        // A host must not be able to open host->client traffic.
        XCTAssertThrowsError(try otherHost.open(message)) { error in
            XCTAssertEqual(error as? SecureChannel.ChannelError, .decryptionFailed)
        }
    }

    func testTooShortMessageIsMalformed() {
        var (_, client) = pair()
        XCTAssertThrowsError(try client.open(Data(count: 35))) { error in
            XCTAssertEqual(error as? SecureChannel.ChannelError, .malformedMessage)
        }
    }

    func testFreshPeerConnectionAcceptedViaSequenceReset() throws {
        // A replaced peer connection restarts its seq at 1 (spec §3). The
        // receiver inspects the stale message and, once it proves to be a
        // fresh hello, resets the receive counter and resumes normally.
        var (host, client) = pair()
        for text in ["hello", "create", "stdin"] {
            _ = try host.open(try client.seal(Data(text.utf8)))
        }

        var freshClient = SecureChannel(secret: secret, role: .client)
        let hello = try freshClient.seal(Data("hello again".utf8))
        XCTAssertThrowsError(try host.open(hello)) { error in
            XCTAssertEqual(
                error as? SecureChannel.ChannelError,
                .staleSequence(received: 1, lastAccepted: 3)
            )
        }

        let (seq, plaintext) = try host.openIgnoringSequence(hello)
        XCTAssertEqual(seq, 1)
        XCTAssertEqual(plaintext, Data("hello again".utf8))
        host.resetReceiveSequence(to: seq)
        // Replay of the same seq is still rejected; the next seq flows.
        XCTAssertThrowsError(try host.open(hello))
        XCTAssertEqual(try host.open(try freshClient.seal(Data("next".utf8))), Data("next".utf8))
    }

    func testOpenIgnoringSequenceDoesNotAdvanceReceiveSeq() throws {
        var (host, client) = pair()
        let first = try client.seal(Data("1".utf8))
        _ = try host.openIgnoringSequence(first)
        XCTAssertEqual(try host.open(first), Data("1".utf8))
    }

    func testEmptyPlaintextRoundTrips() throws {
        var (host, client) = pair()
        let message = try host.seal(Data())
        XCTAssertEqual(message.count, 8 + 12 + 16)
        XCTAssertEqual(try client.open(message), Data())
    }
}
