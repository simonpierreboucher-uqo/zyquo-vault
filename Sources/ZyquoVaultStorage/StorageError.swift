import Foundation

/// Typed errors for the storage layer (CLAUDE.md §11.3).
public enum StorageError: Error, Equatable, Sendable {
    case vaultNotFound
    case permissionDenied
    case unsafePermissions(path: String, mode: UInt16)
    case fileLocked(ownerPID: Int32?)
    case invalidHeader(reason: String)
    case invalidManifest(reason: String)
    case transactionRecoveryRequired
    case atomicWriteFailed(reason: String)
    case corruptedRecord(UUID)
    /// Requested record is not in the manifest (no such item).
    case recordNotFound(UUID)
    /// Manifest lists the record but its file is absent — integrity failure.
    case missingRecord(UUID)
    case unsupportedFormatVersion(found: UInt32, minimumReader: UInt32)
}
