// Standalone test runner for ResultTabName. Not part of the app target —
// compiled together with the implementation by scripts/test-result-tab-name.sh.
//
// This is the whole rule for what a result-tab rename commits, so the two
// answers that mean "no custom name" are covered here rather than being left to
// inspection of the caller.
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

    print(failures == 0 ? "\nAll tests passed" : "\n\(failures) test(s) failed")
    if failures > 0 { exit(1) }
}

func expectTrueName(_ actual: Bool, _ name: String) {
    if actual { print("PASS \(name)") } else { failures += 1; print("FAIL \(name) — expected true") }
}
