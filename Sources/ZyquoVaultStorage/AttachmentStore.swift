import CryptoKit
import Foundation
import ZyquoVaultCrypto

/// Chunked authenticated attachment encryption (§10.8, `attachments/<uuid>.zyqatt`).
///
/// Layout — integers big-endian (docs/vault-format.md §Attachments):
/// ```
/// 0    4    magic "ZYQA"
/// 4    4    format version (1)
/// 8    16   attachment UUID
/// 24   4    schema version (1)
/// 28   12   DEK-wrap nonce
/// 40   4    DEK ciphertext length (must be 32)
/// 44   32   DEK ciphertext (wrapped by the attachment-wrapping HKDF subkey)
/// 76   16   DEK-wrap GCM tag
/// 92   …    chunks, each: UInt32 ciphertext length ‖ 12-byte nonce ‖ ciphertext ‖ 16-byte tag
/// …    …    metadata block (same framing as a chunk; JSON under the DEK)
/// end-8 8   metadata block offset
/// ```
///
/// AAD binding uses the canonical structure with object type `attachmentChunk`
/// and the **revision slot carrying the section index**: chunk i → i,
/// metadata → 2⁶⁴−2, DEK wrap → 2⁶⁴−1. A chunk moved, reordered, or copied
/// from another attachment fails authentication.
///
/// Files are processed in `chunkSize` pieces — never whole-file in memory.
public enum AttachmentStore {

    public static let magic: [UInt8] = Array("ZYQA".utf8)
    public static let formatVersion: UInt32 = 1
    public static let schemaVersion: UInt32 = 1
    public static let defaultChunkSize = 1 << 20          // 1 MiB plaintext
    public static let maximumChunks = 1 << 20             // 1 TiB at 1 MiB chunks
    static let dekWrapIndex = UInt64.max
    static let metadataIndex = UInt64.max - 1

    /// Encrypted (inside the metadata block) attachment descriptor.
    public struct Metadata: Codable, Equatable, Sendable {
        public var originalFilename: String
        public var mimeType: String
        public var totalPlaintextSize: UInt64
        public var chunkCount: UInt32
        public var chunkSize: UInt32
        /// SHA-256 over the whole chunk region (framing + ciphertexts).
        public var ciphertextDigest: Data
    }

    static func aad(vaultID: UUID, attachmentID: UUID, index: UInt64) -> AssociatedData {
        AssociatedData(
            vaultID: vaultID, objectID: attachmentID, objectType: .attachmentChunk,
            schemaVersion: schemaVersion, revision: index
        )
    }

    // MARK: Encryption (streamed)

    /// Encrypts `sourceURL` into `destinationURL` (temp-file + atomic rename is
    /// the caller's job — this writes the final bytes to the given handle path).
    public static func encrypt(
        sourceURL: URL,
        to destinationURL: URL,
        vaultID: UUID,
        attachmentID: UUID,
        attachmentKey: SymmetricKey,
        mimeType: String,
        chunkSize: Int = defaultChunkSize,
        random: SecureRandomSource = SystemSecureRandom()
    ) throws -> Metadata {
        guard chunkSize >= 4096, chunkSize <= 8 << 20 else {
            throw StorageError.atomicWriteFailed(reason: "invalid chunk size")
        }
        let engine = AEADEngine(random: random)
        let dek = try random.secureBytes(count: 32)
        defer { dek.wipe() }
        let dekKey = dek.withUnsafeBytes { SymmetricKey(data: Data($0)) }

        FileManager.default.createFile(
            atPath: destinationURL.path, contents: nil,
            attributes: [.posixPermissions: 0o600]
        )
        guard let output = FileHandle(forWritingAtPath: destinationURL.path),
              let input = FileHandle(forReadingAtPath: sourceURL.path) else {
            throw StorageError.atomicWriteFailed(reason: "attachment IO open failed")
        }
        defer {
            try? input.close()
            try? output.close()
        }

        // Header + wrapped DEK.
        var header = Data()
        header.append(contentsOf: magic)
        appendBigEndian(formatVersion, to: &header)
        withUnsafeBytes(of: attachmentID.uuid) { header.append(contentsOf: $0) }
        appendBigEndian(schemaVersion, to: &header)
        let wrappedDEK = try engine.seal(
            plaintext: dek.withUnsafeBytes { Data($0) },
            key: attachmentKey,
            aad: aad(vaultID: vaultID, attachmentID: attachmentID, index: dekWrapIndex)
        )
        header.append(wrappedDEK.nonce)
        appendBigEndian(UInt32(wrappedDEK.ciphertext.count), to: &header)
        header.append(wrappedDEK.ciphertext)
        header.append(wrappedDEK.tag)
        try output.write(contentsOf: header)

        // Chunks (streamed).
        var digest = SHA256()
        var totalPlaintext: UInt64 = 0
        var chunkIndex: UInt64 = 0
        while true {
            let plaintext = try input.read(upToCount: chunkSize) ?? Data()
            if plaintext.isEmpty && chunkIndex > 0 { break }
            let sealed = try engine.seal(
                plaintext: plaintext, key: dekKey,
                aad: aad(vaultID: vaultID, attachmentID: attachmentID, index: chunkIndex)
            )
            var frame = Data()
            appendBigEndian(UInt32(sealed.ciphertext.count), to: &frame)
            frame.append(sealed.nonce)
            frame.append(sealed.ciphertext)
            frame.append(sealed.tag)
            try output.write(contentsOf: frame)
            digest.update(data: frame)
            totalPlaintext += UInt64(plaintext.count)
            chunkIndex += 1
            if plaintext.count < chunkSize { break } // final (possibly empty) chunk
            guard chunkIndex < maximumChunks else {
                throw StorageError.atomicWriteFailed(reason: "attachment too large")
            }
        }

        // Metadata block + offset trailer.
        let metadata = Metadata(
            originalFilename: sourceURL.lastPathComponent,
            mimeType: mimeType,
            totalPlaintextSize: totalPlaintext,
            chunkCount: UInt32(chunkIndex),
            chunkSize: UInt32(chunkSize),
            ciphertextDigest: Data(digest.finalize())
        )
        let metadataOffset = try output.offset()
        let sealedMetadata = try engine.seal(
            plaintext: try JSONEncoder().encode(metadata), key: dekKey,
            aad: aad(vaultID: vaultID, attachmentID: attachmentID, index: metadataIndex)
        )
        var tail = Data()
        appendBigEndian(UInt32(sealedMetadata.ciphertext.count), to: &tail)
        tail.append(sealedMetadata.nonce)
        tail.append(sealedMetadata.ciphertext)
        tail.append(sealedMetadata.tag)
        appendBigEndian(metadataOffset, to: &tail)
        try output.write(contentsOf: tail)
        return metadata
    }

