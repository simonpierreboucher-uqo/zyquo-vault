import CryptoKit
import Foundation
import ZyquoVaultCrypto
import ZyquoVaultDomain

/// Integrity findings from `verifyIntegrity`. Missing/unexpected files are never
/// silently accepted (CLAUDE.md §6.2).
public struct IntegrityReport: Sendable, Equatable {
    /// In the manifest, but the file is absent.
    public var missingRecords: [UUID] = []
    /// `.zyqrec` files present but not in the manifest.
    public var unexpectedFiles: [String] = []
    /// Files that fail parsing, authentication, or revision cross-checks.
    public var corruptedRecords: [UUID] = []
    /// Leftover `.pending` files without a journal entry.
    public var orphanedPendingFiles: [String] = []
    public var recordCount: Int = 0

    public var isClean: Bool {
        missingRecords.isEmpty && unexpectedFiles.isEmpty
            && corruptedRecords.isEmpty && orphanedPendingFiles.isEmpty
    }
}

/// The M2 vault repository: owns an open vault's keys and manifest, and performs
/// crash-safe record CRUD per the journal protocol in `TransactionJournal.swift`.
///
/// Not `Sendable` by design — M3 wraps it in the `VaultSession` actor, which is
/// the only place key material may live long-term. Views never see this type.
public final class VaultRepository {
    public static let recordsDirectoryName = "records"
    public static let recordSchemaVersion: UInt32 = 1

    public let directory: URL
    public private(set) var header: VaultHeader
    /// Non-fatal permission findings from `open` (§6.5: warn, fail only on writes).
    public private(set) var permissionWarnings: [String]

    private let vmk: SecureBytes
    private let recordKey: SymmetricKey
    private let manifestKey: SymmetricKey
    public internal(set) var manifest: VaultManifest
    private var lock: VaultLock
    private let now: @Sendable () -> UInt64
    private var closed = false

    // MARK: Lifecycle

    private init(
        directory: URL,
        header: VaultHeader,
        vmk: SecureBytes,
        manifest: VaultManifest,
        lock: VaultLock,
        permissionWarnings: [String],
        now: @escaping @Sendable () -> UInt64
    ) {
        self.directory = directory
        self.header = header
        self.vmk = vmk
        self.recordKey = KeyDerivation.subkey(vmk: vmk, vaultID: header.vaultID, context: .recordWrapping)
        self.manifestKey = KeyDerivation.subkey(vmk: vmk, vaultID: header.vaultID, context: .manifestProtection)
        self.manifest = manifest
        self.lock = lock
        self.permissionWarnings = permissionWarnings
        self.now = now
    }

    /// Creates a vault (header + empty manifest + directory skeleton), verifying
    /// creation by a full reopen, and returns the open repository. When
    /// `recoveryKey` is provided, a second VMK wrap under it lands in the header.
    public static func create(
        at directory: URL,
        password: SecureBytes,
        recoveryKey: RecoveryKey? = nil,
        parameters: Argon2id.Parameters = .baseline,
        random: SecureRandomSource = SystemSecureRandom(),
        now: @escaping @Sendable () -> UInt64 = { UInt64(Date().timeIntervalSince1970) }
    ) throws -> VaultRepository {
        let (header, vmk) = try VaultStore.createVaultKeepingKeys(
            at: directory, password: password, recoveryKey: recoveryKey,
            parameters: parameters, random: random, now: now
        )

        do {
            let fm = FileManager.default
            for sub in [recordsDirectoryName, TransactionJournal.directoryName, "attachments", "backups"] {
                try fm.createDirectory(
                    at: directory.appendingPathComponent(sub),
                    withIntermediateDirectories: true,
                    attributes: [.posixPermissions: 0o700]
                )
            }
            let manifestKey = KeyDerivation.subkey(vmk: vmk, vaultID: header.vaultID, context: .manifestProtection)
            let manifest = VaultManifest(vaultID: header.vaultID, generation: 1, updatedAt: now())
            try AtomicFileWriter.write(
                try manifest.sealedFileData(manifestKey: manifestKey, random: random),
                to: directory.appendingPathComponent(VaultManifest.fileName)
            )
        } catch {
            vmk.wipe()
            throw error
        }
        vmk.wipe()

        // Full verification reopen — creation isn't done until this succeeds.
        return try open(at: directory, password: password, now: now)
    }

    /// Opens a vault: permissions check → stale-temp sweep → process lock →
    /// header + VMK unwrap → manifest → journal recovery.
    public static func open(
        at directory: URL,
        password: SecureBytes,
        now: @escaping @Sendable () -> UInt64 = { UInt64(Date().timeIntervalSince1970) }
    ) throws -> VaultRepository {
        try open(at: directory, now: now) {
            try VaultStore.openVault(at: directory, password: password)
        }
    }

