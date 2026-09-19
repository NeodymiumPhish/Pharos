// Standalone test for `ConnectionConfig.sshTunnel` — the per-connection SSH
// tunnel as it crosses the FFI.
//
// The Rust struct uses `rename_all = "camelCase"` and this side uses plain
// `CodingKeys`, so every key name is a hand-matched contract. The dangerous
// case is an OPTIONAL key: serde reports a mis-cased optional field as absent,
// and so does Swift, so a renamed `keyPath` or `acceptNewHostKeys` breaks
// NOTHING that a round trip can see — both sides would simply drop it.
// The fix is a LITERAL document with every key present, asserted field by
// field. See tasks/lessons.md and memory pharos-ffi-json-casing.
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

/// Every required key of the connection itself, so a document can be built
/// with or without a tunnel.
private let requiredKeys = """
"id":"c1","name":"prod","host":"db.internal","port":5432,\
"database":"nbt","username":"app"
"""

/// Every tunnel key present, and no field left at its default value — a
/// fixture that used the defaults could not tell "the key was read" from
/// "the key was missed and the default applied".
private let fullTunnel = """
{"host":"bastion.example.com","port":2222,"user":"deploy","auth":"keyFile",\
"keyPath":"/Users/x/.ssh/id_ed25519","secret":"s3cret","acceptNewHostKeys":true,\
"rememberSecret":false}
"""

private func sample(tunnel: SshTunnelConfig?) -> ConnectionConfig {
    ConnectionConfig(id: "c1", name: "prod", host: "db.internal", port: 5432,
                     database: "nbt", username: "app", sshTunnel: tunnel)
}

private func encoded(_ config: ConnectionConfig, _ name: String) -> String? {
    do {
        return String(data: try encoder.encode(config), encoding: .utf8)
    } catch {
        failures += 1
        print("FAIL \(name) — encode threw: \(error)")
        return nil
    }
}

