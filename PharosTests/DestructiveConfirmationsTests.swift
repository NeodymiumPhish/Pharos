// Standalone test runner for DestructiveConfirmations — which kinds of
// database-changing statement still ask before they run. Compiled by
// scripts/test-destructive-confirmations.sh with the settings model.
//
// The subject is a filter over what `DestructiveSQLScanner` found. The
// scanner itself has its own suite; this one is only about the choice.
import Foundation

private var failures = 0

private func expectEqual<T: Equatable>(_ actual: T, _ expected: T, _ name: String) {
    if actual == expected { print("PASS \(name)") } else {
        failures += 1
        print("FAIL \(name)\n  expected: \(expected)\n  actual:   \(actual)")
    }
}

private func expectTrue(_ actual: Bool, _ name: String) {
    if actual { print("PASS \(name)") } else { failures += 1; print("FAIL \(name) — expected true") }
}

private let everyKeyword = ["DROP", "ALTER", "TRUNCATE", "DELETE", "UPDATE", "INSERT", "GRANT"]

/// The default must confirm everything, or an upgrade quietly removes a
/// confirmation the user has had since the guard was written.
private func testDefaultConfirmsEverything() {
    let defaults = DestructiveConfirmations()
    for keyword in everyKeyword {
        expectTrue(defaults.confirms(keyword), "default confirms \(keyword)")
    }
    expectEqual(defaults.filtered(everyKeyword), everyKeyword, "the default filter removes nothing")
    expectTrue(defaults.confirms("REVOKE"), "REVOKE follows the GRANT switch")
}

private func testOneOff() {
    var settings = DestructiveConfirmations()
    settings.insert = false
    expectEqual(settings.filtered(["INSERT"]), [], "an INSERT alone no longer asks")
    expectEqual(settings.filtered(["INSERT", "DELETE"]), ["DELETE"],
                "a statement that also DELETEs still asks")
    expectEqual(settings.filtered(everyKeyword), ["DROP", "ALTER", "TRUNCATE", "DELETE", "UPDATE", "GRANT"],
                "only the one kind is dropped, and the order is kept")
}

private func testAllOff() {
    var settings = DestructiveConfirmations()
    for keyPath in [\DestructiveConfirmations.dropObject, \.alter, \.truncate, \.delete, \.update, \.insert, \.grant] {
        settings[keyPath: keyPath] = false
    }
    expectEqual(settings.filtered(everyKeyword), [], "with every kind off, nothing asks")
    // The gate above it is the master switch; this struct never re-enables.
    expectEqual(settings.filtered([]), [], "nothing found, nothing asked")
}

private func testGrantAndRevokeShareASwitch() {
    var settings = DestructiveConfirmations()
    settings.grant = false
    expectEqual(settings.filtered(["GRANT", "REVOKE"]), [], "REVOKE is silenced with GRANT")
    settings.grant = true
    expectEqual(settings.filtered(["REVOKE"]), ["REVOKE"], "and asks with it")
}

/// The direction this must fail in. A keyword the scanner learns and this
/// struct has not got must still raise the confirmation: the alternative is a
/// statement that changes the database running with no warning because the
/// two sides were updated in different commits.
private func testUnknownKeywordFailsSafe() {
    var settings = DestructiveConfirmations()
    for keyPath in [\DestructiveConfirmations.dropObject, \.alter, \.truncate, \.delete, \.update, \.insert, \.grant] {
        settings[keyPath: keyPath] = false
    }
    expectTrue(settings.confirms("MERGE"), "an unknown keyword still asks, with every switch off")
    expectEqual(settings.filtered(["MERGE", "INSERT"]), ["MERGE"], "and survives the filter")
}

private func testStoredShape() {
    // A struct of seven named bools, not a `Set<String>`. The reason is NOT
    // that a struct encodes deterministically — measured 2026-09-19, Swift's
    // JSONEncoder writes a struct's keys in a DIFFERENT order on each call,
    // so neither shape gives stable bytes. The reason is that seven named
    // keys can be mirrored field for field by the Rust struct that is the
    // wire truth, and can each carry `#[serde(default)]`; an array of
    // whichever kinds happen to be on cannot, and cannot tell "switched off"
    // from "written by a build that did not know this kind".
    let encoded = try! JSONEncoder().encode(DestructiveConfirmations())
    let object = (try! JSONSerialization.jsonObject(with: encoded)) as! [String: Any]
    expectEqual(Set(object.keys), ["dropObject", "alter", "truncate", "delete", "update", "insert", "grant"],
                "the wire keys are the seven named fields")
    // What must hold: the VALUE survives a round trip, whatever order the
    // keys came out in.
    var mixed = DestructiveConfirmations()
    mixed.truncate = false
    mixed.grant = false
    let decoded = try! JSONDecoder().decode(
        DestructiveConfirmations.self, from: try! JSONEncoder().encode(mixed))
    expectEqual(decoded, mixed, "a mixed set of switches round-trips")
    expectEqual(AppSettings().query.destructiveConfirmations, DestructiveConfirmations(),
                "AppSettings starts with every kind confirmed")
}

func runTests() {
    testDefaultConfirmsEverything()
    testOneOff()
    testAllOff()
    testGrantAndRevokeShareASwitch()
    testUnknownKeywordFailsSafe()
    testStoredShape()
    print(failures == 0 ? "\nALL PASSED" : "\n\(failures) FAILURE(S)")
    exit(failures == 0 ? 0 : 1)
}
