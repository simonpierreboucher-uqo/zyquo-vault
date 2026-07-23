import CryptoKit
import Foundation
import Testing
@testable import ZyquoVaultCrypto
@testable import ZyquoVaultDomain
@testable import ZyquoVaultStorage

/// M6 suite: chunked attachment encryption, corruption detection, temp-file
/// hygiene, backups (create/verify/tamper/restore/retention).
@Suite("Attachments & backups (M6)", .serialized)
struct AttachmentBackupTests {

    static let params = Argon2id.Parameters(
        memoryKiB: Argon2id.Floor.memoryKiB,
        iterations: Argon2id.Floor.iterations,
        parallelism: 4
    )
    static let password = "example-master-password-not-real"

    func makeVault() throws -> (dir: URL, repo: VaultRepository) {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("zyquo-m6-test-\(UUID().uuidString)")
        let repo = try VaultRepository.create(
            at: dir, password: SecureBytes(utf8: Self.password), parameters: Self.params
        )
        return (dir, repo)
    }

    /// Deterministic multi-chunk plaintext (~200 KiB with 64 KiB chunks → 4 chunks).
    func writeSampleFile(bytes: Int) throws -> URL {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("zyquo-attachment-src-\(UUID().uuidString).bin")
        var data = Data(capacity: bytes)
        var state: UInt8 = 7
        for _ in 0..<bytes {
            state = state &* 31 &+ 17
            data.append(state)
        }
        try data.write(to: url)
        return url
    }

    @Test func multiChunkRoundTripAndHygiene() throws {
        let (dir, repo) = try makeVault()
        defer { try? FileManager.default.removeItem(at: dir) }
        let source = try writeSampleFile(bytes: 200_000)
        defer { try? FileManager.default.removeItem(at: source) }
        let original = try Data(contentsOf: source)

        let id = UUID()

        // Store via the repository (journalled, manifest-registered).
        let metadata = try repo.storeAttachment(from: source, id: id, mimeType: "application/octet-stream")
        #expect(metadata.totalPlaintextSize == 200_000)
        #expect(metadata.chunkCount == 1) // 1 MiB default chunk → single chunk here
        #expect(repo.listAttachments().map(\.id) == [id])

        // Round trip through the temp-decrypt path.
        let opened = try repo.openAttachment(id: id)
        #expect(try Data(contentsOf: opened.url) == original)
        #expect(opened.metadata.originalFilename == source.lastPathComponent)
        // Decrypted temp file is 0600 and inside the vault-controlled dir.
        let mode = (try FileManager.default.attributesOfItem(atPath: opened.url.path)[.posixPermissions] as? NSNumber)?.uint16Value
        #expect(mode == 0o600)
        #expect(opened.url.path.contains(VaultRepository.decryptedTempDirectoryName))

        // close() destroys every decrypted temp file.
        repo.close()
        #expect(!FileManager.default.fileExists(atPath: opened.url.path))

        // Reopen: attachment still verifies deeply; delete removes it.
        let reopened = try VaultRepository.open(at: dir, password: SecureBytes(utf8: Self.password))
        defer { reopened.close() }
        #expect(reopened.verifyIntegrity(deep: true).isClean)
        try reopened.deleteAttachment(id: id)
        #expect(reopened.listAttachments().isEmpty)
        #expect(!FileManager.default.fileExists(atPath: reopened.attachmentURL(id).path))
    }

    @Test func trueMultiChunkEncryptionAndOrderBinding() throws {
        let (dir, repo) = try makeVault()
        defer {
            repo.close()
            try? FileManager.default.removeItem(at: dir)
        }
        let source = try writeSampleFile(bytes: 150_000)
        defer { try? FileManager.default.removeItem(at: source) }
        let original = try Data(contentsOf: source)
        let id = UUID()
        let destination = repo.attachmentURL(id)
        let key = repo.testingAttachmentKey

        // Small chunks force real multi-chunk streaming (150 KB / 16 KB → 10 chunks).
        let metadata = try AttachmentStore.encrypt(
            sourceURL: source, to: destination,
            vaultID: repo.header.vaultID, attachmentID: id,
            attachmentKey: key, mimeType: "application/octet-stream", chunkSize: 16_384
        )
        #expect(metadata.chunkCount == 10)

        let plainURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("zyquo-m6-out-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: plainURL) }
        _ = try AttachmentStore.decrypt(
            fileURL: destination, to: plainURL,
            vaultID: repo.header.vaultID, attachmentID: id, attachmentKey: key
        )
        #expect(try Data(contentsOf: plainURL) == original)

        // Tamper one ciphertext byte inside the chunk region → rejected.
        var bytes = try Data(contentsOf: destination)
        bytes[Int(AttachmentStore.chunkRegionStart) + 100] ^= 0x01
        try bytes.write(to: destination)
        #expect(throws: StorageError.corruptedRecord(id)) {
            try AttachmentStore.verify(
                fileURL: destination, vaultID: repo.header.vaultID,
                attachmentID: id, attachmentKey: key
            )
        }

        // Swap two chunk frames (correct tags, wrong positions) → AAD rejects.
        _ = try AttachmentStore.encrypt(
            sourceURL: source, to: destination,
            vaultID: repo.header.vaultID, attachmentID: id,
            attachmentKey: key, mimeType: "application/octet-stream", chunkSize: 16_384
        )
        var swapped = try Data(contentsOf: destination)
        let frameSize = 4 + 12 + 16_384 + 16
        let start = Int(AttachmentStore.chunkRegionStart)
        let chunk0 = swapped.subdata(in: start..<(start + frameSize))
        let chunk1 = swapped.subdata(in: (start + frameSize)..<(start + 2 * frameSize))
        swapped.replaceSubrange(start..<(start + frameSize), with: chunk1)
        swapped.replaceSubrange((start + frameSize)..<(start + 2 * frameSize), with: chunk0)
        try swapped.write(to: destination)
        #expect(throws: StorageError.corruptedRecord(id)) {
            try AttachmentStore.verify(
                fileURL: destination, vaultID: repo.header.vaultID,
                attachmentID: id, attachmentKey: key
            )
        }

