import Foundation
import ZyquoVaultCrypto

/// The vault header: a versioned, canonical **binary** structure (no JSON —
/// CLAUDE.md §6.3) holding identity, KDF parameters, and the wrapped VMK.
///
/// Byte layout v1 — all integers big-endian (full table in docs/vault-format.md):
/// ```
/// offset  size  field
/// 0       4     magic "ZYQV"
/// 4       4     formatVersion        (currently 1)
/// 8       4     minReaderVersion     (currently 1)
/// 12      16    vault UUID
/// 28      8     createdAt   (unix seconds, unsigned)
/// 36      8     updatedAt   (unix seconds, unsigned)
/// 44      4     kdf id               (1 = Argon2id v19)
/// 48      1     salt length S        (16…64)
/// 49      S     salt
/// …       4     Argon2 memoryKiB
/// …       4     Argon2 iterations
/// …       4     Argon2 parallelism
/// …       1     Argon2 output length (32…64)
/// …       4     key-wrap algorithm   (1 = AES-256-GCM)
/// …       12    wrap nonce
/// …       4     wrapped-VMK ciphertext length C (== VMK length, 32)
/// …       C     wrapped-VMK ciphertext
/// …       16    wrap tag
/// …       4     feature flags        (0 for v1; unknown bits ⇒ reject)
/// …       1     header-auth version  (1 = HMAC-SHA256 via header-auth subkey)
/// …       32    header-auth tag      (over every preceding byte)
/// ```
///
/// Authentication model (documented in docs/cryptography.md):
/// - Salt/KDF-parameter tampering ⇒ a different PKEK ⇒ the authenticated VMK
///   unwrap fails (AES-GCM tag) ⇒ fail closed.
/// - The wrapped VMK is bound by AAD to the vault UUID + format version.
/// - All remaining fields (timestamps, flags, versions) are covered by an
///   HMAC-SHA256 whose key is HKDF-derived from the VMK (`header-auth` context),
///   verified immediately after a successful unwrap.
public struct VaultHeader: Equatable, Sendable {
    public static let magic: [UInt8] = Array("ZYQV".utf8)
    public static let currentFormatVersion: UInt32 = 1
    public static let currentMinReaderVersion: UInt32 = 1
    public static let kdfArgon2id: UInt32 = 1
    public static let headerAuthVersion: UInt8 = 1
    public static let headerAuthTagLength = 32
    /// DoS guard: no legitimate v1 header is larger than this.
    public static let maximumEncodedLength = 4096

    public var formatVersion: UInt32
    public var minReaderVersion: UInt32
    public var vaultID: UUID
    public var createdAt: UInt64
    public var updatedAt: UInt64
    public var wrappedVMK: KeyHierarchy.WrappedVMK
    public var featureFlags: UInt32
    /// HMAC-SHA256 over the serialized header body; empty until sealed.
    public var headerAuthTag: Data

    public init(
        vaultID: UUID,
        createdAt: UInt64,
        updatedAt: UInt64,
        wrappedVMK: KeyHierarchy.WrappedVMK,
        featureFlags: UInt32 = 0,
        formatVersion: UInt32 = VaultHeader.currentFormatVersion,
        minReaderVersion: UInt32 = VaultHeader.currentMinReaderVersion,
        headerAuthTag: Data = Data()
    ) {
        self.formatVersion = formatVersion
        self.minReaderVersion = minReaderVersion
        self.vaultID = vaultID
        self.createdAt = createdAt
        self.updatedAt = updatedAt
        self.wrappedVMK = wrappedVMK
        self.featureFlags = featureFlags
        self.headerAuthTag = headerAuthTag
    }

    // MARK: Serialization

    /// Serializes every field except the trailing auth version + tag.
    public func encodedBody() -> Data {
        var d = Data(capacity: 256)
        d.append(contentsOf: Self.magic)
        appendBigEndian(formatVersion, to: &d)
        appendBigEndian(minReaderVersion, to: &d)
        withUnsafeBytes(of: vaultID.uuid) { d.append(contentsOf: $0) }
        appendBigEndian(createdAt, to: &d)
        appendBigEndian(updatedAt, to: &d)
        appendBigEndian(Self.kdfArgon2id, to: &d)
        d.append(UInt8(wrappedVMK.kdfSalt.count))
        d.append(contentsOf: wrappedVMK.kdfSalt)
        appendBigEndian(wrappedVMK.kdfParameters.memoryKiB, to: &d)
        appendBigEndian(wrappedVMK.kdfParameters.iterations, to: &d)
        appendBigEndian(wrappedVMK.kdfParameters.parallelism, to: &d)
        d.append(UInt8(wrappedVMK.kdfParameters.outputLength))
        appendBigEndian(wrappedVMK.sealed.algorithm.rawValue, to: &d)
        d.append(wrappedVMK.sealed.nonce)
        appendBigEndian(UInt32(wrappedVMK.sealed.ciphertext.count), to: &d)
        d.append(wrappedVMK.sealed.ciphertext)
        d.append(wrappedVMK.sealed.tag)
        appendBigEndian(featureFlags, to: &d)
        return d
    }

