import AppKit
import Observation
import SwiftUI
import ZyquoVaultCrypto
import ZyquoVaultStorage

/// UI-facing application state. Owns no key material — everything sensitive
/// lives inside the `VaultSession` actor. `@MainActor` throughout.
@MainActor
@Observable
public final class AppModel {

    public enum Screen: Equatable {
        case loading
        case welcome           // no vault yet
        case locked            // vault exists, session locked
        case unlocked
    }

    public let session = VaultSession()
    public private(set) var screen: Screen = .loading
    public private(set) var vaultDirectory: URL?
    public var vaultName: String = "My vault"
    /// Non-fatal notices surfaced after unlock (permissions, recovery hints).
    public private(set) var startupWarnings: [String] = []

    @ObservationIgnored private var observersInstalled = false

    public init() {}

    // MARK: Locations

    /// `…/Application Support/Zyquo Vault/vaults` (inside the sandbox container
    /// when sandboxed — same logical path either way).
    public static func vaultsRoot() -> URL {
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first!
        return base.appendingPathComponent("Zyquo Vault/vaults", isDirectory: true)
    }

    /// Newest directory containing a vault header, if any.
    static func discoverDefaultVault() -> URL? {
        let root = vaultsRoot()
        let fm = FileManager.default
        guard let entries = try? fm.contentsOfDirectory(
            at: root, includingPropertiesForKeys: [.contentModificationDateKey]
        ) else { return nil }
        return entries
            .filter { fm.fileExists(atPath: $0.appendingPathComponent(VaultStore.headerFileName).path) }
            .max { a, b in
                let da = (try? a.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate) ?? .distantPast
                let db = (try? b.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate) ?? .distantPast
                return da < db
            }
    }

    // MARK: Lifecycle

    public func bootstrap() {
        installSystemObservers()
        if let dir = Self.discoverDefaultVault() {
            vaultDirectory = dir
            vaultName = Self.storedName(for: dir) ?? "My vault"
            screen = .locked
        } else {
            screen = .welcome
        }
    }

    public func didUnlock() {
        Task { self.startupWarnings = await session.permissionWarnings }
        screen = .unlocked
    }

    public func didCreateVault(at directory: URL, name: String) {
        vaultDirectory = directory
        vaultName = name
        Self.storeName(name, for: directory)
        screen = .unlocked
    }

    public func lockNow() {
        Task {
            await session.lock() // the lock-event stream flips the screen
        }
    }

    // MARK: Vault display names (non-sensitive preference; the lock screen must
    // show a name before any key exists. Documented as observable metadata.)

    static func storedName(for directory: URL) -> String? {
        (UserDefaults.standard.dictionary(forKey: "vaultDisplayNames") as? [String: String])?[directory.lastPathComponent]
    }

    static func storeName(_ name: String, for directory: URL) {
        var names = (UserDefaults.standard.dictionary(forKey: "vaultDisplayNames") as? [String: String]) ?? [:]
        names[directory.lastPathComponent] = name
        UserDefaults.standard.set(names, forKey: "vaultDisplayNames")
    }

    // MARK: System lock triggers (§8.3)

    private func installSystemObservers() {
        guard !observersInstalled else { return }
        observersInstalled = true

        // React to every session lock, whatever triggered it.
        Task { [weak self] in
            guard let self else { return }
            for await _ in await self.session.lockEventStream() {
                if self.screen == .unlocked { self.screen = .locked }
            }
        }

        let workspace = NSWorkspace.shared.notificationCenter
        workspace.addObserver(forName: NSWorkspace.willSleepNotification, object: nil, queue: .main) { [weak self] _ in
            guard let session = self?.session else { return }
            Task { await session.systemWillSleep() }
        }
        DistributedNotificationCenter.default().addObserver(
            forName: Notification.Name("com.apple.screenIsLocked"), object: nil, queue: .main
        ) { [weak self] _ in
            guard let session = self?.session else { return }
            Task { await session.screenDidLock() }
        }
        NotificationCenter.default.addObserver(
            forName: NSApplication.willTerminateNotification, object: nil, queue: .main
        ) { [weak self] _ in
            guard let session = self?.session else { return }
            Task { await session.applicationWillTerminate() }
        }
    }
}
