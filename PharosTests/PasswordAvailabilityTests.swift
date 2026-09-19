// Standalone test for `PasswordAvailability` — the rule that decides whether a
// connect attempt dials, asks for a password, or does neither.
//
// Four booleans, sixteen combinations, every one of them asserted. The rule is
// short enough that a table is the honest test: a reader can check the table
// against the requirement without reading the implementation, and a change to
// the implementation that alters ANY cell fails here rather than silently
// changing what a user sees.
import Foundation

var failures = 0
func expect(_ c: Bool, _ n: String) { if c { print("PASS \(n)") } else { failures += 1; print("FAIL \(n)") } }

private struct Case {
    let session: Bool
    let keychain: Bool
    let remember: Bool
    let gated: Bool
    let expected: PasswordAvailability.Decision
    let why: String
}

/// Every combination of the four inputs, in counting order, so a missing row
/// is visible. `session`, `keychain`, `remember`, `gated`.
private let table: [Case] = [
    // --- nothing typed this run, nothing stored -------------------------
    Case(session: false, keychain: false, remember: false, gated: false,
         expected: .prompt,
         why: "no password anywhere and no gate: ask"),
    Case(session: false, keychain: false, remember: false, gated: true,
         expected: .authenticateThenPrompt,
         why: "no password anywhere, gated: prove the device owner, then ask"),
    Case(session: false, keychain: false, remember: true, gated: false,
         expected: .prompt,
         why: "remembers, but has nothing yet — the first connect of a new record"),
    Case(session: false, keychain: false, remember: true, gated: true,
         expected: .authenticateThenPrompt,
         why: "the gate is owed whether or not the record remembers"),

    // --- nothing typed this run, something stored -----------------------
    Case(session: false, keychain: true, remember: false, gated: false,
         expected: .refuse,
         why: "a stored password on a record that remembers none: the delete failed"),
    Case(session: false, keychain: true, remember: false, gated: true,
         expected: .refuse,
         why: "the same contradiction; the gate does not resolve it"),
    Case(session: false, keychain: true, remember: true, gated: false,
         expected: .connect,
         why: "the ordinary remembered connection"),
    Case(session: false, keychain: true, remember: true, gated: true,
         expected: .connect,
         why: "gated and remembered — the gate ran before this decision, not after"),

    // --- typed this run -------------------------------------------------
    Case(session: true, keychain: false, remember: false, gated: false,
         expected: .connect,
         why: "the answer to a prompt, on a record that deliberately stores none"),
    Case(session: true, keychain: false, remember: false, gated: true,
         expected: .connect,
         why: "typed after the gate was passed, so it is not asked twice"),
    Case(session: true, keychain: false, remember: true, gated: false,
         expected: .connect,
         why: "remembers, but nothing is stored yet; what was typed serves"),
    Case(session: true, keychain: false, remember: true, gated: true,
         expected: .connect,
         why: "same, gated"),
    Case(session: true, keychain: true, remember: false, gated: false,
         expected: .connect,
         why: "what was typed wins over a stored password the record disowns"),
    Case(session: true, keychain: true, remember: false, gated: true,
         expected: .connect,
         why: "and the contradiction does not matter once there is a typed password"),
    Case(session: true, keychain: true, remember: true, gated: false,
         expected: .connect,
         why: "typed beats stored — a re-typed password must not lose to a stale one"),
    Case(session: true, keychain: true, remember: true, gated: true,
         expected: .connect,
         why: "same, gated"),
]

func runTests() {
    expect(table.count == 16, "the table covers all sixteen combinations")

    // No two rows describe the same input.
    var seen = Set<String>()
    for c in table { seen.insert("\(c.session)\(c.keychain)\(c.remember)\(c.gated)") }
    expect(seen.count == 16, "no combination is listed twice")

    for c in table {
        let got = PasswordAvailability.decide(
            hasSessionPassword: c.session,
            hasKeychainPassword: c.keychain,
            rememberPassword: c.remember,
            requiresAuthentication: c.gated)
        expect(got == c.expected,
               "session=\(c.session) keychain=\(c.keychain) remember=\(c.remember) "
               + "gated=\(c.gated) → \(c.expected) — \(c.why)")
    }

    // The two properties the table encodes, stated on their own so a future
    // edit that breaks one of them says WHICH one.
    let gatedWithoutPassword = PasswordAvailability.decide(
        hasSessionPassword: false, hasKeychainPassword: false,
        rememberPassword: false, requiresAuthentication: true)
    expect(gatedWithoutPassword == .authenticateThenPrompt,
           "the prompt is never a way around the Touch ID gate")

    let disownedStoredPassword = PasswordAvailability.decide(
        hasSessionPassword: false, hasKeychainPassword: true,
        rememberPassword: false, requiresAuthentication: false)
    expect(disownedStoredPassword != .connect,
           "a password the record asked to forget is never dialled with")

    print(failures == 0 ? "ALL TESTS PASSED" : "\(failures) TEST(S) FAILED")
    exit(failures == 0 ? 0 : 1)
}
