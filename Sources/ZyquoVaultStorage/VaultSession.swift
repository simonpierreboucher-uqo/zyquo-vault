import Foundation
import ZyquoVaultCrypto
import ZyquoVaultDomain

/// The one owner of unlocked key material (CLAUDE.md §8.2). UI views never hold
/// the VMK, subkeys, or the repository — they talk to this actor.
///
/// Locking (§8.3) closes the repository (which zeroes the VMK and releases the
/// process lock) and drops every decrypted value this actor holds. Hiding UI
/// while keys stay alive is impossible by construction: the lock screen appears
/// because the keys are gone.
public actor VaultSession {

    public struct Configuration: Sendable, Equatable {
        /// Inactivity window before auto-lock. Default 5 minutes.
        public var autoLockAfter: Duration
        public var lockOnSleep: Bool
        public var lockOnScreenLock: Bool

        public init(
            autoLockAfter: Duration = .seconds(300),
            lockOnSleep: Bool = true,
            lockOnScreenLock: Bool = true
        ) {
            self.autoLockAfter = autoLockAfter
            self.lockOnSleep = lockOnSleep
            self.lockOnScreenLock = lockOnScreenLock
        }
    }

    public enum SessionError: Error, Equatable, Sendable {
        case locked
        case emptyPasswordForbidden
        /// In-process unlock rate limiting (§10.2). Offline attacks are
        /// unaffected — this only slows interactive guessing.
        case tooManyAttempts(retryAfterSeconds: Int)
    }

    private var repository: VaultRepository?
    private var configuration: Configuration
    private let clock = ContinuousClock()
    private var lastActivity: ContinuousClock.Instant
    private var autoLockTask: Task<Void, Never>?
    /// Bumped on every lock so the UI can react (observed via polling or await).
    public private(set) var lockGeneration: UInt64 = 0
    private var lockObservers: [UUID: AsyncStream<Void>.Continuation] = [:]
    private var failedUnlockAttempts = 0
    private var nextUnlockAllowedAt: ContinuousClock.Instant?

    public init(configuration: Configuration = Configuration()) {
        self.configuration = configuration
        self.lastActivity = clock.now
    }

    // MARK: State

    public var isUnlocked: Bool { repository != nil }

    public var currentConfiguration: Configuration { configuration }

    public func updateConfiguration(_ new: Configuration) {
        configuration = new
        noteActivity()
    }

    public var vaultID: UUID? { repository?.header.vaultID }

    public var hasRecoveryKey: Bool { repository?.header.recoveryWrap != nil }

    public var permissionWarnings: [String] { repository?.permissionWarnings ?? [] }

    // MARK: Create / unlock / lock

    /// Creates a vault and leaves the session unlocked on it. Returns the
    /// generated recovery key (ceremony: show once) when requested.
    @discardableResult
    public func createVault(
        at directory: URL,
        password: SecureBytes,
        generateRecoveryKey: Bool,
        parameters: Argon2id.Parameters
    ) throws -> RecoveryKey? {
        guard password.count > 0 else { throw SessionError.emptyPasswordForbidden }
        lock()
        let recoveryKey = generateRecoveryKey ? try RecoveryKey.generate() : nil
        repository = try VaultRepository.create(
            at: directory, password: password,
            recoveryKey: recoveryKey, parameters: parameters
        )
        afterUnlock()
        return recoveryKey
    }

    public func unlock(directory: URL, password: SecureBytes) throws {
        try enforceRateLimit()
        lock()
        do {
            repository = try VaultRepository.open(at: directory, password: password)
        } catch {
            registerFailedUnlock(error)
            throw error
        }
        failedUnlockAttempts = 0
        afterUnlock()
    }

    public func unlock(directory: URL, recoveryKey: RecoveryKey) throws {
        try enforceRateLimit()
        lock()
        do {
            repository = try VaultRepository.open(at: directory, recoveryKey: recoveryKey)
        } catch {
            registerFailedUnlock(error)
            throw error
        }
        failedUnlockAttempts = 0
        afterUnlock()
    }

    private func enforceRateLimit() throws {
        if let at = nextUnlockAllowedAt, clock.now < at {
            let remaining = clock.now.duration(to: at)
            throw SessionError.tooManyAttempts(
                retryAfterSeconds: max(1, Int(remaining.components.seconds))
            )
        }
    }

    private func registerFailedUnlock(_ error: Error) {
        // Only wrong-password/corruption counts; locks and IO errors don't.
        guard case CryptoError.invalidPasswordOrCorruptedVault = error else { return }
        failedUnlockAttempts += 1
        if failedUnlockAttempts >= 3 {
            let delay = min(30, 1 << min(failedUnlockAttempts - 3, 5))
            nextUnlockAllowedAt = clock.now + .seconds(delay)
        }
    }

    /// Re-verifies the current password against the open vault's header without
    /// disturbing the session (used before password change / sensitive settings).
    public func verifyPassword(_ password: SecureBytes) -> Bool {
        guard let repository else { return false }
        guard let vmk = try? KeyHierarchy.unwrap(
            repository.header.wrappedVMK, password: password,
            vaultID: repository.header.vaultID,
            formatVersion: repository.header.formatVersion
        ) else { return false }
        vmk.wipe()
        noteActivity()
        return true
    }

    /// Fires once per lock (manual, auto, sleep, …) for the app layer to observe.
    public func lockEventStream() -> AsyncStream<Void> {
        AsyncStream { continuation in
            let id = UUID()
            lockObservers[id] = continuation
            continuation.onTermination = { [weak self] _ in
                Task { await self?.removeLockObserver(id) }
            }
        }
    }

    private func removeLockObserver(_ id: UUID) {
        lockObservers[id] = nil
    }

    /// Locks immediately: zeroes the VMK, releases the process lock, cancels the
    /// auto-lock watcher, and invalidates everything derived from this session.
    public func lock() {
        autoLockTask?.cancel()
        autoLockTask = nil
        if let repository {
            repository.close()
            self.repository = nil
            lockGeneration &+= 1
            for continuation in lockObservers.values {
                continuation.yield()
            }
        }
    }

    private func afterUnlock() {
        noteActivity()
        scheduleAutoLock()
    }

    // MARK: Activity & auto-lock

    /// Any meaningful user interaction resets the inactivity window.
    public func noteActivity() {
        lastActivity = clock.now
    }

    private func scheduleAutoLock() {
        autoLockTask?.cancel()
        autoLockTask = Task { [weak self] in
            while let self, !Task.isCancelled {
                let deadline = await self.lastActivity + self.configuration.autoLockAfter
                if self.clock.now >= deadline {
                    await self.lock()
                    return
                }
                try? await self.clock.sleep(until: deadline)
            }
        }
    }

    /// System events routed from the app layer (sleep, screen lock, quit).
    public func systemWillSleep() {
        if configuration.lockOnSleep { lock() }
    }

    public func screenDidLock() {
        if configuration.lockOnScreenLock { lock() }
    }

    public func applicationWillTerminate() {
        lock()
    }

    // MARK: Vault operations (all require an unlocked session)

    private func requireRepository() throws -> VaultRepository {
        guard let repository else { throw SessionError.locked }
        noteActivity()
        return repository
    }

    /// Decrypts all live items (M4 adds the bounded cache + summaries).
    public func items() throws -> [VaultItem] {
        let repo = try requireRepository()
        return try repo.list().map { try repo.item(id: $0.id) }
            .sorted { $0.title.localizedCaseInsensitiveCompare($1.title) == .orderedAscending }
    }

    public func item(id: UUID) throws -> VaultItem {
        try requireRepository().item(id: id)
    }

    @discardableResult
    public func save(_ item: VaultItem) throws -> UInt64 {
        try requireRepository().put(item)
    }

    public func delete(id: UUID) throws {
        try requireRepository().delete(id: id)
    }

    public func verifyIntegrity(deep: Bool) throws -> IntegrityReport {
        try requireRepository().verifyIntegrity(deep: deep)
    }

    public func itemCount() throws -> Int {
        try requireRepository().list().count
    }

    /// Non-secret summaries for lists and the in-memory search index (§10.6).
    /// Never persisted; the UI discards its copy on lock.
    public func summaries() throws -> [ItemSummary] {
        try requireRepository().summaries()
            .sorted { $0.title.localizedCaseInsensitiveCompare($1.title) == .orderedAscending }
    }

    // MARK: Trash (§7.2 — encrypted trash; deletion honesty)

    /// Moves an item to the encrypted trash (recoverable).
    public func trash(id: UUID) throws {
        let repo = try requireRepository()
        var item = try repo.item(id: id)
        item.trashedAt = Date()
        try repo.put(item)
    }

    /// Restores an item from the trash.
    public func restore(id: UUID) throws {
        let repo = try requireRepository()
        var item = try repo.item(id: id)
        item.trashedAt = nil
        try repo.put(item)
    }

    /// Permanent deletion: ciphertext removed, wrapped DEK gone with it. Old
    /// backups may still hold the encrypted item (documented honestly).
    public func deletePermanently(id: UUID) throws {
        try requireRepository().delete(id: id)
    }

    public func emptyTrash() throws {
        let repo = try requireRepository()
        for entry in repo.list() {
            if try repo.item(id: entry.id).trashedAt != nil {
                try repo.delete(id: entry.id)
            }
        }
    }

    /// Duplicates an item (new identity, "copy" suffix, never a favorite).
    @discardableResult
    public func duplicate(id: UUID) throws -> VaultItem {
        let repo = try requireRepository()
        let source = try repo.item(id: id)
        var copy = VaultItem(
            itemType: source.itemType,
            title: source.title + " copy",
            subtitle: source.subtitle,
            fields: source.fields.map {
                VaultField(label: $0.label, value: $0.value, kind: $0.kind,
                           isConcealed: $0.isConcealed, isCopyable: $0.isCopyable)
            },
            notes: source.notes,
            tags: source.tags,
            folderID: source.folderID
        )
        copy.attachmentIDs = []
        try repo.put(copy)
        return copy
    }

    // MARK: Folders

    public func folders() throws -> [VaultFolder] {
        try requireRepository().folders()
    }

    public func setFolders(_ folders: [VaultFolder]) throws {
        try requireRepository().setFolders(folders)
    }

    /// §5.4 password change. The UI re-verifies the current password first.
    public func changePassword(to newPassword: SecureBytes) throws {
        guard newPassword.count > 0 else { throw SessionError.emptyPasswordForbidden }
        try requireRepository().changePassword(to: newPassword)
    }

    public func rotateRecoveryKey() throws -> RecoveryKey {
        try requireRepository().rotateRecoveryKey()
    }

    /// Installs a caller-provided recovery key (creation ceremony flow).
    public func installRecoveryKey(_ key: RecoveryKey) throws {
        try requireRepository().installRecoveryKey(key)
    }
}
