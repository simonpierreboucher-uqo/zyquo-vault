import Foundation
import Testing
@testable import ZyquoVaultCrypto

@Suite("Base32 (RFC 4648)")
struct Base32Tests {

    @Test func rfc4648Vectors() throws {
        let vectors: [(String, String)] = [
            ("f", "MY"), ("fo", "MZXQ"), ("foo", "MZXW6"),
            ("foob", "MZXW6YQ"), ("fooba", "MZXW6YTB"), ("foobar", "MZXW6YTBOI"),
        ]
        for (plain, encoded) in vectors {
            #expect(Base32.encode(Array(plain.utf8)) == encoded)
            #expect(try Base32.decode(encoded) == Array(plain.utf8))
            // Padding, case, and whitespace are tolerated on decode.
            #expect(try Base32.decode(encoded.lowercased() + "====") == Array(plain.utf8))
        }
    }

    @Test func malformedRejected() {
        #expect(throws: CryptoError.self) { _ = try Base32.decode("") }
        #expect(throws: CryptoError.self) { _ = try Base32.decode("MZXW1") } // '1' not in alphabet
        #expect(throws: CryptoError.self) { _ = try Base32.decode(String(repeating: "A", count: 500)) }
    }
}

@Suite("TOTP (RFC 6238) — mandatory vectors")
struct TOTPTests {

    static let sha1Secret = Array("12345678901234567890".utf8)
    static let sha256Secret = Array("12345678901234567890123456789012".utf8)
    static let sha512Secret = Array("1234567890123456789012345678901234567890123456789012345678901234".utf8)

    /// RFC 6238 Appendix B (8 digits, period 30).
    static let vectors: [(time: Int64, sha1: String, sha256: String, sha512: String)] = [
        (59, "94287082", "46119246", "90693936"),
        (1_111_111_109, "07081804", "68084774", "25091201"),
        (1_111_111_111, "14050471", "67062674", "99943326"),
        (1_234_567_890, "89005924", "91819424", "93441116"),
        (2_000_000_000, "69279037", "90698825", "38618901"),
        (20_000_000_000, "65353130", "77737706", "47863826"),
    ]

    @Test func rfc6238AppendixB() throws {
        for vector in Self.vectors {
            let date = Date(timeIntervalSince1970: TimeInterval(vector.time))
            let sha1 = TOTPConfiguration(secret: Self.sha1Secret, algorithm: .sha1, digits: 8)
            let sha256 = TOTPConfiguration(secret: Self.sha256Secret, algorithm: .sha256, digits: 8)
            let sha512 = TOTPConfiguration(secret: Self.sha512Secret, algorithm: .sha512, digits: 8)
            #expect(try TOTPGenerator.code(for: sha1, at: date).code == vector.sha1)
            #expect(try TOTPGenerator.code(for: sha256, at: date).code == vector.sha256)
            #expect(try TOTPGenerator.code(for: sha512, at: date).code == vector.sha512)
        }
    }

    /// RFC 4226 Appendix D (HOTP, 6 digits).
    @Test func rfc4226AppendixD() throws {
        let expected = ["755224", "287082", "359152", "969429", "338314",
                        "254676", "287922", "162583", "399871", "520489"]
        let config = TOTPConfiguration(secret: Self.sha1Secret, algorithm: .sha1, digits: 6)
        for (counter, code) in expected.enumerated() {
            #expect(try TOTPGenerator.hotp(configuration: config, counter: UInt64(counter)) == code)
        }
    }

    @Test func secondsRemainingAndGrouping() throws {
        let config = TOTPConfiguration(secret: Self.sha1Secret)
        let result = try TOTPGenerator.code(for: config, at: Date(timeIntervalSince1970: 59))
        #expect(result.secondsRemaining == 1)
        #expect(TOTPGenerator.grouped("123456") == "123 456")
        #expect(TOTPGenerator.grouped("12345678") == "1234 5678")
    }

    @Test func invalidConfigurationsRejected() {
        #expect(throws: CryptoError.self) {
            _ = try TOTPGenerator.code(for: TOTPConfiguration(secret: [], digits: 6))
        }
        #expect(throws: CryptoError.self) {
            _ = try TOTPGenerator.code(for: TOTPConfiguration(secret: Self.sha1Secret, digits: 7))
        }
        #expect(throws: CryptoError.self) {
            _ = try TOTPGenerator.code(for: TOTPConfiguration(secret: Self.sha1Secret, period: 1))
        }
    }
}

@Suite("otpauth:// parser")
struct OTPAuthURLTests {

    @Test func parsesFullURL() throws {
        let config = try OTPAuthURL.parse(
            "otpauth://totp/Example:alice@example.com?secret=MZXW6YTBOI&issuer=Example&algorithm=SHA256&digits=8&period=60"
        )
        #expect(config.secret == Array("foobar".utf8))
        #expect(config.algorithm == .sha256)
        #expect(config.digits == 8)
        #expect(config.period == 60)
        #expect(config.issuer == "Example")
        #expect(config.account == "alice@example.com")
    }

    @Test func defaultsApplied() throws {
        let config = try OTPAuthURL.parse("otpauth://totp/alice?secret=MZXW6YTBOI")
        #expect(config.algorithm == .sha1)
        #expect(config.digits == 6)
        #expect(config.period == 30)
        #expect(config.account == "alice")
    }

    @Test func malformedInputRejectedWithoutCrashing() {
        let malformed = [
            "",
            "https://example.com",
            "otpauth://hotp/x?secret=MZXW6YTBOI",     // HOTP unsupported in v1
            "otpauth://totp/x",                        // missing secret
            "otpauth://totp/x?secret=notbase32!!",
            "otpauth://totp/x?secret=MZXW6YTBOI&digits=9",
            "otpauth://totp/x?secret=MZXW6YTBOI&period=1",
            "otpauth://totp/x?secret=MZXW6YTBOI&algorithm=MD5",
            String(repeating: "otpauth://totp/x?", count: 500),
        ]
        for input in malformed {
            #expect(throws: CryptoError.self, "input: \(input.prefix(40))") {
                _ = try OTPAuthURL.parse(input)
            }
        }
    }
}
