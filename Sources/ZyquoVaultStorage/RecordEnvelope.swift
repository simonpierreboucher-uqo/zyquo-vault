import CryptoKit
import Foundation
import ZyquoVaultCrypto

/// A record file (`records/<uuid>.zyqrec`): independently authenticated, carrying
/// its own wrapped DEK so one record can be rewritten without touching the vault.
///
/// Byte layout v1 — all integers big-endian (docs/vault-format.md §Record):
/// ```
/// offset  size  field
/// 0       4     magic "ZYQR"
/// 4       4     envelope version        (1)
/// 8       16    record UUID
/// 24      4     schema version
/// 28      8     revision
/// 36      12    DEK-wrap nonce
/// 48      4     DEK ciphertext length   (must be 32)
/// 52      32    DEK ciphertext
/// 84      16    DEK-wrap GCM tag
/// 100     12    payload nonce
/// 112     8     payload ciphertext length N (≤ 16 MiB)
/// 120     N     payload ciphertext
/// 120+N   16    payload GCM tag
/// ```
///
/// Both seals use the same canonical AAD (vault UUID, record UUID, type=record,
/// schema version, revision) under two different keys: the HKDF record-wrapping
/// subkey for the DEK, and the DEK itself for the payload. Tampering with any
/// header field breaks both authentications; a swapped payload from another
/// record or revision fails its AAD check.
public struct RecordEnvelope: Equatable, Sendable {
    public static let magic: [UInt8] = Array("ZYQR".utf8)
    public static let currentVersion: UInt32 = 1
    /// DoS guard for a single record payload.
    public static let maximumPayloadLength = 16 * 1024 * 1024

    public var recordID: UUID
    public var schemaVersion: UInt32
    public var revision: UInt64
    public var wrappedDEK: SealedMessage
    public var payload: SealedMessage

    // MARK: Sealing / opening

    static func aad(vaultID: UUID, recordID: UUID, schemaVersion: UInt32, revision: UInt64) -> AssociatedData {
        AssociatedData(
            vaultID: vaultID, objectID: recordID, objectType: .record,
            schemaVersion: schemaVersion, revision: revision
        )
    }

    /// Encrypts `plaintext` under a fresh random DEK, wrapping the DEK with the
    /// record-wrapping subkey.
    public static func seal(
        plaintext: Data,
        vaultID: UUID,
        recordID: UUID,
        schemaVersion: UInt32,
        revision: UInt64,
        recordWrappingKey: SymmetricKey,
        random: SecureRandomSource = SystemSecureRandom()
    ) throws -> RecordEnvelope {
        let engine = AEADEngine(random: random)
        let aad = aad(vaultID: vaultID, recordID: recordID, schemaVersion: schemaVersion, revision: revision)
        let dek = try random.secureBytes(count: 32)
        defer { dek.wipe() }
        let dekKey = dek.withUnsafeBytes { SymmetricKey(data: Data($0)) }
        let payload = try engine.seal(plaintext: plaintext, key: dekKey, aad: aad)
        let wrappedDEK = try engine.seal(
            plaintext: dek.withUnsafeBytes { Data($0) },
            key: recordWrappingKey, aad: aad
        )
        return RecordEnvelope(
            recordID: recordID, schemaVersion: schemaVersion, revision: revision,
            wrappedDEK: wrappedDEK, payload: payload
        )
    }

    /// Unwraps the DEK and decrypts the payload. Fails closed with
    /// `StorageError.corruptedRecord` on any authentication failure.
    public func open(vaultID: UUID, recordWrappingKey: SymmetricKey) throws -> Data {
        let engine = AEADEngine()
        let aad = Self.aad(vaultID: vaultID, recordID: recordID, schemaVersion: schemaVersion, revision: revision)
        do {
            let dekBytes = try engine.open(wrappedDEK, key: recordWrappingKey, aad: aad)
            guard dekBytes.count == 32 else { throw StorageError.corruptedRecord(recordID) }
            let dek = SecureBytes(bytes: Array(dekBytes))
            defer { dek.wipe() }
            let dekKey = dek.withUnsafeBytes { SymmetricKey(data: Data($0)) }
            return try engine.open(payload, key: dekKey, aad: aad)
        } catch {
            throw StorageError.corruptedRecord(recordID)
        }
    }

    // MARK: Serialization

    public func encoded() -> Data {
        var d = Data(capacity: 160 + payload.ciphertext.count)
        d.append(contentsOf: Self.magic)
        appendBigEndian(Self.currentVersion, to: &d)
        withUnsafeBytes(of: recordID.uuid) { d.append(contentsOf: $0) }
        appendBigEndian(schemaVersion, to: &d)
        appendBigEndian(revision, to: &d)
        d.append(wrappedDEK.nonce)
        appendBigEndian(UInt32(wrappedDEK.ciphertext.count), to: &d)
        d.append(wrappedDEK.ciphertext)
        d.append(wrappedDEK.tag)
        d.append(payload.nonce)
        appendBigEndian(UInt64(payload.ciphertext.count), to: &d)
        d.append(payload.ciphertext)
        d.append(payload.tag)
        return d
    }

    public static func decode(_ data: Data, expectedRecordID: UUID? = nil) throws -> RecordEnvelope {
        func fail(_ id: UUID?) -> StorageError { .corruptedRecord(id ?? UUID(uuid: (0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0))) }
        var reader = BinaryReader(data)
        do {
            guard data.count <= 200 + maximumPayloadLength else { throw fail(expectedRecordID) }
            guard try reader.bytes(4).elementsEqual(magic) else { throw fail(expectedRecordID) }
            let version: UInt32 = try reader.integer()
            guard version == currentVersion else { throw fail(expectedRecordID) }
            let recordID = try reader.uuid()
            if let expected = expectedRecordID, recordID != expected { throw fail(expectedRecordID) }
            let schemaVersion: UInt32 = try reader.integer()
            let revision: UInt64 = try reader.integer()
            let dekNonce = try reader.bytes(SealedMessage.nonceLength)
            let dekLength = Int(try reader.integer() as UInt32)
            guard dekLength == 32 else { throw fail(recordID) }
            let dekCiphertext = try reader.bytes(dekLength)
            let dekTag = try reader.bytes(SealedMessage.tagLength)
            let payloadNonce = try reader.bytes(SealedMessage.nonceLength)
            let payloadLength64: UInt64 = try reader.integer()
            guard payloadLength64 <= UInt64(maximumPayloadLength) else { throw fail(recordID) }
            let payloadCiphertext = try reader.bytes(Int(payloadLength64))
            let payloadTag = try reader.bytes(SealedMessage.tagLength)
            guard reader.isAtEnd else { throw fail(recordID) }
            return RecordEnvelope(
                recordID: recordID, schemaVersion: schemaVersion, revision: revision,
                wrappedDEK: SealedMessage(algorithm: .aes256gcm, nonce: dekNonce, ciphertext: dekCiphertext, tag: dekTag),
                payload: SealedMessage(algorithm: .aes256gcm, nonce: payloadNonce, ciphertext: payloadCiphertext, tag: payloadTag)
            )
        } catch let error as StorageError {
            // Preserve corruptedRecord; map BinaryReader truncation errors too.
            if case .corruptedRecord = error { throw error }
            throw fail(expectedRecordID)
        } catch {
            throw fail(expectedRecordID)
        }
    }
}
