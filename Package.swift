// swift-tools-version: 6.0
// Zyquo Vault — local-first, offline password manager for macOS.
// Canonical project definition. Built entirely from the terminal; no Xcode.
import PackageDescription

let package = Package(
    name: "ZyquoVault",
    defaultLocalization: "en",
    platforms: [
        .macOS(.v15)
    ],
    products: [
        .executable(name: "ZyquoVaultApp", targets: ["ZyquoVaultApp"]),
        .executable(name: "zyquo-vault-cli", targets: ["ZyquoVaultCLI"]),
        .library(name: "ZyquoVaultCrypto", targets: ["ZyquoVaultCrypto"]),
        .library(name: "ZyquoVaultStorage", targets: ["ZyquoVaultStorage"]),
        .library(name: "ZyquoVaultDomain", targets: ["ZyquoVaultDomain"]),
        .library(name: "ZyquoVaultDesign", targets: ["ZyquoVaultDesign"]),
    ],
    targets: [
        // MARK: Vendored official Argon2 reference implementation (PHC winner).
        // See docs/decisions/ADR-0002-argon2-vendored-reference.md.
        .target(
            name: "CArgon2",
            cSettings: [
                .headerSearchPath(".")
            ]
        ),

        // MARK: Cryptography — depends on nothing internal except CArgon2.
        .target(
            name: "ZyquoVaultCrypto",
            dependencies: ["CArgon2"],
            swiftSettings: swiftSettings
        ),

        // MARK: Domain models — pure value types, no crypto, no storage.
        .target(
            name: "ZyquoVaultDomain",
            swiftSettings: swiftSettings
        ),

        // MARK: Storage — vault format, atomic writes. Storage → Crypto + Domain.
        .target(
            name: "ZyquoVaultStorage",
            dependencies: ["ZyquoVaultCrypto", "ZyquoVaultDomain"],
            swiftSettings: swiftSettings
        ),

        // MARK: Design system — tokens, modifiers, components (§3 of CLAUDE.md).
        .target(
            name: "ZyquoVaultDesign",
            swiftSettings: swiftSettings
        ),

        // MARK: UI — UI → Design + Domain + Storage.
        .target(
            name: "ZyquoVaultUI",
            dependencies: ["ZyquoVaultDesign", "ZyquoVaultDomain", "ZyquoVaultStorage"],
            swiftSettings: swiftSettings
        ),

        // MARK: Importers.
        .target(
            name: "ZyquoVaultImport",
            dependencies: ["ZyquoVaultDomain"],
            swiftSettings: swiftSettings
        ),

        // MARK: App entry point.
        .executableTarget(
            name: "ZyquoVaultApp",
            dependencies: ["ZyquoVaultUI", "ZyquoVaultDesign", "ZyquoVaultDomain", "ZyquoVaultStorage", "ZyquoVaultCrypto"],
            swiftSettings: swiftSettings
        ),

        // MARK: CLI — safe commands only (vault info/verify/backup, format describe).
        .executableTarget(
            name: "ZyquoVaultCLI",
            dependencies: ["ZyquoVaultStorage", "ZyquoVaultCrypto", "ZyquoVaultDomain"],
            swiftSettings: swiftSettings
        ),

        // MARK: Tests.
        .testTarget(
            name: "ZyquoVaultCryptoTests",
            dependencies: ["ZyquoVaultCrypto"],
            swiftSettings: swiftSettings
        ),
        .testTarget(
            name: "ZyquoVaultDesignTests",
            dependencies: ["ZyquoVaultDesign"],
            swiftSettings: swiftSettings
        ),
        .testTarget(
            name: "ZyquoVaultDomainTests",
            dependencies: ["ZyquoVaultDomain"],
            swiftSettings: swiftSettings
        ),
        .testTarget(
            name: "ZyquoVaultIntegrationTests",
            dependencies: ["ZyquoVaultCrypto", "ZyquoVaultStorage", "ZyquoVaultDomain"],
            swiftSettings: swiftSettings
        ),
        .testTarget(
            name: "ZyquoVaultUITests",
            dependencies: ["ZyquoVaultUI"],
            swiftSettings: swiftSettings
        ),
    ]
)

var swiftSettings: [SwiftSetting] {
    [
        .swiftLanguageMode(.v6)
    ]
}
