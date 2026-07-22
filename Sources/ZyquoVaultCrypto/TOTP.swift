import CryptoKit
import Foundation

/// RFC 4648 base32 decoding (standard alphabet, padding optional, case- and
/// whitespace-insensitive) for TOTP seeds.
public enum Base32 {
    static let alphabet = Array("ABCDEFGHIJKLMNOPQRSTUVWXYZ234567")

    public static func decode(_ input: String) throws -> [UInt8] {
        let cleaned = input.uppercased().filter { $0 != "=" && !$0.isWhitespace }
        guard !cleaned.isEmpty, cleaned.count <= 256 else {
            throw CryptoError.invalidParameter(reason: "base32 input length")
        }
        var buffer = 0, bits = 0
        var out: [UInt8] = []
        for char in cleaned {
            guard let value = alphabet.firstIndex(of: char) else {
                throw CryptoError.invalidParameter(reason: "invalid base32 character")
            }
            buffer = (buffer << 5) | value
            bits += 5
            if bits >= 8 {
                bits -= 8
                out.append(UInt8((buffer >> bits) & 0xFF))
            }
        }
        return out
    }

    public static func encode(_ bytes: [UInt8]) -> String {
        var buffer = 0, bits = 0
        var out = ""
        for byte in bytes {
            buffer = (buffer << 8) | Int(byte)
            bits += 8
            while bits >= 5 {
                bits -= 5
                out.append(alphabet[(buffer >> bits) & 0x1F])
            }
        }
        if bits > 0 { out.append(alphabet[(buffer << (5 - bits)) & 0x1F]) }
        return out
    }
}

/// RFC 6238 TOTP (built on RFC 4226 HOTP). Generated codes are never stored or
/// logged; the seed is encrypted like any other secret.
public struct TOTPConfiguration: Equatable, Sendable {
    public enum Algorithm: String, Sendable, CaseIterable {
        case sha1 = "SHA1"     // compatibility default
        case sha256 = "SHA256"
        case sha512 = "SHA512"
    }

    public var secret: [UInt8]
    public var algorithm: Algorithm
    public var digits: Int
    public var period: Int
    public var issuer: String?
    public var account: String?

    public init(
        secret: [UInt8],
        algorithm: Algorithm = .sha1,
        digits: Int = 6,
        period: Int = 30,
        issuer: String? = nil,
        account: String? = nil
    ) {
        self.secret = secret
        self.algorithm = algorithm
        self.digits = digits
        self.period = period
        self.issuer = issuer
        self.account = account
    }

    public func validate() throws {
        guard !secret.isEmpty, secret.count <= 128 else {
            throw CryptoError.invalidParameter(reason: "TOTP secret length")
        }
        guard digits == 6 || digits == 8 else {
            throw CryptoError.invalidParameter(reason: "TOTP digits must be 6 or 8")
        }
        guard period >= 15, period <= 120 else {
            throw CryptoError.invalidParameter(reason: "TOTP period out of range")
        }
    }
}

public enum TOTPGenerator {

    /// The code for `date`, plus seconds remaining in the current period.
    public static func code(
        for configuration: TOTPConfiguration,
        at date: Date = Date()
    ) throws -> (code: String, secondsRemaining: Int) {
        try configuration.validate()
        let epoch = Int64(date.timeIntervalSince1970)
        guard epoch >= 0 else { throw CryptoError.invalidParameter(reason: "date before epoch") }
        let counter = UInt64(epoch) / UInt64(configuration.period)
        let remaining = configuration.period - Int(UInt64(epoch) % UInt64(configuration.period))
        return (try hotp(configuration: configuration, counter: counter), remaining)
    }

    /// RFC 4226 HOTP with dynamic truncation.
    static func hotp(configuration: TOTPConfiguration, counter: UInt64) throws -> String {
        var message = Data(count: 8)
        withUnsafeBytes(of: counter.bigEndian) { message = Data($0) }
        let key = SymmetricKey(data: Data(configuration.secret))

        let mac: [UInt8]
        switch configuration.algorithm {
        case .sha1:
            mac = Array(HMAC<Insecure.SHA1>.authenticationCode(for: message, using: key))
        case .sha256:
            mac = Array(HMAC<SHA256>.authenticationCode(for: message, using: key))
        case .sha512:
            mac = Array(HMAC<SHA512>.authenticationCode(for: message, using: key))
        }

        let offset = Int(mac[mac.count - 1] & 0x0F)
        let binary = (UInt32(mac[offset] & 0x7F) << 24)
            | (UInt32(mac[offset + 1]) << 16)
            | (UInt32(mac[offset + 2]) << 8)
            | UInt32(mac[offset + 3])
        let modulus = UInt32(pow(10, Double(configuration.digits)))
        let value = binary % modulus
        return String(format: "%0\(configuration.digits)d", value)
    }

    /// Formats a code in display groups: `123 456` / `1234 5678`.
    public static func grouped(_ code: String) -> String {
        let half = code.count / 2
        return code.prefix(half) + " " + code.suffix(code.count - half)
    }
}

/// `otpauth://totp/…` parser (§10.5). Strict and crash-free on malformed input;
/// only the TOTP type is accepted in v1.
public enum OTPAuthURL {

    public static func parse(_ string: String) throws -> TOTPConfiguration {
        guard string.count <= 2048,
              let components = URLComponents(string: string),
              components.scheme?.lowercased() == "otpauth" else {
            throw CryptoError.invalidParameter(reason: "not an otpauth URL")
        }
        guard components.host?.lowercased() == "totp" else {
            throw CryptoError.invalidParameter(reason: "only TOTP otpauth URLs are supported")
        }

        var secret: [UInt8]?
        var algorithm = TOTPConfiguration.Algorithm.sha1
        var digits = 6
        var period = 30
        var issuer: String?

        for item in components.queryItems ?? [] {
            switch item.name.lowercased() {
            case "secret":
                secret = try Base32.decode(item.value ?? "")
            case "algorithm":
                guard let alg = TOTPConfiguration.Algorithm(rawValue: (item.value ?? "").uppercased()) else {
                    throw CryptoError.invalidParameter(reason: "unsupported TOTP algorithm")
                }
                algorithm = alg
            case "digits":
                guard let d = Int(item.value ?? ""), d == 6 || d == 8 else {
                    throw CryptoError.invalidParameter(reason: "unsupported digit count")
                }
                digits = d
            case "period":
                guard let p = Int(item.value ?? ""), p >= 15, p <= 120 else {
                    throw CryptoError.invalidParameter(reason: "unsupported period")
                }
                period = p
            case "issuer":
                issuer = item.value
            default:
                continue // unknown parameters are ignored, never trusted
            }
        }
        guard let secretBytes = secret, !secretBytes.isEmpty else {
            throw CryptoError.invalidParameter(reason: "missing secret")
        }

        // Label: "Issuer:account" or "account".
        var account: String?
        let label = components.path.trimmingCharacters(in: CharacterSet(charactersIn: "/"))
            .removingPercentEncoding ?? ""
        if !label.isEmpty {
            let parts = label.split(separator: ":", maxSplits: 1).map(String.init)
            if parts.count == 2 {
                if issuer == nil { issuer = parts[0] }
                account = parts[1].trimmingCharacters(in: .whitespaces)
            } else {
                account = parts.first
            }
        }

        let config = TOTPConfiguration(
            secret: secretBytes, algorithm: algorithm,
            digits: digits, period: period,
            issuer: issuer, account: account
        )
        try config.validate()
        return config
    }
}
