import CryptoKit
import Foundation
import ZyquoVaultCrypto

/// Local encrypted backups (§7.3). A backup snapshots the header, manifest,
/// records, and attachments — every file is already independently encrypted and
/// authenticated, so a backup is encrypted by construction. `backup.info` adds
/// non-secret structure (counts, per-file SHA-256) for offline verification.
///
/// **A backup is not valid until verified**: `create` runs a structural +
/// cryptographic verification pass before reporting success. Restore always
/// targets a NEW vault directory; the active vault is never overwritten.
public enum BackupService {

    public static let directoryName = "backups"
    public static let infoFileName = "backup.info"

    /// Non-secret backup descriptor (plaintext JSON inside the backup folder).
    public struct Info: Codable, Equatable, Sendable {
        public var vaultID: UUID
        public var createdAt: UInt64
        public var manifestGeneration: UInt64
        public var recordCount: Int
        public var attachmentCount: Int
        public var formatVersion: UInt32
        /// SHA-256 per relative file path.
        public var fileDigests: [String: Data]
    }

    public struct BackupRef: Equatable, Sendable, Identifiable {
        public var id: String { name }
        public let name: String
        public let url: URL
        public let info: Info
    }

    // MARK: Create

    /// Copies the vault's persistent files into `backups/<stamp>-g<generation>/`,
    /// writes digests, then verifies the copy cryptographically with the open
    /// repository's keys. Throws (and removes the partial copy) on any failure.
    @discardableResult
    public static func create(for repository: VaultRepository) throws -> BackupRef {
        let fm = FileManager.default
        let stamp = ISO8601DateFormatter().string(from: Date())
            .replacingOccurrences(of: ":", with: "-")
        let name = "\(stamp)-g\(repository.manifest.generation)"
        let root = repository.directory.appendingPathComponent(directoryName)
        let destination = root.appendingPathComponent(name)
        try fm.createDirectory(
            at: destination, withIntermediateDirectories: true,
            attributes: [.posixPermissions: 0o700]
        )

        do {
            var digests: [String: Data] = [:]
            func copy(_ relative: String) throws {
                let source = repository.directory.appendingPathComponent(relative)
                guard fm.fileExists(atPath: source.path) else {
                    throw StorageError.atomicWriteFailed(reason: "backup source missing: \(relative)")
                }
                let target = destination.appendingPathComponent(relative)
                try fm.createDirectory(
                    at: target.deletingLastPathComponent(),
                    withIntermediateDirectories: true,
                    attributes: [.posixPermissions: 0o700]
                )
                let data = try Data(contentsOf: source)
                try data.write(to: target)
                try fm.setAttributes([.posixPermissions: 0o600], ofItemAtPath: target.path)
                digests[relative] = Data(SHA256.hash(data: data))
            }

            try copy(VaultStore.headerFileName)
            try copy(VaultManifest.fileName)
            for entry in repository.manifest.records {
                try copy("\(VaultRepository.recordsDirectoryName)/\(entry.id.uuidString).zyqrec")
            }
            for entry in repository.manifest.attachments {
                try copy("\(VaultRepository.attachmentsDirectoryName)/\(entry.id.uuidString).zyqatt")
            }

            let info = Info(
                vaultID: repository.header.vaultID,
                createdAt: UInt64(Date().timeIntervalSince1970),
                manifestGeneration: repository.manifest.generation,
                recordCount: repository.manifest.records.count,
                attachmentCount: repository.manifest.attachments.count,
                formatVersion: repository.header.formatVersion,
                fileDigests: digests
            )
            let infoData = try JSONEncoder().encode(info)
            try infoData.write(to: destination.appendingPathComponent(infoFileName))

            // Mandatory verification before the backup counts as created.
            try verify(backupAt: destination, with: repository)
            return BackupRef(name: name, url: destination, info: info)
        } catch {
            try? fm.removeItem(at: destination)
            throw error
        }
    }

    // MARK: Verify

