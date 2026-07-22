import CryptoKit
import Foundation
import ZyquoVaultCrypto

/// M1-scope vault store: creates a vault directory with an authenticated header,
/// reopens it with the master password, and fails closed on tampering.
/// (Records, manifest, journal, and locking arrive with M2.)
public enum VaultStore {

    public static let headerFileName = "vault.header"

    /// Creates the vault directory (0700), generates a VMK, wraps it under the
    /// password-derived PKEK, seals and writes the header atomically, then
    /// **verifies by actually reopening** (CLAUDE.md §10.1). Returns the vault UUID.
    @discardableResult
    public static func createVault(
        at directory: URL,
        password: SecureBytes,
        parameters: Argon2id.Parameters = .baseline,
        random: SecureRandomSource = SystemSecureRandom(),
        now: @Sendable () -> UInt64 = { UInt64(Date().timeIntervalSince1970) }
    ) throws -> UUID {
        let (header, vmk) = try createVaultKeepingKeys(
            at: directory, password: password, parameters: parameters,
            random: random, now: now
        )
        vmk.wipe()
        return header.vaultID
    }

    /// Creation core that hands the live VMK back to the caller (used by
    /// `VaultRepository.create` to write the initial manifest without a second
    /// KDF run). Caller owns the VMK and must `wipe()` it.
    static func createVaultKeepingKeys(
        at directory: URL,
        password: SecureBytes,
        recoveryKey: RecoveryKey? = nil,
        parameters: Argon2id.Parameters = .baseline,
        random: SecureRandomSource = SystemSecureRandom(),
        now: @Sendable () -> UInt64 = { UInt64(Date().timeIntervalSince1970) }
    ) throws -> (header: VaultHeader, vmk: SecureBytes) {
        let fm = FileManager.default
        try fm.createDirectory(
            at: directory, withIntermediateDirectories: true,
            attributes: [.posixPermissions: 0o700]
        )

        let vaultID = UUID()
        let (wrapped, vmk) = try KeyHierarchy.createVMK(
            password: password,
            vaultID: vaultID,
            formatVersion: VaultHeader.currentFormatVersion,
            parameters: parameters,
            random: random
        )

        let timestamp = now()
        var header = VaultHeader(
            vaultID: vaultID, createdAt: timestamp, updatedAt: timestamp, wrappedVMK: wrapped
        )
        if let recoveryKey {
            do {
                header.recoveryWrap = try KeyHierarchy.wrapWithRecoveryKey(
                    vmk: vmk, recoveryKey: recoveryKey,
                    vaultID: vaultID, formatVersion: VaultHeader.currentFormatVersion,
                    random: random
                )
            } catch {
                vmk.wipe()
                throw error
            }
        }
        header.headerAuthTag = headerAuthTag(for: header, vmk: vmk)
        do {
            try AtomicFileWriter.write(try header.encoded(), to: directory.appendingPathComponent(headerFileName))

            // Creation is not done until the vault provably reopens with this password.
            let reopened = try openVault(at: directory, password: password)
            reopened.vmk.wipe()
            guard reopened.header.vaultID == vaultID else {
                throw StorageError.invalidHeader(reason: "verification reopen mismatch")
            }
        } catch {
            vmk.wipe()
            throw error
        }
        return (header, vmk)
    }

    /// Opens a vault: parses + validates the header, unwraps the VMK (this IS the
    /// password check), then verifies the header-auth HMAC over all remaining
    /// fields. Caller owns the returned VMK and must `wipe()` it on lock.
    public static func openVault(
        at directory: URL,
        password: SecureBytes
    ) throws -> (header: VaultHeader, vmk: SecureBytes) {
        let url = directory.appendingPathComponent(headerFileName)
        guard FileManager.default.fileExists(atPath: url.path) else {
            throw StorageError.vaultNotFound
        }
        let header = try VaultHeader.decode(try Data(contentsOf: url))
        let vmk = try KeyHierarchy.unwrap(
            header.wrappedVMK,
            password: password,
            vaultID: header.vaultID,
            formatVersion: header.formatVersion
        )
        let expected = headerAuthTag(for: header, vmk: vmk)
        let matches = header.headerAuthTag.withUnsafeBytes { a in
            expected.withUnsafeBytes { b in constantTimeEquals(a, b) }
        }
        guard matches else {
            vmk.wipe()
            // Unauthenticated field tampered with (timestamps/flags): fail closed.
            throw CryptoError.invalidPasswordOrCorruptedVault
        }
        return (header, vmk)
    }

    /// Opens a vault with the user-held recovery key instead of the password
    /// (§7.1). Same fail-closed semantics as the password path.
    public static func openVaultWithRecoveryKey(
        at directory: URL,
        recoveryKey: RecoveryKey
    ) throws -> (header: VaultHeader, vmk: SecureBytes) {
        let url = directory.appendingPathComponent(headerFileName)
        guard FileManager.default.fileExists(atPath: url.path) else {
            throw StorageError.vaultNotFound
        }
        let header = try VaultHeader.decode(try Data(contentsOf: url))
        guard let wrap = header.recoveryWrap else {
            throw StorageError.invalidHeader(reason: "this vault has no recovery key")
        }
        let vmk = try KeyHierarchy.unwrapWithRecoveryKey(
            wrap, recoveryKey: recoveryKey,
            vaultID: header.vaultID, formatVersion: header.formatVersion
        )
        let expected = headerAuthTag(for: header, vmk: vmk)
        let matches = header.headerAuthTag.withUnsafeBytes { a in
            expected.withUnsafeBytes { b in constantTimeEquals(a, b) }
        }
        guard matches else {
            vmk.wipe()
            throw CryptoError.invalidPasswordOrCorruptedVault
        }
        return (header, vmk)
    }

    /// HMAC-SHA256 over the header body, keyed by the HKDF `header-auth` subkey.
    static func headerAuthTag(for header: VaultHeader, vmk: SecureBytes) -> Data {
        let key = KeyDerivation.subkey(vmk: vmk, vaultID: header.vaultID, context: .headerAuth)
        let mac = HMAC<SHA256>.authenticationCode(for: header.encodedBody(), using: key)
        return Data(mac)
    }
}
