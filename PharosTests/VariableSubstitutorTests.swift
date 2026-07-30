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

    // MARK: BoolChoice is the single source the panel's choice control reads

    // Property: every choice's canonical rawValue round-trips — classified back to
    // itself, and rendered by format() as exactly that same string. This is what
    // lets the detail level's segmented control write `rawValue` and read
    // `boolChoice(for:)` without restating any spellings of its own.
    for choice in VariableSubstitutor.BoolChoice.allCases {
        expectTrue(VariableSubstitutor.boolChoice(for: choice.rawValue) == choice,
                   "BoolChoice \(choice.rawValue) classifies back to itself")
        expectEqual(VariableSubstitutor.render("c = {{x}}", with: [v("x", choice.rawValue, .bool)]).sql,
                    "c = \(choice.rawValue)", "BoolChoice \(choice.rawValue) renders as its rawValue")
        expectProblemNil(VariableSubstitutor.problem(for: v("x", choice.rawValue, .bool)),
                         "BoolChoice \(choice.rawValue) is a valid bool value")
    }

    // Property: classification agrees with validity for every spelling either
    // accepts, so the control can never show a selection for a value the badge
    // calls broken, or vice versa.
    for spelling in ["true", "TRUE", "t", "1", "yes", "y", "false", "F", "0", "no", "n",
                     "null", "NULL", "Null", "", " ", "abc", "maybe", "2", "nil"] {
        let classified = VariableSubstitutor.boolChoice(for: spelling) != nil
        let valid = VariableSubstitutor.problem(for: v("x", spelling, .bool)) == nil
        expectAgree(classified, valid, "boolChoice agrees with validity for \(spelling.debugDescription)")
    }

    // The three choices, in the order the segmented control relies on.
    expectEqual(VariableSubstitutor.BoolChoice.allCases.map(\.rawValue).joined(separator: ","),
                "true,false,NULL", "BoolChoice order and canonical spellings")

    // NULL is a Bool value, not a type of its own. Case-insensitive on the way in
    // (legacy values, hand-typed values), uppercase `NULL` on the way out.
    expectEqual(
        VariableSubstitutor.render("c = {{x}}", with: [v("x", "NULL", .bool)]).sql,
        "c = NULL", "bool NULL -> NULL")
    expectEqual(
        VariableSubstitutor.render("c = {{x}}", with: [v("x", "null", .bool)]).sql,
        "c = NULL", "bool lowercase null -> NULL")
    expectEqual(
        VariableSubstitutor.render("c = {{x}}", with: [v("x", "Null", .bool)]).sql,
        "c = NULL", "bool mixed-case Null -> NULL")
    expectProblemNil(VariableSubstitutor.problem(for: v("x", "NULL", .bool)),
                     "a bool holding NULL is valid")

    // The type set itself: `Null` was removed in favour of a Literal holding NULL.
    expectTrue(VariableType.allCases.count == 4, "four variable types remain")
    expectTrue(VariableType(rawValue: "null") == nil, "there is no null variable type")

    // Legacy saved queries may carry `"type": "null"`. Decoding must migrate it to
    // a Literal holding NULL — identical rendering — rather than throw, because
    // SavedQueryVariables.decode swallows errors and would drop the whole array.
    let legacyJSON = #"[{"id":"3F2504E0-4F89-11D3-9A0C-0305E82C3301","name":"n","value":"ignored","type":"null"}]"#
    if let data = legacyJSON.data(using: .utf8),
       let migrated = try? JSONDecoder().decode([QueryVariable].self, from: data),
       let first = migrated.first {
        expectTrue(first.type == .literal, "a legacy null type migrates to Literal")
        expectEqual(first.value, "NULL", "a legacy null type migrates to the value NULL")
        expectEqual(VariableSubstitutor.render("c = {{n}}", with: migrated).sql,
                    "c = NULL", "a migrated legacy null still renders NULL")
    } else {
        failures += 1
        print("FAIL legacy null type failed to decode at all")
    }

    // An unknown future type must also not throw away the array.
    let futureJSON = #"[{"id":"3F2504E0-4F89-11D3-9A0C-0305E82C3302","name":"n","value":"x","type":"quantum"}]"#
    if let data = futureJSON.data(using: .utf8),
       let decoded = try? JSONDecoder().decode([QueryVariable].self, from: data),
       let first = decoded.first {
        expectTrue(first.type == .literal, "an unknown type falls back to Literal")
        expectEqual(first.value, "x", "an unknown type keeps its value")
    } else {
        failures += 1
        print("FAIL unknown type failed to decode at all")
    }

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

    // Text renders '' — a legal empty string, so an empty one is not a problem.
    expectProblemNil(VariableSubstitutor.problem(for: v("a", "", .text)), "empty text not flagged")

    // A Bool with no value chosen yet IS flagged: it renders nothing usable, and
    // the detail level offers three explicit choices, so "unset" is a real gap
    // rather than a default worth guessing at.
    expectProblem(VariableSubstitutor.problem(for: v("a", "", .bool)),
                  .invalidValue(reason: "not a valid boolean: \"\""), "an unset bool is flagged")

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

    // MARK: rowStates(in:referenced:) — problem + duplication signal per row

    let ipEmpty = v("ip", "", .literal)
    expectProblem(VariableSubstitutor.rowStates(in: [ipEmpty], referenced: ["ip"])[ipEmpty.id]?.problem,
                  .emptyLiteral, "referenced empty literal flagged")
    expectProblemNil(VariableSubstitutor.rowStates(in: [ipEmpty], referenced: [])[ipEmpty.id]?.problem,
                     "unreferenced empty literal not flagged")
    expectProblemNil(VariableSubstitutor.rowStates(in: [ipEmpty], referenced: ["other"])[ipEmpty.id]?.problem,
                     "empty literal referenced under a different name not flagged")

    // Two different reasons an unnamed variable is not flagged, asserted separately
    // so the `!name.isEmpty` guard in rowStates is load-bearing in this suite.
    // First: the name simply isn't in the set (also true without the guard).
    let unnamed = v("", "", .literal)
    expectProblemNil(VariableSubstitutor.rowStates(in: [unnamed], referenced: ["ip"])[unnamed.id]?.problem,
                     "unnamed variable not flagged when the set has other names")
    // Second: the set contains the empty string, so only the guard prevents a
    // false-positive flag. `referencedNames` can never produce this — its regex
    // requires a leading identifier character — but rowStates takes an
    // arbitrary Set, so the guard is what makes that safe.
    expectProblemNil(VariableSubstitutor.rowStates(in: [unnamed], referenced: [""])[unnamed.id]?.problem,
                     "unnamed variable not flagged even when the set contains an empty name")

    // Clicking + twice leaves two unnamed rows. They are not duplicates of each
    // other in any sense the user cares about, and badging them would make the
    // most common state in the panel look broken.
    let twoBlank = [v("", "", .literal), v("", "", .literal)]
    expectTrue(VariableSubstitutor.rowStates(in: twoBlank, referenced: []).isEmpty,
               "two freshly added blank rows are not reported as duplicates of each other")

    // A whitespace-only name is just as inert as an empty one — tokenRegex
    // requires a leading identifier character, so " " can never be referenced,
    // same as "". The guard trims before checking for exactly this reason.
    let twoWhitespace = [v(" ", "", .literal), v(" ", "", .literal)]
    expectTrue(VariableSubstitutor.rowStates(in: twoWhitespace, referenced: []).isEmpty,
               "two rows named whitespace-only are not reported as duplicates of each other")
    // A real (non-blank) name with incidental surrounding whitespace is a
    // distinct, unreferenceable name — not the same case as "unnamed" — and is
    // still correctly left unflagged when nothing references it under that
    // literal, untrimmed spelling.
    let spacedName = v(" ip ", "", .literal)
    expectProblemNil(VariableSubstitutor.rowStates(in: [spacedName], referenced: ["ip"])[spacedName.id]?.problem,
                     "a name with surrounding whitespace is not flagged under the trimmed name")

    // Duplicate names: render() takes the LAST definition. The earlier row is
    // inert, so it is marked shadowed and never carries a problem; the effective
    // row is marked overriding.
    let dupA = [v("ip", "", .literal), v("ip", "8.8.8.8", .literal)]
    let statesA = VariableSubstitutor.rowStates(in: dupA, referenced: ["ip"])
    expectTrue(statesA[dupA[0].id]?.duplication == .shadowed, "earlier duplicate is shadowed")
    expectProblemNil(statesA[dupA[0].id]?.problem, "shadowed row carries no problem")
    expectTrue(statesA[dupA[1].id]?.duplication == .overriding, "later duplicate is overriding")
    expectProblemNil(statesA[dupA[1].id]?.problem, "effective valid row carries no problem")
    // …and the query it belongs to really does succeed, which is why.
    expectEqual(VariableSubstitutor.render("WHERE ip = {{ip}}", with: dupA).sql,
                "WHERE ip = 8.8.8.8", "last definition wins at render time")

    // Both signals on one row: the effective definition is also unable to render.
    let dupB = [v("ip", "8.8.8.8", .literal), v("ip", "", .literal)]
    let statesB = VariableSubstitutor.rowStates(in: dupB, referenced: ["ip"])
    expectTrue(statesB[dupB[0].id]?.duplication == .shadowed, "valid earlier duplicate is still shadowed")
    expectTrue(statesB[dupB[1].id]?.duplication == .overriding, "broken later duplicate is overriding")
    expectProblem(statesB[dupB[1].id]?.problem, .emptyLiteral, "effective broken row carries the problem")

    // Three or more: only the last is effective.
    let dupC = [v("n", "", .literal), v("n", "", .literal), v("n", "5", .literal)]
    let statesC = VariableSubstitutor.rowStates(in: dupC, referenced: ["n"])
    expectTrue(statesC[dupC[0].id]?.duplication == .shadowed
                && statesC[dupC[1].id]?.duplication == .shadowed, "all earlier duplicates are shadowed")
    expectTrue(statesC[dupC[2].id]?.duplication == .overriding, "only the last is overriding")
    expectTrue(statesC.values.allSatisfy { $0.problem == nil }, "no problem when the effective value is fine")

    // A unique name is not marked at all when its value is fine.
    expectTrue(VariableSubstitutor.rowStates(in: [v("ip", "1", .literal)], referenced: ["ip"]).isEmpty,
               "a healthy unique row has nothing to say")
    // Duplication is a fact about the list, not about the query — it is reported
    // even when nothing references the name.
    let unrefDup = [v("z", "", .literal), v("z", "", .literal)]
    expectTrue(VariableSubstitutor.rowStates(in: unrefDup, referenced: []).count == 2,
               "duplication is reported even when the name is unreferenced")

    // Property: across a sweep of small variable lists, two invariants must hold
    // by construction regardless of names/values/lengths — the .overriding row
    // for a duplicated name is exactly the LAST occurrence of that name in the
    // list (which subsumes "at most one overriding row per name" and ties the
    // marking to render()'s own last-wins rule, rather than just counting), and
    // a .shadowed row never also carries a problem (it cannot break a query it
    // does not reach).
    // Pool holds (name, value, type) recipes, not QueryVariable instances — a
    // combination that repeats a recipe must still produce two DISTINCT rows
    // (fresh UUIDs), matching how real duplicate-named rows arise (each added
    // independently via the panel's + button). Reusing one QueryVariable value
    // across two slots would give both the same id, which rowStates is not
    // required to handle sanely (ids are guaranteed fresh in practice).
    let pool: [(name: String, value: String, type: VariableType)] = [
        ("a", "", .literal), ("a", "1", .literal),
        ("b", "abc", .number), ("b", "2", .number),
        ("c", "", .text),
    ]
    func combinations(_ pool: [(name: String, value: String, type: VariableType)], length: Int)
        -> [[(name: String, value: String, type: VariableType)]] {
        guard length > 0 else { return [[]] }
        var result: [[(name: String, value: String, type: VariableType)]] = []
        for item in pool {
            for rest in combinations(pool, length: length - 1) {
                result.append([item] + rest)
            }
        }
        return result
    }
    // Describes every row's name, value, and type, so a failure names the exact
    // offending list — two pool recipes share the value "", so a value-only
    // label would be ambiguous across several possible lists.
    func describe(_ list: [QueryVariable]) -> String {
        "[" + list.map { "\($0.name.debugDescription)=\($0.value.debugDescription):\($0.type.displayName)" }
            .joined(separator: ", ") + "]"
    }
    for length in 1...3 {
        for recipe in combinations(pool, length: length) {
            let list = recipe.map { v($0.name, $0.value, $0.type) }
            let names = Set(list.map(\.name))
            let states = VariableSubstitutor.rowStates(in: list, referenced: names)
            let label = describe(list)
            for name in names {
                let indices = list.indices.filter { list[$0].name == name }
                guard indices.count > 1, let lastIndex = indices.last else { continue }
                let overridingIndices = indices.filter { states[list[$0].id]?.duplication == .overriding }
                expectTrue(overridingIndices == [lastIndex],
                           "the overriding row for name \(name.debugDescription) is the last occurrence in \(label)")
            }
            for variable in list where states[variable.id]?.duplication == .shadowed {
                expectTrue(states[variable.id]?.problem == nil,
                           "shadowed row carries no problem in \(label)")
            }
        }
    }

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

    // MARK: Number validation must mean ASCII digits, anchored to the whole value

    // ICU's `\d` matches all of Unicode category Nd, so these three passed
    // validation, rendered bare into the SQL, and Postgres then lexed them as
    // identifiers — the user got `column "٤٤٣" does not exist` instead of the
    // "not a valid number" message the type check exists to give them.
    // Asserted as non-nil rather than against a reason string, because the reason
    // embeds the value and a literal here would be about quoting, not behaviour.
    for digits in ["\u{0664}\u{0664}\u{0663}", "\u{FF11}\u{FF12}\u{FF13}", "\u{0967}\u{0968}\u{0969}"] {
        expectTrue(VariableSubstitutor.problem(for: v("n", digits, .number)) != nil,
                   "non-ASCII digits are not a valid number: \(digits.debugDescription)")
        let rendered = VariableSubstitutor.render("p = {{n}}", with: [v("n", digits, .number)])
        expectEqual(rendered.sql, "p = {{n}}", "non-ASCII digits leave the token verbatim: \(digits.debugDescription)")
        expectTrue(rendered.invalid.count == 1, "non-ASCII digits are collected as invalid: \(digits.debugDescription)")
    }

    // `$` in ICU also matches before a single trailing line terminator, so a
    // pasted value carrying one validated and then rendered *with* the newline
    // still attached (`.whitespaces` does not trim newlines). Both halves are
    // fixed: the anchor is `\z`, and the trim covers newlines — so the value is
    // still accepted, but it renders clean.
    expectEqual(VariableSubstitutor.render("p = {{n}}", with: [v("n", "443\n", .number)]).sql,
                "p = 443", "a trailing newline is trimmed, not rendered")
    expectEqual(VariableSubstitutor.render("p = {{n}}", with: [v("n", "443\r\n", .number)]).sql,
                "p = 443", "a trailing CRLF is trimmed, not rendered")
    expectEqual(VariableSubstitutor.render("p = {{n}}", with: [v("n", "443\r", .number)]).sql,
                "p = 443", "a trailing CR is trimmed, not rendered")

    // An interior newline is a different matter and stays rejected — this one
    // holds both before and after the fix, and is pinned because it is the case
    // that would actually matter if the anchor were ever loosened again.
    expectTrue(VariableSubstitutor.problem(for: v("n", "443\nDROP TABLE t", .number)) != nil,
               "a number with an interior newline stays invalid")

    // Asymmetry left in place deliberately: only the `.number` branch trims
    // newlines. A Bool carrying one is still rejected rather than coerced, which
    // is the safer default for a value that renders as a bare `true`/`false`.
    expectTrue(VariableSubstitutor.problem(for: v("b", "yes\n", .bool)) != nil,
               "a bool with a trailing newline is still rejected")

    print(failures == 0 ? "\nALL PASSED" : "\n\(failures) FAILURE(S)")
    exit(failures == 0 ? 0 : 1)
}
