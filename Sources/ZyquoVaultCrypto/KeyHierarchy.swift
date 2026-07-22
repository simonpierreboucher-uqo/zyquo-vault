import CryptoKit
import Foundation

/// Key hierarchy operations (CLAUDE.md §5.4):
///
/// ```
/// master password + salt + Argon2id params → PKEK
///   PKEK —AEAD-unwrap→ VMK (random 256-bit, wrapped in the header)
///     VMK —HKDF→ purpose subkeys → per-record/attachment DEKs → payloads
/// ```
///
/// The PKEK exists only inside these functions' scopes; the VMK is random and never
/// password-derived; password verification IS the authenticated unwrap of the VMK.
public enum KeyHierarchy {

    /// A wrapped Vault Master Key as stored in the vault header.
    public struct WrappedVMK: Equatable, Sendable {
        public let kdfSalt: [UInt8]
        public let kdfParameters: Argon2id.Parameters
        public let sealed: SealedMessage

        public init(kdfSalt: [UInt8], kdfParameters: Argon2id.Parameters, sealed: SealedMessage) {
            self.kdfSalt = kdfSalt
            self.kdfParameters = kdfParameters
            self.sealed = sealed
        }
    }

    static func headerAAD(vaultID: UUID, formatVersion: UInt32) -> AssociatedData {
        // The wrapped VMK is bound to the vault UUID and format version; the object
        // UUID slot repeats the vault UUID (the header has no separate identity) and
        // revision 0 (the header wrap is replaced, not revised).
        AssociatedData(
            vaultID: vaultID,
            objectID: vaultID,
            objectType: .vaultHeaderVMK,
            schemaVersion: formatVersion,
            revision: 0
        )
    }

    /// Creates a fresh random 256-bit VMK and wraps it under the password-derived PKEK.
    /// Returns the wrapped form (for the header) and the live VMK (for the session).
    public static func createVMK(
        password: SecureBytes,
        vaultID: UUID,
        formatVersion: UInt32,
        parameters: Argon2id.Parameters,
        random: SecureRandomSource = SystemSecureRandom()
    ) throws -> (wrapped: WrappedVMK, vmk: SecureBytes) {
        let salt = try random.bytes(count: Argon2id.Floor.saltLength)
        let vmk = try random.secureBytes(count: 32)
        let wrapped = try wrap(
            vmk: vmk, password: password, salt: salt, parameters: parameters,
            vaultID: vaultID, formatVersion: formatVersion, random: random
        )
        return (wrapped, vmk)
    }

    /// Wraps an existing VMK under a (possibly new) password — used at creation and
    /// for password change (new salt, new PKEK, records untouched).
    public static func wrap(
        vmk: SecureBytes,
        password: SecureBytes,
        salt: [UInt8],
        parameters: Argon2id.Parameters,
        vaultID: UUID,
        formatVersion: UInt32,
        random: SecureRandomSource = SystemSecureRandom()
    ) throws -> WrappedVMK {
        let pkek = try Argon2id.deriveKey(password: password, salt: salt, parameters: parameters)
        defer { pkek.wipe() }
        let key = pkek.withUnsafeBytes { SymmetricKey(data: Data($0)) }
        let sealed = try AEADEngine(random: random).seal(
            plaintext: vmk.withUnsafeBytes { Data($0) },
            key: key,
            aad: headerAAD(vaultID: vaultID, formatVersion: formatVersion)
        )
        return WrappedVMK(kdfSalt: salt, kdfParameters: parameters, sealed: sealed)
    }

    /// Unwraps the VMK. A wrong password and a tampered header are indistinguishable
    /// here by design; both throw `.invalidPasswordOrCorruptedVault`.
    public static func unwrap(
        _ wrapped: WrappedVMK,
        password: SecureBytes,
        vaultID: UUID,
        formatVersion: UInt32
    ) throws -> SecureBytes {
        try wrapped.kdfParameters.validate()
        let pkek = try Argon2id.deriveKey(
            password: password, salt: wrapped.kdfSalt, parameters: wrapped.kdfParameters
        )
        defer { pkek.wipe() }
        let key = pkek.withUnsafeBytes { SymmetricKey(data: Data($0)) }
        do {
            let plaintext = try AEADEngine().open(
                wrapped.sealed, key: key,
                aad: headerAAD(vaultID: vaultID, formatVersion: formatVersion)
            )
            guard plaintext.count == 32 else { throw CryptoError.invalidPasswordOrCorruptedVault }
            return SecureBytes(bytes: Array(plaintext))
        } catch {
            throw CryptoError.invalidPasswordOrCorruptedVault
        }
    }
}