    /// Opens a vault with the recovery key instead of the password (§7.1).
    public static func open(
        at directory: URL,
        recoveryKey: RecoveryKey,
        now: @escaping @Sendable () -> UInt64 = { UInt64(Date().timeIntervalSince1970) }
    ) throws -> VaultRepository {
        try open(at: directory, now: now) {
            try VaultStore.openVaultWithRecoveryKey(at: directory, recoveryKey: recoveryKey)
        }
    }

    private static func open(
        at directory: URL,
        now: @escaping @Sendable () -> UInt64,
        unwrap: () throws -> (header: VaultHeader, vmk: SecureBytes)
    ) throws -> VaultRepository {
        let warnings = validatePermissions(in: directory)
        AtomicFileWriter.sweepStaleTempFiles(in: directory)
        AtomicFileWriter.sweepStaleTempFiles(in: directory.appendingPathComponent(recordsDirectoryName))

        let lock = VaultLock(vaultDirectory: directory)
        try lock.acquire()

        do {
            let (header, vmk) = try unwrap()
            let manifestKey = KeyDerivation.subkey(vmk: vmk, vaultID: header.vaultID, context: .manifestProtection)
            let manifestURL = directory.appendingPathComponent(VaultManifest.fileName)
            guard FileManager.default.fileExists(atPath: manifestURL.path) else {
                vmk.wipe()
                throw StorageError.invalidManifest(reason: "manifest missing")
            }
            let manifest: VaultManifest
            do {
                manifest = try VaultManifest.decode(
                    try Data(contentsOf: manifestURL), vaultID: header.vaultID, manifestKey: manifestKey
                )
            } catch {
                vmk.wipe()
                throw error
            }

            let repository = VaultRepository(
                directory: directory, header: header, vmk: vmk,
                manifest: manifest, lock: lock,
                permissionWarnings: warnings, now: now
            )
            repository.recoverPendingTransactions()
            return repository
        } catch {
            lock.release()
            throw error
        }
    }

    /// Locks the repository: releases the process lock and wipes key material.
    /// The instance must not be used afterwards.
    public func close() {
        guard !closed else { return }
        closed = true
        lock.release()
        vmk.wipe()
    }

    deinit {
        close()
    }

    // MARK: CRUD

    /// All live records (manifest order is unspecified; callers sort).
    public func list() -> [VaultManifest.RecordEntry] {
        manifest.records
    }

    public func tombstones() -> [VaultManifest.Tombstone] {
        manifest.tombstones
    }

    /// Decrypts one record, cross-checking manifest revision and identity.
    public func item(id: UUID) throws -> VaultItem {
        guard let entry = manifest.entry(for: id) else {
            throw StorageError.recordNotFound(id)
        }
        let url = recordURL(id)
        guard FileManager.default.fileExists(atPath: url.path) else {
            throw StorageError.missingRecord(id)
        }
        let envelope = try RecordEnvelope.decode(try Data(contentsOf: url), expectedRecordID: id)
        guard envelope.revision == entry.revision, envelope.schemaVersion == entry.schemaVersion else {
            // Stale or substituted file — never silently accept (§6.2).
            throw StorageError.corruptedRecord(id)
        }
        let plaintext = try envelope.open(vaultID: header.vaultID, recordWrappingKey: recordKey)
        let item = try JSONDecoder().decode(VaultItem.self, from: plaintext)
        guard item.id == id else { throw StorageError.corruptedRecord(id) }
        return item
    }

    /// Inserts or updates a record (revision is managed here, not by the caller).
    @discardableResult
    public func put(_ item: VaultItem) throws -> UInt64 {
        let newRevision = (manifest.entry(for: item.id)?.revision ?? 0) + 1
        let tx = JournalEntry(
            transactionID: UUID(), operation: .put, recordID: item.id,
            previousGeneration: manifest.generation,
            newGeneration: manifest.generation + 1,
            timestamp: now()
        )
        try TransactionJournal.begin(tx, in: directory)

        var stored = item
        stored.revision = newRevision
        stored.updatedAt = Date(timeIntervalSince1970: TimeInterval(now()))
        let plaintext = try JSONEncoder().encode(stored)
        let envelope = try RecordEnvelope.seal(
            plaintext: plaintext, vaultID: header.vaultID, recordID: item.id,
            schemaVersion: Self.recordSchemaVersion, revision: newRevision,
            recordWrappingKey: recordKey
        )
        try AtomicFileWriter.write(envelope.encoded(), to: pendingURL(item.id))

        var next = manifest
        next.generation += 1
        next.records.removeAll { $0.id == item.id }
        next.records.append(.init(id: item.id, revision: newRevision, schemaVersion: Self.recordSchemaVersion))
        next.tombstones.removeAll { $0.id == item.id }
        next.lastTransactionID = tx.transactionID
        next.updatedAt = now()
        try commitManifest(next) // ← COMMIT point

        try AtomicFileWriter.atomicReplace(from: pendingURL(item.id), to: recordURL(item.id))
        TransactionJournal.complete(tx, in: directory)
        return newRevision
    }

