import CArgon2
import Foundation

/// Swift wrapper around the vendored official Argon2 reference implementation
/// (PHC winner, github.com/P-H-C/phc-winner-argon2, pinned — see ADR-0002).
///
/// Only Argon2**id** is exposed. Parameters are validated against enforced floors
/// (never below 64 MiB / t=3 / p=1 on this platform, CLAUDE.md §5.3) and DoS
/// ceilings before any memory is allocated. Inputs are never logged.
public enum Argon2id {

    /// Argon2 version embedded in vault headers (0x13 = version 19).
    public static let version: UInt32 = 0x13

    /// Enforced parameter floors (documented in docs/cryptography.md).
    public enum Floor {
        public static let memoryKiB: UInt32 = 64 * 1024   // 64 MiB
        public static let iterations: UInt32 = 3
        public static let parallelism: UInt32 = 1
        public static let saltLength = 16
        public static let outputLength = 32
    }

    /// DoS ceilings — a hostile header must not be able to demand absurd resources.
    public enum Ceiling {
        public static let memoryKiB: UInt32 = 4 * 1024 * 1024   // 4 GiB
        public static let iterations: UInt32 = 64
        public static let parallelism: UInt32 = 8
        public static let saltLength = 64
        public static let outputLength = 64
    }

    public struct Parameters: Equatable, Sendable, Codable {
        public var memoryKiB: UInt32
        public var iterations: UInt32
        public var parallelism: UInt32
        public var outputLength: Int

        public init(memoryKiB: UInt32, iterations: UInt32, parallelism: UInt32, outputLength: Int = 32) {
            self.memoryKiB = memoryKiB
            self.iterations = iterations
            self.parallelism = parallelism
            self.outputLength = outputLength
        }

        /// Default profile before on-device calibration (mid of the suggested range).
        public static let baseline = Parameters(memoryKiB: 128 * 1024, iterations: 3, parallelism: 4)

        /// Throws if outside [floor, ceiling]. Called before every derivation and by
        /// the header parser, so hostile headers fail closed without allocating.
        public func validate() throws {
            func check(_ ok: Bool, _ reason: String) throws {
                if !ok { throw CryptoError.kdfParametersOutOfRange(reason: reason) }
            }
            try check(memoryKiB >= Floor.memoryKiB, "memory below floor")
            try check(memoryKiB <= Ceiling.memoryKiB, "memory above ceiling")
            try check(iterations >= Floor.iterations, "iterations below floor")
            try check(iterations <= Ceiling.iterations, "iterations above ceiling")
            try check(parallelism >= Floor.parallelism, "parallelism below floor")
            try check(parallelism <= Ceiling.parallelism, "parallelism above ceiling")
            try check(outputLength >= Floor.outputLength, "output length below floor")
            try check(outputLength <= Ceiling.outputLength, "output length above ceiling")
            try check(memoryKiB >= 8 * parallelism, "memory must be ≥ 8×parallelism KiB")
        }
    }

    /// Derives `parameters.outputLength` bytes from `password` and `salt`.
    ///
    /// - The password buffer is read in place (no intermediate `String`).
    /// - The reference implementation is invoked with `ARGON2_FLAG_CLEAR_PASSWORD`
    ///   disabled because our copy of the password lives in `SecureBytes` and is
    ///   wiped by the caller; the C library still wipes its internal memory blocks.
    /// - Never logs inputs or outputs. Returns a `SecureBytes` key.
    public static func deriveKey(
        password: SecureBytes,
        salt: [UInt8],
        parameters: Parameters
    ) throws -> SecureBytes {
        try parameters.validate()
        guard salt.count >= Floor.saltLength, salt.count <= Ceiling.saltLength else {
            throw CryptoError.kdfParametersOutOfRange(reason: "salt length out of range")
        }

        var output = [UInt8](repeating: 0, count: parameters.outputLength)
        let code: Int32 = password.withUnsafeBytes { pwd in
            salt.withUnsafeBytes { s in
                output.withUnsafeMutableBytes { out in
                    argon2id_hash_raw(
                        parameters.iterations,
                        parameters.memoryKiB,
                        parameters.parallelism,
                        pwd.baseAddress, pwd.count,
                        s.baseAddress, s.count,
                        out.baseAddress, out.count
                    )
                }
            }
        }
        guard code == ARGON2_OK.rawValue else {
            // Zero the (possibly partial) output before failing.
            _ = output.withUnsafeMutableBytes { memset_s($0.baseAddress, $0.count, 0, $0.count) }
            throw CryptoError.kdfFailure(code: code)
        }
        defer {
            _ = output.withUnsafeMutableBytes { memset_s($0.baseAddress, $0.count, 0, $0.count) }
        }
        return SecureBytes(bytes: output)
    }

    /// On-device calibration: finds parameters targeting `targetSeconds` per unlock
    /// (default 0.75 s, inside the 0.5–1.0 s band of §5.3), never below the floors.
    /// Scales memory first (stronger against GPU attacks), then iterations.
    public static func calibrate(
        targetSeconds: Double = 0.75,
        maximumMemoryKiB: UInt32 = 256 * 1024
    ) throws -> Parameters {
        let probePassword = SecureBytes(utf8: "zyquo-calibration-probe")
        let salt = [UInt8](repeating: 0xA5, count: Floor.saltLength)
        var params = Parameters(
            memoryKiB: Floor.memoryKiB,
            iterations: Floor.iterations,
            parallelism: UInt32(min(4, max(1, ProcessInfo.processInfo.activeProcessorCount / 2)))
        )

        func measure(_ p: Parameters) throws -> Double {
            let start = DispatchTime.now()
            _ = try deriveKey(password: probePassword, salt: salt, parameters: p)
            return Double(DispatchTime.now().uptimeNanoseconds - start.uptimeNanoseconds) / 1e9
        }

        var elapsed = try measure(params)
        // Grow memory while comfortably under target and under the calibration cap.
        while elapsed < targetSeconds * 0.6, params.memoryKiB * 2 <= maximumMemoryKiB {
            params.memoryKiB *= 2
            elapsed = try measure(params)
        }
        // Then grow iterations toward the target.
        while elapsed < targetSeconds * 0.8, params.iterations < 8 {
            params.iterations += 1
            elapsed = try measure(params)
        }
        probePassword.wipe()
        return params
    }
}
