import Darwin
import Foundation
import ZyquoVaultCrypto
import ZyquoVaultStorage

// zyquo-vault-cli — v1 safe commands only (CLAUDE.md §10.13):
//   vault info <path>      show non-secret header metadata
//   vault verify <path>    verify the header opens (password via secure prompt/stdin)
//   format describe        summarize the on-disk format
// The master password is NEVER accepted as a command-line argument (it would be
// visible in process lists) and never read from an environment variable.

let arguments = CommandLine.arguments.dropFirst()

func fail(_ message: String, code: Int32 = 1) -> Never {
    FileHandle.standardError.write(Data("error: \(message)\n".utf8))
    exit(code)
}

func usage() -> Never {
    print("""
    zyquo-vault-cli — Zyquo Vault maintenance tool (safe commands only)

    Usage:
      zyquo-vault-cli vault info <vault-directory>
      zyquo-vault-cli vault verify <vault-directory>
      zyquo-vault-cli format describe

    The master password is requested on the terminal with echo disabled, or read
    from stdin when piped. It is never accepted as an argument.
    """)
    exit(2)
}

/// Reads the master password without echo (TTY) or from stdin (piped).
func readPassword(prompt: String) -> SecureBytes {
    if isatty(fileno(stdin)) != 0 {
        guard let raw = getpass(prompt) else { fail("could not read password") }
        let secure = SecureBytes(bytes: Array(String(cString: raw).utf8))
        // Best-effort: clear getpass's static buffer.
        var p = raw
        while p.pointee != 0 { p.pointee = 0; p += 1 }
        return secure
    }
    guard let line = readLine(strippingNewline: true) else { fail("could not read password from stdin") }
    return SecureBytes(utf8: line)
}

func loadHeader(_ path: String) -> VaultHeader {
    let dir = URL(fileURLWithPath: path)
    let url = dir.appendingPathComponent(VaultStore.headerFileName)
    guard FileManager.default.fileExists(atPath: url.path) else {
        fail("no \(VaultStore.headerFileName) found in \(path)")
    }
    do {
        return try VaultHeader.decode(try Data(contentsOf: url))
    } catch {
        fail("invalid header: \(error)")
    }
}

switch (arguments.first, arguments.dropFirst().first) {
case ("vault", "info"):
    guard let path = arguments.dropFirst(2).first else { usage() }
    let header = loadHeader(path)
    let params = header.wrappedVMK.kdfParameters
    print("""
    Vault:            \(header.vaultID.uuidString)
    Format version:   \(header.formatVersion) (minimum reader \(header.minReaderVersion))
    Created:          \(Date(timeIntervalSince1970: TimeInterval(header.createdAt)))
    Updated:          \(Date(timeIntervalSince1970: TimeInterval(header.updatedAt)))
    KDF:              Argon2id (v19)
      memory:         \(params.memoryKiB / 1024) MiB
      iterations:     \(params.iterations)
      parallelism:    \(params.parallelism)
      salt length:    \(header.wrappedVMK.kdfSalt.count) bytes
    Key wrap:         AES-256-GCM
    """)

case ("vault", "verify"):
    guard let path = arguments.dropFirst(2).first else { usage() }
    let password = readPassword(prompt: "Master password: ")
    defer { password.wipe() }
    do {
        let opened = try VaultStore.openVault(at: URL(fileURLWithPath: path), password: password)
        opened.vmk.wipe()
        print("OK — header authenticated and vault master key unwrapped.")
    } catch {
        fail("the password is incorrect or the vault file is damaged.", code: 3)
    }

case ("format", "describe"):
    print("""
    Zyquo Vault on-disk format v1 (full specification: docs/vault-format.md)

      vault.header    versioned binary header: magic "ZYQV", format version,
                      vault UUID, Argon2id parameters + salt, AES-256-GCM-wrapped
                      vault master key (AAD-bound to vault UUID + format version),
                      HMAC-SHA256 header authentication tag.
      vault.manifest  encrypted inventory of records (milestone M2).
      records/        one independently authenticated ciphertext per item (M2).
      attachments/    chunked authenticated attachment ciphertexts (M6).
      journal/        crash-safe transaction journal, no plaintext secrets (M2).
      backups/        encrypted, verified backups (M6).
    """)

default:
    usage()
}
