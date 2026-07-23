import CryptoKit
import Foundation
import Testing
@testable import ZyquoVaultCrypto
@testable import ZyquoVaultDomain
@testable import ZyquoVaultStorage

/// Deterministic PRNG (SplitMix64) so fuzz failures reproduce exactly.
struct FuzzRNG {
    var state: UInt64

    mutating func next() -> UInt64 {
        state &+= 0x9E3779B97F4A7C15
        var z = state
        z = (z ^ (z >> 30)) &* 0xBF58476D1CE4E5B9
        z = (z ^ (z >> 27)) &* 0x94D049BB133111EB
        return z ^ (z >> 31)
    }

    mutating func int(below bound: Int) -> Int {
        Int(next() % UInt64(bound))
    }

    mutating func bytes(_ count: Int) -> Data {
        var out = Data(capacity: count)
        for _ in 0..<count { out.append(UInt8(truncatingIfNeeded: next())) }
        return out
    }

    /// Mutations: byte flips, truncation, extension, splice, zero-fill.
    mutating func mutate(_ input: Data) -> Data {
        var data = input
        switch int(below: 5) {
        case 0 where !data.isEmpty: // flip 1–8 bytes
            for _ in 0...int(below: 8) {
                let index = int(below: data.count)
                data[data.startIndex + index] ^= UInt8(truncatingIfNeeded: next() | 1)
            }
        case 1 where data.count > 1: // truncate
            data = data.prefix(int(below: data.count))
        case 2: // extend with junk
            data.append(bytes(1 + int(below: 64)))
        case 3 where data.count > 8: // splice a random window with junk
            let start = int(below: data.count - 4)
            let length = min(1 + int(below: 32), data.count - start)
            data.replaceSubrange(
                (data.startIndex + start)..<(data.startIndex + start + length),
                with: bytes(length)
            )
        default: // fully random buffer
            data = bytes(1 + int(below: 512))
        }
        return data
    }
}

/// §12 fuzz targets: every persisted-format and import parser must reject
/// malformed input by *throwing*, never by crashing. All runs are seeded and
/// deterministic; a failure prints as a normal test failure with its input.
@Suite("Fuzz — parsers never crash", .serialized)
struct FuzzTests {

    static let params = Argon2id.Parameters(
        memoryKiB: Argon2id.Floor.memoryKiB,
        iterations: Argon2id.Floor.iterations,
        parallelism: 4
    )

    @Test func vaultHeaderParser() throws {
        // A valid header as mutation seed.
        let password = SecureBytes(utf8: "fuzz-password-not-real")
        let vaultID = UUID(uuidString: "00000000-0000-4000-8000-000000000001")!
        let (wrapped, vmk) = try KeyHierarchy.createVMK(
            password: password, vaultID: vaultID, formatVersion: 1, parameters: Self.params
        )
        defer { vmk.wipe() }
        var header = VaultHeader(vaultID: vaultID, createdAt: 1, updatedAt: 2, wrappedVMK: wrapped)
        header.headerAuthTag = VaultStore.headerAuthTag(for: header, vmk: vmk)
        let valid = try header.encoded()

        var rng = FuzzRNG(state: 0xDEAD_0001)
        for _ in 0..<400 {
            _ = try? VaultHeader.decode(rng.mutate(valid))
        }
        for _ in 0..<200 {
            _ = try? VaultHeader.decode(rng.bytes(1 + rng.int(below: 600)))
        }
    }

    @Test func manifestAndRecordParsers() throws {
        let vaultID = UUID(uuidString: "00000000-0000-4000-8000-000000000002")!
        let key = SymmetricKey(size: .bits256)
        let manifest = VaultManifest(vaultID: vaultID, generation: 3, updatedAt: 1)
        let validManifest = try manifest.sealedFileData(manifestKey: key)

        let recordKey = SymmetricKey(size: .bits256)
        let envelope = try RecordEnvelope.seal(
            plaintext: Data("fuzz-payload".utf8), vaultID: vaultID, recordID: UUID(),
            schemaVersion: 1, revision: 1, recordWrappingKey: recordKey
        )
        let validRecord = envelope.encoded()

        var rng = FuzzRNG(state: 0xDEAD_0002)
        for _ in 0..<400 {
            _ = try? VaultManifest.decode(rng.mutate(validManifest), vaultID: vaultID, manifestKey: key)
            _ = try? RecordEnvelope.decode(rng.mutate(validRecord))
        }
        for _ in 0..<200 {
            _ = try? VaultManifest.decode(rng.bytes(1 + rng.int(below: 400)), vaultID: vaultID, manifestKey: key)
            _ = try? RecordEnvelope.decode(rng.bytes(1 + rng.int(below: 400)))
        }
    }

    @Test func attachmentParser() throws {
        let vaultID = UUID(uuidString: "00000000-0000-4000-8000-000000000003")!
        let attachmentID = UUID(uuidString: "00000000-0000-4000-8000-000000000004")!
        let key = SymmetricKey(size: .bits256)
        let source = FileManager.default.temporaryDirectory
            .appendingPathComponent("zyquo-fuzz-src-\(UUID().uuidString)")
        try Data(repeating: 0xAB, count: 40_000).write(to: source)
        defer { try? FileManager.default.removeItem(at: source) }
        let sealed = FileManager.default.temporaryDirectory
            .appendingPathComponent("zyquo-fuzz-att-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: sealed) }
        _ = try AttachmentStore.encrypt(
            sourceURL: source, to: sealed, vaultID: vaultID, attachmentID: attachmentID,
            attachmentKey: key, mimeType: "application/octet-stream", chunkSize: 8192
        )
        let valid = try Data(contentsOf: sealed)

        var rng = FuzzRNG(state: 0xDEAD_0003)
        let scratch = FileManager.default.temporaryDirectory
            .appendingPathComponent("zyquo-fuzz-mut-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: scratch) }
        for _ in 0..<150 {
            try rng.mutate(valid).write(to: scratch)
            _ = try? AttachmentStore.readMetadata(
                at: scratch, vaultID: vaultID, attachmentID: attachmentID, attachmentKey: key
            )
            _ = try? AttachmentStore.verify(
                fileURL: scratch, vaultID: vaultID, attachmentID: attachmentID, attachmentKey: key
            )
        }
    }

    @Test func otpauthAndTextParsers() {
        var rng = FuzzRNG(state: 0xDEAD_0004)
        let seed = "otpauth://totp/Ex:me@example.com?secret=MZXW6YTBOI&digits=6&period=30&algorithm=SHA1"
        for _ in 0..<600 {
            let mutated = String(decoding: rng.mutate(Data(seed.utf8)), as: UTF8.self)
            _ = try? OTPAuthURL.parse(mutated)
            _ = try? Base32.decode(mutated)
            _ = try? RecoveryKey.parse(mutated)
        }
    }
}
