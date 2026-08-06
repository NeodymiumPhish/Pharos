// Standalone test runner for QueryErrorSheet. Uses real AppKit: the sheet's view
// is hosted in a headless, never-shown NSWindow so Auto Layout runs, and the
// buttons are driven with performClick so the real actions fire.
// Compiled with QueryErrorSheet.swift, QueryFailure.swift, SQLErrorLocation.swift,
// SQLSyntaxHighlighter.swift and SQLLexer.swift by scripts/test-query-error-sheet.sh.
import AppKit

private var failures = 0

private func expectTrue(_ actual: Bool, _ name: String) {
    if actual { print("PASS \(name)") } else { failures += 1; print("FAIL \(name) — expected true") }
}

private func expectString(_ actual: String, _ expected: String, _ name: String) {
    if actual == expected { print("PASS \(name)") } else {
        failures += 1
        print("FAIL \(name)\n  expected: \(expected.debugDescription)\n  actual:   \(actual.debugDescription)")
    }
}

// MARK: - Recording delegate

private final class SpyDelegate: QueryErrorSheetDelegate {
    var shown: [String] = []
    var dismissed: [String] = []
    var dismissedAll = 0
    var wentTo: [String] = []
    var closed = 0

    func errorSheet(_ sheet: QueryErrorSheet, didShow failureId: String, tabId: String) {
        shown.append(failureId)
    }
    func errorSheet(_ sheet: QueryErrorSheet, didRequestDismiss failureId: String, tabId: String) {
        dismissed.append(failureId)
    }
    func errorSheetDidRequestDismissAll(_ sheet: QueryErrorSheet, tabId: String) {
        dismissedAll += 1
    }
    func errorSheet(_ sheet: QueryErrorSheet, didRequestGoToError failure: QueryFailure) {
        wentTo.append(failure.id)
    }
    func errorSheetDidRequestClose(_ sheet: QueryErrorSheet) {
        closed += 1
    }
}

private func failure(
    _ id: String, message: String = "syntax error at or near \"WHERE\" at character 21",
    sql: String = "SELECT * FROM users\nWHERE"
) -> QueryFailure {
    QueryFailure(
        id: id, sql: sql, message: message, kind: .error,
        tabId: "tab-1", tabName: "Query 1", connectionName: "localhost",
        timestamp: Date(timeIntervalSince1970: 0)
    )
}

/// Hosting the view is what makes Auto Layout run; an unhosted view keeps
/// whatever frame its initializer gave it.
private func host(_ sheet: QueryErrorSheet) -> NSWindow {
    let window = NSWindow(
        contentRect: NSRect(x: 0, y: 0, width: 560, height: 480),
        styleMask: [.borderless], backing: .buffered, defer: false
    )
    window.contentView = sheet.view
    sheet.view.layoutSubtreeIfNeeded()
    return window
}

func runTests() {
    // MARK: one entry

    let spy = SpyDelegate()
    let sheet = QueryErrorSheet(entries: [failure("a")], index: 0, tabId: "tab-1")
    sheet.delegate = spy
    _ = host(sheet)

    expectString(spy.shown.joined(separator: ","), "a", "opening reports the shown entry once")
    expectTrue(sheet.counterLabel.isHidden, "the counter is hidden for a log of one")
    expectTrue(sheet.previousButton.isHidden && sheet.nextButton.isHidden,
               "the arrows are hidden for a log of one")
    expectString(sheet.titleLabel.stringValue, "Query Failed", "the title names the failure kind")
    expectTrue(sheet.subheaderLabel.stringValue.hasPrefix("Query 1 · localhost · "),
               "the sub-header holds the tab, the connection and the time")

    expectTrue(!sheet.errorTextView.isEditable, "the error text cannot be edited")
    expectTrue(sheet.errorTextView.isSelectable, "the error text can be selected, so it can be copied")
    expectString(sheet.errorTextView.string, failure("a").message, "the error text is the message")
    expectString(sheet.sqlTextView.string, failure("a").sql, "the SQL text is the query that ran")

    // The highlight must land on the token the message names: `WHERE` starts at
    // character 21, which is index 20, and is 5 characters long.
    var highlighted: NSRange? = nil
    sheet.sqlTextView.textStorage?.enumerateAttribute(
        .backgroundColor, in: NSRange(location: 0, length: (failure("a").sql as NSString).length)
    ) { value, range, _ in
        if value != nil { highlighted = range }
    }
    expectTrue(highlighted == NSRange(location: 20, length: 5),
               "the faulty token carries a background highlight")
    expectTrue(sheet.goToErrorButton.isEnabled, "Go to Error is enabled when a position exists")

    sheet.goToErrorButton.performClick(nil)
    expectString(spy.wentTo.joined(separator: ","), "a", "Go to Error reports the failure")

    sheet.doneButton.performClick(nil)
    expectString("\(spy.closed)", "1", "Done asks the owner to close the sheet")

    // MARK: no position

    let plain = QueryErrorSheet(
        entries: [failure("p", message: "relation \"users\" does not exist")], index: 0, tabId: "tab-1"
    )
    plain.delegate = SpyDelegate()
    _ = host(plain)
    expectTrue(!plain.goToErrorButton.isEnabled, "Go to Error is disabled with no position in the message")

    // MARK: three entries

    let spy3 = SpyDelegate()
    let many = QueryErrorSheet(
        entries: [failure("c"), failure("b"), failure("a")], index: 0, tabId: "tab-1"
    )
    many.delegate = spy3
    _ = host(many)

    expectTrue(!many.counterLabel.isHidden, "the counter shows for more than one entry")
    expectString(many.counterLabel.stringValue, "1 of 3", "the counter counts from 1")
    expectTrue(!many.previousButton.isEnabled, "Previous is disabled on the newest entry")

    many.nextButton.performClick(nil)
    expectString(many.counterLabel.stringValue, "2 of 3", "Next moves one entry down the log")
    expectString(spy3.shown.joined(separator: ","), "c,b", "each shown entry is reported once")
    expectTrue(many.previousButton.isEnabled, "Previous is enabled away from the newest entry")

    many.nextButton.performClick(nil)
    expectTrue(!many.nextButton.isEnabled, "Next is disabled on the oldest entry")

    many.previousButton.performClick(nil)
    expectString(many.counterLabel.stringValue, "2 of 3", "Previous moves one entry back up")

    // MARK: dismiss

    many.dismissButton.performClick(nil)
    expectString(spy3.dismissed.joined(separator: ","), "b", "Dismiss reports the entry on screen")
    // The owner answers by handing back the shorter list, following
    // QueryFailureLog.indexAfterRemoval(removedIndex: 1, remainingCount: 2) == 1.
    many.update(entries: [failure("c"), failure("a")], index: 1)
    expectString(many.counterLabel.stringValue, "2 of 2", "the sheet takes the shorter list")
    expectString(many.entries[many.index].id, "a", "the sheet shows the entry that took the index")

    many.dismissAllButton.performClick(nil)
    expectString("\(spy3.dismissedAll)", "1", "Dismiss All asks the owner to empty the log")

    print(failures == 0 ? "\nALL PASSED" : "\n\(failures) FAILURE(S)")
    exit(failures == 0 ? 0 : 1)
}
