import CArgon2
import Foundation
import Testing
@testable import ZyquoVaultCrypto

/// Official known-answer vectors from the Argon2 reference implementation
/// (`src/test.c`, version 0x13). These exercise the vendored C code directly —
/// the official vectors use parameters below Zyquo's enforced floors, which the
/// Swift wrapper (correctly) refuses.
@Suite("Argon2id known-answer vectors (official)")
struct Argon2idKATTests {

    static let vectors: [(t: UInt32, log2m: UInt32, p: UInt32, password: String, salt: String, hex: String)] = [
        (2, 16, 1, "password", "somesalt", "09316115d5cf24ed5a15a31a3ba326e5cf32edc24702987c02b6566f61913cf7"),
        (2, 18, 1, "password", "somesalt", "78fe1ec91fb3aa5657d72e710854e4c3d9b9198c742f9616c2f085bed95b2e8c"),
        (2, 8, 1, "password", "somesalt", "9dfeb910e80bad0311fee20f9c0e2b12c17987b4cac90c2ef54d5b3021c68bfe"),
        (2, 8, 2, "password", "somesalt", "6d093c501fd5999645e0ea3bf620d7b8be7fd2db59c20d9fff9539da2bf57037"),
        (1, 16, 1, "password", "somesalt", "f6a5adc1ba723dddef9b5ac1d464e180fcd9dffc9d1cbf76cca2fed795d9ca98"),
        (4, 16, 1, "password", "somesalt", "9025d48e68ef7395cca9079da4c4ec3affb3c8911fe4f86d1a2520856f63172c"),
        (2, 16, 1, "differentpassword", "somesalt", "0b84d652cf6b0c4beaef0dfe278ba6a80df6696281d7e0d2891b817d8c458fde"),
        (2, 16, 1, "password", "diffsalt", "bdf32b05ccc42eb15d58fd19b1f856b113da1e9a5874fdcc544308565aa8141c"),
    ]

    @Test func officialVectorsMatch() throws {
        for v in Self.vectors {
            var output = [UInt8](repeating: 0, count: 32)
            let password = Array(v.password.utf8)
            let salt = Array(v.salt.utf8)
            let code = output.withUnsafeMutableBytes { out in
                password.withUnsafeBytes { pwd in
                    salt.withUnsafeBytes { s in
                        argon2id_hash_raw(
                            v.t, 1 << v.log2m, v.p,
                            pwd.baseAddress, pwd.count,
                            s.baseAddress, s.count,
                            out.baseAddress, out.count
                        )
                    }
                }
            }
            #expect(code == ARGON2_OK.rawValue)
            #expect(hexString(output) == v.hex, "vector t=\(v.t) m=2^\(v.log2m) p=\(v.p)")
        }
    }
}

@Suite("Argon2id wrapper")
struct Argon2idWrapperTests {

    /// Smallest floor-compliant parameters, to keep the suite fast but honest.
    static let floorParams = Argon2id.Parameters(
        memoryKiB: Argon2id.Floor.memoryKiB,
        iterations: Argon2id.Floor.iterations,
        parallelism: 4
    )

    @Test func deterministicAndPasswordSensitive() throws {
        let salt = [UInt8](repeating: 0x42, count: 16)
        let a = try Argon2id.deriveKey(password: SecureBytes(utf8: "correct horse"), salt: salt, parameters: Self.floorParams)
        let b = try Argon2id.deriveKey(password: SecureBytes(utf8: "correct horse"), salt: salt, parameters: Self.floorParams)
        let c = try Argon2id.deriveKey(password: SecureBytes(utf8: "correct horsf"), salt: salt, parameters: Self.floorParams)
        #expect(a == b)
        #expect(!(a == c))
        #expect(a.count == 32)
    }

    @Test func saltSensitive() throws {
        let pw = "same password"
        let a = try Argon2id.deriveKey(password: SecureBytes(utf8: pw), salt: [UInt8](repeating: 1, count: 16), parameters: Self.floorParams)
        let b = try Argon2id.deriveKey(password: SecureBytes(utf8: pw), salt: [UInt8](repeating: 2, count: 16), parameters: Self.floorParams)
        #expect(!(a == b))
    }

    @Test func rejectsBelowFloorAndAboveCeiling() {
        let salt = [UInt8](repeating: 0, count: 16)
        let pw = SecureBytes(utf8: "x")
        let belowMemory = Argon2id.Parameters(memoryKiB: 1024, iterations: 3, parallelism: 1)
        let belowIterations = Argon2id.Parameters(memoryKiB: 65536, iterations: 2, parallelism: 1)
        let dosMemory = Argon2id.Parameters(memoryKiB: .max, iterations: 3, parallelism: 1)
        let shortSalt = [UInt8](repeating: 0, count: 8)
        #expect(throws: CryptoError.self) { try Argon2id.deriveKey(password: pw, salt: salt, parameters: belowMemory) }
        #expect(throws: CryptoError.self) { try Argon2id.deriveKey(password: pw, salt: salt, parameters: belowIterations) }
        #expect(throws: CryptoError.self) { try Argon2id.deriveKey(password: pw, salt: salt, parameters: dosMemory) }
        #expect(throws: CryptoError.self) { try Argon2id.deriveKey(password: pw, salt: shortSalt, parameters: Self.floorParams) }
    }
}

func hexString(_ bytes: [UInt8]) -> String {
    bytes.map { String(format: "%02x", $0) }.joined()
}

func hexBytes(_ hex: String) -> [UInt8] {
    var result: [UInt8] = []
    var iterator = hex.makeIterator()
    while let high = iterator.next(), let low = iterator.next() {
        result.append(UInt8(String([high, low]), radix: 16)!)
    }
    return result
}
