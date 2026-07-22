import Foundation

/// Typed errors for the cryptographic layer. User-facing text is produced by the UI
/// layer (§3.8) — these cases never carry secret material and never reach logs with
/// sensitive payloads attached.
public enum CryptoError: Error, Equatable, Sendable {
    /// Wrong password OR corrupted/tampered data — deliberately indistinguishable
    /// at the API boundary that the UI consumes (§5.6).
    case invalidPasswordOrCorruptedVault
    /// AEAD authentication failed on a non-unlock object (record, manifest, backup).
    case authenticationFailed
    case unsupportedAlgorithm(identifier: UInt32)
    case invalidNonce
    case invalidKeyLength(expected: Int, actual: Int)
    case kdfFailure(code: Int32)
    /// KDF parameters below the enforced security floors or above DoS bounds.
    case kdfParametersOutOfRange(reason: String)
    case malformedCiphertext
    case randomGenerationFailed(status: Int32)
    case invalidParameter(reason: String)
}