    /// Structural + cryptographic verification: digests match, the header
    /// authenticates under the live VMK, the manifest decrypts, every listed
    /// record and attachment authenticates fully.
    public static func verify(backupAt url: URL, with repository: VaultRepository) throws {
        let info = try readInfo(at: url)
        guard info.vaultID == repository.header.vaultID else {
            throw StorageError.invalidManifest(reason: "backup belongs to a different vault")
        }
        // 1. Digests.
        for (relative, expected) in info.fileDigests {
            let data = try Data(contentsOf: url.appendingPathComponent(relative))
            guard constantTimeEquals(Data(SHA256.hash(data: data)), expected) else {
                throw StorageError.invalidManifest(reason: "backup digest mismatch: \(relative)")
            }
        }
        // 2. Cryptographic verification with the open repository's keys.
        try repository.verifySnapshot(at: url)
    }

    static func readInfo(at url: URL) throws -> Info {
        let data = try Data(contentsOf: url.appendingPathComponent(infoFileName))
        guard data.count <= 32 << 20 else {
            throw StorageError.invalidManifest(reason: "oversized backup info")
        }
        do {
            return try JSONDecoder().decode(Info.self, from: data)
        } catch {
            throw StorageError.invalidManifest(reason: "unreadable backup info")
        }
    }

    // MARK: List / prune / restore

    public static func list(in vaultDirectory: URL) -> [BackupRef] {
        let root = vaultDirectory.appendingPathComponent(directoryName)
        let fm = FileManager.default
        guard let names = try? fm.contentsOfDirectory(atPath: root.path) else { return [] }
        return names.compactMap { name in
            let url = root.appendingPathComponent(name)
            guard let info = try? readInfo(at: url) else { return nil }
            return BackupRef(name: name, url: url, info: info)
        }
        .sorted { $0.info.createdAt > $1.info.createdAt }
    }

    /// Retention (§7.3 defaults): keep the 10 most recent, plus one per day for
    /// 7 days, plus one per week for 4 weeks. Everything else is deleted.
    public static func prune(in vaultDirectory: URL, now: Date = Date()) {
        let backups = list(in: vaultDirectory) // newest first
        var keep = Set(backups.prefix(10).map(\.name))
        var dailyKept: Set<Int> = []
        var weeklyKept: Set<Int> = []
        for backup in backups {
            let age = now.timeIntervalSince1970 - Double(backup.info.createdAt)
            let day = Int(age / 86_400)
            let week = Int(age / (7 * 86_400))
            if day < 7, !dailyKept.contains(day) {
                dailyKept.insert(day)
                keep.insert(backup.name)
            }
            if week < 4, !weeklyKept.contains(week) {
                weeklyKept.insert(week)
                keep.insert(backup.name)
            }
        }
        for backup in backups where !keep.contains(backup.name) {
            try? FileManager.default.removeItem(at: backup.url)
        }
    }

    /// Restores a backup **into a new vault directory** (never over the active
    /// vault). The restored vault opens with the same master password/recovery
    /// key as when the backup was taken. Returns the new directory.
    public static func restore(backupAt url: URL, intoVaultsRoot vaultsRoot: URL) throws -> URL {
        let info = try readInfo(at: url)
        let fm = FileManager.default
        let destination = vaultsRoot.appendingPathComponent("restored-\(UUID().uuidString)")
        try fm.createDirectory(
            at: destination, withIntermediateDirectories: true,
            attributes: [.posixPermissions: 0o700]
        )
        do {
            for relative in [VaultStore.headerFileName, VaultManifest.fileName] + info.fileDigests.keys.sorted()
            where fm.fileExists(atPath: url.appendingPathComponent(relative).path) {
                let target = destination.appendingPathComponent(relative)
                try fm.createDirectory(
                    at: target.deletingLastPathComponent(),
                    withIntermediateDirectories: true,
                    attributes: [.posixPermissions: 0o700]
                )
                if !fm.fileExists(atPath: target.path) {
                    try fm.copyItem(at: url.appendingPathComponent(relative), to: target)
                    try fm.setAttributes([.posixPermissions: 0o600], ofItemAtPath: target.path)
                }
            }
            for sub in [VaultRepository.recordsDirectoryName, TransactionJournal.directoryName,
                        VaultRepository.attachmentsDirectoryName, directoryName] {
                try fm.createDirectory(
                    at: destination.appendingPathComponent(sub),
                    withIntermediateDirectories: true,
                    attributes: [.posixPermissions: 0o700]
                )
            }
            return destination
        } catch {
            try? fm.removeItem(at: destination)
            throw error
        }
    }
}

