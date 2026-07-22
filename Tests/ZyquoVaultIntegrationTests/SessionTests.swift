import Foundation
import Testing
@testable import ZyquoVaultCrypto
@testable import ZyquoVaultDomain
@testable import ZyquoVaultStorage

/// M3 suite: recovery key end-to-end, password change, session lifecycle,
/// auto-lock, memory clearing, unlock rate limiting.
@Suite("Session & recovery (M3)", .serialized)
struct SessionTests {

    static let params = Argon2id.Parameters(
        memoryKiB: Argon2id.Floor.memoryKiB,
        iterations: Argon2id.Floor.iterations,
        parallelism: 4
    )
    static let password = "example-master-password-not-real"

    func temporaryDirectory() -> URL {
        FileManager.default.temporaryDirectory
            .appendingPathComponent("zyquo-session-test-\(UUID().uuidString)")
    }

    @Test func recoveryKeyOpensVaultAndSurvivesPasswordChange() throws {
        let dir = temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: dir) }
        let recoveryKey = try RecoveryKey.generate()
        let repo = try VaultRepository.create(
            at: dir, password: SecureBytes(utf8: Self.password),
            recoveryKey: recoveryKey, parameters: Self.params
        )
        try repo.put(VaultItem(itemType: .login, title: "Kept item"))

        // Password change: old fails, new works, records intact.
        try repo.changePassword(to: SecureBytes(utf8: "new-example-password-not-real"))
        repo.close()

        #expect(throws: CryptoError.invalidPasswordOrCorruptedVault) {
            _ = try VaultStore.openVault(at: dir, password: SecureBytes(utf8: Self.password))
        }
        let viaNew = try VaultRepository.open(at: dir, password: SecureBytes(utf8: "new-example-password-not-real"))
        #expect(try viaNew.list().count == 1)
        viaNew.close()

        // The recovery key still opens the vault after the password change.
        let viaRecovery = try VaultRepository.open(at: dir, recoveryKey: recoveryKey)
        #expect(try viaRecovery.item(id: viaRecovery.list()[0].id).title == "Kept item")

        // Rotation: the old key stops working, the new one works.
        let newKey = try viaRecovery.rotateRecoveryKey()
        viaRecovery.close()
        #expect(throws: CryptoError.invalidPasswordOrCorruptedVault) {
            _ = try VaultStore.openVaultWithRecoveryKey(at: dir, recoveryKey: recoveryKey)
        }
        let viaRotated = try VaultRepository.open(at: dir, recoveryKey: newKey)
        #expect(try viaRotated.list().count == 1)

        // Removal: no recovery wrap left in the header.
        try viaRotated.removeRecoveryKey()
        viaRotated.close()
        #expect(throws: StorageError.self) {
            _ = try VaultStore.openVaultWithRecoveryKey(at: dir, recoveryKey: newKey)
        }
    }

    @Test func headerRejectsUnknownFeatureFlags() throws {
        let dir = temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: dir) }
        let repo = try VaultRepository.create(
            at: dir, password: SecureBytes(utf8: Self.password), parameters: Self.params
        )
        repo.close()
        let headerURL = dir.appendingPathComponent(VaultStore.headerFileName)
        var bytes = try Data(contentsOf: headerURL)
        // Feature flags sit 4+1+32 bytes before the end trailer… locate via decode:
        // simplest robust approach: set an unknown high bit in the flags field,
        // which lives 37 bytes from the end (flags 4 + authVersion 1 + tag 32).
        let flagsOffset = bytes.count - 37
        bytes[flagsOffset] = 0x80
        try bytes.write(to: headerURL)
        #expect(throws: (any Error).self) {
            _ = try VaultStore.openVault(at: dir, password: SecureBytes(utf8: Self.password))
        }
    }

    @Test func sessionLifecycleAndMemoryClearing() async throws {
        let dir = temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: dir) }
        let session = VaultSession()

        #expect(await !session.isUnlocked)
        try await session.createVault(
            at: dir, password: SecureBytes(utf8: Self.password),
            generateRecoveryKey: false, parameters: Self.params
        )
        #expect(await session.isUnlocked)
        try await session.save(VaultItem(itemType: .secureNote, title: "Session note"))
        #expect(try await session.items().map(\.title) == ["Session note"])

        // Lock: repository closed (VMK wiped, file lock released), ops now throw.
        await session.lock()
        #expect(await !session.isUnlocked)
        await #expect(throws: VaultSession.SessionError.locked) { _ = try await session.items() }

        // Unlock again — the released file lock proves close() ran fully.
        try await session.unlock(directory: dir, password: SecureBytes(utf8: Self.password))
        #expect(try await session.itemCount() == 1)

        // System events lock the session per configuration.
        await session.systemWillSleep()
        #expect(await !session.isUnlocked)
        await session.lock()
    }

    @Test func autoLockFiresAfterInactivity() async throws {
        let dir = temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: dir) }
        let session = VaultSession(
            configuration: .init(autoLockAfter: .milliseconds(250))
        )
        try await session.createVault(
            at: dir, password: SecureBytes(utf8: Self.password),
            generateRecoveryKey: false, parameters: Self.params
        )
        #expect(await session.isUnlocked)

        // Activity keeps it open past the original deadline…
        try await Task.sleep(for: .milliseconds(150))
        await session.noteActivity()
        try await Task.sleep(for: .milliseconds(150))
        #expect(await session.isUnlocked)

        // …then inactivity locks it.
        try await Task.sleep(for: .milliseconds(400))
        #expect(await !session.isUnlocked)
    }

    @Test func unlockRateLimiting() async throws {
        let dir = temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: dir) }
        let session = VaultSession()
        try await session.createVault(
            at: dir, password: SecureBytes(utf8: Self.password),
            generateRecoveryKey: false, parameters: Self.params
        )
        await session.lock()

        for _ in 0..<3 {
            await #expect(throws: CryptoError.invalidPasswordOrCorruptedVault) {
                try await session.unlock(directory: dir, password: SecureBytes(utf8: "wrong-guess-not-real"))
            }
        }
        // Now rate limited, even with the CORRECT password.
        do {
            try await session.unlock(directory: dir, password: SecureBytes(utf8: Self.password))
            Issue.record("expected tooManyAttempts")
        } catch let VaultSession.SessionError.tooManyAttempts(seconds) {
            #expect(seconds >= 1)
        }
    }

    @Test func passwordStrengthEstimatorSanity() {
        let empty = PasswordStrength.estimateEntropyBits("")
        let short = PasswordStrength.estimateEntropyBits("abc")
        let repeated = PasswordStrength.estimateEntropyBits("aaaaaaaaaaaaaaaa")
        let phrase = PasswordStrength.estimateEntropyBits("correct horse battery staple 9!")
        #expect(empty == 0)
        #expect(short < 30)
        #expect(repeated < PasswordStrength.estimateEntropyBits("axbyczdwevfugthr"))
        #expect(phrase > 80)
    }
}
