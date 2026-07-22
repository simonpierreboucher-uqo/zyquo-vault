import Foundation

/// Constant-time byte-buffer comparison for MACs and verifiers.
///
/// Returns `false` immediately when lengths differ (length is not secret in every
/// context where this is used — tags and digests have fixed public lengths).
/// For equal lengths, the running time does not depend on the contents.
public func constantTimeEquals(_ lhs: UnsafeRawBufferPointer, _ rhs: UnsafeRawBufferPointer) -> Bool {
    guard lhs.count == rhs.count else { return false }
    var accumulator: UInt8 = 0
    for i in 0..<lhs.count {
        accumulator |= lhs[i] ^ rhs[i]
    }
    return accumulator == 0
}

/// Convenience overload for byte arrays / `Data`.
public func constantTimeEquals<L: ContiguousBytes, R: ContiguousBytes>(_ lhs: L, _ rhs: R) -> Bool {
    lhs.withUnsafeBytes { l in
        rhs.withUnsafeBytes { r in
            constantTimeEquals(l, r)
        }
    }
}
