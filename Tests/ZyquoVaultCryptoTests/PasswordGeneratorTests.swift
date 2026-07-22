import Foundation
import Testing
@testable import ZyquoVaultCrypto

@Suite("Password generator")
struct PasswordGeneratorTests {

    @Test func randomPasswordRespectsClassesAndLength() throws {
        let password = try PasswordGenerator.randomPassword(length: 24, classes: .all)
        #expect(password.count == 24)
        #expect(password.contains { $0.isLowercase })
        #expect(password.contains { $0.isUppercase })
        #expect(password.contains { $0.isNumber })
        #expect(password.contains { !$0.isLetter && !$0.isNumber })

        let digitsOnly = try PasswordGenerator.randomPassword(length: 12, classes: .digits)
        #expect(digitsOnly.allSatisfy({ $0.isNumber }))
    }

    @Test func excludeAmbiguousRemovesConfusableGlyphs() throws {
        for _ in 0..<20 {
            let password = try PasswordGenerator.randomPassword(length: 40, classes: .all, excludeAmbiguous: true)
            #expect(password.allSatisfy { !PasswordGenerator.ambiguous.contains($0) })
        }
    }

    @Test func pinIsDigitsOnly() throws {
        let pin = try PasswordGenerator.pin(length: 8)
        #expect(pin.count == 8)
        #expect(pin.allSatisfy({ $0.isNumber }))
    }

    @Test func passphraseStructure() throws {
        let phrase = try PasswordGenerator.passphrase(wordCount: 5, separator: ".", capitalize: true, includeDigit: true)
        let words = phrase.split(separator: ".")
        #expect(words.count == 5)
        #expect(words.allSatisfy { $0.first?.isUppercase == true })
        #expect(phrase.contains { $0.isNumber })
    }

    @Test func patternMode() throws {
        let value = try PasswordGenerator.fromPattern("Aaaa-9999-#a")
        #expect(value.count == 12)
        let chars = Array(value)
        #expect(chars[0].isUppercase)
        #expect(chars[1].isLowercase && chars[2].isLowercase && chars[3].isLowercase)
        #expect(chars[4] == "-")
        #expect(chars[5].isNumber && chars[6].isNumber && chars[7].isNumber && chars[8].isNumber)
        #expect(chars[9] == "-")
        #expect(PasswordGenerator.symbols.contains(chars[10]))
        #expect(chars[11].isLowercase)
    }

    @Test func invalidParametersRejected() {
        #expect(throws: CryptoError.self) { _ = try PasswordGenerator.randomPassword(length: 2) }
        #expect(throws: CryptoError.self) { _ = try PasswordGenerator.randomPassword(length: 20, classes: []) }
        #expect(throws: CryptoError.self) { _ = try PasswordGenerator.pin(length: 2) }
        #expect(throws: CryptoError.self) { _ = try PasswordGenerator.passphrase(wordCount: 1) }
        #expect(throws: CryptoError.self) { _ = try PasswordGenerator.fromPattern("") }
    }

    /// No modulo bias: over many draws from a 10-element space, every element's
    /// frequency stays within a generous tolerance of uniform.
    @Test func uniformSamplingIsUnbiased() throws {
        let random = SystemSecureRandom()
        var counts = [Int](repeating: 0, count: 10)
        let draws = 20_000
        for _ in 0..<draws {
            counts[try PasswordGenerator.uniformIndex(below: 10, random: random)] += 1
        }
        let expected = Double(draws) / 10
        for count in counts {
            // ±10% of expected (~14σ for a binomial with p=0.1, n=20k) —
            // astronomically unlikely to fail with a uniform sampler.
            #expect(abs(Double(count) - expected) < expected * 0.10, "counts: \(counts)")
        }
    }

    @Test func entropyEstimates() {
        let random = PasswordGenerator.randomPasswordEntropy(length: 20, classes: .all, excludeAmbiguous: false)
        #expect(random > 120 && random < 140) // 20 × log2(100) ≈ 133
        let phrase = PasswordGenerator.passphraseEntropy(wordCount: 6)
        #expect(phrase > 60 && phrase < 63)   // 6 × log2(1296) ≈ 62
        #expect(PassphraseWordlist.english.count == 1296)
        #expect(Set(PassphraseWordlist.english).count == 1296) // no duplicates
    }
}
