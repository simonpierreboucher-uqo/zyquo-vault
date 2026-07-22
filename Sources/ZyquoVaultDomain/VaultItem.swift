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
        attachmentIDs: [UUID] = []
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
    }
}
