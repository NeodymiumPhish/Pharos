// Standalone test runner for VariableSubstitutor. Not part of the app target —
// compiled together with the implementation by scripts/test-variable-substitutor.sh.
import Foundation

var failures = 0

func expectEqual(_ actual: String, _ expected: String, _ name: String) {
    if actual == expected { print("PASS \(name)") } else {
        failures += 1
        print("FAIL \(name)\n  expected: \(expected.debugDescription)\n  actual:   \(actual.debugDescription)")
    }
}

func expectEqualArr(_ actual: [String], _ expected: [String], _ name: String) {
    if actual == expected { print("PASS \(name)") } else {
        failures += 1
        print("FAIL \(name)\n  expected: \(expected)\n  actual:   \(actual)")
    }
}

func expectTrue(_ actual: Bool, _ name: String) {
    if actual { print("PASS \(name)") } else { failures += 1; print("FAIL \(name) — expected true") }
}

func v(_ name: String, _ value: String, _ type: VariableType) -> QueryVariable {
    QueryVariable(name: name, value: value, type: type)
}

func runTests() {
    // Literal (raw) substitution
    expectEqual(
        VariableSubstitutor.render("orig_h = '{{ip}}'", with: [v("ip", "8.8.4.4", .literal)]).sql,
        "orig_h = '8.8.4.4'", "literal raw substitution")

    // Optional inner whitespace
    expectEqual(
        VariableSubstitutor.render("x = {{  ip  }}", with: [v("ip", "1", .literal)]).sql,
        "x = 1", "inner whitespace tolerated")

    // Text: quoted + escaped
    expectEqual(
        VariableSubstitutor.render("name = {{n}}", with: [v("n", "O'Brien", .text)]).sql,
        "name = 'O''Brien'", "text quoted + apostrophe escaped")

    // Number: valid stays bare
    expectEqual(
        VariableSubstitutor.render("port = {{p}}", with: [v("p", "443", .number)]).sql,
        "port = 443", "number valid bare")

    // Bool: normalized
    expectEqual(
        VariableSubstitutor.render("ok = {{b}}", with: [v("b", "YES", .bool)]).sql,
        "ok = true", "bool YES -> true")

    // Null: emits NULL, ignores value
    expectEqual(
        VariableSubstitutor.render("c = {{x}}", with: [v("x", "ignored", .null)]).sql,
        "c = NULL", "null emits NULL")

    // Unresolved: token left verbatim, name collected
    let unres = VariableSubstitutor.render("a = {{foo}}", with: [])
    expectEqual(unres.sql, "a = {{foo}}", "unresolved left verbatim")
    expectEqualArr(unres.unresolved, ["foo"], "unresolved name collected")

    // Invalid number: token left verbatim, invalid collected
    let inv = VariableSubstitutor.render("p = {{p}}", with: [v("p", "abc", .number)])
    expectEqual(inv.sql, "p = {{p}}", "invalid number left verbatim")
    expectTrue(inv.invalid.count == 1 && inv.invalid[0].name == "p", "invalid number collected")

    // Collision safety: emails / operators / casts / params untouched
    let safe = "email = 'admin@example.com' AND tags @> '{\"k\":1}' AND a::int = $1"
    expectEqual(VariableSubstitutor.render(safe, with: [v("k", "X", .literal)]).sql, safe,
                "no collision with emails/operators/casts/params")

    // Multiple + repeated
    expectEqual(
        VariableSubstitutor.render("{{a}}-{{b}}-{{a}}", with: [v("a", "1", .literal), v("b", "2", .literal)]).sql,
        "1-2-1", "multiple + repeated tokens")

    // containsTokens
    expectTrue(VariableSubstitutor.containsTokens("x = {{y}}"), "containsTokens true")
    expectTrue(!VariableSubstitutor.containsTokens("x = 'a@b'"), "containsTokens false")

    print(failures == 0 ? "\nALL PASSED" : "\n\(failures) FAILURE(S)")
    exit(failures == 0 ? 0 : 1)
}
