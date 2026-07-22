import Foundation

/// A best-effort secure container for sensitive byte buffers (passwords, keys, seeds).
///
/// Guarantees provided:
/// - Backing storage is a manually managed, page-aligned allocation, `mlock`ed where
///   possible so it is not written to swap (best-effort; failure is non-fatal).
/// - The buffer is zeroed with `memset_s` (not elidable by the optimizer) on `deinit`
///   and on explicit `wipe()`.
/// - `description` / `debugDescription` never reveal contents (`<redacted>`).
/// - Not `Codable`. Access is scoped through closures to discourage copies.
///
/// Honest limitations (see docs/cryptography.md §Memory): Swift may create transient
/// copies (ARC, `Data` bridging, String internals) that this type cannot reach.
/// `SecureBytes` reduces exposure; it cannot eliminate it.
public final class SecureBytes: @unchecked Sendable {
    private let pointer: UnsafeMutableRawPointer
    private let capacity: Int
    private let locked: Bool
    private let lock = NSLock()
    private var wiped = false

    /// Number of valid bytes.
    public let count: Int

    /// Creates a container by copying `bytes`, then wiping nothing of the caller's copy
    /// (the caller remains responsible for its own buffer).
    public init(bytes: [UInt8]) {
        self.count = bytes.count
        self.capacity = max(1, bytes.count)
        self.pointer = UnsafeMutableRawPointer.allocate(
            byteCount: capacity,
            alignment: Int(getpagesize())
        )
        self.locked = mlock(pointer, capacity) == 0
        if !bytes.isEmpty {
            bytes.withUnsafeBytes { src in
                pointer.copyMemory(from: src.baseAddress!, byteCount: bytes.count)
            }
        }
    }

    /// Creates a container of `count` bytes populated by `initializer`.
    public convenience init(count: Int, initializer: (UnsafeMutableRawBufferPointer) throws -> Void) rethrows {
        self.init(bytes: [UInt8](repeating: 0, count: count))
        try lock.withLock {
            try initializer(UnsafeMutableRawBufferPointer(start: pointer, count: count))
        }
    }

    /// Consumes a UTF-8 password `String` as late as possible. The returned container
    /// owns a copy; the `String`'s own backing cannot be erased (documented limitation).
    public convenience init(utf8 string: String) {
        self.init(bytes: Array(string.utf8))
    }

    /// Scoped read access. The pointer is valid only inside `body`; do not escape it.
    public func withUnsafeBytes<T>(_ body: (UnsafeRawBufferPointer) throws -> T) rethrows -> T {
        lock.lock()
        defer { lock.unlock() }
        precondition(!wiped, "SecureBytes accessed after wipe()")
        return try body(UnsafeRawBufferPointer(start: pointer, count: count))
    }

    /// Copies contents into a fresh `[UInt8]`. Use only at API boundaries that require
    /// value types (e.g. CryptoKit `SymmetricKey`); prefer `withUnsafeBytes`.
    public func copyBytes() -> [UInt8] {
        withUnsafeBytes { Array($0) }
    }

    /// Explicitly zeroes the buffer. The container must not be read afterwards.
    public func wipe() {
        lock.lock()
        defer { lock.unlock() }
        guard !wiped else { return }
        _ = memset_s(pointer, capacity, 0, capacity)
        wiped = true
    }

    deinit {
        _ = memset_s(pointer, capacity, 0, capacity)
        if locked { munlock(pointer, capacity) }
        pointer.deallocate()
    }
}

extension SecureBytes: CustomStringConvertible, CustomDebugStringConvertible {
    public var description: String { "<redacted>" }
    public var debugDescription: String { "<redacted>" }
}

extension SecureBytes: Equatable {
    /// Constant-time equality (never early-exits on content).
    public static func == (lhs: SecureBytes, rhs: SecureBytes) -> Bool {
        lhs.withUnsafeBytes { l in
            rhs.withUnsafeBytes { r in
                constantTimeEquals(l, r)
            }
        }
    }
}
