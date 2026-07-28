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

func expectAgree(_ a: Bool, _ b: Bool, _ name: String) {
    if a == b { print("PASS \(name)") } else {
        failures += 1
        print("FAIL \(name)\n  panel: \(a)  render: \(b)")
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

    // Trimming: format(_:) trims surrounding whitespace before validating, so
    // problem(for:) must not flag a value that only has stray whitespace
    // around an otherwise-valid number/bool/literal. Pinned so a future
    // reimplementation that forgets to trim is caught here.
    expectProblemNil(VariableSubstitutor.problem(for: v("a", " 443 ", .number)), "trimmed number not flagged")
    expectProblemNil(VariableSubstitutor.problem(for: v("a", " TRUE ", .bool)), "trimmed bool not flagged")
    expectProblemNil(VariableSubstitutor.problem(for: v("a", " 5 ", .literal)), "trimmed literal not flagged")

    // MARK: message — the tooltip text the panel shows

    expectEqual(VariableSubstitutor.ValueProblem.emptyLiteral.message,
                "Referenced in the query but has no value — the query will fail.",
                "emptyLiteral message")
    expectEqual(VariableSubstitutor.ValueProblem.invalidValue(reason: "not a valid number: \"abc\"").message,
                "Referenced in the query but the value is not a valid number: \"abc\".",
                "invalidValue message")

    // MARK: referencedNames(in:)

    expectNames(VariableSubstitutor.referencedNames(in: "a = {{x}} AND b = {{y}}"), ["x", "y"], "two tokens")
    // A name appearing twice still names one variable, not two — the fact that
    // inserting into a Set naturally dedups is a property of Set, not
    // something this code needs to get right. What's actually checked here is
    // that both occurrences are recognized as the same name.
    expectNames(VariableSubstitutor.referencedNames(in: "{{a}}-{{b}}-{{a}}"), ["a", "b"], "repeated token recognized as one name")
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

    // A token inside a comment or a dollar-quoted body IS substituted by
    // render(), so referencedNames must count it too. These pin that agreement
    // so a future "don't substitute inside comments" change to render() cannot
    // silently desynchronise the panel.
    expectNames(VariableSubstitutor.referencedNames(in: "$tag$ {{x}} $tag$"), ["x"], "token inside a dollar-quoted body counts")
    expectNames(VariableSubstitutor.referencedNames(in: "-- {{x}} in a comment"), ["x"], "token inside a line comment counts")
    expectNames(VariableSubstitutor.referencedNames(in: "/* {{x}} */ SELECT 1"), ["x"], "token inside a block comment counts")
    expectNames(VariableSubstitutor.referencedNames(in: "{{{x}}}"), ["x"], "extra braces do not prevent a match")
    // NOTE: verified empirically — NSRegularExpression's \s matches line
    // breaks (ICU semantics), so tokenRegex's `\s*` DOES span a newline here.
    // render() agrees (substitutes SENTINEL for this exact input), so this is
    // not a referencedNames/render disagreement — it pins actual behavior
    // rather than the assumption that whitespace excludes newlines.
    expectNames(VariableSubstitutor.referencedNames(in: "{{\nx\n}}"), ["x"], "a token can span a newline (regex \\s matches line breaks)")
    expectNames(VariableSubstitutor.referencedNames(in: "{{1x}}"), [], "a name cannot start with a digit")

    // MARK: displayProblems(in:referenced:) — only referenced, non-shadowed variables are flagged

    let ipEmpty = v("ip", "", .literal)
    expectProblem(VariableSubstitutor.displayProblems(in: [ipEmpty], referenced: ["ip"])[ipEmpty.id],
                  .emptyLiteral, "referenced empty literal flagged")
    expectProblemNil(VariableSubstitutor.displayProblems(in: [ipEmpty], referenced: [])[ipEmpty.id],
                     "unreferenced empty literal not flagged")
    expectProblemNil(VariableSubstitutor.displayProblems(in: [ipEmpty], referenced: ["other"])[ipEmpty.id],
                     "empty literal referenced under a different name not flagged")

    // Two different reasons an unnamed variable is not flagged, asserted separately
    // so the `!name.isEmpty` guard in displayProblems is load-bearing in this suite.
    // First: the name simply isn't in the set (also true without the guard).
    let unnamed = v("", "", .literal)
    expectProblemNil(VariableSubstitutor.displayProblems(in: [unnamed], referenced: ["ip"])[unnamed.id],
                     "unnamed variable not flagged when the set has other names")
    // Second: the set contains the empty string, so only the guard prevents a
    // false-positive flag. `referencedNames` can never produce this — its regex
    // requires a leading identifier character — but displayProblems takes an
    // arbitrary Set, so the guard is what makes that safe.
    expectProblemNil(VariableSubstitutor.displayProblems(in: [unnamed], referenced: [""])[unnamed.id],
                     "unnamed variable not flagged even when the set contains an empty name")

    // Duplicate names: render() takes the LAST definition, so a shadowed row
    // cannot break the query and must not be flagged.
    let shadowedFirst = [v("ip", "", .literal), v("ip", "8.8.8.8", .literal)]
    let shadowedProblems = VariableSubstitutor.displayProblems(in: shadowedFirst, referenced: ["ip"])
    expectTrue(shadowedProblems.isEmpty, "shadowed empty literal is not flagged")
    // …and the query it belongs to really does succeed, which is why.
    expectEqual(VariableSubstitutor.render("WHERE ip = {{ip}}", with: shadowedFirst).sql,
                "WHERE ip = 8.8.8.8", "last definition wins at render time")

    // Reverse order: now the empty one is the effective definition, so it IS
    // flagged — and only it.
    let shadowedLast = [v("ip", "8.8.8.8", .literal), v("ip", "", .literal)]
    let lastProblems = VariableSubstitutor.displayProblems(in: shadowedLast, referenced: ["ip"])
    expectProblem(lastProblems[shadowedLast[1].id], .emptyLiteral, "effective empty literal is flagged")
    expectProblemNil(lastProblems[shadowedLast[0].id], "shadowed valid literal is not flagged")
    expectTrue(lastProblems.count == 1, "exactly one row flagged for a duplicated name")

    // MARK: Property — problem(for:) agrees with render()'s rejection, and
    // referencedNames(in:) agrees with render()'s substitution. These are the
    // only assertions that would catch a future edit to format(_:),
    // numberRegex, or tokenRegex silently breaking the panel's agreement with
    // what actually executes.

    let probeValues = ["", " ", "443", " 443 ", "-4.5", "+5", ".5", "abc", "1.2.3", "1e3", "yes", "no", "TRUE", "0", "maybe", "'"]
    for type in VariableType.allCases where type != .literal {
        for value in probeValues {
            let variable = v("x", value, type)
            let renderRejects = !VariableSubstitutor.render("q = {{x}}", with: [variable]).invalid.isEmpty
            let panelFlags = VariableSubstitutor.problem(for: variable) != nil
            expectAgree(panelFlags, renderRejects,
                        "problem() agrees with render() for \(type.displayName) \(value.debugDescription)")
        }
    }

    // .literal is excluded from the loop above because render() reports no
    // `invalid` for it — a raw value is substituted verbatim, whatever it is.
    // Its failure mode is a HOLE in the SQL, so derive that from render's own
    // output: substitute into a marked slot and see whether the slot came back
    // empty. This is what ties "empty Literal breaks the query" to what actually
    // executes, rather than to our own restatement of the rule.
    for value in probeValues {
        let variable = v("x", value, .literal)
        let inner = VariableSubstitutor.render("<{{x}}>", with: [variable]).sql
            .dropFirst().dropLast()
        let rendersHole = inner.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        let panelFlags = VariableSubstitutor.problem(for: variable) != nil
        expectAgree(panelFlags, rendersHole,
                    "emptyLiteral agrees with render's hole for \(value.debugDescription)")
    }

    let probeSQL = [
        "a = {{x}}", "'{{x}}'", "-- {{x}}", "/* {{x}} */", "$tag$ {{x}} $tag$",
        "{{{x}}}", "{{ x }}", "{{\nx\n}}", "{{1x}}", "{{x-y}}", "{ {x} }", "SELECT 1",
    ]
    for sql in probeSQL {
        let substituted = VariableSubstitutor.render(sql, with: [v("x", "SENTINEL", .literal)]).sql
        let renderSubstitutes = substituted.contains("SENTINEL")
        let named = VariableSubstitutor.referencedNames(in: sql).contains("x")
        expectAgree(named, renderSubstitutes,
                    "referencedNames agrees with render for \(sql.debugDescription)")
    }

    print(failures == 0 ? "\nALL PASSED" : "\n\(failures) FAILURE(S)")
    exit(failures == 0 ? 0 : 1)
}
