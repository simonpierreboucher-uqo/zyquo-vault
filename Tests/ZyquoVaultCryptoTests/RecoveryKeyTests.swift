import Foundation
import Testing
@testable import ZyquoVaultCrypto

@Suite("Recovery key")
struct RecoveryKeyTests {

    @Test func displayParseRoundTrip() throws {
        let key = try RecoveryKey.generate()
        let display = key.displayString()
        #expect(display.hasPrefix("ZQRK-"))

        let parsed = try RecoveryKey.parse(display)
        #expect(parsed.bytes == key.bytes)

        // Lowercase, extra whitespace, and O/I/L misreadings are forgiven.
        let sloppy = display.lowercased()
            .replacingOccurrences(of: "0", with: "o")
            .replacingOccurrences(of: "1", with: "l")
            .replacingOccurrences(of: "-", with: " ")
        let reparsed = try RecoveryKey.parse(sloppy)
        #expect(reparsed.bytes == key.bytes)
    }

    @Test func malformedInputRejected() {
        #expect(throws: CryptoError.self) { _ = try RecoveryKey.parse("ZQRK-TOO-SHORT") }
        #expect(throws: CryptoError.self) { _ = try RecoveryKey.parse("") }
        #expect(throws: CryptoError.self) { _ = try RecoveryKey.parse(String(repeating: "!", count: 52)) }
    }

    @Test func wrapUnwrapAndWrongKeyRejected() throws {
        let vmk = try SystemSecureRandom().secureBytes(count: 32)
        let vaultID = UUID()
        let key = try RecoveryKey.generate()
        let wrap = try KeyHierarchy.wrapWithRecoveryKey(
            vmk: vmk, recoveryKey: key, vaultID: vaultID, formatVersion: 1
        )
        let unwrapped = try KeyHierarchy.unwrapWithRecoveryKey(
            wrap, recoveryKey: key, vaultID: vaultID, formatVersion: 1
        )
        #expect(unwrapped == vmk)

        let wrongKey = try RecoveryKey.generate()
        #expect(throws: CryptoError.invalidPasswordOrCorruptedVault) {
            _ = try KeyHierarchy.unwrapWithRecoveryKey(wrap, recoveryKey: wrongKey, vaultID: vaultID, formatVersion: 1)
        }
        // Bound to the vault identity.
        #expect(throws: CryptoError.invalidPasswordOrCorruptedVault) {
            _ = try KeyHierarchy.unwrapWithRecoveryKey(wrap, recoveryKey: key, vaultID: UUID(), formatVersion: 1)
        }
    }
}
