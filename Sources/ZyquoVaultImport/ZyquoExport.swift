import CryptoKit
import Foundation
import ZyquoVaultCrypto
import ZyquoVaultDomain

/// The encrypted Zyquo export container (`.zyquoexport`, §10.9) — the preferred
/// export format. Self-contained: protected by its **own** password (which may
/// differ from the vault's), so a recipient never learns vault keys.
///
/// Layout — integers big-endian (docs/vault-format.md §Export):
/// ```
/// 0    4    magic "ZYQX"
/// 4    4    format version (1)
/// 8    16   export UUID
/// 24   1    salt length S (16…64)
/// 25   S    Argon2id salt
/// 25+S 4/4/4/1  Argon2id memory KiB / iterations / parallelism / output length
/// …    12   nonce
/// …    8    ciphertext length N
/// …    N    ciphertext (JSON payload below)
/// …    16   GCM tag
/// ```
/// AAD: canonical structure with vaultID = objectID = export UUID, object
/// type 5 (backup/export), schema = format version, revision 0. The payload
/// carries items and folders; nothing else leaves the vault.
public enum ZyquoExport {

    public static let magic: [UInt8] = Array("ZYQX".utf8)
    public static let formatVersion: UInt32 = 1
    public static let fileExtension = "zyquoexport"
    public static let maximumCiphertext = 512 << 20

    public struct Payload: Codable, Equatable, Sendable {
        public var exportedAt: UInt64
        public var items: [VaultItem]
        public var folders: [VaultFolder]

        public init(exportedAt: UInt64, items: [VaultItem], folders: [VaultFolder]) {
            self.exportedAt = exportedAt
            self.items = items
            self.folders = folders
        }
    }

    static func aad(exportID: UUID) -> AssociatedData {
        AssociatedData(
            vaultID: exportID, objectID: exportID, objectType: .backup,
            schemaVersion: formatVersion, revision: 0
        )
    }

    /// Seals items + folders under a fresh KEK derived from `password`.
    public static func seal(
        payload: Payload,
        password: SecureBytes,
        parameters: Argon2id.Parameters = .baseline,
        random: SecureRandomSource = SystemSecureRandom()
    ) throws -> Data {
        guard password.count > 0 else {
            throw CryptoError.invalidParameter(reason: "an export password is required")
        }
        let exportID = UUID()
        let salt = try random.bytes(count: Argon2id.Floor.saltLength)
        let kek = try Argon2id.deriveKey(password: password, salt: salt, parameters: parameters)
        defer { kek.wipe() }
        let key = kek.withUnsafeBytes { SymmetricKey(data: Data($0)) }
        let sealed = try AEADEngine(random: random).seal(
            plaintext: try JSONEncoder().encode(payload),
            key: key,
            aad: aad(exportID: exportID)
        )

        var out = Data()
        out.append(contentsOf: magic)
        appendBigEndian(formatVersion, to: &out)
        withUnsafeBytes(of: exportID.uuid) { out.append(contentsOf: $0) }
        out.append(UInt8(salt.count))
        out.append(contentsOf: salt)
        appendBigEndian(parameters.memoryKiB, to: &out)
        appendBigEndian(parameters.iterations, to: &out)
        appendBigEndian(parameters.parallelism, to: &out)
        out.append(UInt8(parameters.outputLength))
        out.append(sealed.nonce)
        appendBigEndian(UInt64(sealed.ciphertext.count), to: &out)
        out.append(sealed.ciphertext)
        out.append(sealed.tag)
        return out
    }

