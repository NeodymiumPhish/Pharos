// Standalone test runner for VariableValuePreview. Not part of the app target —
// compiled together with the implementation by scripts/test-variable-value-preview.sh.
import Foundation

var failures = 0

func expectEqual(_ actual: String, _ expected: String, _ name: String) {
    if actual == expected { print("PASS \(name)") } else {
        failures += 1
        print("FAIL \(name)\n  expected: \(expected.debugDescription)\n  actual:   \(actual.debugDescription)")
    }
}

func runTests() {
    // snippet: the first line with visible content wins.
    expectEqual(VariableValuePreview.snippet(for: "production"), "production", "snippet single line")
    expectEqual(VariableValuePreview.snippet(for: "8f2a1c,\n9b0e44,\n71cc03,"), "8f2a1c,", "snippet first of many")
    expectEqual(VariableValuePreview.snippet(for: "\n\n  \nfoo"), "foo", "snippet skips blank lines")
    expectEqual(VariableValuePreview.snippet(for: "\tindented"), "indented", "snippet flattens tabs then trims")
    expectEqual(VariableValuePreview.snippet(for: "a\tb"), "a b", "snippet flattens interior tabs to spaces")
    expectEqual(VariableValuePreview.snippet(for: ""), "", "snippet of empty value is empty")
    expectEqual(VariableValuePreview.snippet(for: "   "), "", "snippet of whitespace-only value is empty")

    // caption: characters when the value has no newline, lines when it does.
    expectEqual(VariableValuePreview.caption(for: ""), "0 chars", "caption empty")
    expectEqual(VariableValuePreview.caption(for: "x"), "1 char", "caption singular char")
    expectEqual(VariableValuePreview.caption(for: "500"), "3 chars", "caption plural chars")
    expectEqual(VariableValuePreview.caption(for: "a\nb"), "2 lines", "caption counts lines")
    expectEqual(VariableValuePreview.caption(for: "a\nb\n"), "2 lines", "caption ignores one trailing newline")
    expectEqual(VariableValuePreview.caption(for: "a\nb\n\n"), "3 lines", "caption counts a blank final line")

    print(failures == 0 ? "\nALL PASSED" : "\n\(failures) FAILURE(S)")
    exit(failures == 0 ? 0 : 1)
}
