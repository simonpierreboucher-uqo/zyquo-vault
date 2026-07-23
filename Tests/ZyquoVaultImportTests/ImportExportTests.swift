import Foundation
import Testing
@testable import ZyquoVaultCrypto
@testable import ZyquoVaultDomain
@testable import ZyquoVaultImport

@Suite("CSV parser (RFC 4180)")
struct CSVParserTests {

    @Test func quotedFieldsCommasNewlinesAndEscapes() {
        let text = "a,\"b,with comma\",\"line\nbreak\",\"esc\"\"aped\"\r\nnext,1,2,3"
        let rows = CSV.parse(text)
        #expect(rows == [
            ["a", "b,with comma", "line\nbreak", "esc\"aped"],
            ["next", "1", "2", "3"],
        ])
    }

    @Test func lineEndingVariants() {
        #expect(CSV.parse("a,b\r\nc,d") == [["a", "b"], ["c", "d"]])
        #expect(CSV.parse("a,b\rc,d") == [["a", "b"], ["c", "d"]])
        #expect(CSV.parse("a,b\nc,d\n") == [["a", "b"], ["c", "d"]])
    }

    @Test func escapeRoundTrips() {
        for value in ["plain", "with,comma", "with\"quote", "multi\nline", ""] {
            let parsed = CSV.parse("x," + CSV.escape(value))
            #expect(parsed == [["x", value]])
        }
    }

    @Test func hostileInputNeverCrashes() {
        for input in ["", "\"", "\"\"\"", ",,,,\n\"\"\"\"", String(repeating: "\",\n", count: 2000)] {
            _ = CSV.parse(input)
        }
    }
}

@Suite("Generic / browser CSV importer")
struct GenericCSVImporterTests {

    @Test func chromeExportImports() throws {
        let csv = """
        name,url,username,password
        Example,https://example.com/,user@example.com,example-password-not-real
        ,https://other.example.net/login,someone,also-not-real
        """
        let items = try GenericCSVImporter().parse(Data(csv.utf8))
        #expect(items.count == 2)
        #expect(items[0].title == "Example")
        #expect(items[0].itemType == .login)
        #expect(items[0].fields.first { $0.kind == .password }?.value.reveal() == "example-password-not-real")
        #expect(items[0].fields.first { $0.kind == .password }?.isConcealed == true)
        // Missing title falls back to the URL host.
        #expect(items[1].title == "other.example.net")
    }

    @Test func richHeaderMappingWithTagsNotesTOTP() throws {
        let csv = """
        Title,Login,Pass,Website,Notes,TOTP,Tags
        Mail,me@example.com,example-password-not-real,https://mail.example.com,Some note,JBSWY3DPEHPK3PXP,work;personal
        """
        let items = try GenericCSVImporter().parse(Data(csv.utf8))
        #expect(items.count == 1)
        let item = items[0]
        #expect(item.notes == "Some note")
        #expect(item.tags == ["work", "personal"])
        #expect(item.fields.first { $0.kind == .totpSeed }?.value.reveal() == "JBSWY3DPEHPK3PXP")
    }

    @Test func malformedRejectedCalmly() {
        #expect(throws: ImportError.self) { _ = try GenericCSVImporter().parse(Data()) }
        #expect(throws: ImportError.self) { _ = try GenericCSVImporter().parse(Data("just,a,header".utf8)) }
        #expect(throws: ImportError.self) {
            _ = try GenericCSVImporter().parse(Data("a,b\n1,2".utf8)) // no password column
        }
    }
}

@Suite("Bitwarden JSON importer")
struct BitwardenImporterTests {

    static let sample = """
    {
      "encrypted": false,
      "folders": [{"id": "f1", "name": "Work"}],
      "items": [
        {"type": 1, "name": "Example login", "favorite": true, "folderId": "f1",
         "notes": "hello",
         "login": {"username": "user@example.com", "password": "example-password-not-real",
                   "totp": "JBSWY3DPEHPK3PXP",
                   "uris": [{"uri": "https://example.com"}, {"uri": "https://alt.example.com"}]},
         "fields": [{"name": "PIN", "value": "0000", "type": 1}]},
        {"type": 2, "name": "A note", "notes": "note body"},
        {"type": 3, "name": "A card",
         "card": {"cardholderName": "Fixture Person", "number": "4111111111111111",
                  "expMonth": "12", "expYear": "2030", "code": "000"}},
        {"type": 4, "name": "An identity",
         "identity": {"firstName": "Fixture", "lastName": "Person", "email": "fixture@example.com"}}
      ]
    }
    """

