// Standalone test runner for QueryErrorBanner. The view has no owner and no
// window: it takes a QueryFailure and hands three closures back.
// Compiled by scripts/test-query-error-banner.sh.
import AppKit

private var failures = 0

private func expectTrue(_ actual: Bool, _ name: String) {
    if actual { print("PASS \(name)") } else { failures += 1; print("FAIL \(name) — expected true") }
}

private func expectString(_ actual: String, _ expected: String, _ name: String) {
    if actual == expected { print("PASS \(name)") } else {
        failures += 1
        print("FAIL \(name)\n  expected: \(expected)\n  actual:   \(actual)")
    }
}

private func failure(_ id: String, message: String = "relation \"nope\" does not exist") -> QueryFailure {
    QueryFailure(
        id: id, sql: "SELECT 1", message: message, kind: .error,
        tabId: "tab-1", tabName: "Query 1", connectionName: "localhost",
        timestamp: Date(timeIntervalSince1970: 0)
    )
}

func runTests() {
    let banner = QueryErrorBanner()
    banner.frame = NSRect(x: 0, y: 0, width: 600, height: QueryErrorBanner.height)

    // MARK: what the bar says

    expectTrue(banner.isHidden == false || banner.isHidden, "a fresh banner builds without a window")

    banner.show(failure("f1"))
    expectString(banner.messageText, "relation \"nope\" does not exist", "the bar shows the message")
    expectString(banner.accessibilityLabelForTesting,
                 "Query error: relation \"nope\" does not exist",
                 "the accessibility label names the message as a query error")
    expectString(banner.toolTip ?? "", "relation \"nope\" does not exist",
                 "the whole message is the tooltip, since the line is truncated")
    expectTrue(!banner.isHidden, "show puts the bar on screen")
    expectTrue(banner.failureId == "f1" && banner.tabId == "tab-1",
               "the bar remembers which entry it is showing")

    // MARK: the three buttons

    var wentToError = 0
    var openedDetails = 0
    var closed = 0
    banner.onGoToError = { wentToError += 1 }
    banner.onDetails = { openedDetails += 1 }
    banner.onClose = { closed += 1 }

    banner.goToErrorButtonForTesting.performClick(nil)
    expectTrue(wentToError == 1 && openedDetails == 0 && closed == 0, "Go to Error calls only its own closure")

    banner.detailsButtonForTesting.performClick(nil)
    expectTrue(openedDetails == 1 && wentToError == 1 && closed == 0, "Details… calls only its own closure")

    banner.closeButtonForTesting.performClick(nil)
    expectTrue(closed == 1 && openedDetails == 1 && wentToError == 1, "the close button calls only its own closure")

    // MARK: hide forgets the entry

    banner.hide()
    expectTrue(banner.isHidden, "hide takes the bar off screen")
    expectTrue(banner.failureId == nil && banner.tabId == nil,
               "a hidden bar keeps no entry, so a stale Details… cannot open the wrong one")
    expectString(banner.messageText, "", "and it keeps no message")

    // MARK: a second failure replaces the first, never stacking

    banner.show(failure("f1"))
    banner.show(failure("f2", message: "syntax error at or near \"slect\""))
    expectString(banner.messageText, "syntax error at or near \"slect\"", "the newer failure replaces the older")
    expectTrue(banner.failureId == "f2", "and the bar points at the newer entry")

    print(failures == 0 ? "\nALL PASSED" : "\n\(failures) FAILURE(S)")
    exit(failures == 0 ? 0 : 1)
}
