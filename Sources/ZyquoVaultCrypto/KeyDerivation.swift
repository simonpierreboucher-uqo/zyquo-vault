import CryptoKit
import Foundation

/// Domain-separated HKDF-SHA256 contexts (CLAUDE.md §5.4). Every subkey purpose has
/// a unique, versioned info string; a subkey is never reused across purposes.
public enum KeyContext: String, CaseIterable, Sendable {
    case recordWrapping = "zyquo-vault/v1/record-wrapping"
    case attachmentWrapping = "zyquo-vault/v1/attachment-wrapping"
    case manifestProtection = "zyquo-vault/v1/manifest-protection"
    case backupProtection = "zyquo-vault/v1/backup-protection"
    case searchSession = "zyquo-vault/v1/search-session"
    case headerAuth = "zyquo-vault/v1/header-auth"

    var info: Data { Data(rawValue.utf8) }
}

/// HKDF-SHA256 subkey derivation from the Vault Master Key.
public enum KeyDerivation {

    /// Derives a 256-bit subkey for `context` from the VMK.
    /// Salt is the vault UUID bytes — public, but binds subkeys to one vault.
    public static func subkey(vmk: SecureBytes, vaultID: UUID, context: KeyContext) -> SymmetricKey {
        let ikm = vmk.withUnsafeBytes { SymmetricKey(data: Data($0)) }
        var salt = Data(count: 16)
        withUnsafeBytes(of: vaultID.uuid) { salt = Data($0) }
        return HKDF<SHA256>.deriveKey(
            inputKeyMaterial: ikm,
            salt: salt,
            info: context.info,
            outputByteCount: 32
        )
    }
}