func runTests() {
    // 1. The absent key. This is the shape of EVERY record written before this
    // feature, and of every connection that has no tunnel. Absent must mean a
    // direct connection, not a decode failure.
    if let c = decode("{\(requiredKeys)}", "absent key") {
        expect(c.sshTunnel == nil, "a document without \"sshTunnel\" decodes to nil")
    }

    // 2. The full document. THIS is the test that can catch a renamed key:
    // each assertion reads one key by name and would report the default if the
    // name were wrong.
    if let c = decode("{\(requiredKeys),\"sshTunnel\":\(fullTunnel)}", "full tunnel") {
        if let t = c.sshTunnel {
            expect(t.host == "bastion.example.com", "\"host\" key name")
            expect(t.port == 2222, "\"port\" is read, not defaulted to 22")
            expect(t.user == "deploy", "\"user\" key name")
            expect(t.auth == .keyFile, "\"auth\":\"keyFile\" decodes to .keyFile")
            expect(t.keyPath == "/Users/x/.ssh/id_ed25519", "\"keyPath\" key name")
            expect(t.secret == "s3cret", "\"secret\" key name")
            expect(t.acceptNewHostKeys, "\"acceptNewHostKeys\" key name")
            expect(!t.rememberSecret, "\"rememberSecret\" key name — read, not defaulted to true")
        } else {
            failures += 1
            print("FAIL full tunnel — sshTunnel decoded to nil")
        }
    }

    // 3. A sparse tunnel proves the DEFAULTS and nothing about the key names.
    // The defaults matter on their own: the safe tunnel is agent auth, port 22
    // and strict host keys.
    if let c = decode("{\(requiredKeys),\"sshTunnel\":{\"host\":\"bastion\"}}", "sparse tunnel") {
        if let t = c.sshTunnel {
            expect(t.port == 22, "an absent \"port\" defaults to 22")
            expect(t.user == nil, "an absent \"user\" lets ~/.ssh/config choose")
            expect(t.auth == .agent, "an absent \"auth\" defaults to the agent")
            expect(t.keyPath == nil, "an absent \"keyPath\" decodes to nil")
            expect(t.secret == "", "an absent \"secret\" decodes to empty")
            expect(!t.acceptNewHostKeys, "host keys are strict unless the key says otherwise")
            // The ONE default that is true. Every tunnel written before this
            // switch existed had its secret stored, so absent must mean
            // remembered — anything else would silently stop remembering a
            // secret the user never asked Pharos to forget.
            expect(t.rememberSecret, "an absent \"rememberSecret\" defaults to remembering")
        } else {
            failures += 1
            print("FAIL sparse tunnel — sshTunnel decoded to nil")
        }
    }

    // 4. An auth mode this build does not know must fail LOUDLY. Reading it as
    // the default would run an agent tunnel where the user asked for a key,
    // and the user would never be told.
    let unknownAuth = "{\(requiredKeys),\"sshTunnel\":{\"host\":\"b\",\"auth\":\"kerberos\"}}"
    var unknownThrew = false
    if let data = unknownAuth.data(using: .utf8) {
        do { _ = try decoder.decode(ConnectionConfig.self, from: data) }
        catch { unknownThrew = true }
    }
    expect(unknownThrew, "an unknown \"auth\" value fails the decode")

    // The same value in the snake_case serde would use WITHOUT `rename_all`
    // must fail too, which pins the camelCase contract from this side.
    let snakeAuth = "{\(requiredKeys),\"sshTunnel\":{\"host\":\"b\",\"auth\":\"key_file\"}}"
    var snakeThrew = false
    if let data = snakeAuth.data(using: .utf8) {
        do { _ = try decoder.decode(ConnectionConfig.self, from: data) }
        catch { snakeThrew = true }
    }
    expect(snakeThrew, "\"auth\" is camelCase on the wire, not snake_case")

    // 5. Encode → decode. This is the path a record takes back to the core
    // when the user saves, and the custom `init(from:)` and the synthesized
    // `encode(to:)` are written separately, so they can drift apart.
    if let original = decode("{\(requiredKeys),\"sshTunnel\":\(fullTunnel)}", "round trip source"),
       let json = encoded(original, "round trip"),
       let back = decode(json, "round trip decode") {
        expect(back.sshTunnel == original.sshTunnel, "the tunnel survives encode → decode")
        expect(back == original, "the whole record survives encode → decode")
    }

    // 6. The keys the ENCODER writes are the keys Rust reads. A round trip
    // cannot see this, because both directions would use the same wrong name.
    if let json = encoded(sample(tunnel: SshTunnelConfig(
        host: "bastion", port: 2222, user: "deploy", auth: .keyFile,
        keyPath: "/k", secret: "s3cret", acceptNewHostKeys: true)), "encoded keys") {
        expect(json.contains("\"sshTunnel\""), "the record is written under \"sshTunnel\"")
        expect(json.contains("\"keyPath\""), "the key path is written as \"keyPath\"")
        expect(json.contains("\"acceptNewHostKeys\""), "the flag is written as \"acceptNewHostKeys\"")
        expect(json.contains("\"keyFile\""), "the auth mode is written as \"keyFile\"")
        expect(json.contains("\"secret\":\"s3cret\""), "the secret is sent to the core")
        expect(json.contains("\"rememberSecret\""), "the switch is written as \"rememberSecret\"")
    }

    // 7. A connection with no tunnel must put no key on the wire, so the
    // document stays byte-identical to what this app sent before the feature.
    if let json = encoded(sample(tunnel: nil), "no tunnel encoded") {
        expect(!json.contains("sshTunnel"), "no tunnel writes no key: \(json)")
    }

    // 8. Equality drives the connections form's dirty state, so a field the
    // comparison forgets is a field the user cannot save. Each one is changed
    // on its own; a `==` that dropped it would report the two as equal.
    let base = SshTunnelConfig(host: "bastion", port: 22, user: "deploy",
                               auth: .agent, keyPath: nil, secret: "",
                               acceptNewHostKeys: false)
    var variants: [(String, SshTunnelConfig)] = []
    var v = base; v.host = "other"; variants.append(("host", v))
    v = base; v.port = 2222; variants.append(("port", v))
    v = base; v.user = "root"; variants.append(("user", v))
    v = base; v.user = nil; variants.append(("user cleared", v))
    v = base; v.auth = .keyFile; variants.append(("auth", v))
    v = base; v.keyPath = "/k"; variants.append(("keyPath", v))
    v = base; v.secret = "s"; variants.append(("secret", v))
    v = base; v.acceptNewHostKeys = true; variants.append(("acceptNewHostKeys", v))
    v = base; v.rememberSecret = false; variants.append(("rememberSecret", v))

    for (field, changed) in variants {
        expect(sample(tunnel: base) != sample(tunnel: changed),
               "a change to \(field) makes the record unequal")
    }

    // Adding or removing the tunnel altogether is a change too.
    expect(sample(tunnel: nil) != sample(tunnel: base), "turning the tunnel on is a change")
    expect(sample(tunnel: base) == sample(tunnel: base), "an unchanged tunnel is equal")

    print(failures == 0 ? "\nAll tests passed" : "\n\(failures) FAILED")
    exit(failures == 0 ? 0 : 1)
}
