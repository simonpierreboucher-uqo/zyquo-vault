import Foundation
import Testing
@testable import ZyquoVaultCrypto
@testable import ZyquoVaultDomain
@testable import ZyquoVaultStorage

/// Regenerates the labeled test-vault fixture when explicitly requested via
/// `ZYQUO_GENERATE_FIXTURES=<repo-root>` (used by scripts/generate-test-vault.sh).
/// Fixture password: "example-password-not-real". Never contains real secrets.
@Suite("Fixture generation")
struct FixtureGeneration {

    @Test func generateBasicVaultFixtureIfRequested() throws {
        guard let root = ProcessInfo.processInfo.environment["ZYQUO_GENERATE_FIXTURES"] else {
            return // not requested; regular test runs skip silently
        }
        let dir = URL(fileURLWithPath: root)
            .appendingPathComponent("Fixtures/ValidVaults/basic-vault")
        try? FileManager.default.removeItem(at: dir)

        let repo = try VaultRepository.create(
            at: dir,
            password: SecureBytes(utf8: "example-password-not-real"),
            parameters: Argon2id.Parameters(
                memoryKiB: Argon2id.Floor.memoryKiB,
                iterations: Argon2id.Floor.iterations,
                parallelism: 4
            )
        )
        defer { repo.close() }

        try repo.put(VaultItem(
            itemType: .login,
            title: "Example website (fixture, not real)",
            fields: [
                VaultField(label: "Username", value: SensitiveFieldValue("fixture-user@example.com"), kind: .username),
                VaultField(label: "Password", value: SensitiveFieldValue("example-password-not-real"), kind: .password, isConcealed: true),
            ],
            tags: ["fixture", "non-production"]
        ))
        try repo.put(VaultItem(
            itemType: .secureNote,
            title: "Fixture note",
            notes: "This vault is a labeled test fixture. test-api-key-000000",
            tags: ["fixture"]
        ))
        #expect(repo.verifyIntegrity(deep: true).isClean)
        // The lock file is transient state; don't ship it in the fixture.
        try? FileManager.default.removeItem(at: dir.appendingPathComponent(VaultLock.fileName))
    }
}
