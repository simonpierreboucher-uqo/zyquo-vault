import Foundation

/// Atomic, permission-tightened file writes (CLAUDE.md §6.5, M1 subset — the full
/// journaled multi-file transaction machinery arrives with M2).
///
/// Sequence: write temp file in the same directory → `F_FULLFSYNC` → chmod 0600 →
/// re-read and byte-compare (validation) → atomic `rename(2)`.
///
/// Honest limitation (docs/vault-format.md §Durability): after `rename`, the
/// *directory entry* update may still be in the disk cache; macOS provides no
/// portable directory-fsync guarantee. `F_FULLFSYNC` on the temp file forces the
/// data itself to stable storage.
public enum AtomicFileWriter {

    public static func write(_ data: Data, to destination: URL) throws {
        let directory = destination.deletingLastPathComponent()
        let tempURL = directory.appendingPathComponent(".zyquo-tmp-\(UUID().uuidString)")
        let fm = FileManager.default

        do {
            fm.createFile(
                atPath: tempURL.path, contents: nil,
                attributes: [.posixPermissions: 0o600]
            )
            let handle = try FileHandle(forWritingTo: tempURL)
            defer { try? handle.close() }
            try handle.write(contentsOf: data)
            // Force data (not just metadata) to stable storage.
            if fcntl(handle.fileDescriptor, F_FULLFSYNC) != 0 {
                _ = fsync(handle.fileDescriptor) // fall back (e.g. filesystems without FULLFSYNC)
            }
            try handle.close()

            // Validate by re-reading before the swap.
            let reread = try Data(contentsOf: tempURL)
            guard reread == data else {
                throw StorageError.atomicWriteFailed(reason: "post-write validation mismatch")
            }

            // Atomic replace.
            if fm.fileExists(atPath: destination.path) {
                _ = try fm.replaceItemAt(destination, withItemAt: tempURL)
            } else {
                try fm.moveItem(at: tempURL, to: destination)
            }
            try fm.setAttributes([.posixPermissions: 0o600], ofItemAtPath: destination.path)
        } catch let error as StorageError {
            try? fm.removeItem(at: tempURL)
            throw error
        } catch {
            try? fm.removeItem(at: tempURL)
            throw StorageError.atomicWriteFailed(reason: String(describing: type(of: error)))
        }
    }

    /// Atomically replaces `destination` with `source` (rename semantics).
    public static func atomicReplace(from source: URL, to destination: URL) throws {
        let fm = FileManager.default
        do {
            if fm.fileExists(atPath: destination.path) {
                _ = try fm.replaceItemAt(destination, withItemAt: source)
            } else {
                try fm.moveItem(at: source, to: destination)
            }
        } catch {
            throw StorageError.atomicWriteFailed(reason: "replace failed")
        }
    }

    /// Sweeps stale temp files left by an interrupted write.
    public static func sweepStaleTempFiles(in directory: URL) {
        let fm = FileManager.default
        guard let names = try? fm.contentsOfDirectory(atPath: directory.path) else { return }
        for name in names where name.hasPrefix(".zyquo-tmp-") {
            try? fm.removeItem(at: directory.appendingPathComponent(name))
        }
    }
}
