import CryptoKit
import XCTest
@testable import PedalsKit

/// Cross-implementation test vectors, shared verbatim with the Node reference
/// implementation (relay/test/crypto-ref.mjs). Canonical copy with derivations:
/// shared/PedalsKit/TESTVECTORS.md.
///
///   secret     = 32 bytes of 0x42
///   key_h2c    = HKDF-SHA256(ikm=secret, salt="pedals-v1", info="host->client", 32)
///              = f5f1ae11b574be72b8afa4068d3509bf2d8f8d469d1ed16651d41406f923e641
///   key_c2h    = HKDF-SHA256(ikm=secret, salt="pedals-v1", info="client->host", 32)
///              = d4f715a850ee4d287fd5aba0d5dad7145fe93a9a4f22223a49bfa91b285ac333
///
/// Sealed-message vector (direction host->client, key_h2c):
///   plaintext  = ctl frame: type 0x00 || sessionId 0 (u32 LE) || "hello"
///              = 000000000068656c6c6f
///   seq        = 1, AAD = 0100000000000000 (u64 LE)
///   nonce      = "pedals-nonce" = 706564616c732d6e6f6e6365
///                (nonces are random on the wire; this one was fixed once at vector
///                 generation time so both implementations can assert exact bytes)
///   message    = seq || nonce || ciphertext || tag
///              = 0100000000000000706564616c732d6e6f6e63658b58f5073d8b010d
///                65505138d2966bdeed53ba46abe5967cb475
final class TestVectorTests: XCTestCase {
    private let secret = Data(repeating: 0x42, count: 32)

    private func hex(_ key: SymmetricKey) -> String {
        key.withUnsafeBytes { Data($0).map { String(format: "%02x", $0) }.joined() }
    }

    func testHKDFHostToClientVector() {
        XCTAssertEqual(
            hex(KeyDerivation.hostToClientKey(secret: secret)),
            "f5f1ae11b574be72b8afa4068d3509bf2d8f8d469d1ed16651d41406f923e641"
        )
    }

    func testHKDFClientToHostVector() {
        XCTAssertEqual(
            hex(KeyDerivation.clientToHostKey(secret: secret)),
            "d4f715a850ee4d287fd5aba0d5dad7145fe93a9a4f22223a49bfa91b285ac333"
        )
    }

    func testSealedMessageVectorDecrypts() throws {
        let message = Data(hexString:
            "0100000000000000" // seq = 1, u64 LE
            + "706564616c732d6e6f6e6365" // nonce "pedals-nonce"
            + "8b58f5073d8b010d6550" // ciphertext (10 bytes)
            + "5138d2966bdeed53ba46abe5967cb475" // Poly1305 tag (16 bytes)
        )!
        var client = SecureChannel(secret: secret, role: .client)
        let plaintext = try client.open(message)
        XCTAssertEqual(plaintext, Data(hexString: "000000000068656c6c6f")!)

        let frame = try Frame.decode(plaintext)
        XCTAssertEqual(frame.type, .ctl)
        XCTAssertEqual(frame.sessionId, 0)
        XCTAssertEqual(String(decoding: frame.payload, as: UTF8.self), "hello")
    }

    func testSealedMessageVectorRejectsReplay() throws {
        let message = Data(hexString:
            "0100000000000000706564616c732d6e6f6e63658b58f5073d8b010d"
            + "65505138d2966bdeed53ba46abe5967cb475"
        )!
        var client = SecureChannel(secret: secret, role: .client)
        _ = try client.open(message)
        XCTAssertThrowsError(try client.open(message)) { error in
            XCTAssertEqual(
                error as? SecureChannel.ChannelError,
                .staleSequence(received: 1, lastAccepted: 1)
            )
        }
    }

    /// The vector's host->client blob must not open with the client->host key.
    func testSealedMessageVectorDirectionality() {
        let message = Data(hexString:
            "0100000000000000706564616c732d6e6f6e63658b58f5073d8b010d"
            + "65505138d2966bdeed53ba46abe5967cb475"
        )!
        var host = SecureChannel(secret: secret, role: .host)
        XCTAssertThrowsError(try host.open(message)) { error in
            XCTAssertEqual(error as? SecureChannel.ChannelError, .decryptionFailed)
        }
    }
}

extension Data {
    init?(hexString: String) {
        guard hexString.count.isMultiple(of: 2) else { return nil }
        var data = Data(capacity: hexString.count / 2)
        var index = hexString.startIndex
        while index < hexString.endIndex {
            let next = hexString.index(index, offsetBy: 2)
            guard let byte = UInt8(hexString[index..<next], radix: 16) else { return nil }
            data.append(byte)
            index = next
        }
        self = data
    }
}
