import Foundation
import Testing
@testable import ZyquoVaultCrypto
@testable import ZyquoVaultDomain
@testable import ZyquoVaultStorage

/// M2 persistence suite: CRUD, crash recovery, corruption detection, locking.
@Suite("Vault repository (M2)", .serialized)
struct RepositoryTests {

    static let params = Argon2id.Parameters(
        memoryKiB: Argon2id.Floor.memoryKiB,
        iterations: Argon2id.Floor.iterations,
        parallelism: 4
    )
    static let password = "example-master-password-not-real"

    func makeVault() throws -> (dir: URL, repo: VaultRepository) {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("zyquo-repo-test-\(UUID().uuidString)")
        let repo = try VaultRepository.create(
            at: dir, password: SecureBytes(utf8: Self.password), parameters: Self.params
        )
        return (dir, repo)
    }

    func reopen(_ dir: URL) throws -> VaultRepository {
        try VaultRepository.open(at: dir, password: SecureBytes(utf8: Self.password))
    }

    func sampleItem(title: String = "Example login") -> VaultItem {
        VaultItem(
            itemType: .login,
            title: title,
            fields: [
                VaultField(label: "Username", value: SensitiveFieldValue("user@example.com"), kind: .username),
                VaultField(label: "Password", value: SensitiveFieldValue("example-password-not-real"), kind: .password, isConcealed: true),
            ],
            tags: ["fixture"]
        )
    }

    @Test func crudRoundTripAndPersistence() throws {
        let (dir, repo) = try makeVault()
        defer { try? FileManager.default.removeItem(at: dir) }

        // Create.
        let item = sampleItem()
        let r1 = try repo.put(item)
        #expect(r1 == 1)
        let fetched = try repo.item(id: item.id)
        #expect(fetched.title == "Example login")
        #expect(fetched.fields[1].value.reveal() == "example-password-not-real")
        #expect(fetched.revision == 1)

        // Update bumps revision.
        var updated = fetched
        updated.title = "Renamed login"
        let r2 = try repo.put(updated)
        #expect(r2 == 2)
        #expect(try repo.item(id: item.id).title == "Renamed login")
        #expect(repo.list().count == 1)

        // Second item, then delete the first (tombstoned).
        let second = sampleItem(title: "Second")
        try repo.put(second)
        try repo.delete(id: item.id)
        #expect(repo.list().count == 1)
        #expect(repo.tombstones().map(\.id) == [item.id])
        #expect(throws: StorageError.recordNotFound(item.id)) { _ = try repo.item(id: item.id) }

        // Everything survives a close + reopen (fresh KDF, fresh keys).
        let generation = repo.manifest.generation
        repo.close()
        let reopened = try reopen(dir)
        defer { reopened.close() }
        #expect(reopened.manifest.generation == generation)
        #expect(reopened.list().count == 1)
        #expect(try reopened.item(id: second.id).title == "Second")
        #expect(reopened.verifyIntegrity(deep: true).isClean)
        #expect(reopened.manifest.previousManifestDigest != nil)
    }

