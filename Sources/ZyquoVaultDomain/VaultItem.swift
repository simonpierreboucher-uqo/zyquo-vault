import Foundation

/// Item categories supported in v1 (CLAUDE.md §9). Raw values are persisted inside
/// encrypted payloads; never renumber.
public enum VaultItemType: String, Codable, Sendable, CaseIterable {
    case login
    case secureNote
    case apiCredential
    case softwareLicense
    case paymentCard
    case identity
    case sshCredential
    case totp
    case genericSecret
}

/// Field semantics; drives concealment, keyboard, validation, and icons.
public enum VaultFieldKind: String, Codable, Sendable, CaseIterable {
    case plain, concealed, username, password, url, email, phone, date, number
    case multiline, totpSeed, apiKey, privateKey, publicKey, custom
}

/// A secret-bearing string whose debug/description output is always redacted.
/// `Codable` is used strictly inside the encrypt/decrypt boundary — this value is
/// never persisted unencrypted.
public struct SensitiveFieldValue: Codable, Sendable, Equatable {
    private var storage: String

    public init(_ value: String) { self.storage = value }

    /// Scoped access; avoid retaining the returned string longer than needed.
    public func reveal() -> String { storage }

    public var isEmpty: Bool { storage.isEmpty }
}

extension SensitiveFieldValue: CustomStringConvertible, CustomDebugStringConvertible, CustomReflectable {
    public var description: String { "<redacted>" }
    public var debugDescription: String { "<redacted>" }
    public var customMirror: Mirror { Mirror(self, children: []) }
}

public struct VaultField: Identifiable, Codable, Sendable, Equatable {
    public let id: UUID
    public var label: String
    public var value: SensitiveFieldValue
    public var kind: VaultFieldKind
    public var isConcealed: Bool
    public var isCopyable: Bool

    public init(
        id: UUID = UUID(),
        label: String,
        value: SensitiveFieldValue,
        kind: VaultFieldKind,
        isConcealed: Bool = false,
        isCopyable: Bool = true
    ) {
        self.id = id
        self.label = label
        self.value = value
        self.kind = kind
        self.isConcealed = isConcealed
        self.isCopyable = isCopyable
    }
}

/// The decrypted form of a vault item. All descriptive metadata (title, tags,
/// folder, notes, …) lives INSIDE the encrypted payload (§9 metadata minimization).
public struct VaultItem: Identifiable, Codable, Sendable, Equatable {
    public let id: UUID
    public var itemType: VaultItemType
    public var title: String
    public var subtitle: String?
    public var fields: [VaultField]
    public var notes: String?
    public var tags: [String]
    public var folderID: UUID?
    public var isFavorite: Bool
    public var createdAt: Date
    public var updatedAt: Date
    public var revision: UInt64
    public var attachmentIDs: [UUID]
    /// Set when the item is in the encrypted trash (§7.2); nil = live.
    public var trashedAt: Date?

    public init(
        id: UUID = UUID(),
        itemType: VaultItemType,
        title: String,
        subtitle: String? = nil,
        fields: [VaultField] = [],
        notes: String? = nil,
        tags: [String] = [],
        folderID: UUID? = nil,
        isFavorite: Bool = false,
        createdAt: Date = Date(),
        updatedAt: Date = Date(),
        revision: UInt64 = 1,
        attachmentIDs: [UUID] = [],
        trashedAt: Date? = nil
    ) {
        self.id = id
        self.itemType = itemType
        self.title = title
        self.subtitle = subtitle
        self.fields = fields
        self.notes = notes
        self.tags = tags
        self.folderID = folderID
        self.isFavorite = isFavorite
        self.createdAt = createdAt
        self.updatedAt = updatedAt
        self.revision = revision
        self.attachmentIDs = attachmentIDs
        self.trashedAt = trashedAt
    }
}

/// A user-created folder/collection. Names are sensitive and persist only
/// inside the encrypted manifest payload.
public struct VaultFolder: Identifiable, Codable, Sendable, Equatable, Hashable {
    public let id: UUID
    public var name: String

    public init(id: UUID = UUID(), name: String) {
        self.id = id
        self.name = name
    }
}

