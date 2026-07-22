import Foundation
import Testing
@testable import ZyquoVaultCrypto
@testable import ZyquoVaultStorage

/// The M1 "first functional demonstration" (CLAUDE.md §16), executed as a test:
/// create a temp vault → derive PKEK (Argon2id) → generate + wrap a random VMK →
/// save the authenticated header → reopen → reject a wrong password → detect a
/// modified tag → recover from corruption attempts without crashing.
@Suite("Vault lifecycle (M1 demo)", .serialized)
struct VaultLifecycleTests {

    static let params = Argon2id.Parameters(
        memoryKiB: Argon2id.Floor.memoryKiB,
        iterations: Argon2id.Floor.iterations,
        parallelism: 4
    )

    func temporaryVaultDirectory() -> URL {
        FileManager.default.temporaryDirectory
            .appendingPathComponent("zyquo-test-vault-\(UUID().uuidString)")
    }

    func headerURL(_ dir: URL) -> URL { dir.appendingPathComponent(VaultStore.headerFileName) }

    @Test func createReopenRejectAndTamperDetect() throws {
        let dir = temporaryVaultDirectory()
        defer { try? FileManager.default.removeItem(at: dir) }
        let password = SecureBytes(utf8: "example-master-password-not-real")

        // Create (includes automatic verification reopen).
        let vaultID = try VaultStore.createVault(at: dir, password: password, parameters: Self.params)

        // Header file exists with 0600; vault dir 0700.
        let fm = FileManager.default
        let fileMode = (try fm.attributesOfItem(atPath: headerURL(dir).path)[.posixPermissions] as? NSNumber)?.uint16Value
        let dirMode = (try fm.attributesOfItem(atPath: dir.path)[.posixPermissions] as? NSNumber)?.uint16Value
        #expect(fileMode == 0o600)
        #expect(dirMode == 0o700)

        // Reopen with the right password.
        let opened = try VaultStore.openVault(at: dir, password: password)
        defer { opened.vmk.wipe() }
        #expect(opened.header.vaultID == vaultID)
        #expect(opened.vmk.count == 32)

        // Wrong password rejected with the deliberately ambiguous error.
        #expect(throws: CryptoError.invalidPasswordOrCorruptedVault) {
            _ = try VaultStore.openVault(at: dir, password: SecureBytes(utf8: "wrong-example-password-not-real"))
        }

        // Modified GCM tag detected (tag = last 16 bytes before flags+auth trailer).
        let original = try Data(contentsOf: headerURL(dir))
        var tampered = original
        // Locate the tag: flip a byte 4+1+32 bytes from the end (flags 4, authVer 1,
        // authTag 32) — i.e. inside the GCM tag region.
        let tagByteIndex = tampered.count - (4 + 1 + 32) - 1
        tampered[tagByteIndex] ^= 0xFF
        try tampered.write(to: headerURL(dir))
        #expect(throws: CryptoError.invalidPasswordOrCorruptedVault) {
            _ = try VaultStore.openVault(at: dir, password: password)
        }

        // Modified unauthenticated-by-AEAD field (createdAt) caught by header HMAC.
        var timestampTampered = original
        timestampTampered[30] ^= 0x01 // inside createdAt (offset 28..<36)
        try timestampTampered.write(to: headerURL(dir))
        #expect(throws: CryptoError.invalidPasswordOrCorruptedVault) {
            _ = try VaultStore.openVault(at: dir, password: password)
        }

        // Restore the original and confirm it still opens (fail-closed, not sticky).
        try original.write(to: headerURL(dir))
        let reopened = try VaultStore.openVault(at: dir, password: password)
        reopened.vmk.wipe()
    }

    @Test func malformedHeadersRejectedWithoutCrashing() throws {
        let dir = temporaryVaultDirectory()
        defer { try? FileManager.default.removeItem(at: dir) }
        let password = SecureBytes(utf8: "example-master-password-not-real")
        try VaultStore.createVault(at: dir, password: password, parameters: Self.params)
        let original = try Data(contentsOf: headerURL(dir))

        var malformed: [Data] = [
            Data(),                                  // empty
            Data("ZYQV".utf8),                       // magic only
            original.prefix(original.count / 2),     // truncated
            Data("not a vault header at all".utf8),  // garbage
            original + Data([0x00]),                 // trailing bytes
            Data(repeating: 0xFF, count: 5000),      // oversized
        ]
        // Bad magic.
        var badMagic = original
        badMagic[0] = 0x00
        malformed.append(badMagic)
        // DoS-scale KDF memory (offset: 4+4+4+16+8+8+4 = 48 is salt length byte,
        // salt is 16 bytes ⇒ memoryKiB at 49+16 = 65).
        var dosParams = original
        dosParams.replaceSubrange(65..<69, with: [0xFF, 0xFF, 0xFF, 0xFF])
        malformed.append(dosParams)

        for (index, data) in malformed.enumerated() {
            try data.write(to: headerURL(dir))
            #expect(throws: (any Error).self, "malformed case \(index) must be rejected") {
                _ = try VaultStore.openVault(at: dir, password: password)
            }
        }
    }

    @Test func headerBinaryRoundTrip() throws {
        let password = SecureBytes(utf8: "example-master-password-not-real")
        let vaultID = UUID()
        let (wrapped, vmk) = try KeyHierarchy.createVMK(
            password: password, vaultID: vaultID, formatVersion: 1, parameters: Self.params
        )
        defer { vmk.wipe() }
        var header = VaultHeader(vaultID: vaultID, createdAt: 1_752_000_000, updatedAt: 1_752_000_001, wrappedVMK: wrapped)
        header.headerAuthTag = VaultStore.headerAuthTag(for: header, vmk: vmk)
        let encoded = try header.encoded()
        let decoded = try VaultHeader.decode(encoded)
        #expect(decoded == header)
    }

    @Test func missingVaultReported() {
        let dir = temporaryVaultDirectory()
        #expect(throws: StorageError.vaultNotFound) {
            _ = try VaultStore.openVault(at: dir, password: SecureBytes(utf8: "x"))
        }
    }

    @Test func atomicWriterValidatesAndSweeps() throws {
        let dir = temporaryVaultDirectory()
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }

        let target = dir.appendingPathComponent("file.bin")
        try AtomicFileWriter.write(Data([1, 2, 3]), to: target)
        try AtomicFileWriter.write(Data([4, 5, 6]), to: target) // replace path
        #expect(try Data(contentsOf: target) == Data([4, 5, 6]))

        // Stale temp files are swept.
        let stale = dir.appendingPathComponent(".zyquo-tmp-stale")
        try Data([9]).write(to: stale)
        AtomicFileWriter.sweepStaleTempFiles(in: dir)
        #expect(!FileManager.default.fileExists(atPath: stale.path))
        #expect(FileManager.default.fileExists(atPath: target.path))
    }
}