    @Test func corruptionIsDetectedNotAccepted() throws {
        let (dir, repo) = try makeVault()
        defer { try? FileManager.default.removeItem(at: dir) }
        let item = sampleItem()
        try repo.put(item)
        let url = repo.recordURL(item.id)

        // Flip a payload byte → corruptedRecord, and the deep verify flags it.
        let original = try Data(contentsOf: url)
        var corrupted = original
        corrupted[original.count - 20] ^= 0x01
        try corrupted.write(to: url)
        #expect(throws: StorageError.corruptedRecord(item.id)) { _ = try repo.item(id: item.id) }
        let report = repo.verifyIntegrity(deep: true)
        #expect(report.corruptedRecords == [item.id])

        // A stale (old-revision) file substituted back is rejected too.
        try original.write(to: url)
        var updated = item
        updated.title = "new revision"
        try repo.put(updated)
        try original.write(to: url) // attacker restores revision-1 file
        #expect(throws: StorageError.corruptedRecord(item.id)) { _ = try repo.item(id: item.id) }

        // Missing file → missingRecord.
        try FileManager.default.removeItem(at: url)
        #expect(throws: StorageError.missingRecord(item.id)) { _ = try repo.item(id: item.id) }
        #expect(repo.verifyIntegrity().missingRecords == [item.id])

        // Unexpected file → flagged, never silently adopted.
        let stray = dir.appendingPathComponent(VaultRepository.recordsDirectoryName)
            .appendingPathComponent("\(UUID().uuidString).zyqrec")
        try Data([1, 2, 3]).write(to: stray)
        #expect(repo.verifyIntegrity().unexpectedFiles.count == 1)
        repo.close()
    }

    @Test func corruptedOrRolledBackManifestRejected() throws {
        let (dir, repo) = try makeVault()
        defer { try? FileManager.default.removeItem(at: dir) }
        try repo.put(sampleItem())
        repo.close()

        let manifestURL = dir.appendingPathComponent(VaultManifest.fileName)
        let good = try Data(contentsOf: manifestURL)

        // Ciphertext tamper.
        var bad = good
        bad[good.count - 5] ^= 0xFF
        try bad.write(to: manifestURL)
        #expect(throws: StorageError.self) { _ = try reopen(dir) }

        // Generation tamper (outer field feeds the AAD → authentication fails).
        var generationTampered = good
        generationTampered[15] ^= 0x01 // generation bytes at offset 8..<16
        try generationTampered.write(to: manifestURL)
        #expect(throws: StorageError.self) { _ = try reopen(dir) }

        // Truncation and garbage.
        try good.prefix(20).write(to: manifestURL)
        #expect(throws: StorageError.self) { _ = try reopen(dir) }
        try Data("junk".utf8).write(to: manifestURL)
        #expect(throws: StorageError.self) { _ = try reopen(dir) }

        // Restore → opens again (fail closed is not sticky).
        try good.write(to: manifestURL)
        let ok = try reopen(dir)
        #expect(ok.list().count == 1)
        ok.close()
    }

    @Test func interruptedPutRollsBack() throws {
        let (dir, repo) = try makeVault()
        defer { try? FileManager.default.removeItem(at: dir) }
        let item = sampleItem(title: "stable")
        try repo.put(item)
        let generation = repo.manifest.generation

        // Simulate a crash after journal+pending were written but BEFORE the
        // manifest commit: journal entry targets generation+1, manifest stays.
        let tx = JournalEntry(
            transactionID: UUID(), operation: .put, recordID: item.id,
            previousGeneration: generation, newGeneration: generation + 1,
            timestamp: 9_999_999_999
        )
        try TransactionJournal.begin(tx, in: dir)
        try Data("pending-garbage".utf8).write(to: repo.pendingURL(item.id))
        repo.close()

        let reopened = try reopen(dir)
        defer { reopened.close() }
        // Rolled back: pending gone, journal drained, old item intact.
        #expect(!FileManager.default.fileExists(atPath: reopened.pendingURL(item.id).path))
        #expect(TransactionJournal.pendingEntries(in: dir).isEmpty)
        #expect(reopened.manifest.generation == generation)
        #expect(try reopened.item(id: item.id).title == "stable")
        #expect(reopened.verifyIntegrity(deep: true).isClean)
    }

