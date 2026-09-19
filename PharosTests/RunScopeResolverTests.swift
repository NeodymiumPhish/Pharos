// Standalone test runner for RunScopeResolver — what ⌘↩ runs.
// Compiled by scripts/test-run-scope-resolver.sh. No editor, no connection.
import Foundation

private var failures = 0

private func expectEqual<T: Equatable>(_ actual: T, _ expected: T, _ name: String) {
    if actual == expected { print("PASS \(name)") } else {
        failures += 1
        print("FAIL \(name)\n  expected: \(expected)\n  actual:   \(actual)")
    }
}

private let statement = RunScopeResolver.Segment(index: 1, sql: "SELECT 2", lineRange: 3...4)
private let buffer = "SELECT 1;\nSELECT 2;\nSELECT 3;"

private func testStatementAtCursor() {
    expectEqual(RunScopeResolver.resolve(mode: .statementAtCursor, selectedText: nil,
                                         segmentAtCursor: statement, fullText: buffer),
                .segment(statement), "the statement at the cursor is run as a segment")
    // A selection is ignored in this mode — that is what choosing it means.
    expectEqual(RunScopeResolver.resolve(mode: .statementAtCursor, selectedText: "SELECT 9",
                                         segmentAtCursor: statement, fullText: buffer),
                .segment(statement), "a selection does not override the statement in this mode")
    // The fallback the app has always had: no segment parsed, run the buffer.
    expectEqual(RunScopeResolver.resolve(mode: .statementAtCursor, selectedText: nil,
                                         segmentAtCursor: nil, fullText: buffer),
                .direct(sql: buffer), "with no parsed statement the whole buffer runs")
}

private func testSelectionElseStatement() {
    expectEqual(RunScopeResolver.resolve(mode: .selectionElseStatement, selectedText: "SELECT 9",
                                         segmentAtCursor: statement, fullText: buffer),
                .direct(sql: "SELECT 9"), "a selection wins")
    expectEqual(RunScopeResolver.resolve(mode: .selectionElseStatement, selectedText: nil,
                                         segmentAtCursor: statement, fullText: buffer),
                .segment(statement), "with no selection the statement runs, as a segment")
    // The case that would otherwise run an empty query and look like a bug.
    expectEqual(RunScopeResolver.resolve(mode: .selectionElseStatement, selectedText: "   \n\t ",
                                         segmentAtCursor: statement, fullText: buffer),
                .segment(statement), "a whitespace-only selection falls back to the statement")
    expectEqual(RunScopeResolver.resolve(mode: .selectionElseStatement, selectedText: "",
                                         segmentAtCursor: statement, fullText: buffer),
                .segment(statement), "an empty selection falls back to the statement")
    expectEqual(RunScopeResolver.resolve(mode: .selectionElseStatement, selectedText: "  SELECT 9  ",
                                         segmentAtCursor: statement, fullText: buffer),
                .direct(sql: "SELECT 9"), "a selection is trimmed before it runs")
    expectEqual(RunScopeResolver.resolve(mode: .selectionElseStatement, selectedText: nil,
                                         segmentAtCursor: nil, fullText: buffer),
                .direct(sql: buffer), "no selection and no statement falls back to the buffer")
}

private func testWholeBuffer() {
    expectEqual(RunScopeResolver.resolve(mode: .wholeBuffer, selectedText: "SELECT 9",
                                         segmentAtCursor: statement, fullText: buffer),
                .direct(sql: buffer), "the whole buffer ignores both the selection and the statement")
    expectEqual(RunScopeResolver.resolve(mode: .wholeBuffer, selectedText: nil,
                                         segmentAtCursor: nil, fullText: "  \n  "),
                .nothing, "an empty buffer has nothing to run")
}

private func testNothingToRun() {
    for mode in RunScope.allCases {
        expectEqual(RunScopeResolver.resolve(mode: mode, selectedText: nil, segmentAtCursor: nil, fullText: ""),
                    .nothing, "\(mode.rawValue): an empty editor has nothing to run")
        expectEqual(RunScopeResolver.resolve(mode: mode, selectedText: "  ", segmentAtCursor: nil, fullText: "\n\n"),
                    .nothing, "\(mode.rawValue): whitespace everywhere has nothing to run")
    }
}

private func testLabels() {
    expectEqual(RunScope.allCases.count, 3, "three run scopes are offered")
    expectEqual(RunScope.statementAtCursor.rawValue, "statementAtCursor", "the stored value is camelCase")
    for mode in RunScope.allCases {
        expectEqual(mode.displayLabel.isEmpty, false, "\(mode.rawValue) has a label")
    }
}

func runTests() {
    testStatementAtCursor()
    testSelectionElseStatement()
    testWholeBuffer()
    testNothingToRun()
    testLabels()
    print(failures == 0 ? "\nALL PASSED" : "\n\(failures) FAILURE(S)")
    exit(failures == 0 ? 0 : 1)
}
