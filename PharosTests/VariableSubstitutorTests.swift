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

func expectProblem(
    _ actual: VariableSubstitutor.ValueProblem?,
    _ expected: VariableSubstitutor.ValueProblem?,
    _ name: String
) {
    if actual == expected { print("PASS \(name)") } else {
        failures += 1
        print("FAIL \(name)\n  expected: \(String(describing: expected))\n  actual:   \(String(describing: actual))")
    }
}

func expectNames(_ actual: Set<String>, _ expected: Set<String>, _ name: String) {
    if actual == expected { print("PASS \(name)") } else {
        failures += 1
        print("FAIL \(name)\n  expected: \(expected.sorted())\n  actual:   \(actual.sorted())")
    }
}

func expectProblemNil(_ actual: VariableSubstitutor.ValueProblem?, _ name: String) {
    if actual == nil { print("PASS \(name)") } else {
        failures += 1
        print("FAIL \(name) — expected nil, got \(String(describing: actual))")
    }
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

    // MARK: problem(for:) — can this value become working SQL?

    // Literal renders raw, so an empty or whitespace-only value leaves a hole.
    expectProblem(VariableSubstitutor.problem(for: v("a", "", .literal)), .emptyLiteral, "empty literal flagged")
    expectProblem(VariableSubstitutor.problem(for: v("a", "   ", .literal)), .emptyLiteral, "whitespace literal flagged")
    expectProblem(VariableSubstitutor.problem(for: v("a", "\n\t", .literal)), .emptyLiteral, "whitespace-newline literal flagged")
    expectProblemNil(VariableSubstitutor.problem(for: v("a", "1", .literal)), "non-empty literal not flagged")

    // Text renders '' — a legal empty string. Null ignores the value entirely.
    expectProblemNil(VariableSubstitutor.problem(for: v("a", "", .text)), "empty text not flagged")
    expectProblemNil(VariableSubstitutor.problem(for: v("a", "", .null)), "empty null not flagged")
    expectProblemNil(VariableSubstitutor.problem(for: v("a", "anything", .null)), "null never flagged")

    // Number / Bool are flagged for any value the substitutor already rejects.
    expectProblem(VariableSubstitutor.problem(for: v("a", "", .number)),
                  .invalidValue(reason: "not a valid number: \"\""), "empty number flagged")
    expectProblem(VariableSubstitutor.problem(for: v("a", "abc", .number)),
                  .invalidValue(reason: "not a valid number: \"abc\""), "non-numeric number flagged")
    expectProblem(VariableSubstitutor.problem(for: v("a", "1.2.3", .number)),
                  .invalidValue(reason: "not a valid number: \"1.2.3\""), "malformed number flagged")
    expectProblemNil(VariableSubstitutor.problem(for: v("a", "-4.5", .number)), "valid negative decimal not flagged")
    expectProblem(VariableSubstitutor.problem(for: v("a", "maybe", .bool)),
                  .invalidValue(reason: "not a valid boolean: \"maybe\""), "invalid bool flagged")
    expectProblemNil(VariableSubstitutor.problem(for: v("a", "yes", .bool)), "yes is a valid bool")
    expectProblemNil(VariableSubstitutor.problem(for: v("a", "0", .bool)), "0 is a valid bool")

    // MARK: message — the tooltip text the panel shows

    expectEqual(VariableSubstitutor.ValueProblem.emptyLiteral.message,
                "Referenced in the query but has no value — the query will fail.",
                "emptyLiteral message")
    expectEqual(VariableSubstitutor.ValueProblem.invalidValue(reason: "not a valid number: \"abc\"").message,
                "Referenced in the query but the value is not a valid number: \"abc\".",
                "invalidValue message")

    // MARK: referencedNames(in:)

    expectNames(VariableSubstitutor.referencedNames(in: "a = {{x}} AND b = {{y}}"), ["x", "y"], "two tokens")
    expectNames(VariableSubstitutor.referencedNames(in: "{{a}}-{{b}}-{{a}}"), ["a", "b"], "duplicates collapse")
    expectNames(VariableSubstitutor.referencedNames(in: "x = {{  ip  }}"), ["ip"], "inner whitespace tolerated")
    // render() substitutes inside string literals, so the panel must count them
    // too — otherwise a broken value inside quotes would never be flagged.
    expectNames(VariableSubstitutor.referencedNames(in: "orig_h = '{{ip}}'"), ["ip"], "tokens inside string literals count")
    expectNames(VariableSubstitutor.referencedNames(in: "SELECT 1"), [], "no tokens")
    // The delimiter was chosen so ordinary SQL cannot form a token by accident.
    expectNames(
        VariableSubstitutor.referencedNames(
            in: "email = 'admin@example.com' AND tags @> '{\"k\":1}' AND a::int = $1 AND $tag$x$tag$ = ''"),
        [], "no collision with emails/operators/casts/params/dollar-quotes")

    // MARK: displayProblem(for:referenced:) — only referenced variables are flagged

    expectProblem(VariableSubstitutor.displayProblem(for: v("ip", "", .literal), referenced: ["ip"]),
                  .emptyLiteral, "referenced empty literal flagged")
    expectProblemNil(VariableSubstitutor.displayProblem(for: v("ip", "", .literal), referenced: []),
                     "unreferenced empty literal not flagged")
    expectProblemNil(VariableSubstitutor.displayProblem(for: v("ip", "", .literal), referenced: ["other"]),
                     "empty literal referenced under a different name not flagged")
    // Two different reasons an unnamed variable is not flagged, asserted separately
    // so the `!name.isEmpty` guard in displayProblem is load-bearing in this suite.
    // First: the name simply isn't in the set (also true without the guard).
    expectProblemNil(VariableSubstitutor.displayProblem(for: v("", "", .literal), referenced: ["ip"]),
                     "unnamed variable not flagged when the set has other names")
    // Second: the set contains the empty string, so only the guard prevents a
    // false-positive flag. `referencedNames` can never produce this — its regex
    // requires a leading identifier character — but displayProblem takes an
    // arbitrary Set, so the guard is what makes that safe.
    expectProblemNil(VariableSubstitutor.displayProblem(for: v("", "", .literal), referenced: [""]),
                     "unnamed variable not flagged even when the set contains an empty name")

    print(failures == 0 ? "\nALL PASSED" : "\n\(failures) FAILURE(S)")
    exit(failures == 0 ? 0 : 1)
}
