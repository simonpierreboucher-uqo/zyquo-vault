import Foundation
import ZyquoVaultDomain

/// Bitwarden unencrypted JSON export importer (§10.9). Maps logins, secure
/// notes, cards, and identities, preserving folders, favorites, TOTP seeds,
/// URIs, and custom fields. Parses locally; rejects malformed input calmly.
public struct BitwardenJSONImporter: VaultImporter {
    public let sourceName = "Bitwarden (JSON)"

    public init() {}

    // Minimal mirror of the Bitwarden export schema (unknown keys ignored).
    struct Export: Decodable {
        var encrypted: Bool?
        var folders: [Folder]?
        var items: [Item]?
    }
    struct Folder: Decodable {
        var id: String
        var name: String
    }
    struct Item: Decodable {
        var type: Int
        var name: String?
        var notes: String?
        var favorite: Bool?
        var folderId: String?
        var login: Login?
        var card: Card?
        var identity: Identity?
        var fields: [CustomField]?
    }
    struct Login: Decodable {
        var username: String?
        var password: String?
        var totp: String?
        var uris: [URI]?
    }
    struct URI: Decodable { var uri: String? }
    struct Card: Decodable {
        var cardholderName: String?
        var number: String?
        var expMonth: String?
        var expYear: String?
        var code: String?
        var brand: String?
    }
    struct Identity: Decodable {
        var firstName: String?
        var lastName: String?
        var email: String?
        var phone: String?
        var address1: String?
        var city: String?
        var country: String?
    }
    struct CustomField: Decodable {
        var name: String?
        var value: String?
        var type: Int? // 0 text, 1 hidden, 2 boolean
    }

    /// Returned alongside items so the UI can recreate folders.
    public struct Result {
        public var items: [VaultItem]
        public var folders: [VaultFolder]
    }

    public func parse(_ data: Data) throws -> [VaultItem] {
        try parseWithFolders(data).items
    }

    public func parseWithFolders(_ data: Data) throws -> Result {
        guard data.count <= 256 << 20 else { throw ImportError.unreadableFile }
        let export: Export
        do {
            export = try JSONDecoder().decode(Export.self, from: data)
        } catch {
            throw ImportError.unrecognizedFormat(reason: "not a Bitwarden JSON export")
        }
        if export.encrypted == true {
            throw ImportError.unrecognizedFormat(
                reason: "this is a Bitwarden *encrypted* export — export as unencrypted JSON instead"
            )
        }
        guard let rawItems = export.items, !rawItems.isEmpty else { throw ImportError.emptyImport }

        // Bitwarden folder ids → new local folder UUIDs.
        var folderMap: [String: VaultFolder] = [:]
        for folder in export.folders ?? [] {
            folderMap[folder.id] = VaultFolder(name: folder.name)
        }

        var items: [VaultItem] = []
        for raw in rawItems {
            var fields: [VaultField] = []
            var itemType = VaultItemType.genericSecret

            switch raw.type {
            case 1: // login
                itemType = .login
                if let username = raw.login?.username, !username.isEmpty {
                    fields.append(VaultField(label: "Username", value: SensitiveFieldValue(username), kind: .username))
                }
                if let password = raw.login?.password, !password.isEmpty {
                    fields.append(VaultField(label: "Password", value: SensitiveFieldValue(password), kind: .password, isConcealed: true))
                }
                if let totp = raw.login?.totp, !totp.isEmpty {
                    fields.append(VaultField(label: "One-time code secret", value: SensitiveFieldValue(totp), kind: .totpSeed, isConcealed: true))
                }
                for (index, uri) in (raw.login?.uris ?? []).enumerated() {
                    if let value = uri.uri, !value.isEmpty {
                        fields.append(VaultField(
                            label: index == 0 ? "Website" : "Website \(index + 1)",
                            value: SensitiveFieldValue(value), kind: .url
                        ))
                    }
                }
            case 2: // secure note
                itemType = .secureNote
            case 3: // card
                itemType = .paymentCard
                if let holder = raw.card?.cardholderName, !holder.isEmpty {
                    fields.append(VaultField(label: "Cardholder", value: SensitiveFieldValue(holder), kind: .plain))
                }
                if let number = raw.card?.number, !number.isEmpty {
                    fields.append(VaultField(label: "Card number", value: SensitiveFieldValue(number), kind: .number, isConcealed: true))
                }
                let expiry = [raw.card?.expMonth, raw.card?.expYear].compactMap { $0 }.joined(separator: "/")
                if !expiry.isEmpty {
                    fields.append(VaultField(label: "Expiry", value: SensitiveFieldValue(expiry), kind: .date))
                }
                if let code = raw.card?.code, !code.isEmpty {
                    fields.append(VaultField(label: "Security code", value: SensitiveFieldValue(code), kind: .concealed, isConcealed: true))
                }
            case 4: // identity
                itemType = .identity
                let identity = raw.identity
                let name = [identity?.firstName, identity?.lastName].compactMap { $0 }.joined(separator: " ")
                if !name.isEmpty {
                    fields.append(VaultField(label: "Full name", value: SensitiveFieldValue(name), kind: .plain))
                }
                if let email = identity?.email, !email.isEmpty {
                    fields.append(VaultField(label: "Email", value: SensitiveFieldValue(email), kind: .email))
                }
                if let phone = identity?.phone, !phone.isEmpty {
                    fields.append(VaultField(label: "Phone", value: SensitiveFieldValue(phone), kind: .phone))
                }
                let address = [identity?.address1, identity?.city, identity?.country].compactMap { $0 }.joined(separator: ", ")
                if !address.isEmpty {
                    fields.append(VaultField(label: "Address", value: SensitiveFieldValue(address), kind: .plain))
                }
            default:
                continue // unknown types skipped, reported via count difference
            }

            for custom in raw.fields ?? [] {
                guard let value = custom.value, !value.isEmpty else { continue }
                fields.append(VaultField(
                    label: custom.name?.isEmpty == false ? custom.name! : "Custom field",
                    value: SensitiveFieldValue(value),
                    kind: custom.type == 1 ? .concealed : .custom,
                    isConcealed: custom.type == 1
                ))
            }

            items.append(VaultItem(
                itemType: itemType,
                title: raw.name?.isEmpty == false ? raw.name! : "Imported item",
                fields: fields,
                notes: raw.notes,
                folderID: raw.folderId.flatMap { folderMap[$0]?.id },
                isFavorite: raw.favorite ?? false
            ))
        }
        guard !items.isEmpty else { throw ImportError.emptyImport }
        return Result(items: items, folders: Array(folderMap.values))
    }
}