    @Test func interruptedPutRollsForward() throws {
        let (dir, repo) = try makeVault()
        defer { try? FileManager.default.removeItem(at: dir) }
        let item = sampleItem(title: "old title")
        try repo.put(item)
        var updated = try repo.item(id: item.id)
        updated.title = "new title"
        try repo.put(updated) // fully committed (generation G)

        // Simulate a crash AFTER the manifest commit but BEFORE the pending →
        // final rename: move the committed file back to pending and restore the
        // journal entry for that transaction.
        let final = repo.recordURL(item.id)
        let pending = repo.pendingURL(item.id)
        try FileManager.default.moveItem(at: final, to: pending)
        let tx = JournalEntry(
            transactionID: UUID(), operation: .put, recordID: item.id,
            previousGeneration: repo.manifest.generation - 1,
            newGeneration: repo.manifest.generation,
            timestamp: 9_999_999_999
        )
        try TransactionJournal.begin(tx, in: dir)
        repo.close()

        let reopened = try reopen(dir)
        defer { reopened.close() }
        // Rolled forward: pending renamed into place, new content readable.
        #expect(try reopened.item(id: item.id).title == "new title")
        #expect(TransactionJournal.pendingEntries(in: dir).isEmpty)
        #expect(reopened.verifyIntegrity(deep: true).isClean)
    }

    @Test func interruptedDeleteRollsForward() throws {
        let (dir, repo) = try makeVault()
        defer { try? FileManager.default.removeItem(at: dir) }
        let item = sampleItem()
        try repo.put(item)
        let bytes = try Data(contentsOf: repo.recordURL(item.id))
        try repo.delete(id: item.id) // committed; file removed

        // Simulate the crash window: record file resurrected, journal restored.
        try bytes.write(to: repo.recordURL(item.id))
        let tx = JournalEntry(
            transactionID: UUID(), operation: .delete, recordID: item.id,
            previousGeneration: repo.manifest.generation - 1,
            newGeneration: repo.manifest.generation,
            timestamp: 9_999_999_999
        )
        try TransactionJournal.begin(tx, in: dir)
        repo.close()

        let reopened = try reopen(dir)
        defer { reopened.close() }
        #expect(!FileManager.default.fileExists(atPath: reopened.recordURL(item.id).path))
        #expect(reopened.verifyIntegrity(deep: true).isClean)
    }

    @Test func concurrentAccessRejectedAndStaleLockReclaimed() throws {
        let (dir, repo) = try makeVault()
        defer { try? FileManager.default.removeItem(at: dir) }

        // A second open while the first holds the lock is rejected.
        #expect(throws: StorageError.fileLocked(ownerPID: getpid())) {
            _ = try reopen(dir)
        }
        repo.close()

        // A lock owned by a provably dead process is reclaimed.
        let probe = Process()
        probe.executableURL = URL(fileURLWithPath: "/usr/bin/true")
        try probe.run()
        probe.waitUntilExit()
        let deadPID = probe.processIdentifier
        let lockURL = dir.appendingPathComponent(VaultLock.fileName)
        try Data(#"{"pid":\#(deadPID),"processName":"gone","acquiredAt":1}"#.utf8).write(to: lockURL)
        let reopened = try reopen(dir)
        #expect(reopened.list().isEmpty)
        reopened.close()

        // A garbled lock file that is NOT old enough is never deleted.
        try Data("not json".utf8).write(to: lockURL)
        #expect(throws: StorageError.fileLocked(ownerPID: nil)) { _ = try reopen(dir) }
        try? FileManager.default.removeItem(at: lockURL)
    }

    @Test func unsafePermissionsAreReported() throws {
        let (dir, repo) = try makeVault()
        defer { try? FileManager.default.removeItem(at: dir) }
        repo.close()

        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: dir.path)
        let reopened = try reopen(dir)
        defer { reopened.close() }
        #expect(!reopened.permissionWarnings.isEmpty)
        try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: dir.path)
    }

    @Test func recordEnvelopeRejectsMalformedInput() throws {
        let id = UUID()
        for data in [Data(), Data("ZYQR".utf8), Data(repeating: 0xAB, count: 64)] {
            #expect(throws: StorageError.self) {
                _ = try RecordEnvelope.decode(data, expectedRecordID: id)
            }
        }
    }
}
