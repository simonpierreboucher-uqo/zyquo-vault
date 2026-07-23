import Foundation
import Testing
@testable import ZyquoVaultCrypto
@testable import ZyquoVaultDomain
@testable import ZyquoVaultStorage

/// M8 performance profile (§14). Bounds are deliberately generous — these catch
/// order-of-magnitude regressions, not micro-drift. Timings print to the test
/// log and are recorded in docs/architecture.md.
@Suite("Performance profile (M8)", .serialized)
struct PerformanceTests {

    static let params = Argon2id.Parameters(
        memoryKiB: Argon2id.Floor.memoryKiB,
        iterations: Argon2id.Floor.iterations,
        parallelism: 4
    )

    func measure(_ label: String, _ body: () throws -> Void) rethrows -> Double {
        let start = DispatchTime.now()
        try body()
        let seconds = Double(DispatchTime.now().uptimeNanoseconds - start.uptimeNanoseconds) / 1e9
        print("perf: \(label) = \(String(format: "%.3f", seconds))s")
        return seconds
    }

    @Test func largeVaultProfile() throws {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("zyquo-perf-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: dir) }
        let password = SecureBytes(utf8: "example-master-password-not-real")
        let repo = try VaultRepository.create(at: dir, password: password, parameters: Self.params)

        // 200 records with realistic field counts.
        let writeTime = try measure("write 200 records (journalled, FULLFSYNC×2 each)") {
            for index in 0..<200 {
                try repo.put(VaultItem(
                    itemType: .login,
                    title: "Perf item \(index)",
                    fields: [
                        VaultField(label: "Username", value: SensitiveFieldValue("user\(index)@example.com"), kind: .username),
                        VaultField(label: "Password", value: SensitiveFieldValue("example-password-not-real-\(index)"), kind: .password, isConcealed: true),
                        VaultField(label: "Website", value: SensitiveFieldValue("https://example\(index).com"), kind: .url),
                    ],
                    tags: ["perf", "tag\(index % 10)"]
                ))
            }
        }
        repo.close()

        // Unlock (KDF at floor params) + manifest load + journal scan.
        var reopened: VaultRepository?
        let unlockTime = try measure("unlock (Argon2id 64MiB/t3 + open)") {
            reopened = try VaultRepository.open(at: dir, password: SecureBytes(utf8: "example-master-password-not-real"))
        }
        let repo2 = reopened!
        defer { repo2.close() }

        // Decrypt-all summary build (the M4 search index path).
        var summaries: [ItemSummary] = []
        let summariesTime = try measure("summaries() — decrypt all 200 records") {
            summaries = try repo2.summaries()
        }
        #expect(summaries.count == 200)

        let verifyTime = measure("verifyIntegrity(deep) — 200 records") {
            #expect(repo2.verifyIntegrity(deep: true).isClean)
        }

        // Generous ceilings (Apple Silicon, floor KDF params).
        #expect(writeTime < 60)
        #expect(unlockTime < 3)
        #expect(summariesTime < 3)
        #expect(verifyTime < 3)
    }
}
