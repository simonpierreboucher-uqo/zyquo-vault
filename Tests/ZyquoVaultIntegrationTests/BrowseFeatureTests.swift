import Foundation
import Testing
@testable import ZyquoVaultCrypto
@testable import ZyquoVaultDomain
@testable import ZyquoVaultStorage

/// M4 suite: trash lifecycle, duplication, folders, summaries & search index.
@Suite("Browse features (M4)", .serialized)
struct BrowseFeatureTests {

    static let params = Argon2id.Parameters(
        memoryKiB: Argon2id.Floor.memoryKiB,
        iterations: Argon2id.Floor.iterations,
        parallelism: 4
    )

    func makeSession() async throws -> (dir: URL, session: VaultSession) {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("zyquo-browse-test-\(UUID().uuidString)")
        let session = VaultSession()
        try await session.createVault(
            at: dir, password: SecureBytes(utf8: "example-master-password-not-real"),
            generateRecoveryKey: false, parameters: Self.params
        )
        return (dir, session)
    }

    @Test func trashLifecycle() async throws {
        let (dir, session) = try await makeSession()
        defer { try? FileManager.default.removeItem(at: dir) }

        let item = VaultItem(itemType: .login, title: "Trashy")
        try await session.save(item)

        // Trash: still stored (encrypted), summary flagged, restorable.
        try await session.trash(id: item.id)
        var summaries = try await session.summaries()
        #expect(summaries.first?.isTrashed == true)
        #expect(try await session.itemCount() == 1)

        try await session.restore(id: item.id)
        summaries = try await session.summaries()
        #expect(summaries.first?.isTrashed == false)

        // Empty trash removes only trashed items.
        let keeper = VaultItem(itemType: .secureNote, title: "Keeper")
        try await session.save(keeper)
        try await session.trash(id: item.id)
        try await session.emptyTrash()
        summaries = try await session.summaries()
        #expect(summaries.map(\.title) == ["Keeper"])

        // Permanent delete of a live item.
        try await session.deletePermanently(id: keeper.id)
        #expect(try await session.itemCount() == 0)
        await session.lock()
    }

    @Test func duplicateCreatesIndependentCopy() async throws {
        let (dir, session) = try await makeSession()
        defer { try? FileManager.default.removeItem(at: dir) }

        var original = VaultItem(itemType: .login, title: "Original", isFavorite: true)
        original.fields = [VaultField(label: "Password", value: SensitiveFieldValue("example-password-not-real"), kind: .password, isConcealed: true)]
        try await session.save(original)

        let copy = try await session.duplicate(id: original.id)
        #expect(copy.id != original.id)
        #expect(copy.title == "Original copy")
        #expect(copy.isFavorite == false)
        #expect(copy.fields.first?.value.reveal() == "example-password-not-real")
        #expect(copy.fields.first?.id != original.fields.first?.id)
        #expect(try await session.itemCount() == 2)
        await session.lock()
    }

    @Test func foldersPersistInsideEncryptedManifest() async throws {
        let (dir, session) = try await makeSession()
        defer { try? FileManager.default.removeItem(at: dir) }

        let work = VaultFolder(name: "Work secrets")
        try await session.setFolders([work])
        var item = VaultItem(itemType: .login, title: "Filed")
        item.folderID = work.id
        try await session.save(item)
        await session.lock()

        // Reopen: folders decrypt from the manifest; nothing plaintext on disk.
        try await session.unlock(directory: dir, password: SecureBytes(utf8: "example-master-password-not-real"))
        let folders = try await session.folders()
        #expect(folders == [work])
        #expect(try await session.summaries().first?.folderID == work.id)

        let manifestBytes = try Data(contentsOf: dir.appendingPathComponent(VaultManifest.fileName))
        #expect(!String(decoding: manifestBytes, as: UTF8.self).contains("Work secrets"))
        await session.lock()
    }

    @Test func summariesIndexNonSecretsOnly() throws {
        var item = VaultItem(itemType: .login, title: "GitHub", tags: ["dev"])
        item.fields = [
            VaultField(label: "Username", value: SensitiveFieldValue("octo@example.com"), kind: .username),
            VaultField(label: "Website", value: SensitiveFieldValue("https://github.com/login"), kind: .url),
            VaultField(label: "Password", value: SensitiveFieldValue("s3cret-example-not-real"), kind: .password, isConcealed: true),
        ]
        let summary = ItemSummary(item: item)

        // Indexed: title, tags, username, URL *hostname*, labels.
        #expect(summary.matches("github"))
        #expect(summary.matches("octo"))
        #expect(summary.matches("dev"))
        #expect(summary.matches("github.com"))
        #expect(summary.matches("GitHub octo")) // all terms must match
        // Never indexed: concealed values; full URL path is reduced to host.
        #expect(!summary.searchText.contains("s3cret"))
        #expect(!summary.searchText.contains("/login"))
        #expect(!summary.matches("s3cret-example-not-real"))
        // Subtitle falls back to the username field.
        #expect(summary.subtitle == "octo@example.com")
        #expect(summary.matches(""))
        #expect(!summary.matches("bitbucket"))
    }
}
