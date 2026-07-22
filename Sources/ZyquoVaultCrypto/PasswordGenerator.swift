import Foundation

/// Password generation (§10.4). All randomness flows through `SecureRandomSource`
/// with **rejection sampling** — never modulo reduction — so every element of a
/// choice space is exactly equally likely. Entropy figures are estimates and are
/// labeled as such in the UI.
public enum PasswordGenerator {

    // MARK: Uniform sampling primitives

    /// Uniform integer in `0..<upperBound` via rejection sampling (no modulo bias).
    static func uniformIndex(below upperBound: Int, random: SecureRandomSource) throws -> Int {
        precondition(upperBound > 0 && upperBound <= 1 << 24)
        let bound = UInt32(upperBound)
        // Largest multiple of `bound` representable in UInt32; values above it
        // are rejected so the fold-down stays uniform.
        let limit = UInt32.max - (UInt32.max % bound + 1) % bound
        while true {
            var raw: UInt32 = 0
            try withUnsafeMutableBytes(of: &raw) { try random.fill($0) }
            if raw <= limit { return Int(raw % bound) }
        }
    }

    static func pick<T>(_ options: [T], random: SecureRandomSource) throws -> T {
        options[try uniformIndex(below: options.count, random: random)]
    }

    /// Fisher–Yates with CSPRNG indices.
    static func shuffle<T>(_ array: inout [T], random: SecureRandomSource) throws {
        guard array.count > 1 else { return }
        for i in stride(from: array.count - 1, through: 1, by: -1) {
            array.swapAt(i, try uniformIndex(below: i + 1, random: random))
        }
    }

    // MARK: Character classes

    public struct CharacterClasses: OptionSet, Sendable, Equatable {
        public let rawValue: Int
        public init(rawValue: Int) { self.rawValue = rawValue }
        public static let lowercase = CharacterClasses(rawValue: 1 << 0)
        public static let uppercase = CharacterClasses(rawValue: 1 << 1)
        public static let digits = CharacterClasses(rawValue: 1 << 2)
        public static let symbols = CharacterClasses(rawValue: 1 << 3)
        public static let all: CharacterClasses = [.lowercase, .uppercase, .digits, .symbols]
    }

    static let lowercase = Array("abcdefghijklmnopqrstuvwxyz")
    static let uppercase = Array("ABCDEFGHIJKLMNOPQRSTUVWXYZ")
    static let digits = Array("0123456789")
    static let symbols = Array("!@#$%^&*-_=+.,:;?/")
    /// Easily confused glyphs removed when "exclude ambiguous" is on.
    static let ambiguous = Set("Il1O0o5SB8Z2")

    static func pool(for classes: CharacterClasses, excludeAmbiguous: Bool) -> [[Character]] {
        var pools: [[Character]] = []
        if classes.contains(.lowercase) { pools.append(lowercase) }
        if classes.contains(.uppercase) { pools.append(uppercase) }
        if classes.contains(.digits) { pools.append(digits) }
        if classes.contains(.symbols) { pools.append(symbols) }
        if excludeAmbiguous {
            pools = pools.map { $0.filter { !ambiguous.contains($0) } }
        }
        return pools.filter { !$0.isEmpty }
    }

    // MARK: Random characters mode

    /// Random password: `length` characters from the enabled classes, with at
    /// least one character of every enabled class when `length` allows
    /// (positions shuffled so required characters are not predictable).
    public static func randomPassword(
        length: Int,
        classes: CharacterClasses = .all,
        excludeAmbiguous: Bool = false,
        random: SecureRandomSource = SystemSecureRandom()
    ) throws -> String {
        guard length >= 4, length <= 256 else {
            throw CryptoError.invalidParameter(reason: "length out of range")
        }
        let pools = pool(for: classes, excludeAmbiguous: excludeAmbiguous)
        guard !pools.isEmpty else {
            throw CryptoError.invalidParameter(reason: "no character classes enabled")
        }
        let combined = pools.flatMap { $0 }
        var characters: [Character] = []
        // One from each enabled class first (guaranteed coverage)…
        if length >= pools.count {
            for p in pools { characters.append(try pick(p, random: random)) }
        }
        // …then uniform draws from the union.
        while characters.count < length {
            characters.append(try pick(combined, random: random))
        }
        try shuffle(&characters, random: random)
        return String(characters)
    }

    // MARK: Passphrase mode

    public static func passphrase(
        wordCount: Int,
        separator: String = "-",
        capitalize: Bool = false,
        includeDigit: Bool = false,
        wordlist: [String] = PassphraseWordlist.english,
        random: SecureRandomSource = SystemSecureRandom()
    ) throws -> String {
        guard wordCount >= 3, wordCount <= 12 else {
            throw CryptoError.invalidParameter(reason: "word count out of range")
        }
        guard wordlist.count >= 1024 else {
            throw CryptoError.invalidParameter(reason: "wordlist too small")
        }
        var words: [String] = []
        for _ in 0..<wordCount {
            var word = try pick(wordlist, random: random)
            if capitalize { word = word.prefix(1).uppercased() + word.dropFirst() }
            words.append(word)
        }
        if includeDigit {
            // Append a digit to one uniformly chosen word.
            let index = try uniformIndex(below: words.count, random: random)
            words[index] += String(try pick(digits, random: random))
        }
        return words.joined(separator: separator)
    }

    // MARK: PIN mode

    public static func pin(
        length: Int,
        random: SecureRandomSource = SystemSecureRandom()
    ) throws -> String {
        guard length >= 4, length <= 16 else {
            throw CryptoError.invalidParameter(reason: "PIN length out of range")
        }
        var out = ""
        for _ in 0..<length { out.append(try pick(digits, random: random)) }
        return out
    }

    // MARK: Safe pattern mode

    /// Pattern language: `a` lowercase, `A` uppercase, `9` digit, `#` symbol,
    /// `x` any of the above; every other character is copied literally.
    public static func fromPattern(
        _ pattern: String,
        excludeAmbiguous: Bool = false,
        random: SecureRandomSource = SystemSecureRandom()
    ) throws -> String {
        guard !pattern.isEmpty, pattern.count <= 256 else {
            throw CryptoError.invalidParameter(reason: "pattern length out of range")
        }
        func filtered(_ set: [Character]) -> [Character] {
            excludeAmbiguous ? set.filter { !ambiguous.contains($0) } : set
        }
        let any = filtered(lowercase + uppercase + digits + symbols)
        var out = ""
        for ch in pattern {
            switch ch {
            case "a": out.append(try pick(filtered(lowercase), random: random))
            case "A": out.append(try pick(filtered(uppercase), random: random))
            case "9": out.append(try pick(filtered(digits), random: random))
            case "#": out.append(try pick(filtered(symbols), random: random))
            case "x": out.append(try pick(any, random: random))
            default: out.append(ch)
            }
        }
        return out
    }

    // MARK: Entropy estimates (labeled as estimates in the UI)

    public static func randomPasswordEntropy(length: Int, classes: CharacterClasses, excludeAmbiguous: Bool) -> Double {
        let size = pool(for: classes, excludeAmbiguous: excludeAmbiguous).flatMap { $0 }.count
        return size > 0 ? Double(length) * log2(Double(size)) : 0
    }

    public static func passphraseEntropy(wordCount: Int, wordlistCount: Int = PassphraseWordlist.english.count) -> Double {
        Double(wordCount) * log2(Double(wordlistCount))
    }
}
