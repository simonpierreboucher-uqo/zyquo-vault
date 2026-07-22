import CryptoKit
import Foundation
import ZyquoVaultCrypto

/// The encrypted, authenticated vault inventory (CLAUDE.md §6.4). Names and
/// counts are sensitive, so the whole payload is ciphertext; only the generation
/// number is public (it feeds the AAD and rollback checks).
///
/// File layout v1 (`vault.manifest`) — integers big-endian:
/// ```
/// offset  size  field
/// 0       4     magic "ZYQM"
/// 4       4     manifest format version (1)
/// 8       8     generation
/// 16      12    nonce
/// 28      8     ciphertext length N (≤ 8 MiB)
/// 36      N     ciphertext (JSON payload below, inside the encryption boundary)
/// 36+N    16    GCM tag
/// ```
/// AAD: (vault UUID, vault UUID, type=manifest, schema=1, revision=generation).
/// The plaintext repeats vault UUID and generation; both must match the outer
/// values or the manifest is rejected.
public struct VaultManifest: Codable, Equatable, Sendable {
    public static let magic: [UInt8] = Array("ZYQM".utf8)
    public static let currentVersion: UInt32 = 1
    public static let maximumCiphertextLength = 8 * 1024 * 1024
    public static let fileName = "vault.manifest"

    public struct RecordEntry: Codable, Equatable, Sendable {
        public var id: UUID
        public var revision: UInt64
        public var schemaVersion: UInt32

        public init(id: UUID, revision: UInt64, schemaVersion: UInt32) {
            self.id = id
            self.revision = revision
            self.schemaVersion = schemaVersion
        }
    }

    public struct Tombstone: Codable, Equatable, Sendable {
        public var id: UUID
        public var deletedAt: UInt64

        public init(id: UUID, deletedAt: UInt64) {
            self.id = id
            self.deletedAt = deletedAt
        }
    }

    public var vaultID: UUID
    public var generation: UInt64
    public var records: [RecordEntry]
    public var attachments: [RecordEntry]
    public var tombstones: [Tombstone]
    public var lastTransactionID: UUID?
    /// SHA-256 of the previous manifest file's full bytes — rollback-detection
    /// chain (verifiable when the previous file is available, e.g. in backups).
    public var previousManifestDigest: Data?
    public var updatedAt: UInt64

    public init(
        vaultID: UUID,
        generation: UInt64,
        records: [RecordEntry] = [],
        attachments: [RecordEntry] = [],
        tombstones: [Tombstone] = [],
        lastTransactionID: UUID? = nil,
        previousManifestDigest: Data? = nil,
        updatedAt: UInt64
    ) {
        self.vaultID = vaultID
        self.generation = generation
        self.records = records
        self.attachments = attachments
        self.tombstones = tombstones
        self.lastTransactionID = lastTransactionID
        self.previousManifestDigest = previousManifestDigest
        self.updatedAt = updatedAt
    }

    public func entry(for id: UUID) -> RecordEntry? {
        records.first { $0.id == id }
    }

    // MARK: Sealing / opening

    static func aad(vaultID: UUID, generation: UInt64) -> AssociatedData {
        AssociatedData(
            vaultID: vaultID, objectID: vaultID, objectType: .manifest,
            schemaVersion: currentVersion, revision: generation
        )
    }

    /// Serializes and encrypts under the manifest-protection subkey.
    public func sealedFileData(
        manifestKey: SymmetricKey,
        random: SecureRandomSource = SystemSecureRandom()
    ) throws -> Data {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys] // stable bytes inside the boundary
        let plaintext = try encoder.encode(self)
        let sealed = try AEADEngine(random: random).seal(
            plaintext: plaintext, key: manifestKey,
            aad: Self.aad(vaultID: vaultID, generation: generation)
        )
        var d = Data(capacity: 36 + sealed.ciphertext.count + 16)
        d.append(contentsOf: Self.magic)
        appendBigEndian(Self.currentVersion, to: &d)
        appendBigEndian(generation, to: &d)
        d.append(sealed.nonce)
        appendBigEndian(UInt64(sealed.ciphertext.count), to: &d)
        d.append(sealed.ciphertext)
        d.append(sealed.tag)
        return d
    }

    /// Parses, decrypts, and cross-checks a manifest file. Fails closed.
    public static func decode(
        _ data: Data,
        vaultID: UUID,
        manifestKey: SymmetricKey
    ) throws -> VaultManifest {
        func fail(_ reason: String) -> StorageError { .invalidManifest(reason: reason) }
        var reader = BinaryReader(data)
        do {
            guard data.count <= 64 + maximumCiphertextLength else { throw fail("oversized") }
            guard try reader.bytes(4).elementsEqual(magic) else { throw fail("bad magic") }
            let version: UInt32 = try reader.integer()
            guard version == currentVersion else { throw fail("unsupported version \(version)") }
            let generation: UInt64 = try reader.integer()
            let nonce = try reader.bytes(SealedMessage.nonceLength)
            let length: UInt64 = try reader.integer()
            guard length <= UInt64(maximumCiphertextLength) else { throw fail("oversized ciphertext") }
            let ciphertext = try reader.bytes(Int(length))
            let tag = try reader.bytes(SealedMessage.tagLength)
            guard reader.isAtEnd else { throw fail("trailing bytes") }

            let sealed = SealedMessage(algorithm: .aes256gcm, nonce: nonce, ciphertext: ciphertext, tag: tag)
            let plaintext: Data
            do {
                plaintext = try AEADEngine().open(
                    sealed, key: manifestKey, aad: aad(vaultID: vaultID, generation: generation)
                )
            } catch {
                throw fail("authentication failed")
            }
            let manifest = try JSONDecoder().decode(VaultManifest.self, from: plaintext)
            guard manifest.vaultID == vaultID else { throw fail("vault UUID mismatch") }
            guard manifest.generation == generation else { throw fail("generation mismatch") }
            return manifest
        } catch let error as StorageError {
            throw error
        } catch {
            throw fail("malformed")
        }
    }
}
