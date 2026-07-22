import CryptoKit
import Foundation
import Testing
@testable import ZyquoVaultCrypto

@Suite("SecureBytes")
struct SecureBytesTests {

    @Test func neverRevealsContents() {
        let secret = SecureBytes(utf8: "hunter2-example-password-not-real")
        #expect(String(describing: secret) == "<redacted>")
        #expect(String(reflecting: secret) == "<redacted>")
    }

    @Test func roundTripAndEquality() {
        let a = SecureBytes(bytes: [1, 2, 3, 4])
        let b = SecureBytes(bytes: [1, 2, 3, 4])
        let c = SecureBytes(bytes: [1, 2, 3, 5])
        #expect(a == b)
        #expect(!(a == c))
        #expect(a.copyBytes() == [1, 2, 3, 4])
    }

    @Test func scopedAccessSeesExactBytes() {
        let s = SecureBytes(bytes: [0xDE, 0xAD, 0xBE, 0xEF])
        let sum = s.withUnsafeBytes { buffer in buffer.reduce(0) { $0 + Int($1) } }
        #expect(sum == 0xDE + 0xAD + 0xBE + 0xEF)
        #expect(s.count == 4)
    }
}

@Suite("Constant-time comparison")
struct ConstantTimeTests {

    @Test func semantics() {
        #expect(constantTimeEquals(Data([1, 2, 3]), Data([1, 2, 3])))
        #expect(!constantTimeEquals(Data([1, 2, 3]), Data([1, 2, 4])))
        #expect(!constantTimeEquals(Data([1, 2, 3]), Data([1, 2])))
        #expect(!constantTimeEquals(Data([0]), Data([0x80])))
        #expect(constantTimeEquals(Data(), Data()))
        // Differences only in first vs only in last byte must both be caught.
        #expect(!constantTimeEquals(Data([9, 2, 3]), Data([1, 2, 3])))
        #expect(!constantTimeEquals(Data([1, 2, 9]), Data([1, 2, 3])))
    }
}

@Suite("SecureRandom")
struct SecureRandomTests {

    @Test func producesRequestedLengthsAndVaries() throws {
        let rng = SystemSecureRandom()
        let a = try rng.bytes(count: 32)
        let b = try rng.bytes(count: 32)
        #expect(a.count == 32)
        #expect(a != b) // 2^-256 false-failure probability
        #expect(try rng.bytes(count: 0).isEmpty)
    }
}

/// Deterministic source for tests only.
struct FixedRandom: SecureRandomSource {
    let byte: UInt8
    func fill(_ buffer: UnsafeMutableRawBufferPointer) throws {
        for i in 0..<buffer.count { buffer[i] = byte }
    }
}

@Suite("HKDF-SHA256")
struct HKDFTests {

    /// RFC 5869 Test Case 1 — validates the CryptoKit HKDF we build on.
    @Test func rfc5869TestCase1() {
        let ikm = SymmetricKey(data: Data(repeating: 0x0B, count: 22))
        let salt = Data(hexBytes("000102030405060708090a0b0c"))
        let info = Data(hexBytes("f0f1f2f3f4f5f6f7f8f9"))
        let okm = HKDF<SHA256>.deriveKey(inputKeyMaterial: ikm, salt: salt, info: info, outputByteCount: 42)
        let expected = "3cb25f25faacd57a90434f64d0362f2a2d2d0a90cf1a5a4c5db02d56ecc4c5bf34007208d5b887185865"
        let actual = okm.withUnsafeBytes { hexString(Array($0)) }
        #expect(actual == expected)
    }

    @Test func contextsAreDomainSeparated() {
        let vmk = SecureBytes(bytes: [UInt8](repeating: 7, count: 32))
        let vault = UUID()
        var keys: Set<Data> = []
        for context in KeyContext.allCases {
            let key = KeyDerivation.subkey(vmk: vmk, vaultID: vault, context: context)
            keys.insert(key.withUnsafeBytes { Data($0) })
        }
        #expect(keys.count == KeyContext.allCases.count, "every context must yield a distinct subkey")

        // Same context, different vault ⇒ different subkey.
        let other = KeyDerivation.subkey(vmk: vmk, vaultID: UUID(), context: .recordWrapping)
        let original = KeyDerivation.subkey(vmk: vmk, vaultID: vault, context: .recordWrapping)
        #expect(other.withUnsafeBytes { Data($0) } != original.withUnsafeBytes { Data($0) })
    }
}
