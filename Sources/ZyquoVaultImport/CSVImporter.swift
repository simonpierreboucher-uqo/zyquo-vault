import Foundation
import ZyquoVaultDomain

/// RFC 4180 CSV parsing: quoted fields, embedded commas/newlines/escaped
/// quotes, CR/LF/CRLF line endings. Crash-free on any input (fuzz-tested).
public enum CSV {

    public static func parse(_ text: String) -> [[String]] {
        var rows: [[String]] = []
        var row: [String] = []
        var field = ""
        var inQuotes = false
        var iterator = text.makeIterator()
        var pending: Character?

        func endField() {
            row.append(field)
            field = ""
        }
        func endRow() {
            endField()
            // Skip fully empty trailing rows.
            if !(row.count == 1 && row[0].isEmpty) { rows.append(row) }
            row = []
        }

        while let char = pending ?? iterator.next() {
            pending = nil
            if inQuotes {
                if char == "\"" {
                    if let next = iterator.next() {
                        if next == "\"" {
                            field.append("\"") // escaped quote
                        } else {
                            inQuotes = false
                            pending = next
                        }
                    } else {
                        inQuotes = false
                    }
                } else {
                    field.append(char)
                }
            } else {
                switch char {
                case "\"" where field.isEmpty:
                    inQuotes = true
                case ",":
                    endField()
                // Swift groups "\r\n" into a single grapheme-cluster Character,
                // so all three newline forms are distinct single cases here.
                case "\r\n", "\n", "\r":
                    endRow()
                default:
                    field.append(char)
                }
            }
        }
        if !field.isEmpty || !row.isEmpty { endRow() }
        return rows
    }

    /// Minimal escaping for plaintext CSV export.
    public static func escape(_ field: String) -> String {
        if field.contains(where: { $0 == "," || $0 == "\"" || $0 == "\n" || $0 == "\r" }) {
            return "\"" + field.replacingOccurrences(of: "\"", with: "\"\"") + "\""
        }
        return field
    }
}

/// Errors shared by importers. Never carries field values.
public enum ImportError: Error, Equatable, Sendable {
    case unreadableFile
    case unrecognizedFormat(reason: String)
    case emptyImport
}

/// Generic CSV importer (§10.9): header-driven column mapping that also covers
/// browser exports (Chrome/Edge/Firefox/Safari all use name/url/username/
/// password headers). Everything parses locally; nothing is logged.
public struct GenericCSVImporter: VaultImporter {
    public let sourceName = "CSV (generic / browser)"

    public init() {}

    static let titleKeys = ["title", "name", "item", "account"]
    static let usernameKeys = ["username", "user", "login", "login_username", "email"]
    static let passwordKeys = ["password", "login_password", "pass"]
    static let urlKeys = ["url", "website", "web site", "login_uri", "uri"]
    static let notesKeys = ["notes", "note", "comments", "extra"]
    static let totpKeys = ["totp", "otp", "otpauth", "2fa"]
    static let tagsKeys = ["tags", "labels"]

    public func parse(_ data: Data) throws -> [VaultItem] {
        guard let text = String(data: data, encoding: .utf8) ?? String(data: data, encoding: .isoLatin1) else {
            throw ImportError.unreadableFile
        }
        let rows = CSV.parse(text)
        guard rows.count >= 2 else {
            throw ImportError.unrecognizedFormat(reason: "a header row and at least one item row are required")
        }
        let header = rows[0].map { $0.trimmingCharacters(in: .whitespaces).lowercased() }

        func column(_ keys: [String]) -> Int? {
            for key in keys {
                if let index = header.firstIndex(of: key) { return index }
            }
            return nil
        }
        guard let passwordColumn = column(Self.passwordKeys) else {
            throw ImportError.unrecognizedFormat(reason: "no password column found in the header")
        }
        let titleColumn = column(Self.titleKeys)
        let usernameColumn = column(Self.usernameKeys)
        let urlColumn = column(Self.urlKeys)
        let notesColumn = column(Self.notesKeys)
        let totpColumn = column(Self.totpKeys)
        let tagsColumn = column(Self.tagsKeys)

        func value(_ row: [String], _ index: Int?) -> String? {
            guard let index, index < row.count else { return nil }
            let v = row[index].trimmingCharacters(in: .whitespacesAndNewlines)
            return v.isEmpty ? nil : v
        }

        var items: [VaultItem] = []
        for row in rows.dropFirst() {
            var fields: [VaultField] = []
            if let username = value(row, usernameColumn) {
                fields.append(VaultField(label: "Username", value: SensitiveFieldValue(username), kind: .username))
            }
            if let password = value(row, passwordColumn) {
                fields.append(VaultField(label: "Password", value: SensitiveFieldValue(password), kind: .password, isConcealed: true))
            }
            if let url = value(row, urlColumn) {
                fields.append(VaultField(label: "Website", value: SensitiveFieldValue(url), kind: .url))
            }
            if let totp = value(row, totpColumn) {
                fields.append(VaultField(label: "One-time code secret", value: SensitiveFieldValue(totp), kind: .totpSeed, isConcealed: true))
            }
            guard !fields.isEmpty else { continue }
            let fallbackTitle = value(row, urlColumn).flatMap { URL(string: $0)?.host } ?? "Imported login"
            items.append(VaultItem(
                itemType: .login,
                title: value(row, titleColumn) ?? fallbackTitle,
                fields: fields,
                notes: value(row, notesColumn),
                tags: value(row, tagsColumn)?
                    .split(whereSeparator: { $0 == "," || $0 == ";" })
                    .map { $0.trimmingCharacters(in: .whitespaces) } ?? []
            ))
        }
        guard !items.isEmpty else { throw ImportError.emptyImport }
        return items
    }
}
