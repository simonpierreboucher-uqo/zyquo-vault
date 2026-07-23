import Foundation
import Testing
@testable import ZyquoVaultCrypto
@testable import ZyquoVaultImport

/// Import-side fuzz targets (§12): CSV, Bitwarden JSON, and the encrypted
/// export container. Deterministic seeds; throwing is fine, crashing is not.
@Suite("Fuzz — import parsers", .serialized)
struct ImportFuzzTests {

    struct RNG {
        var state: UInt64
        mutating func next() -> UInt64 {
            state &+= 0x9E3779B97F4A7C15
            var z = state
            z = (z ^ (z >> 30)) &* 0xBF58476D1CE4E5B9
            z = (z ^ (z >> 27)) &* 0x94D049BB133111EB
            return z ^ (z >> 31)
        }
        mutating func int(below bound: Int) -> Int { Int(next() % UInt64(bound)) }
        mutating func bytes(_ count: Int) -> Data {
            var out = Data(capacity: count)
            for _ in 0..<count { out.append(UInt8(truncatingIfNeeded: next())) }
            return out
        }
        mutating func mutate(_ input: Data) -> Data {
            var data = input
            switch int(below: 4) {
            case 0 where !data.isEmpty:
                for _ in 0...int(below: 6) {
                    let index = int(below: data.count)
                    data[data.startIndex + index] ^= UInt8(truncatingIfNeeded: next() | 1)
                }
            case 1 where data.count > 1:
                data = data.prefix(int(below: data.count))
            case 2:
                data.append(bytes(1 + int(below: 48)))
            default:
                data = bytes(1 + int(below: 300))
            }
            return data
        }
    }

    @Test func csvAndBitwarden() {
        var rng = RNG(state: 0xFEED_0001)
        let csvSeed = Data("name,url,username,password\nA,https://example.com,u,example-password-not-real\n".utf8)
        let bwSeed = Data(#"{"encrypted":false,"items":[{"type":1,"name":"x","login":{"username":"u","password":"p"}}]}"#.utf8)
        for _ in 0..<600 {
            _ = try? GenericCSVImporter().parse(rng.mutate(csvSeed))
            _ = try? BitwardenJSONImporter().parse(rng.mutate(bwSeed))
        }
    }

    @Test func encryptedExportContainer() throws {
        // Expensive target (mutants that survive framing reach Argon2id), so
        // fewer iterations; the cheap framing paths are covered above.
        let params = Argon2id.Parameters(
            memoryKiB: Argon2id.Floor.memoryKiB,
            iterations: Argon2id.Floor.iterations,
            parallelism: 4
        )
        let payload = ZyquoExport.Payload(exportedAt: 1, items: [], folders: [])
        let valid = try ZyquoExport.seal(
            payload: payload,
            password: SecureBytes(utf8: "fuzz-password-not-real"),
            parameters: params
        )
        var rng = RNG(state: 0xFEED_0002)
        for _ in 0..<12 {
            _ = try? ZyquoExport.open(rng.mutate(valid), password: SecureBytes(utf8: "fuzz-password-not-real"))
        }
        for _ in 0..<50 {
            _ = try? ZyquoExport.open(rng.bytes(1 + rng.int(below: 200)), password: SecureBytes(utf8: "x"))
        }
    }
}
