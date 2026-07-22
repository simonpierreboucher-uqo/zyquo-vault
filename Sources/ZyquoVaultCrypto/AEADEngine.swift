import CryptoKit
import Foundation

/// A sealed AEAD message: nonce ‖ ciphertext ‖ tag, plus the algorithm that made it.
public struct SealedMessage: Equatable, Sendable {
    public static let nonceLength = 12
    public static let tagLength = 16

    public let algorithm: AEADAlgorithm
    public let nonce: Data       // 12 bytes
    public let ciphertext: Data
    public let tag: Data         // 16 bytes

    public init(algorithm: AEADAlgorithm, nonce: Data, ciphertext: Data, tag: Data) {
        self.algorithm = algorithm
        self.nonce = nonce
        self.ciphertext = ciphertext
        self.tag = tag
    }

    /// Canonical wire form: nonce ‖ ciphertext ‖ tag.
    public var combined: Data { nonce + ciphertext + tag }

    /// Parses the wire form; rejects anything shorter than nonce + tag.
    public init(algorithm: AEADAlgorithm, combined: Data) throws {
        guard combined.count >= Self.nonceLength + Self.tagLength else {
            throw CryptoError.malformedCiphertext
        }
        let d = Data(combined) // rebase indices
        self.algorithm = algorithm
        self.nonce = d.prefix(Self.nonceLength)
        self.ciphertext = d.dropFirst(Self.nonceLength).dropLast(Self.tagLength)
        self.tag = d.suffix(Self.tagLength)
    }
}

/// The one canonical AEAD for format v1: AES-256-GCM via CryptoKit
/// (hardware-accelerated on Apple Silicon — ADR-0003).
///
/// Rules enforced here:
/// - Every seal draws a fresh 12-byte nonce from the injected CSPRNG. Nonces are
///   never derived from counters or timestamps.
/// - Keys must be exactly 256 bits.
/// - Associated data always uses the canonical `AssociatedData` encoding.
/// - Any authentication failure throws `CryptoError.authenticationFailed` and no
///   partial plaintext is ever returned (CryptoKit verifies the tag before
///   releasing plaintext).
public struct AEADEngine: Sendable {
    private let random: SecureRandomSource

    public init(random: SecureRandomSource = SystemSecureRandom()) {
        self.random = random
    }

    /// Encrypts `plaintext` bound to `aad`. Key lifetime: caller-owned; this function
    /// keeps no copy beyond the call.
    public func seal(plaintext: Data, key: SymmetricKey, aad: AssociatedData) throws -> SealedMessage {
        guard key.bitCount == 256 else {
            throw CryptoError.invalidKeyLength(expected: 32, actual: key.bitCount / 8)
        }
        let nonceBytes = try random.bytes(count: SealedMessage.nonceLength)
        let nonce = try AES.GCM.Nonce(data: Data(nonceBytes))
        let box = try AES.GCM.seal(plaintext, using: key, nonce: nonce, authenticating: aad.encoded())
        return SealedMessage(
            algorithm: .aes256gcm,
            nonce: Data(nonceBytes),
            ciphertext: box.ciphertext,
            tag: box.tag
        )
    }

    /// Decrypts and authenticates. Fails closed: one opaque error for any mismatch
    /// of tag, AAD, nonce, or key.
    public func open(_ message: SealedMessage, key: SymmetricKey, aad: AssociatedData) throws -> Data {
        guard message.algorithm == .aes256gcm else {
            throw CryptoError.unsupportedAlgorithm(identifier: message.algorithm.rawValue)
        }
        guard key.bitCount == 256 else {
            throw CryptoError.invalidKeyLength(expected: 32, actual: key.bitCount / 8)
        }
        guard message.nonce.count == SealedMessage.nonceLength else {
            throw CryptoError.invalidNonce
        }
        do {
            let nonce = try AES.GCM.Nonce(data: message.nonce)
            let box = try AES.GCM.SealedBox(nonce: nonce, ciphertext: message.ciphertext, tag: message.tag)
            return try AES.GCM.open(box, using: key, authenticating: aad.encoded())
        } catch let error as CryptoError {
            throw error
        } catch {
            throw CryptoError.authenticationFailed
        }
    }
}
