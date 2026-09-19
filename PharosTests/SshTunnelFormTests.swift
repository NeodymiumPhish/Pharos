// Standalone test for `SshTunnelForm` — the decisions behind the SSH Tunnel
// section of the Connections Manager.
//
// `ConnectionsManagerVC` reaches `AppStateManager` and through it the whole
// FFI, so it cannot be compiled by a `swiftc` harness. The rules therefore
// live in a value type and the view controller only applies them; these tests
// pin the rules. What the harness canNOT see is the application itself — that
// six-line loop is checked in the live app (Phase 7).
import AppKit
import Foundation

var failures = 0
func expect(_ c: Bool, _ n: String) { if c { print("PASS \(n)") } else { failures += 1; print("FAIL \(n)") } }
func expectEqual<T: Equatable>(_ a: T, _ b: T, _ n: String) {
    if a == b { print("PASS \(n)") } else { failures += 1; print("FAIL \(n) — got \(a), wanted \(b)") }
}

func runTests() {
    // MARK: Row visibility

    // 1. The checkbox governs everything below it. A form with the tunnel off
    // must show no SSH row at all, whatever the pop-up happens to hold —
    // otherwise a user who turns the tunnel off is left with a key-file row.
    for auth in [SshAuthMethod.agent, .keyFile, .password] {
        let v = SshTunnelForm.visibility(enabled: false, auth: auth)
        expect(!v.tunnelRows, "tunnel off hides the rows (auth \(auth.rawValue))")
        expect(!v.keyFileRow, "tunnel off hides the key-file row (auth \(auth.rawValue))")
        expect(!v.secretRow, "tunnel off hides the secret row (auth \(auth.rawValue))")
        expect(!v.rememberSecretRow,
               "tunnel off hides the remember-secret row (auth \(auth.rawValue))")
    }

    // 2. The agent needs neither a key file nor a secret. Showing a secret
    // field here would invite the user to type one that is never used.
    let agent = SshTunnelForm.visibility(enabled: true, auth: .agent)
    expect(agent.tunnelRows, "the tunnel's rows show when it is on")
    expect(!agent.keyFileRow, "the agent needs no key file")
    expect(!agent.secretRow, "the agent needs no secret")
    // HIDDEN, not disabled. There is no secret for the agent, so a checkbox
    // left on screen would show a state — ticked — that claims Pharos keeps
    // something it does not have.
    expect(!agent.rememberSecretRow, "the agent has no secret to remember")

    // 3. A key file shows BOTH rows: the path, and the passphrase the key may
    // carry. A key with no passphrase leaves the field empty, which is exactly
    // the case `needs_askpass` reads in the core.
    let keyFile = SshTunnelForm.visibility(enabled: true, auth: .keyFile)
    expect(keyFile.keyFileRow, "a key file shows the path row")
    expect(keyFile.secretRow, "a key file shows the passphrase row")
    expectEqual(keyFile.secretLabel, "Passphrase", "a key file's secret is a passphrase")
    expect(keyFile.rememberSecretRow, "a key file's passphrase can be remembered")

    // 4. Password auth shows the secret and NOT the key path — a path here
    // would be offered to ssh with no key to go with it.
    let password = SshTunnelForm.visibility(enabled: true, auth: .password)
    expect(!password.keyFileRow, "password auth shows no key-file row")
    expect(password.secretRow, "password auth shows the secret row")
    expectEqual(password.secretLabel, "Password", "password auth's secret is a password")
    expect(password.rememberSecretRow, "password auth's secret can be remembered")
    // The switch follows the secret it governs, exactly. A row that could
    // appear without the field above it would govern nothing on screen.
    for auth in [SshAuthMethod.agent, .keyFile, .password] {
        let v = SshTunnelForm.visibility(enabled: true, auth: auth)
        expectEqual(v.rememberSecretRow, v.secretRow,
                    "the remember switch shows exactly when the secret does (\(auth.rawValue))")
    }

    // MARK: Form to model

    // 5. A form with the checkbox off describes NO tunnel, even when every
    // other field is filled — a user who turns the tunnel off and saves must
    // get a direct connection.
    var filled = SshTunnelForm.Fields(
        enabled: false, host: "bastion", port: "2222", user: "deploy",
        auth: .keyFile, keyPath: "/k", secret: "s", acceptNewHostKeys: true)
    expect(SshTunnelForm.tunnel(from: filled, existing: nil) == nil,
           "the checkbox off means no tunnel, whatever the fields hold")

    // 6. Every field reaches the model.
    filled.enabled = true
    if let t = SshTunnelForm.tunnel(from: filled, existing: nil) {
        expectEqual(t.host, "bastion", "the host reaches the model")
        expectEqual(t.port, 2222, "the port reaches the model")
        expectEqual(t.user, "deploy", "the user reaches the model")
        expectEqual(t.auth, .keyFile, "the auth mode reaches the model")
        expectEqual(t.keyPath, "/k", "the key path reaches the model")
        expectEqual(t.secret, "s", "the secret reaches the model")
        expect(t.acceptNewHostKeys, "the host-key flag reaches the model")
    } else {
        failures += 1; print("FAIL a filled form must describe a tunnel")
    }

    // 7. An empty user is not a user named "". `ssh user@host` with an empty
    // user is a different command from `ssh host`, and only the second lets
    // ~/.ssh/config choose. The same rule for a blank key path, which would
    // otherwise send `-i ""` to ssh.
    var blanks = SshTunnelForm.Fields(enabled: true, host: "bastion",
                                      user: "   ", keyPath: "  ")
    if let t = SshTunnelForm.tunnel(from: blanks, existing: nil) {
        expect(t.user == nil, "a blank user becomes nil, not an empty string")
        expect(t.keyPath == nil, "a blank key path becomes nil, not an empty string")
    }
    blanks.user = "  root  "
    if let t = SshTunnelForm.tunnel(from: blanks, existing: nil) {
        expectEqual(t.user, "root", "a user is trimmed")
    }

    // 8. THE gate rule (D6). While the secret field is masked it holds the
    // mask, not a secret. Writing that back would overwrite the stored secret
    // with bullet characters on the next Save — the same defect the password
    // field is already protected from.
    let stored = SshTunnelConfig(host: "bastion", secret: "the-real-secret")
    var masked = SshTunnelForm.Fields(enabled: true, host: "bastion",
                                      secret: "••••••••", secretRevealed: false)
    if let t = SshTunnelForm.tunnel(from: masked, existing: stored) {
        expectEqual(t.secret, "the-real-secret", "a masked field keeps the stored secret")
    }
    // And once revealed, a typed secret DOES replace it, or the user could
    // never change it.
    masked.secretRevealed = true
    masked.secret = "a-new-secret"
    if let t = SshTunnelForm.tunnel(from: masked, existing: stored) {
        expectEqual(t.secret, "a-new-secret", "a revealed field writes the typed secret")
    }
    // A masked field on a record that has no stored secret yields empty, not
    // the mask.
    let noStored = SshTunnelForm.Fields(enabled: true, host: "b",
                                        secret: "••••••••", secretRevealed: false)
    if let t = SshTunnelForm.tunnel(from: noStored, existing: nil) {
        expectEqual(t.secret, "", "a masked field with nothing stored yields empty")
    }

    // 9. A port field that is not a number keeps the value the record had, so
    // a half-typed port cannot silently reset the tunnel to 22.
    let badPort = SshTunnelForm.Fields(enabled: true, host: "b", port: "")
    expectEqual(SshTunnelForm.tunnel(from: badPort, existing: stored)?.port, 22,
                "an unparsable port falls back to the stored port")
    let stored2222 = SshTunnelConfig(host: "b", port: 2222)
    expectEqual(SshTunnelForm.tunnel(from: badPort, existing: stored2222)?.port, 2222,
                "an unparsable port keeps 2222, it does not reset to 22")

    // MARK: Fingerprint

    // 10. The fingerprint decides whether a fetched schema list still
    // describes this server. Every field that changes WHICH machine is reached
    // must move it; a changed SECRET must not, because it reaches the same
    // machine and this string is used as a dictionary key.
    let base = SshTunnelConfig(host: "bastion", port: 22, user: "deploy",
                               auth: .agent, keyPath: nil, secret: "",
                               acceptNewHostKeys: false)
    let baseline = SshTunnelForm.fingerprint(base)
    expect(SshTunnelForm.fingerprint(nil) != baseline, "no tunnel differs from a tunnel")
    expectEqual(SshTunnelForm.fingerprint(nil), "none", "no tunnel has a stable fingerprint")

    var moves: [(String, SshTunnelConfig)] = []
    var m = base; m.host = "other"; moves.append(("host", m))
    m = base; m.port = 2222; moves.append(("port", m))
    m = base; m.user = "root"; moves.append(("user", m))
    m = base; m.user = nil; moves.append(("user cleared", m))
    m = base; m.auth = .keyFile; moves.append(("auth", m))
    m = base; m.keyPath = "/k"; moves.append(("keyPath", m))
    m = base; m.acceptNewHostKeys = true; moves.append(("acceptNewHostKeys", m))
    for (field, changed) in moves {
        expect(SshTunnelForm.fingerprint(changed) != baseline,
               "a change to \(field) moves the fingerprint")
    }

    var secretOnly = base
    secretOnly.secret = "a-new-passphrase"
    expectEqual(SshTunnelForm.fingerprint(secretOnly), baseline,
                "a changed secret reaches the same server, so the fingerprint holds")
    // Nor does WHERE the secret is kept change which machine is reached.
    var rememberOnly = base
    rememberOnly.rememberSecret = false
    expectEqual(SshTunnelForm.fingerprint(rememberOnly), baseline,
                "the remember switch reaches the same server, so the fingerprint holds")

    // MARK: The remember switch, form to model

    // 10b. The switch defaults to ON — today's behaviour, where the secret was
    // stored whatever the record said — and the form carries it through in
    // both positions.
    expectEqual(SshTunnelForm.Fields(enabled: true, host: "b").rememberSecret, true,
                "a fresh form remembers, which is what every tunnel did before this switch")
    let remembering = SshTunnelForm.Fields(enabled: true, host: "b", rememberSecret: true)
    expectEqual(SshTunnelForm.tunnel(from: remembering, existing: nil)?.rememberSecret, true,
                "the switch on reaches the model on")
    let forgetting = SshTunnelForm.Fields(enabled: true, host: "b", rememberSecret: false)
    expectEqual(SshTunnelForm.tunnel(from: forgetting, existing: nil)?.rememberSecret, false,
                "the switch off reaches the model off — this is the destructive save")
    // It is carried for the AGENT too, whose row is hidden rather than reset,
    // so moving to the agent and back does not silently change the answer.
    let agentFields = SshTunnelForm.Fields(enabled: true, host: "b", auth: .agent,
                                           rememberSecret: false)
    expectEqual(SshTunnelForm.tunnel(from: agentFields, existing: nil)?.rememberSecret, false,
                "a hidden row keeps the user's answer rather than resetting it")

    // MARK: Derived text

    // 11. The bastion is the one thing that tells two otherwise identical
    // records apart, so the list row and the tooltip both name it. The host is
    // a STORED string shown as a label, so it goes through the same escape as
    // every other name there.
    expectEqual(SshTunnelForm.viaSuffix(nil, escape: { $0 }), "",
                "a direct connection adds nothing to the row")
    expectEqual(SshTunnelForm.viaSuffix(base, escape: { $0 }), " · via bastion",
                "a tunnel adds the bastion to the row")
    expectEqual(SshTunnelForm.viaPhrase(base, escape: { $0 }), "via bastion",
                "the tooltip phrase carries no separator of its own")
    expect(SshTunnelForm.viaPhrase(nil, escape: { $0 }) == nil,
           "a direct connection has no tooltip phrase")
    expectEqual(SshTunnelForm.viaSuffix(base, escape: { "<\($0)>" }), " · via <bastion>",
                "the caller's escape is applied to the host")

    print(failures == 0 ? "\nAll tests passed" : "\n\(failures) FAILED")
    exit(failures == 0 ? 0 : 1)
}