    // MARK: Decryption (streamed)

    /// Reads and authenticates only the metadata block.
    public static func readMetadata(
        at fileURL: URL,
        vaultID: UUID,
        attachmentID: UUID,
        attachmentKey: SymmetricKey
    ) throws -> Metadata {
        guard let input = FileHandle(forReadingAtPath: fileURL.path) else {
            throw StorageError.corruptedRecord(attachmentID)
        }
        defer { try? input.close() }
        let dekKey = try unwrapDEK(input, vaultID: vaultID, attachmentID: attachmentID, attachmentKey: attachmentKey)
        return try readMetadataBlock(input, vaultID: vaultID, attachmentID: attachmentID, dekKey: dekKey).metadata
    }

    /// Streams the decrypted plaintext to `destinationURL` (created 0600).
    /// Every chunk is authenticated before its plaintext is written; ordering is
    /// enforced by the per-chunk AAD; the ciphertext digest is cross-checked.
    public static func decrypt(
        fileURL: URL,
        to destinationURL: URL,
        vaultID: UUID,
        attachmentID: UUID,
        attachmentKey: SymmetricKey
    ) throws -> Metadata {
        let engine = AEADEngine()
        guard let input = FileHandle(forReadingAtPath: fileURL.path) else {
            throw StorageError.corruptedRecord(attachmentID)
        }
        defer { try? input.close() }

        let dekKey = try unwrapDEK(input, vaultID: vaultID, attachmentID: attachmentID, attachmentKey: attachmentKey)
        let (metadata, chunkRegionEnd) = try readMetadataBlock(
            input, vaultID: vaultID, attachmentID: attachmentID, dekKey: dekKey
        )

        FileManager.default.createFile(
            atPath: destinationURL.path, contents: nil,
            attributes: [.posixPermissions: 0o600]
        )
        guard let output = FileHandle(forWritingAtPath: destinationURL.path) else {
            throw StorageError.atomicWriteFailed(reason: "temp file open failed")
        }
        defer { try? output.close() }

        try input.seek(toOffset: chunkRegionStart)
        var digest = SHA256()
        var written: UInt64 = 0
        for index in 0..<UInt64(metadata.chunkCount) {
            let frame = try readFrame(
                input, attachmentID: attachmentID,
                notBeyond: chunkRegionEnd
            )
            digest.update(data: frame.raw)
            let plaintext: Data
            do {
                plaintext = try engine.open(
                    frame.sealed, key: dekKey,
                    aad: aad(vaultID: vaultID, attachmentID: attachmentID, index: index)
                )
            } catch {
                try? FileManager.default.removeItem(at: destinationURL) // no partial plaintext
                throw StorageError.corruptedRecord(attachmentID)
            }
            try output.write(contentsOf: plaintext)
            written += UInt64(plaintext.count)
        }
        guard try input.offset() == chunkRegionEnd,
              written == metadata.totalPlaintextSize,
              constantTimeEquals(Data(digest.finalize()), metadata.ciphertextDigest) else {
            try? FileManager.default.removeItem(at: destinationURL)
            throw StorageError.corruptedRecord(attachmentID)
        }
        return metadata
    }