    @Test func fullExportMaps() throws {
        let result = try BitwardenJSONImporter().parseWithFolders(Data(Self.sample.utf8))
        #expect(result.items.count == 4)
        #expect(result.folders.map(\.name) == ["Work"])

        let login = result.items[0]
        #expect(login.itemType == .login)
        #expect(login.isFavorite)
        #expect(login.folderID == result.folders[0].id)
        #expect(login.fields.first { $0.kind == .totpSeed } != nil)
        #expect(login.fields.filter { $0.kind == .url }.count == 2)
        #expect(login.fields.first { $0.label == "PIN" }?.isConcealed == true)

        #expect(result.items[1].itemType == .secureNote)
        #expect(result.items[2].itemType == .paymentCard)
        #expect(result.items[2].fields.first { $0.kind == .number }?.isConcealed == true)
        #expect(result.items[3].itemType == .identity)
    }

    @Test func encryptedExportRefusedWithGuidance() {
        let encrypted = #"{"encrypted": true, "items": [{"type": 1}]}"#
        #expect(throws: ImportError.self) {
            _ = try BitwardenJSONImporter().parse(Data(encrypted.utf8))
        }
    }

    @Test func malformedRejected() {
        for input in ["", "not json", "[]", #"{"items": []}"#] {
            #expect(throws: ImportError.self) {
                _ = try BitwardenJSONImporter().parse(Data(input.utf8))
            }
        }
    }
}

@Suite("Zyquo encrypted export", .serialized)
struct ZyquoExportTests {

    static let params = Argon2id.Parameters(
        memoryKiB: Argon2id.Floor.memoryKiB,
        iterations: Argon2id.Floor.iterations,
        parallelism: 4
    )

    func samplePayload() -> ZyquoExport.Payload {
        ZyquoExport.Payload(
            exportedAt: 1_753_000_000,
            items: [
                VaultItem(
                    itemType: .login, title: "Exported",
                    fields: [VaultField(label: "Password", value: SensitiveFieldValue("example-password-not-real"), kind: .password, isConcealed: true)],
                    tags: ["fixture"]
                )
            ],
            folders: [VaultFolder(name: "Exported folder")]
        )
    }

    @Test func sealOpenRoundTrip() throws {
        // One payload instance: VaultItem stamps fresh Dates per construction.
        let payload = samplePayload()
        let password = SecureBytes(utf8: "export-password-not-real")
        let sealed = try ZyquoExport.seal(payload: payload, password: password, parameters: Self.params)
        let opened = try ZyquoExport.open(sealed, password: SecureBytes(utf8: "export-password-not-real"))
        #expect(opened == payload)
        // Secrets never appear in the ciphertext file.
        #expect(!String(decoding: sealed, as: UTF8.self).contains("example-password-not-real"))
        #expect(!String(decoding: sealed, as: UTF8.self).contains("Exported folder"))
    }

    @Test func wrongPasswordAndTamperRejected() throws {
        let sealed = try ZyquoExport.seal(
            payload: samplePayload(),
            password: SecureBytes(utf8: "export-password-not-real"),
            parameters: Self.params
        )
        #expect(throws: CryptoError.invalidPasswordOrCorruptedVault) {
            _ = try ZyquoExport.open(sealed, password: SecureBytes(utf8: "wrong-password-not-real"))
        }
        var tampered = sealed
        tampered[sealed.count - 5] ^= 0x01
        #expect(throws: CryptoError.invalidPasswordOrCorruptedVault) {
            _ = try ZyquoExport.open(tampered, password: SecureBytes(utf8: "export-password-not-real"))
        }
    }

    @Test func malformedContainersRejectedWithoutCrashing() throws {
        let password = SecureBytes(utf8: "x")
        let good = try ZyquoExport.seal(
            payload: samplePayload(),
            password: SecureBytes(utf8: "export-password-not-real"),
            parameters: Self.params
        )
        var wrongMagic = good
        wrongMagic[0] = 0x00
        var dosParams = good
        // Argon2 memory field sits at offset 4+4+16+1+16 = 41.
        dosParams.replaceSubrange(41..<45, with: [0xFF, 0xFF, 0xFF, 0xFF])
        for data in [Data(), Data("ZYQX".utf8), good.prefix(60), wrongMagic, dosParams, good + Data([0])] {
            #expect(throws: (any Error).self) {
                _ = try ZyquoExport.open(Data(data), password: password)
            }
        }
    }

    @Test func plaintextExportSerializers() throws {
        let payload = samplePayload()
        let json = try PlaintextExport.json(items: payload.items, folders: payload.folders)
        let text = String(decoding: json, as: UTF8.self)
        #expect(text.contains("UNENCRYPTED"))
        #expect(text.contains("example-password-not-real")) // it IS plaintext, by contract

        let csv = PlaintextExport.csv(items: payload.items)
        let lines = String(decoding: csv, as: UTF8.self).components(separatedBy: "\r\n")
        #expect(lines[0].hasPrefix("title,type,username,password"))
        #expect(lines[1].contains("Exported"))
        // And it round-trips through our own importer.
        let reimported = try GenericCSVImporter().parse(csv)
        #expect(reimported.count == 1)
        #expect(reimported[0].fields.first { $0.kind == .password }?.value.reveal() == "example-password-not-real")
    }
}
