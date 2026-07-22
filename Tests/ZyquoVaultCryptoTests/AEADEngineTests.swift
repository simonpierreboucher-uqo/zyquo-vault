import CryptoKit
import Foundation
import Testing
@testable import ZyquoVaultCrypto

@Suite("AEAD engine (AES-256-GCM)")
struct AEADEngineTests {

    let engine = AEADEngine()
    let key = SymmetricKey(size: .bits256)
    let aad = AssociatedData(
        vaultID: UUID(), objectID: UUID(), objectType: .record,
        schemaVersion: 1, revision: 7
    )
    let plaintext = Data("example-payload-not-real".utf8)

    @Test func roundTrip() throws {
        let sealed = try engine.seal(plaintext: plaintext, key: key, aad: aad)
        let opened = try engine.open(sealed, key: key, aad: aad)
        #expect(opened == plaintext)
        #expect(sealed.nonce.count == 12)
        #expect(sealed.tag.count == 16)
    }

    @Test func freshNoncePerSeal() throws {
        let first = try engine.seal(plaintext: plaintext, key: key, aad: aad)
        let second = try engine.seal(plaintext: plaintext, key: key, aad: aad)
        #expect(first.nonce != second.nonce)
        #expect(first.ciphertext != second.ciphertext)
    }

    @Test func tamperedCiphertextFails() throws {
        let sealed = try engine.seal(plaintext: plaintext, key: key, aad: aad)
        var bytes = Data(sealed.ciphertext)
        bytes[0] ^= 0x01
        let tampered = SealedMessage(algorithm: .aes256gcm, nonce: sealed.nonce, ciphertext: bytes, tag: sealed.tag)
        #expect(throws: CryptoError.authenticationFailed) { try engine.open(tampered, key: key, aad: aad) }
    }

    @Test func tamperedTagFails() throws {
        let sealed = try engine.seal(plaintext: plaintext, key: key, aad: aad)
        var tag = Data(sealed.tag)
        tag[15] ^= 0x80
        let tampered = SealedMessage(algorithm: .aes256gcm, nonce: sealed.nonce, ciphertext: sealed.ciphertext, tag: tag)
        #expect(throws: CryptoError.authenticationFailed) { try engine.open(tampered, key: key, aad: aad) }
    }

    @Test func wrongKeyFails() throws {
        let sealed = try engine.seal(plaintext: plaintext, key: key, aad: aad)
        #expect(throws: CryptoError.authenticationFailed) {
            try engine.open(sealed, key: SymmetricKey(size: .bits256), aad: aad)
        }
    }

    @Test func aadMismatchFails() throws {
        let sealed = try engine.seal(plaintext: plaintext, key: key, aad: aad)
        var wrongRevision = aad
        wrongRevision.revision = 8
        var wrongObject = aad
        wrongObject.objectID = UUID()
        var wrongType = aad
        wrongType.objectType = .manifest
        for wrong in [wrongRevision, wrongObject, wrongType] {
            #expect(throws: CryptoError.authenticationFailed) { try engine.open(sealed, key: key, aad: wrong) }
        }
    }

    @Test func rejectsNon256BitKeys() throws {
        let short = SymmetricKey(size: .bits128)
        #expect(throws: CryptoError.self) { try engine.seal(plaintext: plaintext, key: short, aad: aad) }
        let sealed = try engine.seal(plaintext: plaintext, key: key, aad: aad)
        #expect(throws: CryptoError.self) { try engine.open(sealed, key: short, aad: aad) }
    }

    @Test func malformedWireFormRejected() {
        #expect(throws: CryptoError.malformedCiphertext) {
            _ = try SealedMessage(algorithm: .aes256gcm, combined: Data([1, 2, 3]))
        }
    }

    @Test func wireFormRoundTrips() throws {
        let sealed = try engine.seal(plaintext: plaintext, key: key, aad: aad)
        let parsed = try SealedMessage(algorithm: .aes256gcm, combined: sealed.combined)
        #expect(parsed == sealed)
        let opened = try engine.open(parsed, key: key, aad: aad)
        #expect(opened == plaintext)
    }

    @Test func canonicalAADEncodingIsStable() {
        let vault = UUID(uuidString: "11111111-2222-3333-4444-555555555555")!
        let object = UUID(uuidString: "AAAAAAAA-BBBB-CCCC-DDDD-EEEEEEEEEEEE")!
        let fixed = AssociatedData(
            vaultID: vault, objectID: object, objectType: .record,
            schemaVersion: 1, revision: 2
        )
        let encoded = fixed.encoded()
        #expect(encoded.count == AssociatedData.encodedLength)
        #expect(encoded == fixed.encoded()) // deterministic
        #expect(Array(encoded.prefix(4)) == Array("ZQAD".utf8))
        // Big-endian revision sits at offset 45..<53.
        #expect(Array(encoded[45..<53]) == [0, 0, 0, 0, 0, 0, 0, 2])
    }
}
