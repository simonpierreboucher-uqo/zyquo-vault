import Foundation
import Testing
@testable import ZyquoVaultDomain

@Suite("Domain model redaction & serialization")
struct SensitiveValueTests {

    @Test func sensitiveValueNeverPrintsItsContents() {
        let secret = SensitiveFieldValue("example-password-not-real")
        #expect(String(describing: secret) == "<redacted>")
        #expect(String(reflecting: secret) == "<redacted>")
        #expect(Mirror(reflecting: secret).children.isEmpty)
        #expect(secret.reveal() == "example-password-not-real")
    }

    @Test func fieldInterpolationStaysRedacted() {
        let field = VaultField(
            label: "Password",
            value: SensitiveFieldValue("example-password-not-real"),
            kind: .password,
            isConcealed: true
        )
        let printed = "\(field)"
        #expect(!printed.contains("example-password-not-real"))
    }

    @Test func itemCodableRoundTrip() throws {
        let item = VaultItem(
            itemType: .login,
            title: "Example service",
            subtitle: "user@example.com",
            fields: [
                VaultField(label: "Username", value: SensitiveFieldValue("user@example.com"), kind: .username),
                VaultField(label: "Password", value: SensitiveFieldValue("example-password-not-real"), kind: .password, isConcealed: true),
            ],
            tags: ["test-fixture"],
            isFavorite: true
        )
        // Codable is used strictly inside the encrypt/decrypt boundary.
        let encoded = try JSONEncoder().encode(item)
        let decoded = try JSONDecoder().decode(VaultItem.self, from: encoded)
        #expect(decoded == item)
    }
}
