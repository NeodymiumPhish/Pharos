// Standalone test runner for ResultTabName. Not part of the app target —
// compiled together with the implementation by scripts/test-result-tab-name.sh.
//
// This is the whole rule for a result tab's name: what a rename commits, and
// what the tab is called when nothing was renamed. The two answers that mean
// "no custom name" are covered here rather than being left to inspection of the
// caller — and so is the derived name they hand the tab back to.
import Foundation

var failures = 0

func expectNil(_ actual: String?, _ name: String) {
    if actual == nil { print("PASS \(name)") } else {
        failures += 1
        print("FAIL \(name)\n  expected: nil\n  actual:   \(actual ?? "")")
    }
}

func expectName(_ actual: String?, _ expected: String, _ name: String) {
    if actual == expected { print("PASS \(name)") } else {
        failures += 1
        print("FAIL \(name)\n  expected: \(expected)\n  actual:   \(actual ?? "<nil>")")
    }
}

private let auto = "L1-3: users"

func runTests() {

    // MARK: An ordinary name

    expectName(ResultTabName.committed("Revenue by month", automatic: auto),
               "Revenue by month",
               "an ordinary name is committed byte-for-byte")

    expectName(ResultTabName.committed("  Revenue  ", automatic: auto), "Revenue",
               "surrounding whitespace is trimmed")

    // Interior spacing is the author's, and is left exactly as typed. A
    // sanitiser that collapsed runs would rewrite a name the user can see.
    expectName(ResultTabName.committed("Q1  vs  Q2", automatic: auto), "Q1  vs  Q2",
               "interior spacing is left as typed")

    // MARK: The two answers that mean "no custom name"

    expectNil(ResultTabName.committed("", automatic: auto),
              "an empty field restores the derived name")
    expectNil(ResultTabName.committed("   ", automatic: auto),
              "a whitespace-only field restores the derived name")
    expectNil(ResultTabName.committed("\t\n ", automatic: auto),
              "whitespace controls fold and then trim away, so they restore it too")

    // The prefilled dialog confirmed unchanged must NOT freeze the derived name
    // as a custom one — the tab has to go on following its statement.
    expectNil(ResultTabName.committed(auto, automatic: auto),
              "the derived name typed back verbatim commits no override")
    expectNil(ResultTabName.committed("  \(auto)  ", automatic: auto),
              "…and still commits none once trimmed")

    // A name that only LOOKS like the derived one must be recognised as it,
    // because on screen the two are indistinguishable. NBSP folds to a space.
    expectNil(ResultTabName.committed("L1-3:\u{00A0}users", automatic: auto),
              "a no-break space inside the derived name still reads as the derived name")

    // A different name that merely starts with the derived one is a real name.
    expectName(ResultTabName.committed("L1-3: users (before)", automatic: auto),
               "L1-3: users (before)",
               "a longer name containing the derived one is still a custom name")

    // MARK: A name cannot misrepresent itself

    // `safe` + U+202E + `gpj.exe` DISPLAYS as `safeexe.jpg`. The override is
    // denied entry rather than escaped, because this string is written to the
    // store and read back into the field.
    let spoof = ResultTabName.committed("safe\u{202E}gpj.exe", automatic: auto)
    expectName(spoof, "safegpj.exe", "a right-to-left override is stripped, not escaped")
    if let spoof {
        expectTrueName(!spoof.unicodeScalars.contains { $0.value == 0x202E },
                       "the committed name holds no bidi override")
    }

    // Zero-width characters are removed: two names differing only by one are
    // two names that read identically.
    expectName(ResultTabName.committed("Reven\u{200B}ue", automatic: auto), "Revenue",
               "a zero-width space is removed")

    // …which is what makes the derived-name check above robust: a zero-width
    // character cannot be used to smuggle a lookalike past it.
    expectNil(ResultTabName.committed("L1-3: users\u{200B}", automatic: auto),
              "a trailing zero-width space does not make a lookalike a custom name")

    // Sanitising runs BEFORE the trim, so an edge zero-width character cannot
    // shelter an ordinary space behind it.
    expectName(ResultTabName.committed("Revenue\u{200B} ", automatic: auto), "Revenue",
               "a space hidden behind a zero-width character is still trimmed")

    // MARK: Committing is idempotent

    // Renaming to a name that came back out of the store must be a fixed point,
    // or a second rename would keep rewriting it.
    if let once = ResultTabName.committed("safe\u{202E}gpj.exe", automatic: auto) {
        expectName(ResultTabName.committed(once, automatic: auto), once,
                   "committing an already-committed name changes nothing")
    }

    // MARK: The derived name

    // The name a live run shows: the statement's line range, then its table.
    expectDerived(ResultTabName.derived(lineRange: 1...3, sql: "SELECT *\nFROM users\nWHERE id = 1"),
                  "L1-3: users",
                  "a multi-line statement names its line range and its table")
    expectDerived(ResultTabName.derived(lineRange: 4...4, sql: "SELECT * FROM users"),
                  "L4: users",
                  "a one-line statement names the single line")

    // No line range means the result came from no editor segment — a browse
    // action, a whole-editor run, a drill, or a result restored from a workspace
    // recorded before the range was stored. `L0:` would state a line the
    // statement is not on, so the prefix is left off entirely.
    expectDerived(ResultTabName.derived(lineRange: 0...0, sql: "SELECT * FROM users"),
                  "users",
                  "with no line range the name is the table alone")

    // The statement's own shape, not its position, decides the subject.
    expectDerived(ResultTabName.derived(lineRange: 2...2, sql: "UPDATE public.orders SET x = 1"),
                  "L2: orders",
                  "a schema prefix is not part of the table name")
    expectDerived(ResultTabName.derived(lineRange: 2...2, sql: #"SELECT * FROM "Odd Name""#),
                  "L2: Odd Name",
                  "a quoted table name is unquoted")
    expectDerived(ResultTabName.derived(lineRange: 1...1, sql: "INSERT INTO logs VALUES (1)"),
                  "L1: logs",
                  "INSERT INTO names its target")

    // No table to read: the first line stands in, cut to 30 characters.
    expectDerived(ResultTabName.derived(lineRange: 1...1, sql: "SELECT now()"),
                  "L1: SELECT now()",
                  "a statement with no table falls back to its first line")
    expectDerived(ResultTabName.derived(lineRange: 1...1, sql: String(repeating: "a", count: 40)),
                  "L1: " + String(repeating: "a", count: 30) + "…",
                  "a long first line is cut to 30 characters")

    // A name must be visible. An empty SQL string would otherwise give an empty
    // tab, which the user cannot click with confidence.
    expectDerived(ResultTabName.derived(lineRange: 0...0, sql: "   "), "Result",
                  "an empty statement still gets a visible name")

    // The rename rule and the derived name have to agree, or the prefilled
    // dialog confirmed unchanged would freeze the derived name as a custom one.
    let derived = ResultTabName.derived(lineRange: 1...3, sql: "SELECT *\nFROM users\nWHERE id = 1")
    expectNil(ResultTabName.committed(derived, automatic: derived),
              "the derived name is refused as a custom name by the rename rule")

    print(failures == 0 ? "\nAll tests passed" : "\n\(failures) test(s) failed")
    if failures > 0 { exit(1) }
}

func expectTrueName(_ actual: Bool, _ name: String) {
    if actual { print("PASS \(name)") } else { failures += 1; print("FAIL \(name) — expected true") }
}

func expectDerived(_ actual: String, _ expected: String, _ name: String) {
    if actual == expected { print("PASS \(name)") } else {
        failures += 1
        print("FAIL \(name)\n  expected: \(expected)\n  actual:   \(actual)")
    }
}
