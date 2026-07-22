import Foundation
import Testing
@testable import ZyquoVaultCrypto

@Suite("Key hierarchy — VMK wrapping", .serialized)
struct KeyHierarchyTests {

    static let params = Argon2id.Parameters(
        memoryKiB: Argon2id.Floor.memoryKiB,
        iterations: Argon2id.Floor.iterations,
        parallelism: 4
    )
    static let vaultID = UUID()
    static let formatVersion: UInt32 = 1

    @Test func createWrapUnwrapRoundTrip() throws {
        let password = SecureBytes(utf8: "example-master-password-not-real")
        let (wrapped, vmk) = try KeyHierarchy.createVMK(
            password: password, vaultID: Self.vaultID,
            formatVersion: Self.formatVersion, parameters: Self.params
        )
        #expect(vmk.count == 32)

        let unwrapped = try KeyHierarchy.unwrap(
            wrapped, password: password,
            vaultID: Self.vaultID, formatVersion: Self.formatVersion
        )
        #expect(unwrapped == vmk)
    }

    @Test func wrongPasswordRejected() throws {
        let password = SecureBytes(utf8: "example-master-password-not-real")
        let (wrapped, _) = try KeyHierarchy.createVMK(
            password: password, vaultID: Self.vaultID,
            formatVersion: Self.formatVersion, parameters: Self.params
        )
        #expect(throws: CryptoError.invalidPasswordOrCorruptedVault) {
            _ = try KeyHierarchy.unwrap(
                wrapped, password: SecureBytes(utf8: "example-master-password-not-reaL"),
                vaultID: Self.vaultID, formatVersion: Self.formatVersion
            )
        }
    }

    @Test func headerBindingRejected() throws {
        let password = SecureBytes(utf8: "example-master-password-not-real")
        let (wrapped, _) = try KeyHierarchy.createVMK(
            password: password, vaultID: Self.vaultID,
            formatVersion: Self.formatVersion, parameters: Self.params
        )
        // Same password, different vault UUID or format version ⇒ AAD mismatch.
        #expect(throws: CryptoError.invalidPasswordOrCorruptedVault) {
            _ = try KeyHierarchy.unwrap(wrapped, password: password, vaultID: UUID(), formatVersion: Self.formatVersion)
        }
        #expect(throws: CryptoError.invalidPasswordOrCorruptedVault) {
            _ = try KeyHierarchy.unwrap(wrapped, password: password, vaultID: Self.vaultID, formatVersion: 2)
        }
    }

    @Test func tamperedWrappedKeyRejected() throws {
        let password = SecureBytes(utf8: "example-master-password-not-real")
        let (wrapped, _) = try KeyHierarchy.createVMK(
            password: password, vaultID: Self.vaultID,
            formatVersion: Self.formatVersion, parameters: Self.params
        )
        var ciphertext = Data(wrapped.sealed.ciphertext)
        ciphertext[3] ^= 0x10
        let tampered = KeyHierarchy.WrappedVMK(
            kdfSalt: wrapped.kdfSalt,
            kdfParameters: wrapped.kdfParameters,
            sealed: SealedMessage(
                algorithm: .aes256gcm, nonce: wrapped.sealed.nonce,
                ciphertext: ciphertext, tag: wrapped.sealed.tag
            )
        )
        #expect(throws: CryptoError.invalidPasswordOrCorruptedVault) {
            _ = try KeyHierarchy.unwrap(tampered, password: password, vaultID: Self.vaultID, formatVersion: Self.formatVersion)
        }
    }

    @Test func passwordChangeRewrapsSameVMK() throws {
        let oldPassword = SecureBytes(utf8: "old-example-password-not-real")
        let newPassword = SecureBytes(utf8: "new-example-password-not-real")
        let (_, vmk) = try KeyHierarchy.createVMK(
            password: oldPassword, vaultID: Self.vaultID,
            formatVersion: Self.formatVersion, parameters: Self.params
        )
        let random = SystemSecureRandom()
        let rewrapped = try KeyHierarchy.wrap(
            vmk: vmk, password: newPassword,
            salt: try random.bytes(count: 16), parameters: Self.params,
            vaultID: Self.vaultID, formatVersion: Self.formatVersion
        )
        let unwrapped = try KeyHierarchy.unwrap(
            rewrapped, password: newPassword,
            vaultID: Self.vaultID, formatVersion: Self.formatVersion
        )
        #expect(unwrapped == vmk, "password change must preserve the VMK (records untouched)")
        #expect(throws: CryptoError.invalidPasswordOrCorruptedVault) {
            _ = try KeyHierarchy.unwrap(rewrapped, password: oldPassword, vaultID: Self.vaultID, formatVersion: Self.formatVersion)
        }
    }
}