    /// Full canonical encoding: body ‖ authVersion ‖ authTag.
    public func encoded() throws -> Data {
        guard headerAuthTag.count == Self.headerAuthTagLength else {
            throw StorageError.invalidHeader(reason: "header not sealed (missing auth tag)")
        }
        var d = encodedBody()
        d.append(Self.headerAuthVersion)
        d.append(headerAuthTag)
        return d
    }

    // MARK: Parsing (strict — rejects malformed input without crashing)

    public static func decode(_ data: Data) throws -> VaultHeader {
        var reader = BinaryReader(data)
        func fail(_ reason: String) -> StorageError { .invalidHeader(reason: reason) }

        guard data.count <= maximumEncodedLength else { throw fail("oversized header") }
        guard try reader.bytes(4).elementsEqual(magic) else { throw fail("bad magic") }
        let formatVersion: UInt32 = try reader.integer()
        let minReader: UInt32 = try reader.integer()
        guard minReader >= 1, minReader <= formatVersion else { throw fail("invalid version pair") }
        guard minReader <= currentFormatVersion else {
            throw StorageError.unsupportedFormatVersion(found: formatVersion, minimumReader: minReader)
        }
        let vaultID = try reader.uuid()
        let createdAt: UInt64 = try reader.integer()
        let updatedAt: UInt64 = try reader.integer()
        let kdfID: UInt32 = try reader.integer()
        guard kdfID == kdfArgon2id else { throw fail("unsupported KDF id \(kdfID)") }
        let saltLen = Int(try reader.byte())
        guard saltLen >= Argon2id.Floor.saltLength, saltLen <= Argon2id.Ceiling.saltLength else {
            throw fail("salt length out of range")
        }
        let salt = Array(try reader.bytes(saltLen))
        let memoryKiB: UInt32 = try reader.integer()
        let iterations: UInt32 = try reader.integer()
        let parallelism: UInt32 = try reader.integer()
        let outputLength = Int(try reader.byte())
        let params = Argon2id.Parameters(
            memoryKiB: memoryKiB, iterations: iterations,
            parallelism: parallelism, outputLength: outputLength
        )
        // Reject below-floor and DoS-scale KDF params before any derivation.
        do { try params.validate() } catch { throw fail("KDF parameters out of range") }

        let algorithmRaw: UInt32 = try reader.integer()
        guard let algorithm = AEADAlgorithm(rawValue: algorithmRaw) else {
            throw fail("unsupported key-wrap algorithm \(algorithmRaw)")
        }
        let nonce = try reader.bytes(SealedMessage.nonceLength)
        let ciphertextLen = Int(try reader.integer() as UInt32)
        guard ciphertextLen == 32 else { throw fail("wrapped-VMK length must be 32") }
        let ciphertext = try reader.bytes(ciphertextLen)
        let tag = try reader.bytes(SealedMessage.tagLength)
        let flags: UInt32 = try reader.integer()
        guard flags == 0 else { throw fail("unknown mandatory feature flags") }
        let authVersion = try reader.byte()
        guard authVersion == headerAuthVersion else { throw fail("unsupported header-auth version") }
        let authTag = try reader.bytes(headerAuthTagLength)
        guard reader.isAtEnd else { throw fail("trailing bytes after header") }

        let wrapped = KeyHierarchy.WrappedVMK(
            kdfSalt: salt,
            kdfParameters: params,
            sealed: SealedMessage(algorithm: algorithm, nonce: nonce, ciphertext: ciphertext, tag: tag)
        )
        return VaultHeader(
            vaultID: vaultID, createdAt: createdAt, updatedAt: updatedAt,
            wrappedVMK: wrapped, featureFlags: flags,
            formatVersion: formatVersion, minReaderVersion: minReader,
            headerAuthTag: authTag
        )
    }
}

/// Bounds-checked big-endian reader; every overrun throws instead of crashing.
struct BinaryReader {
    private let data: Data
    private var offset: Int

    init(_ data: Data) {
        self.data = Data(data) // rebase to zero-based indices
        self.offset = 0
    }

    var isAtEnd: Bool { offset == data.count }

    mutating func byte() throws -> UInt8 {
        guard offset + 1 <= data.count else { throw StorageError.invalidHeader(reason: "truncated") }
        defer { offset += 1 }
        return data[offset]
    }

    mutating func bytes(_ count: Int) throws -> Data {
        guard count >= 0, offset + count <= data.count else {
            throw StorageError.invalidHeader(reason: "truncated")
        }
        defer { offset += count }
        return data.subdata(in: offset..<(offset + count))
    }

    mutating func integer<T: FixedWidthInteger>() throws -> T {
        let raw = try bytes(MemoryLayout<T>.size)
        return raw.withUnsafeBytes { $0.loadUnaligned(as: T.self).bigEndian }
    }

    mutating func uuid() throws -> UUID {
        let raw = try bytes(16)
        return raw.withUnsafeBytes { UUID(uuid: $0.loadUnaligned(as: uuid_t.self)) }
    }
}
