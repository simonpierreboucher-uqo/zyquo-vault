import Foundation

/// Crash-safe transaction journal (CLAUDE.md §6.5). One JSON file per in-flight
/// multi-file transaction under `journal/`; it contains **no plaintext secrets**
/// — only UUIDs, generations, and paths.
///
/// Write protocol (the atomic manifest replacement is the commit point):
///
/// PUT   1. journal entry written (state "begun", old/new generation)
///       2. new record ciphertext written to `records/<uuid>.zyqrec.pending`
///       3. manifest (generation+1, updated entry) atomically replaced  ← COMMIT
///       4. pending file atomically renamed over `records/<uuid>.zyqrec`
///       5. journal entry deleted
///
/// DELETE 1. journal entry (state "begun")
///        2. manifest without the entry (+tombstone) atomically replaced ← COMMIT
///        3. record file deleted
///        4. journal entry deleted
///
/// Recovery on open, per surviving entry: if the on-disk manifest generation
/// reached `newGeneration`, the transaction committed → roll FORWARD (finish
/// steps 4/3). Otherwise it never committed → roll BACK (remove the pending
/// file; the previous record file and manifest are untouched and consistent).
/// The last known valid state is never auto-discarded.
public struct JournalEntry: Codable, Equatable, Sendable {
    public enum Operation: String, Codable, Sendable {
        case put
        case delete
    }

    public var transactionID: UUID
    public var operation: Operation
    public var recordID: UUID
    public var previousGeneration: UInt64
    public var newGeneration: UInt64
    public var timestamp: UInt64
}

public enum TransactionJournal {
    public static let directoryName = "journal"

    static func directory(in vaultDirectory: URL) -> URL {
        vaultDirectory.appendingPathComponent(directoryName)
    }

    static func url(for entry: JournalEntry, in vaultDirectory: URL) -> URL {
        directory(in: vaultDirectory).appendingPathComponent("\(entry.transactionID.uuidString).zyqjournal")
    }

    public static func begin(_ entry: JournalEntry, in vaultDirectory: URL) throws {
        let dir = directory(in: vaultDirectory)
        try FileManager.default.createDirectory(
            at: dir, withIntermediateDirectories: true,
            attributes: [.posixPermissions: 0o700]
        )
        let data = try JSONEncoder().encode(entry)
        try AtomicFileWriter.write(data, to: url(for: entry, in: vaultDirectory))
    }

    public static func complete(_ entry: JournalEntry, in vaultDirectory: URL) {
        try? FileManager.default.removeItem(at: url(for: entry, in: vaultDirectory))
    }

    /// All surviving (incomplete) entries, oldest first.
    public static func pendingEntries(in vaultDirectory: URL) -> [JournalEntry] {
        let dir = directory(in: vaultDirectory)
        guard let names = try? FileManager.default.contentsOfDirectory(atPath: dir.path) else { return [] }
        return names
            .filter { $0.hasSuffix(".zyqjournal") }
            .compactMap { name -> JournalEntry? in
                guard let data = try? Data(contentsOf: dir.appendingPathComponent(name)) else { return nil }
                return try? JSONDecoder().decode(JournalEntry.self, from: data)
            }
            .sorted { $0.timestamp < $1.timestamp }
    }
}
