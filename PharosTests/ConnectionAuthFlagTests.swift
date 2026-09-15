// Standalone test for `ConnectionConfig.requiresAuthentication` — the per
// connection Touch ID gate's stored flag.
//
// The flag crosses the FFI as one more key on the connection document, so the
// three things that can break it are all decode-shaped: an absent key (every
// record written before the column existed), a present key, and the equality
// that decides whether the connections form thinks it has unsaved work.
import AppKit
import Foundation

var failures = 0
func expect(_ c: Bool, _ n: String) { if c { print("PASS \(n)") } else { failures += 1; print("FAIL \(n)") } }

private let decoder = JSONDecoder()
private let encoder = JSONEncoder()

private func decode(_ json: String, _ name: String) -> ConnectionConfig? {
    guard let data = json.data(using: .utf8) else { return nil }
    do {
        return try decoder.decode(ConnectionConfig.self, from: data)
    } catch {
        failures += 1
        print("FAIL \(name) — decode threw: \(error)")
        return nil
    }
}

/// Every required key, so a document can be built with or without the flag.
private let requiredKeys = """
"id":"c1","name":"prod","host":"127.0.0.1","port":5432,\
"database":"nfinn","username":"nfinn"
"""

func runTests() {
    // 1. The absent key. This is the shape EVERY existing record has: the Rust
    // struct writes the key, but a record read from a store that predates the
    // column, and any other producer, may not. Absent must mean ungated —
    // anything else would lock the user out of their own connections.
    if let c = decode("{\(requiredKeys)}", "absent key") {
        expect(!c.requiresAuthentication, "a document without the key decodes to false")
    }

    // 2. The key present and true. A mis-cased key would read as false here,
    // which is exactly the silent failure an optional key can hide, so the
    // true case is asserted from a LITERAL document rather than a round trip.
    if let c = decode("{\(requiredKeys),\"requiresAuthentication\":true}", "key true") {
        expect(c.requiresAuthentication, "\"requiresAuthentication\":true decodes to true")
    }

    // 3. And false stated explicitly, so the key is proved to be READ rather
    // than defaulted — a decoder that ignored the key would pass test 2 only
    // if it defaulted to true, and this pins the other direction.
    if let c = decode("{\(requiredKeys),\"requiresAuthentication\":false}", "key false") {
        expect(!c.requiresAuthentication, "\"requiresAuthentication\":false decodes to false")
    }

    // 4. Encode → decode, both values. This is the path a record takes back to
    // the core when the user saves, so the KEY NAME has to survive it: the
    // custom `init(from:)` and the synthesized `encode(to:)` are written
    // separately and could drift apart.
    for flag in [true, false] {
        let original = ConnectionConfig(id: "c2", name: "round", host: "h", port: 5432,
                                        database: "d", username: "u", password: "p",
                                        sslMode: .disable, color: nil, defaultSchema: nil,
                                        requiresAuthentication: flag)
        do {
            let data = try encoder.encode(original)
            let back = try decoder.decode(ConnectionConfig.self, from: data)
            expect(back.requiresAuthentication == flag, "round trip preserves the flag (\(flag))")
            // The wire name, read from the encoder's own output: an encoder that
            // wrote some other key would still round-trip through a decoder that
            // read the same wrong key, and the core would silently ignore it.
            let text = String(data: data, encoding: .utf8) ?? ""
            expect(text.contains("\"requiresAuthentication\""),
                   "the encoded document carries the camelCase key (\(flag))")
        } catch {
            failures += 1
            print("FAIL round trip (\(flag)) — \(error)")
        }
    }

    // 5. The memberwise initialiser defaults to ungated, so every existing call
    // site keeps building an ungated record without naming the flag.
    let plain = ConnectionConfig(id: "c3", name: "plain", host: "h", port: 5432,
                                 database: "d", username: "u")
    expect(!plain.requiresAuthentication, "the memberwise init defaults to false")

    // 6. Equality. The connections form drives Save and Revert from `draft !=
    // baseline`, so a `==` blind to the flag would leave ticking the box
    // unsavable — the one change the user made would not register as a change.
    let ungated = ConnectionConfig(id: "c4", name: "n", host: "h", port: 5432,
                                   database: "d", username: "u")
    var gated = ungated
    gated.requiresAuthentication = true
    expect(gated != ungated, "== distinguishes the flag")
    expect(ungated == ungated, "== still holds for two identical records")

    // And the flag is the ONLY difference here, so the inequality above cannot
    // be coming from another field.
    var alsoUngated = gated
    alsoUngated.requiresAuthentication = false
    expect(alsoUngated == ungated, "clearing the flag restores equality")

    print(failures == 0 ? "ALL TESTS PASSED" : "\(failures) TEST(S) FAILED")
    exit(failures == 0 ? 0 : 1)
}