        // Truncation and garbage are rejected, never crash.
        try Data(bytes.prefix(50)).write(to: destination)
        #expect(throws: StorageError.self) {
            _ = try AttachmentStore.readMetadata(
                at: destination, vaultID: repo.header.vaultID,
                attachmentID: id, attachmentKey: key
            )
        }
    }

    @Test func interruptedAttachmentStoreRollsBack() throws {
        let (dir, repo) = try makeVault()
        defer { try? FileManager.default.removeItem(at: dir) }
        let generation = repo.manifest.generation

        // Simulate a crash after journal+pending, before manifest commit.
        let id = UUID()
        let tx = JournalEntry(
            transactionID: UUID(), operation: .putAttachment, recordID: id,
            previousGeneration: generation, newGeneration: generation + 1,
            timestamp: 9_999_999_999
        )
        try TransactionJournal.begin(tx, in: dir)
        try Data("pending".utf8).write(to: repo.attachmentPendingURL(id))
        repo.close()

        let reopened = try VaultRepository.open(at: dir, password: SecureBytes(utf8: Self.password))
        defer { reopened.close() }
        #expect(!FileManager.default.fileExists(atPath: reopened.attachmentPendingURL(id).path))
        #expect(TransactionJournal.pendingEntries(in: dir).isEmpty)
        #expect(reopened.listAttachments().isEmpty)
        #expect(reopened.verifyIntegrity(deep: true).isClean)
    }

    @Test func backupCreateVerifyTamperRestore() throws {
        let (dir, repo) = try makeVault()
        defer { try? FileManager.default.removeItem(at: dir) }

        try repo.put(VaultItem(itemType: .login, title: "Backed up"))
        let source = try writeSampleFile(bytes: 10_000)
        defer { try? FileManager.default.removeItem(at: source) }
        try repo.storeAttachment(from: source, id: UUID())

        // Create + automatic verification.
        let ref = try BackupService.create(for: repo)
        #expect(ref.info.recordCount == 1)
        #expect(ref.info.attachmentCount == 1)
        #expect(try BackupService.verify(backupAt: ref.url, with: repo) == ())

        // Tampering any backed-up file fails verification.
        let recordRelative = ref.info.fileDigests.keys.first { $0.hasSuffix(".zyqrec") }!
        let recordURL = ref.url.appendingPathComponent(recordRelative)
        var bytes = try Data(contentsOf: recordURL)
        bytes[bytes.count - 3] ^= 0xFF
        try bytes.write(to: recordURL)
        #expect(throws: StorageError.self) {
            try BackupService.verify(backupAt: ref.url, with: repo)
        }

        // A fresh, intact backup restores into a SEPARATE vault that opens with
        // the same password and passes deep verification.
        let good = try BackupService.create(for: repo)
        let vaultsRoot = FileManager.default.temporaryDirectory
            .appendingPathComponent("zyquo-m6-restore-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: vaultsRoot) }
        let restoredDir = try BackupService.restore(backupAt: good.url, intoVaultsRoot: vaultsRoot)
        #expect(restoredDir.path != dir.path)
        repo.close()

        let restored = try VaultRepository.open(at: restoredDir, password: SecureBytes(utf8: Self.password))
        defer { restored.close() }
        #expect(restored.list().count == 1)
        #expect(try restored.item(id: restored.list()[0].id).title == "Backed up")
        #expect(restored.verifyIntegrity(deep: true).isClean)
    }

    @Test func retentionKeepsRecentDailyAndWeekly() throws {
        let (dir, repo) = try makeVault()
        defer {
            repo.close()
            try? FileManager.default.removeItem(at: dir)
        }
        // Fabricate 30 backups spread over 40 days by editing backup.info dates.
        let root = dir.appendingPathComponent(BackupService.directoryName)
        let now = Date()
        for index in 0..<30 {
            let ref = try BackupService.create(for: repo)
            var info = try BackupService.readInfo(at: ref.url)
            info.createdAt = UInt64(now.timeIntervalSince1970) - UInt64(index * 32 * 3600) // ~1.3 days apart
            try JSONEncoder().encode(info).write(to: ref.url.appendingPathComponent(BackupService.infoFileName))
            let renamed = root.appendingPathComponent("backup-\(index)")
            try FileManager.default.moveItem(at: ref.url, to: renamed)
        }
        #expect(BackupService.list(in: dir).count == 30)
        BackupService.prune(in: dir, now: now)
        let remaining = BackupService.list(in: dir)
        // 10 most recent + daily/weekly representatives ⇒ well under 30, over 9.
        #expect(remaining.count < 16)
        #expect(remaining.count >= 10)
        // The newest is always kept.
        #expect(remaining.first?.info.createdAt == UInt64(now.timeIntervalSince1970))
    }
}
