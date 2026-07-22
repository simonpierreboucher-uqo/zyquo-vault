import Foundation

/// Algorithm identifiers persisted in headers and AAD. Never renumber.
public enum AEADAlgorithm: UInt32, Sendable, Codable {
    case aes256gcm = 1
}

/// Object type identifiers used in AAD binding. Never renumber.
public enum BoundObjectType: UInt32, Sendable {
    case vaultHeaderVMK = 1
    case record = 2
    case attachmentChunk = 3
    case manifest = 4
    case backup = 5
    case recoveryVMK = 6
}

/// Canonical associated-data encoding, version 1 (CLAUDE.md §5.5).
///
/// Byte layout — fixed 57 bytes, all integers big-endian
/// (full table in docs/cryptography.md §AAD):
/// ```
/// offset  size  field
/// 0       4     magic "ZQAD"
/// 4       1     aadVersion  = 0x01
/// 5       16    vault UUID  (RFC 4122 byte order)
/// 21      16    object UUID (RFC 4122 byte order)
/// 37      4     objectType  (BoundObjectType raw value)
/// 41      4     schemaVersion
/// 45      8     revision
/// 53      4     algorithm   (AEADAlgorithm raw value)
/// ```
public struct AssociatedData: Equatable, Sendable {
    public static let magic: [UInt8] = Array("ZQAD".utf8)
    public static let aadVersion: UInt8 = 1
    public static let encodedLength = 57

    public var vaultID: UUID
    public var objectID: UUID
    public var objectType: BoundObjectType
    public var schemaVersion: UInt32
    public var revision: UInt64
    public var algorithm: AEADAlgorithm

    public init(
        vaultID: UUID,
        objectID: UUID,
        objectType: BoundObjectType,
        schemaVersion: UInt32,
        revision: UInt64,
        algorithm: AEADAlgorithm = .aes256gcm
    ) {
        self.vaultID = vaultID
        self.objectID = objectID
        self.objectType = objectType
        self.schemaVersion = schemaVersion
        self.revision = revision
        self.algorithm = algorithm
    }

    /// Deterministic canonical encoding — identical input always yields identical bytes.
    public func encoded() -> Data {
        var data = Data(capacity: Self.encodedLength)
        data.append(contentsOf: Self.magic)
        data.append(Self.aadVersion)
        withUnsafeBytes(of: vaultID.uuid) { data.append(contentsOf: $0) }
        withUnsafeBytes(of: objectID.uuid) { data.append(contentsOf: $0) }
        appendBigEndian(objectType.rawValue, to: &data)
        appendBigEndian(schemaVersion, to: &data)
        appendBigEndian(revision, to: &data)
        appendBigEndian(algorithm.rawValue, to: &data)
        assert(data.count == Self.encodedLength)
        return data
    }
}

/// Canonical big-endian integer append, shared by every serialized structure.
@inline(__always)
public func appendBigEndian<T: FixedWidthInteger>(_ value: T, to data: inout Data) {
    withUnsafeBytes(of: value.bigEndian) { data.append(contentsOf: $0) }
}
