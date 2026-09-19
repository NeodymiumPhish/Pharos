// Standalone test runner for AppSettings' decode of what pharos-core sends.
//
// `AppSettings` uses Swift's synthesized `init(from:)`, which THROWS on a
// missing key. The core re-serializes its own `AppSettings` struct on every
// load, so the contract is: every Swift field has a camelCase key on the wire,
// and every value the core can write decodes to the same Swift value.
//
// The two blobs come from `PharosTests/Fixtures/` and are GENERATED from the
// Rust struct (`scripts/gen-settings-fixture.sh`); `cargo test` fails while
// they are stale. So a Swift field added without its Rust mirror fails here,
// and a Rust field added without its Swift mirror fails the re-encode check.
import Foundation

var failures = 0

func expectTrue(_ actual: Bool, _ name: String) {
    if actual { print("PASS \(name)") } else { failures += 1; print("FAIL \(name) — expected true") }
}

let fixtureDir = ProcessInfo.processInfo.environment["PHAROS_FIXTURE_DIR"] ?? "PharosTests/Fixtures"

func fixture(_ name: String) -> Data {
    let url = URL(fileURLWithPath: fixtureDir).appendingPathComponent(name)
    guard let data = try? Data(contentsOf: url) else {
        print("FAIL cannot read \(url.path) — run scripts/gen-settings-fixture.sh")
        exit(1)
    }
    return data
}

func jsonObject(_ data: Data) -> NSDictionary? {
    (try? JSONSerialization.jsonObject(with: data)) as? NSDictionary
}

func runTests() {
    let defaultBlob = fixture("settings-default.json")
    let nonDefaultBlob = fixture("settings-nondefault.json")

    // 1. The default blob decodes to Swift's default. Catches a Swift default
    //    that disagrees with the Rust one.
    do {
        let decoded = try JSONDecoder().decode(AppSettings.self, from: defaultBlob)
        expectTrue(decoded == AppSettings(), "the core's default blob decodes to Swift's default AppSettings")
    } catch {
        failures += 1
        print("FAIL the core's default blob must decode: \(error)")
    }

    // 2. The non-default blob decodes, differs from the default, and re-encodes
    //    to the SAME JSON dictionary. Catches a Rust field with no Swift mirror
    //    (its key vanishes on re-encode) and an enum case spelled differently on
    //    the two sides (the decode throws, or the value changes).
    do {
        let decoded = try JSONDecoder().decode(AppSettings.self, from: nonDefaultBlob)
        expectTrue(decoded != AppSettings(), "the non-default blob is not the default")
        let reEncoded = try JSONEncoder().encode(decoded)
        let original = jsonObject(nonDefaultBlob)
        let roundTripped = jsonObject(reEncoded)
        expectTrue(original != nil && roundTripped != nil, "both blobs are JSON objects")
        expectTrue(original == roundTripped, "the non-default blob re-encodes to the same JSON dictionary")
        if original != roundTripped, let o = original, let r = roundTripped {
            let missing = Set(o.allKeys.compactMap { $0 as? String }).subtracting(r.allKeys.compactMap { $0 as? String })
            let extra = Set(r.allKeys.compactMap { $0 as? String }).subtracting(o.allKeys.compactMap { $0 as? String })
            print("  keys the Rust side writes and Swift drops: \(missing.sorted())")
            print("  keys Swift writes and the Rust side has not got: \(extra.sorted())")
        }
    } catch {
        failures += 1
        print("FAIL the non-default blob must decode and re-encode: \(error)")
    }

    // 3. The failure this suite exists to catch: each top-level key missing
    //    makes the decode throw — so every Rust mirror is load-bearing.
    if let object = jsonObject(defaultBlob) as? [String: Any] {
        for key in object.keys.sorted() {
            var without = object
            without.removeValue(forKey: key)
            guard let data = try? JSONSerialization.data(withJSONObject: without) else { continue }
            let decoded = try? JSONDecoder().decode(AppSettings.self, from: data)
            expectTrue(decoded == nil, "a blob without `\(key)` does not decode")
        }
    } else {
        failures += 1
        print("FAIL the default fixture is not a JSON object")
    }

    print(failures == 0 ? "\nALL PASSED" : "\n\(failures) FAILURE(S)")
    exit(failures == 0 ? 0 : 1)
}