    /// Opens an export. Wrong password ≡ corruption (one calm error).
    public static func open(_ data: Data, password: SecureBytes) throws -> Payload {
        func fail() -> CryptoError { .invalidPasswordOrCorruptedVault }
        var reader = ImportBinaryReader(data)
        do {
            guard try reader.bytes(4).elementsEqual(magic) else {
                throw ImportError.unrecognizedFormat(reason: "not a Zyquo export file")
            }
            let version: UInt32 = try reader.integer()
            guard version == formatVersion else {
                throw ImportError.unrecognizedFormat(reason: "unsupported export version \(version)")
            }
            let exportID = try reader.uuid()
            let saltLength = Int(try reader.byte())
            guard saltLength >= 16, saltLength <= 64 else { throw fail() }
            let salt = Array(try reader.bytes(saltLength))
            let parameters = Argon2id.Parameters(
                memoryKiB: try reader.integer(),
                iterations: try reader.integer(),
                parallelism: try reader.integer(),
                outputLength: Int(try reader.byte())
            )
            try parameters.validate() // DoS guard before any derivation
            let nonce = try reader.bytes(12)
            let length: UInt64 = try reader.integer()
            guard length <= UInt64(maximumCiphertext) else { throw fail() }
            let ciphertext = try reader.bytes(Int(length))
            let tag = try reader.bytes(16)
            guard reader.isAtEnd else { throw fail() }

            let kek = try Argon2id.deriveKey(password: password, salt: salt, parameters: parameters)
            defer { kek.wipe() }
            let key = kek.withUnsafeBytes { SymmetricKey(data: Data($0)) }
            let plaintext = try AEADEngine().open(
                SealedMessage(algorithm: .aes256gcm, nonce: nonce, ciphertext: ciphertext, tag: tag),
                key: key,
                aad: aad(exportID: exportID)
            )
            return try JSONDecoder().decode(Payload.self, from: plaintext)
        } catch let error as ImportError {
            throw error
        } catch {
            throw fail()
        }
    }
}

/// Bounds-checked big-endian reader for import formats (mirror of the storage
/// module's reader; kept separate to preserve module boundaries).
struct ImportBinaryReader {
    private let data: Data
    private var offset = 0

    init(_ data: Data) { self.data = Data(data) }

    var isAtEnd: Bool { offset == data.count }

    mutating func byte() throws -> UInt8 {
        guard offset < data.count else { throw ImportError.unreadableFile }
        defer { offset += 1 }
        return data[offset]
    }

    mutating func bytes(_ count: Int) throws -> Data {
        guard count >= 0, offset + count <= data.count else { throw ImportError.unreadableFile }
        defer { offset += count }
        return data.subdata(in: offset..<(offset + count))
    }

    mutating func integer<T: FixedWidthInteger>() throws -> T {
        try bytes(MemoryLayout<T>.size).withUnsafeBytes { $0.loadUnaligned(as: T.self).bigEndian }
    }

    mutating func uuid() throws -> UUID {
        try bytes(16).withUnsafeBytes { UUID(uuid: $0.loadUnaligned(as: uuid_t.self)) }
    }
}

/// Plaintext export (§10.9) — only ever produced behind the UI's explicit
/// warning-and-confirm flow. These functions just serialize.
public enum PlaintextExport {

    public static func json(items: [VaultItem], folders: [VaultFolder]) throws -> Data {
        struct Envelope: Encodable {
            var warning = "UNENCRYPTED Zyquo Vault export — delete after use. Anyone with this file has every secret in it."
            var items: [VaultItem]
            var folders: [VaultFolder]
        }
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        return try encoder.encode(Envelope(items: items, folders: folders))
    }

    public static func csv(items: [VaultItem]) -> Data {
        var lines = ["title,type,username,password,url,totp,notes,tags"]
        for item in items {
            func field(_ kind: VaultFieldKind) -> String {
                item.fields.first { $0.kind == kind }?.value.reveal() ?? ""
            }
            lines.append([
                item.title,
                item.itemType.rawValue,
                field(.username),
                field(.password),
                field(.url),
                field(.totpSeed),
                item.notes ?? "",
                item.tags.joined(separator: ";"),
            ].map(CSV.escape).joined(separator: ","))
        }
        return Data(lines.joined(separator: "\r\n").utf8)
    }
}
