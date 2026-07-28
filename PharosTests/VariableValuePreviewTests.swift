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

func expectTrue(_ actual: Bool, _ name: String) {
    if actual { print("PASS \(name)") } else {
        failures += 1
        print("FAIL \(name) — expected true")
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
    expectEqual(VariableValuePreview.caption(for: "500\n"), "3 chars", "caption strips one trailing break before counting chars")

    // CRLF / lone-CR line breaks (Windows/Excel/RDP pastes) must split just like "\n".
    expectEqual(VariableValuePreview.caption(for: "8f2a1c,\r\n9b0e44,\r\n71cc03,"), "3 lines", "caption splits on CRLF")
    expectEqual(VariableValuePreview.snippet(for: "8f2a1c,\r\n9b0e44,"), "8f2a1c,", "snippet splits on CRLF")
    expectEqual(VariableValuePreview.caption(for: "a\rb"), "2 lines", "caption splits on lone CR")

    // snippet length is bounded so one very long line cannot blow out row layout.
    let longSingleLine = String(repeating: "a", count: 900)
    expectEqual(VariableValuePreview.snippet(for: longSingleLine), String(repeating: "a", count: 500),
                "snippet caps at 500 characters")

    // Invariant: whatever line-break style the input used, the snippet is truly one line.
    let crlfSnippet = VariableValuePreview.snippet(for: "8f2a1c,\r\n9b0e44,\r\n71cc03,")
    expectTrue(crlfSnippet.rangeOfCharacter(from: .newlines) == nil, "snippet never contains a line break")

    print(failures == 0 ? "\nALL PASSED" : "\n\(failures) FAILURE(S)")
    exit(failures == 0 ? 0 : 1)
}