    /// Removes a record (manifest first — the commit point — then the file).
    public func delete(id: UUID) throws {
        guard manifest.entry(for: id) != nil else {
            throw StorageError.recordNotFound(id)
        }
        let tx = JournalEntry(
            transactionID: UUID(), operation: .delete, recordID: id,
            previousGeneration: manifest.generation,
            newGeneration: manifest.generation + 1,
            timestamp: now()
        )
        try TransactionJournal.begin(tx, in: directory)

        var next = manifest
        next.generation += 1
        next.records.removeAll { $0.id == id }
        next.tombstones.append(.init(id: id, deletedAt: now()))
        next.lastTransactionID = tx.transactionID
        next.updatedAt = now()
        try commitManifest(next) // ← COMMIT point

        try? FileManager.default.removeItem(at: recordURL(id))
        TransactionJournal.complete(tx, in: directory)
    }

    // MARK: Folders (stored inside the encrypted manifest)

    public func folders() -> [VaultFolder] {
        manifest.folders ?? []
    }

    /// Replaces the folder list. A manifest-only change is a single atomic file
    /// write — crash-consistent without a journal entry.
    public func setFolders(_ folders: [VaultFolder]) throws {
        var next = manifest
        next.generation += 1
        next.folders = folders
        next.updatedAt = now()
        try commitManifest(next)
    }

    /// Decrypts every record into its non-secret summary projection.
    public func summaries() throws -> [ItemSummary] {
        try manifest.records.map { ItemSummary(item: try item(id: $0.id)) }
    }

    // MARK: Header maintenance (password change, recovery key)

    /// Changes the master password: fresh salt → fresh PKEK → re-wrap the SAME
    /// VMK (records untouched), reseal the header auth, write atomically, then
    /// verify the header actually reopens with the new password (§5.4).
    /// The caller must have verified the current password (UI re-prompts).
    public func changePassword(
        to newPassword: SecureBytes,
        parameters: Argon2id.Parameters? = nil,
        random: SecureRandomSource = SystemSecureRandom()
    ) throws {
        let params = parameters ?? header.wrappedVMK.kdfParameters
        var next = header
        next.wrappedVMK = try KeyHierarchy.wrap(
            vmk: vmk, password: newPassword,
            salt: try random.bytes(count: Argon2id.Floor.saltLength),
            parameters: params,
            vaultID: header.vaultID, formatVersion: header.formatVersion,
            random: random
        )
        try commitHeader(next)

        // Not done until it provably reopens with the new password.
        let verification = try VaultStore.openVault(at: directory, password: newPassword)
        verification.vmk.wipe()
    }

    /// Installs a specific recovery key (e.g. the one confirmed during the
    /// creation ceremony), replacing any previous wrap, then verifies it opens.
    public func installRecoveryKey(
        _ key: RecoveryKey,
        random: SecureRandomSource = SystemSecureRandom()
    ) throws {
        var next = header
        next.recoveryWrap = try KeyHierarchy.wrapWithRecoveryKey(
            vmk: vmk, recoveryKey: key,
            vaultID: header.vaultID, formatVersion: header.formatVersion,
            random: random
        )
        try commitHeader(next)
        let verification = try VaultStore.openVaultWithRecoveryKey(at: directory, recoveryKey: key)
        verification.vmk.wipe()
    }

    /// Generates and installs a fresh recovery key (rotation), invalidating any
    /// previous one. The returned key is shown to the user exactly once.
    public func rotateRecoveryKey(random: SecureRandomSource = SystemSecureRandom()) throws -> RecoveryKey {
        let key = try RecoveryKey.generate(random: random)
        try installRecoveryKey(key, random: random)
        return key
    }

    /// Removes the recovery wrap (user opted out).
    public func removeRecoveryKey() throws {
        var next = header
        next.recoveryWrap = nil
        try commitHeader(next)
    }

    private func commitHeader(_ next: VaultHeader) throws {
        var stamped = next
        stamped.updatedAt = now()
        stamped.headerAuthTag = VaultStore.headerAuthTag(for: stamped, vmk: vmk)
        try AtomicFileWriter.write(
            try stamped.encoded(),
            to: directory.appendingPathComponent(VaultStore.headerFileName)
        )
        header = stamped
    }