/// Non-secret projection of an item for lists and the in-memory search index
/// (§10.6): titles, usernames, hostnames, tags — never passwords or seeds.
/// Lives only in memory while the session is unlocked.
public struct ItemSummary: Identifiable, Sendable, Equatable, Hashable {
    public let id: UUID
    public var itemType: VaultItemType
    public var title: String
    public var subtitle: String?
    public var tags: [String]
    public var folderID: UUID?
    public var isFavorite: Bool
    public var isTrashed: Bool
    public var updatedAt: Date
    /// Lowercased haystack built from non-secret fields only.
    public var searchText: String

    public init(item: VaultItem) {
        self.id = item.id
        self.itemType = item.itemType
        self.title = item.title
        self.subtitle = item.subtitle ?? item.fields.first(where: { $0.kind == .username })?.value.reveal()
        self.tags = item.tags
        self.folderID = item.folderID
        self.isFavorite = item.isFavorite
        self.isTrashed = item.trashedAt != nil
        self.updatedAt = item.updatedAt
        var haystack: [String] = [item.title]
        haystack.append(contentsOf: item.tags)
        if let subtitle = item.subtitle { haystack.append(subtitle) }
        for field in item.fields where !field.isConcealed {
            switch field.kind {
            case .username, .email, .phone, .plain, .custom:
                haystack.append(field.value.reveal())
                haystack.append(field.label)
            case .url:
                // Index the hostname only, per §10.6.
                let raw = field.value.reveal()
                if let host = URL(string: raw)?.host {
                    haystack.append(host)
                } else {
                    haystack.append(raw)
                }
                haystack.append(field.label)
            default:
                haystack.append(field.label) // labels are non-secret; values may not be
            }
        }
        self.searchText = haystack.joined(separator: " ").lowercased()
    }

    public func matches(_ query: String) -> Bool {
        let trimmed = query.trimmingCharacters(in: .whitespaces).lowercased()
        guard !trimmed.isEmpty else { return true }
        return trimmed.split(separator: " ").allSatisfy { searchText.contains($0) }
    }
}

/// Presentation metadata + starter fields per item type.
public enum ItemTemplates {

    public static func displayName(_ type: VaultItemType) -> String {
        switch type {
        case .login: "Login"
        case .secureNote: "Secure note"
        case .apiCredential: "API credential"
        case .softwareLicense: "Software license"
        case .paymentCard: "Payment card"
        case .identity: "Identity"
        case .sshCredential: "SSH credential"
        case .totp: "One-time code"
        case .genericSecret: "Generic secret"
        }
    }

    /// SF Symbol per type (hierarchical rendering in the UI).
    public static func icon(_ type: VaultItemType) -> String {
        switch type {
        case .login: "person.crop.circle"
        case .secureNote: "note.text"
        case .apiCredential: "curlybraces"
        case .softwareLicense: "checkmark.seal"
        case .paymentCard: "creditcard"
        case .identity: "person.text.rectangle"
        case .sshCredential: "terminal"
        case .totp: "clock.badge.checkmark"
        case .genericSecret: "key"
        }
    }

    /// Starter fields for a new item of `type`.
    public static func starterFields(_ type: VaultItemType) -> [VaultField] {
        func field(_ label: String, _ kind: VaultFieldKind, concealed: Bool = false) -> VaultField {
            VaultField(label: label, value: SensitiveFieldValue(""), kind: kind, isConcealed: concealed)
        }
        switch type {
        case .login:
            return [field("Username", .username), field("Password", .password, concealed: true), field("Website", .url)]
        case .secureNote:
            return []
        case .apiCredential:
            return [field("API key", .apiKey, concealed: true), field("Endpoint", .url)]
        case .softwareLicense:
            return [field("License key", .concealed, concealed: true), field("Licensed to", .plain)]
        case .paymentCard:
            return [field("Cardholder", .plain), field("Card number", .number, concealed: true),
                    field("Expiry", .date), field("Security code", .concealed, concealed: true)]
        case .identity:
            return [field("Full name", .plain), field("Email", .email), field("Phone", .phone)]
        case .sshCredential:
            return [field("Host", .plain), field("Username", .username),
                    field("Private key", .privateKey, concealed: true), field("Public key", .publicKey)]
        case .totp:
            return [field("Secret (base32)", .totpSeed, concealed: true), field("Issuer", .plain)]
        case .genericSecret:
            return [field("Secret", .concealed, concealed: true)]
        }
    }
}
