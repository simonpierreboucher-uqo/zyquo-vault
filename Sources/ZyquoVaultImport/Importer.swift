import Foundation
import ZyquoVaultDomain

/// Import pipeline entry point. Concrete importers (generic CSV, Bitwarden,
/// KeePass, browser CSV, Zyquo encrypted export) arrive with milestone M7.
/// Everything parses locally; nothing is ever uploaded or logged (§10.9).
public protocol VaultImporter: Sendable {
    /// Human-readable source name ("Bitwarden JSON", "Generic CSV", …).
    var sourceName: String { get }
    /// Parses `data` into vault items, throwing on malformed input.
    func parse(_ data: Data) throws -> [VaultItem]
}