    // MARK: Integrity

    /// Cross-checks manifest against the records directory. `deep` also unwraps
    /// every DEK and authenticates every payload.
    public func verifyIntegrity(deep: Bool = false) -> IntegrityReport {
        var report = IntegrityReport()
        report.recordCount = manifest.records.count
        let fm = FileManager.default

        for entry in manifest.records {
            let url = recordURL(entry.id)
            guard let data = try? Data(contentsOf: url) else {
                report.missingRecords.append(entry.id)
                continue
            }
            do {
                let envelope = try RecordEnvelope.decode(data, expectedRecordID: entry.id)
                guard envelope.revision == entry.revision,
                      envelope.schemaVersion == entry.schemaVersion else {
                    report.corruptedRecords.append(entry.id)
                    continue
                }
                if deep {
                    _ = try envelope.open(vaultID: header.vaultID, recordWrappingKey: recordKey)
                }
            } catch {
                report.corruptedRecords.append(entry.id)
            }
        }

        let recordsDir = directory.appendingPathComponent(Self.recordsDirectoryName)
        let known = Set(manifest.records.map { "\($0.id.uuidString).zyqrec" })
        let journaled = Set(TransactionJournal.pendingEntries(in: directory).map(\.recordID))
        for name in (try? fm.contentsOfDirectory(atPath: recordsDir.path)) ?? [] {
            if name.hasSuffix(".zyqrec.pending") {
                let stem = String(name.dropLast(".zyqrec.pending".count))
                if UUID(uuidString: stem).map({ !journaled.contains($0) }) ?? true {
                    report.orphanedPendingFiles.append(name)
                }
            } else if name.hasSuffix(".zyqrec"), !known.contains(name) {
                report.unexpectedFiles.append(name)
            }
        }
        return report
    }

    // MARK: Journal recovery

    /// Rolls surviving transactions forward (committed) or back (uncommitted).
    /// The manifest on disk is authoritative; it is never auto-discarded.
    private func recoverPendingTransactions() {
        for entry in TransactionJournal.pendingEntries(in: directory) {
            let committed = manifest.generation >= entry.newGeneration
            switch (entry.operation, committed) {
            case (.put, true):
                // Finish step 4: move the pending ciphertext into place.
                let pending = pendingURL(entry.recordID)
                if FileManager.default.fileExists(atPath: pending.path) {
                    try? AtomicFileWriter.atomicReplace(from: pending, to: recordURL(entry.recordID))
                }
            case (.put, false):
                // Never committed: discard the pending file; old state is intact.
                try? FileManager.default.removeItem(at: pendingURL(entry.recordID))
            case (.delete, true):
                // Finish step 3: remove the record file.
                try? FileManager.default.removeItem(at: recordURL(entry.recordID))
            case (.delete, false):
                break // nothing changed on disk
            }
            TransactionJournal.complete(entry, in: directory)
        }
    }

    // MARK: Helpers

    func recordURL(_ id: UUID) -> URL {
        directory.appendingPathComponent(Self.recordsDirectoryName)
            .appendingPathComponent("\(id.uuidString).zyqrec")
    }

    func pendingURL(_ id: UUID) -> URL {
        directory.appendingPathComponent(Self.recordsDirectoryName)
            .appendingPathComponent("\(id.uuidString).zyqrec.pending")
    }

    private func commitManifest(_ next: VaultManifest) throws {
        var stamped = next
        let manifestURL = directory.appendingPathComponent(VaultManifest.fileName)
        if let currentBytes = try? Data(contentsOf: manifestURL) {
            stamped.previousManifestDigest = Data(SHA256.hash(data: currentBytes))
        }
        try AtomicFileWriter.write(
            try stamped.sealedFileData(manifestKey: manifestKey),
            to: manifestURL
        )
        manifest = stamped
    }

    /// Non-fatal permission audit (0700 dirs / 0600 files expected).
    static func validatePermissions(in directory: URL) -> [String] {
        var warnings: [String] = []
        let fm = FileManager.default
        func mode(_ url: URL) -> UInt16? {
            (try? fm.attributesOfItem(atPath: url.path)[.posixPermissions] as? NSNumber)?.uint16Value
        }
        if let m = mode(directory), m & 0o077 != 0 {
            warnings.append("vault directory permits group/other access (mode \(String(m, radix: 8)))")
        }
        for name in [VaultStore.headerFileName, VaultManifest.fileName] {
            let url = directory.appendingPathComponent(name)
            if fm.fileExists(atPath: url.path), let m = mode(url), m & 0o077 != 0 {
                warnings.append("\(name) permits group/other access (mode \(String(m, radix: 8)))")
            }
        }
        return warnings
    }
}
