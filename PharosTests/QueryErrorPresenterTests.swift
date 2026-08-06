// Standalone test runner for QueryErrorPresenter. The presenter's showSheet and
// closeSheet closures are injected, so this runs with no window and no
// AppStateManager. Compiled by scripts/test-query-error-presenter.sh.
import AppKit

private var failures = 0

private func expectTrue(_ actual: Bool, _ name: String) {
    if actual { print("PASS \(name)") } else { failures += 1; print("FAIL \(name) — expected true") }
}

private func expectInt(_ actual: Int, _ expected: Int, _ name: String) {
    if actual == expected { print("PASS \(name)") } else {
        failures += 1
        print("FAIL \(name)\n  expected: \(expected)\n  actual:   \(actual)")
    }
}

private final class NullDelegate: QueryErrorSheetDelegate {
    func errorSheet(_ sheet: QueryErrorSheet, didShow failureId: String, tabId: String) {}
    func errorSheet(_ sheet: QueryErrorSheet, didRequestDismiss failureId: String, tabId: String) {}
    func errorSheetDidRequestDismissAll(_ sheet: QueryErrorSheet, tabId: String) {}
    func errorSheet(_ sheet: QueryErrorSheet, didRequestGoToError failure: QueryFailure) {}
    func errorSheetDidRequestClose(_ sheet: QueryErrorSheet) {}
}

private func failure(_ id: String, kind: QueryFailure.Kind = .error, tabId: String = "tab-1") -> QueryFailure {
    QueryFailure(
        id: id, sql: "SELECT 1", message: "boom", kind: kind,
        tabId: tabId, tabName: "Query 1", connectionName: "localhost",
        timestamp: Date(timeIntervalSince1970: 0)
    )
}

private func makePresenter(showCancelled: Bool) -> (QueryErrorPresenter, () -> Int, () -> Int) {
    var opened = 0
    var closed = 0
    let presenter = QueryErrorPresenter()
    presenter.showCancelledDialog = { showCancelled }
    presenter.showSheet = { sheet in
        opened += 1
        // The real owner presents the sheet, which loads the view. Touch the view
        // here for the same reason: the sheet reports its first entry on load.
        _ = sheet.view
    }
    presenter.closeSheet = { _ in closed += 1 }
    return (presenter, { opened }, { closed })
}

func runTests() {
    let delegate = NullDelegate()

    // MARK: the setting gates a cancellation only

    let (offP, offOpened, _) = makePresenter(showCancelled: false)
    offP.failureDidArrive(failure("a", kind: .cancelled), entries: [failure("a", kind: .cancelled)], delegate: delegate)
    expectInt(offOpened(), 0, "a cancellation opens no sheet when the setting is off")

    let (onP, onOpened, _) = makePresenter(showCancelled: true)
    onP.failureDidArrive(failure("a", kind: .cancelled), entries: [failure("a", kind: .cancelled)], delegate: delegate)
    expectInt(onOpened(), 1, "a cancellation opens a sheet when the setting is on")

    let (errP, errOpened, _) = makePresenter(showCancelled: false)
    errP.failureDidArrive(failure("a"), entries: [failure("a")], delegate: delegate)
    expectInt(errOpened(), 1, "an error always opens a sheet, whatever the setting says")

    // MARK: a second failure keeps the reader in place

    let (keepP, keepOpened, _) = makePresenter(showCancelled: true)
    keepP.failureDidArrive(failure("b"), entries: [failure("b"), failure("a")], delegate: delegate)
    expectInt(keepOpened(), 1, "the first failure opens the sheet")
    expectInt(keepP.liveSheet?.index ?? -1, 0, "the sheet starts on the newest entry")

    // A new failure goes in at index 0, so the entry on screen moves down one.
    keepP.failureDidArrive(failure("c"), entries: [failure("c"), failure("b"), failure("a")], delegate: delegate)
    expectInt(keepOpened(), 1, "a second failure opens no second sheet")
    expectInt(keepP.liveSheet?.index ?? -1, 1, "the sheet stays on the entry the user reads")
    expectInt(keepP.liveSheet?.entries.count ?? -1, 3, "the sheet takes the longer list")

    // MARK: explicit open, and close

    let (openP, openOpened, openClosed) = makePresenter(showCancelled: true)
    openP.open(entries: [failure("c"), failure("b")], index: 1, tabId: "tab-1", delegate: delegate)
    expectInt(openOpened(), 1, "open puts a sheet on screen")
    expectInt(openP.liveSheet?.index ?? -1, 1, "open starts at the index it was given")

    openP.close()
    expectInt(openClosed(), 1, "close takes the sheet off screen")
    expectTrue(openP.liveSheet == nil, "close forgets the sheet")

    // A failure on another tab replaces the sheet rather than stacking one.
    let (swapP, swapOpened, swapClosed) = makePresenter(showCancelled: true)
    swapP.open(entries: [failure("a")], index: 0, tabId: "tab-1", delegate: delegate)
    swapP.failureDidArrive(failure("z", tabId: "tab-2"), entries: [failure("z", tabId: "tab-2")], delegate: delegate)
    expectInt(swapClosed(), 1, "the sheet for the other tab is closed first")
    expectInt(swapOpened(), 2, "then the new tab's sheet opens")

    // MARK: a suppressed cancellation still refreshes an open sheet

    let (refreshP, refreshOpened, _) = makePresenter(showCancelled: false)
    refreshP.open(entries: [failure("a")], index: 0, tabId: "tab-1", delegate: delegate)
    refreshP.failureDidArrive(
        failure("b", kind: .cancelled), entries: [failure("b", kind: .cancelled), failure("a")], delegate: delegate
    )
    expectInt(refreshOpened(), 1, "the suppressed cancellation opens no second sheet")
    expectInt(refreshP.liveSheet?.entries.count ?? -1, 2,
              "an open sheet still takes the new entry, so its counter is right")
    expectInt(refreshP.liveSheet?.index ?? -1, 1, "and it stays on the entry the user reads")

    print(failures == 0 ? "\nALL PASSED" : "\n\(failures) FAILURE(S)")
    exit(failures == 0 ? 0 : 1)
}