    /// Full authentication pass without writing plaintext anywhere.
    public static func verify(
        fileURL: URL,
        vaultID: UUID,
        attachmentID: UUID,
        attachmentKey: SymmetricKey
    ) throws {
        let scratch = FileManager.default.temporaryDirectory
            .appendingPathComponent(".zyquo-verify-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: scratch) }
        _ = try decrypt(
            fileURL: fileURL, to: scratch,
            vaultID: vaultID, attachmentID: attachmentID, attachmentKey: attachmentKey
        )
    }

    // MARK: Internals

    static let chunkRegionStart: UInt64 = 92

    private static func unwrapDEK(
        _ input: FileHandle,
        vaultID: UUID,
        attachmentID: UUID,
        attachmentKey: SymmetricKey
    ) throws -> SymmetricKey {
        func fail() -> StorageError { .corruptedRecord(attachmentID) }
        try input.seek(toOffset: 0)
        guard let headerData = try input.read(upToCount: Int(chunkRegionStart)),
              headerData.count == Int(chunkRegionStart) else { throw fail() }
        var reader = BinaryReader(headerData)
        do {
            guard try reader.bytes(4).elementsEqual(magic) else { throw fail() }
            let version: UInt32 = try reader.integer()
            guard version == formatVersion else { throw fail() }
            let storedID = try reader.uuid()
            guard storedID == attachmentID else { throw fail() }
            let schema: UInt32 = try reader.integer()
            guard schema == schemaVersion else { throw fail() }
            let nonce = try reader.bytes(SealedMessage.nonceLength)
            let length = Int(try reader.integer() as UInt32)
            guard length == 32 else { throw fail() }
            let ciphertext = try reader.bytes(length)
            let tag = try reader.bytes(SealedMessage.tagLength)
            let dekBytes = try AEADEngine().open(
                SealedMessage(algorithm: .aes256gcm, nonce: nonce, ciphertext: ciphertext, tag: tag),
                key: attachmentKey,
                aad: aad(vaultID: vaultID, attachmentID: attachmentID, index: dekWrapIndex)
            )
            guard dekBytes.count == 32 else { throw fail() }
            let dek = SecureBytes(bytes: Array(dekBytes))
            defer { dek.wipe() }
            return dek.withUnsafeBytes { SymmetricKey(data: Data($0)) }
        } catch {
            throw fail()
        }
    }

    private static func readMetadataBlock(
        _ input: FileHandle,
        vaultID: UUID,
        attachmentID: UUID,
        dekKey: SymmetricKey
    ) throws -> (metadata: Metadata, chunkRegionEnd: UInt64) {
        func fail() -> StorageError { .corruptedRecord(attachmentID) }
        let fileSize = try input.seekToEnd()
        guard fileSize > chunkRegionStart + 8 else { throw fail() }
        try input.seek(toOffset: fileSize - 8)
        guard let offsetData = try input.read(upToCount: 8), offsetData.count == 8 else { throw fail() }
        let metadataOffset = offsetData.withUnsafeBytes { $0.loadUnaligned(as: UInt64.self).bigEndian }
        guard metadataOffset >= chunkRegionStart, metadataOffset < fileSize - 8 else { throw fail() }

        try input.seek(toOffset: metadataOffset)
        let frame = try readFrame(input, attachmentID: attachmentID, notBeyond: fileSize - 8)
        do {
            let plaintext = try AEADEngine().open(
                frame.sealed, key: dekKey,
                aad: aad(vaultID: vaultID, attachmentID: attachmentID, index: metadataIndex)
            )
            let metadata = try JSONDecoder().decode(Metadata.self, from: plaintext)
            guard metadata.chunkCount <= maximumChunks,
                  metadata.ciphertextDigest.count == 32 else { throw fail() }
            return (metadata, metadataOffset)
        } catch {
            throw fail()
        }
    }

    private static func readFrame(
        _ input: FileHandle,
        attachmentID: UUID,
        notBeyond limit: UInt64
    ) throws -> (sealed: SealedMessage, raw: Data) {
        func fail() -> StorageError { .corruptedRecord(attachmentID) }
        guard let lengthData = try input.read(upToCount: 4), lengthData.count == 4 else { throw fail() }
        let length = lengthData.withUnsafeBytes { $0.loadUnaligned(as: UInt32.self).bigEndian }
        guard length <= 16 << 20 else { throw fail() }
        let bodyCount = Int(length) + SealedMessage.nonceLength + SealedMessage.tagLength
        guard try input.offset() + UInt64(bodyCount) <= limit else { throw fail() }
        guard let body = try input.read(upToCount: bodyCount), body.count == bodyCount else { throw fail() }
        let nonce = body.prefix(SealedMessage.nonceLength)
        let ciphertext = body.dropFirst(SealedMessage.nonceLength).dropLast(SealedMessage.tagLength)
        let tag = body.suffix(SealedMessage.tagLength)
        return (
            SealedMessage(algorithm: .aes256gcm, nonce: Data(nonce), ciphertext: Data(ciphertext), tag: Data(tag)),
            lengthData + body
        )
    }
}
