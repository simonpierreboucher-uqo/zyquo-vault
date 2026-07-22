import Foundation
import Security

/// Abstraction over the system CSPRNG so tests can inject deterministic bytes.
/// Production code MUST use `SystemSecureRandom` (backed by `SecRandomCopyBytes`).
public protocol SecureRandomSource: Sendable {
    /// Fills `buffer` with cryptographically secure random bytes, or throws.
    func fill(_ buffer: UnsafeMutableRawBufferPointer) throws
}

extension SecureRandomSource {
    /// Returns `count` fresh random bytes.
    public func bytes(count: Int) throws -> [UInt8] {
        var out = [UInt8](repeating: 0, count: count)
        try out.withUnsafeMutableBytes { try fill($0) }
        return out
    }

    /// Returns `count` fresh random bytes inside a `SecureBytes` container.
    public func secureBytes(count: Int) throws -> SecureBytes {
        try SecureBytes(count: count) { try fill($0) }
    }
}

/// The one production randomness source: the OS secure RNG.
/// Note: `SecRandomCopyBytes` lives in Security.framework but is NOT a Keychain
/// storage API — its use is explicitly allowed (CLAUDE.md §4.2).
public struct SystemSecureRandom: SecureRandomSource {
    public init() {}

    public func fill(_ buffer: UnsafeMutableRawBufferPointer) throws {
        guard buffer.count > 0 else { return }
        let status = SecRandomCopyBytes(kSecRandomDefault, buffer.count, buffer.baseAddress!)
        guard status == errSecSuccess else {
            throw CryptoError.randomGenerationFailed(status: status)
        }
    }
}
