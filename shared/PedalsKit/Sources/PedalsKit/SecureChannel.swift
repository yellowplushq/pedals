import CryptoKit
import Foundation

/// Seals/opens full WebSocket binary messages per PROTOCOL.md §3:
///
///     message = seq (u64 LE) || ChaChaPoly.seal(plaintextFrame,
///                                               key=direction key, aad=seq bytes).combined
///
/// `combined` = nonce(12) || ciphertext || tag(16). `seq` starts at 1 per direction per
/// connection and is strictly increasing; the receiver drops non-increasing seq (replay
/// protection). Create a fresh SecureChannel for every WebSocket connection.
public struct SecureChannel: Sendable {
    public enum ChannelError: Error, Equatable {
        case malformedMessage
        /// seq was not strictly greater than the last accepted seq (replay / reorder).
        case staleSequence(received: UInt64, lastAccepted: UInt64)
        case decryptionFailed
    }

    private let sendKey: SymmetricKey
    private let receiveKey: SymmetricKey
    private var sendSeq: UInt64 = 0
    private var lastReceivedSeq: UInt64 = 0

    /// minimum message length: seq(8) + nonce(12) + tag(16); empty plaintext is legal.
    private static let minimumMessageLength = 8 + 12 + 16

    /// Derives both direction keys from the pairing secret for the given local role.
    public init(secret: Data, role: PeerRole) {
        let h2c = KeyDerivation.hostToClientKey(secret: secret)
        let c2h = KeyDerivation.clientToHostKey(secret: secret)
        switch role {
        case .host:
            sendKey = h2c
            receiveKey = c2h
        case .client:
            sendKey = c2h
            receiveKey = h2c
        }
    }

    /// seq assigned to the next sealed message.
    public var nextSendSeq: UInt64 { sendSeq + 1 }

    /// Encrypts a plaintext frame into a full WebSocket message.
    public mutating func seal(_ plaintext: Data) throws -> Data {
        let seq = sendSeq + 1
        var seqBytes = Data(capacity: 8)
        seqBytes.appendUInt64LE(seq)
        let box = try ChaChaPoly.seal(plaintext, using: sendKey, authenticating: seqBytes)
        sendSeq = seq
        var message = seqBytes
        message.append(box.combined)
        return message
    }

    public mutating func seal(_ frame: Frame) throws -> Data {
        try seal(frame.encoded())
    }

    /// Decrypts a full WebSocket message, enforcing strictly increasing seq.
    /// Per spec, `.decryptionFailed` means the caller must close the connection.
    public mutating func open(_ message: Data) throws -> Data {
        let (seq, plaintext) = try decrypt(message)
        guard seq > lastReceivedSeq else {
            throw ChannelError.staleSequence(received: seq, lastAccepted: lastReceivedSeq)
        }
        lastReceivedSeq = seq
        return plaintext
    }

    /// Decrypts without enforcing seq monotonicity and without advancing the
    /// receive counter. After `.staleSequence`, callers use this to check for a
    /// peer `hello` announcing a fresh connection whose seq restarted at 1
    /// (PROTOCOL.md §3), then accept it via `resetReceiveSequence(to:)`.
    public func openIgnoringSequence(_ message: Data) throws -> (seq: UInt64, plaintext: Data) {
        try decrypt(message)
    }

    /// Accepts a peer that restarted its send sequence on a fresh connection:
    /// subsequent messages must be strictly greater than `seq`.
    public mutating func resetReceiveSequence(to seq: UInt64) {
        lastReceivedSeq = seq
    }

    private func decrypt(_ message: Data) throws -> (seq: UInt64, plaintext: Data) {
        guard message.count >= Self.minimumMessageLength else {
            throw ChannelError.malformedMessage
        }
        let start = message.startIndex
        let seq = message.uint64LE(at: start)
        let seqBytes = Data(message[start..<(start + 8)])
        do {
            let box = try ChaChaPoly.SealedBox(combined: message[(start + 8)...])
            return (seq, try ChaChaPoly.open(box, using: receiveKey, authenticating: seqBytes))
        } catch {
            throw ChannelError.decryptionFailed
        }
    }

    /// Decrypts and decodes a plaintext frame in one step.
    public mutating func openFrame(_ message: Data) throws -> Frame {
        try Frame.decode(try open(message))
    }
}
