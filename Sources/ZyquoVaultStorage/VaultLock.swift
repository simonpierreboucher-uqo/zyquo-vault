import Darwin
import Foundation

/// Process-level write lock (`lock` file in the vault directory) with owner
/// metadata and stale-lock detection (CLAUDE.md §6.5).
///
/// Rules: a lock is never deleted just because it exists. It is considered stale
/// only when its owning PID provably no longer runs (`kill(pid, 0)` → ESRCH) or
/// the file is unreadable/garbled AND older than `staleAge`.
public struct VaultLock {
    public static let fileName = "lock"
    /// Age beyond which an unreadable lock file may be treated as stale.
    public static let staleAge: TimeInterval = 24 * 60 * 60

    struct Owner: Codable {
        var pid: Int32
        var processName: String
        var acquiredAt: UInt64
    }

    public let url: URL

    public init(vaultDirectory: URL) {
        self.url = vaultDirectory.appendingPathComponent(Self.fileName)
    }

    /// Acquires the lock, taking over provably stale ones. Throws
    /// `StorageError.fileLocked` when another live process holds it.
    public func acquire() throws {
        if let owner = currentOwner() {
            if processIsAlive(owner.pid) {
                // A live owner — including another repository instance inside
                // this same process — means concurrent access: reject.
                throw StorageError.fileLocked(ownerPID: owner.pid)
            }
            // Owner provably dead: stale, take over.
            try? FileManager.default.removeItem(at: url)
        } else if FileManager.default.fileExists(atPath: url.path) {
            // Unreadable/garbled lock: only reclaim when old enough.
            let age = fileAge()
            guard age > Self.staleAge else {
                throw StorageError.fileLocked(ownerPID: nil)
            }
            try? FileManager.default.removeItem(at: url)
        }

        let owner = Owner(
            pid: getpid(),
            processName: ProcessInfo.processInfo.processName,
            acquiredAt: UInt64(Date().timeIntervalSince1970)
        )
        let data = try JSONEncoder().encode(owner)
        // O_EXCL: creation races with another process lose cleanly.
        let fd = Darwin.open(url.path, O_WRONLY | O_CREAT | O_EXCL, 0o600)
        guard fd >= 0 else {
            throw StorageError.fileLocked(ownerPID: currentOwner()?.pid)
        }
        defer { close(fd) }
        _ = data.withUnsafeBytes { write(fd, $0.baseAddress, $0.count) }
    }

    /// Releases the lock only if this process owns it.
    public func release() {
        guard let owner = currentOwner(), owner.pid == getpid() else { return }
        try? FileManager.default.removeItem(at: url)
    }

    func currentOwner() -> Owner? {
        guard let data = try? Data(contentsOf: url) else { return nil }
        return try? JSONDecoder().decode(Owner.self, from: data)
    }

    private func processIsAlive(_ pid: Int32) -> Bool {
        guard pid > 0 else { return false }
        if kill(pid, 0) == 0 { return true }
        return errno != ESRCH
    }

    private func fileAge() -> TimeInterval {
        let attrs = try? FileManager.default.attributesOfItem(atPath: url.path)
        guard let modified = attrs?[.modificationDate] as? Date else { return 0 }
        return Date().timeIntervalSince(modified)
    }
}
