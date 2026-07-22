import CryptoKit
import Foundation

/// The optional user-held recovery key (CLAUDE.md §7.1): 32 CSPRNG bytes the user
/// sees exactly once, formatted as 13 groups of 4 Crockford-base32 characters
/// (`ZQRK-XXXX-…`). Zyquo never stores it — only a second AEAD wrap of the VMK
/// under a KEK derived from it lives in the header.
public struct RecoveryKey: Sendable {
    public static let byteCount = 32
    /// Crockford base32: no I, L, O, U — unambiguous to read from paper.
    static let alphabet = Array("0123456789ABCDEFGHJKMNPQRSTVWXYZ")
    static let prefix = "ZQRK"

    /// The raw 256-bit key. Wiped by the owner after the ceremony.
    public let bytes: SecureBytes

    public init(bytes: SecureBytes) {
        self.bytes = bytes
    }

    public static func generate(random: SecureRandomSource = SystemSecureRandom()) throws -> RecoveryKey {
        RecoveryKey(bytes: try random.secureBytes(count: byteCount))
    }

    /// Display form, e.g. `ZQRK-4Q7M-…` (prefix + 13 groups). Compute only for
    /// the one-time ceremony sheet; the returned string is sensitive.
    public func displayString() -> String {
        let raw = bytes.copyBytes()
        var bits = 0, buffer = 0
        var encoded: [Character] = []
        for byte in raw {
            buffer = (buffer << 8) | Int(byte)
            bits += 8
            while bits >= 5 {
                bits -= 5
                encoded.append(Self.alphabet[(buffer >> bits) & 0x1F])
            }
        }
        if bits > 0 { encoded.append(Self.alphabet[(buffer << (5 - bits)) & 0x1F]) }
        let groups = stride(from: 0, to: encoded.count, by: 4).map {
            String(encoded[$0..<min($0 + 4, encoded.count)])
        }
        return ([Self.prefix] + groups).joined(separator: "-")
    }

    /// Parses user input: case-insensitive, separator/whitespace tolerant, and
    /// forgiving of the classic O→0, I/L→1 misreadings.
    public static func parse(_ input: String) throws -> RecoveryKey {
        var normalized = input.uppercased()
            .replacingOccurrences(of: "O", with: "0")
            .replacingOccurrences(of: "I", with: "1")
            .replacingOccurrences(of: "L", with: "1")
            .filter { !"- \t\n".contains($0) }
        if normalized.hasPrefix(prefix) { normalized.removeFirst(prefix.count) }

        var buffer = 0, bits = 0
        var raw: [UInt8] = []
        for char in normalized {
            guard let value = alphabet.firstIndex(of: char) else {
                throw CryptoError.invalidParameter(reason: "recovery key contains an invalid character")
            }
            buffer = (buffer << 5) | value
            bits += 5
            if bits >= 8 {
                bits -= 8
                raw.append(UInt8((buffer >> bits) & 0xFF))
            }
        }
        guard raw.count == byteCount else {
            throw CryptoError.invalidParameter(reason: "recovery key has the wrong length")
        }
        return RecoveryKey(bytes: SecureBytes(bytes: raw))
    }

    /// Derives the recovery KEK. The recovery key is already high-entropy, so
    /// HKDF (not a memory-hard KDF) is appropriate; the salt binds it per vault.
    public func deriveKEK(salt: [UInt8]) -> SymmetricKey {
        let ikm = bytes.withUnsafeBytes { SymmetricKey(data: Data($0)) }
        return HKDF<SHA256>.deriveKey(
            inputKeyMaterial: ikm,
            salt: Data(salt),
            info: Data("zyquo-vault/v1/recovery-kek".utf8),
            outputByteCount: 32
        )
    }
}

extension KeyHierarchy {

    static func recoveryAAD(vaultID: UUID, formatVersion: UInt32) -> AssociatedData {
        AssociatedData(
            vaultID: vaultID, objectID: vaultID, objectType: .recoveryVMK,
            schemaVersion: formatVersion, revision: 0
        )
    }

    /// A second, independent wrap of the VMK under the recovery KEK.
    public struct RecoveryWrap: Equatable, Sendable {
        public let salt: [UInt8]
        public let sealed: SealedMessage

        public init(salt: [UInt8], sealed: SealedMessage) {
            self.salt = salt
            self.sealed = sealed
        }
    }

    public static func wrapWithRecoveryKey(
        vmk: SecureBytes,
        recoveryKey: RecoveryKey,
        vaultID: UUID,
        formatVersion: UInt32,
        random: SecureRandomSource = SystemSecureRandom()
    ) throws -> RecoveryWrap {
        let salt = try random.bytes(count: 16)
        let kek = recoveryKey.deriveKEK(salt: salt)
        let sealed = try AEADEngine(random: random).seal(
            plaintext: vmk.withUnsafeBytes { Data($0) },
            key: kek,
            aad: recoveryAAD(vaultID: vaultID, formatVersion: formatVersion)
        )
        return RecoveryWrap(salt: salt, sealed: sealed)
    }

    /// Unwraps via the recovery key. Wrong key ≡ corruption, as with passwords.
    public static func unwrapWithRecoveryKey(
        _ wrap: RecoveryWrap,
        recoveryKey: RecoveryKey,
        vaultID: UUID,
        formatVersion: UInt32
    ) throws -> SecureBytes {
        let kek = recoveryKey.deriveKEK(salt: wrap.salt)
        do {
            let plaintext = try AEADEngine().open(
                wrap.sealed, key: kek,
                aad: recoveryAAD(vaultID: vaultID, formatVersion: formatVersion)
            )
            guard plaintext.count == 32 else { throw CryptoError.invalidPasswordOrCorruptedVault }
            return SecureBytes(bytes: Array(plaintext))
        } catch {
            throw CryptoError.invalidPasswordOrCorruptedVault
        }
    }
}
