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

private func makePresenter(showCancelled: Bool) -> (QueryErrorPresenter, () -> Int, () -> Int, () -> Void) {
    var opened = 0
    var closed = 0
    let presenter = QueryErrorPresenter()
    presenter.showCancelledDialog = { showCancelled }
    var deferred: [() -> Void] = []
    // Collected, not run at once: the gap between a close and the next present is
    // exactly where the swap bug lived, so a test must be able to stand inside it.
    presenter.afterCurrentTurn = { deferred.append($0) }
    let drain = { let blocks = deferred; deferred = []; blocks.forEach { $0() } }
    presenter.showSheet = { sheet in
        opened += 1
        // The real owner presents the sheet, which loads the view. Touch the view
        // here for the same reason: the sheet reports its first entry on load.
        _ = sheet.view
    }
    presenter.closeSheet = { _ in closed += 1 }
    return (presenter, { opened }, { closed }, drain)
}

func runTests() {
    let delegate = NullDelegate()

    // MARK: the setting gates a cancellation only

    let (offP, offOpened, _, _) = makePresenter(showCancelled: false)
    offP.failureDidArrive(failure("a", kind: .cancelled), entries: [failure("a", kind: .cancelled)], delegate: delegate)
    expectInt(offOpened(), 0, "a cancellation opens no sheet when the setting is off")

    let (onP, onOpened, _, _) = makePresenter(showCancelled: true)
    onP.failureDidArrive(failure("a", kind: .cancelled), entries: [failure("a", kind: .cancelled)], delegate: delegate)
    expectInt(onOpened(), 1, "a cancellation opens a sheet when the setting is on")

    let (errP, errOpened, _, _) = makePresenter(showCancelled: false)
    errP.failureDidArrive(failure("a"), entries: [failure("a")], delegate: delegate)
    expectInt(errOpened(), 1, "an error always opens a sheet, whatever the setting says")

    // MARK: a second failure keeps the reader in place

    let (keepP, keepOpened, _, _) = makePresenter(showCancelled: true)
    keepP.failureDidArrive(failure("b"), entries: [failure("b"), failure("a")], delegate: delegate)
    expectInt(keepOpened(), 1, "the first failure opens the sheet")
    expectInt(keepP.liveSheet?.index ?? -1, 0, "the sheet starts on the newest entry")

    // A new failure goes in at index 0, so the entry on screen moves down one.
    keepP.failureDidArrive(failure("c"), entries: [failure("c"), failure("b"), failure("a")], delegate: delegate)
    expectInt(keepOpened(), 1, "a second failure opens no second sheet")
    expectInt(keepP.liveSheet?.index ?? -1, 1, "the sheet stays on the entry the user reads")
    expectInt(keepP.liveSheet?.entries.count ?? -1, 3, "the sheet takes the longer list")

    // MARK: explicit open, and close

    let (openP, openOpened, openClosed, _) = makePresenter(showCancelled: true)
    openP.open(entries: [failure("c"), failure("b")], index: 1, tabId: "tab-1", delegate: delegate)
    expectInt(openOpened(), 1, "open puts a sheet on screen")
    expectInt(openP.liveSheet?.index ?? -1, 1, "open starts at the index it was given")

    openP.close()
    expectInt(openClosed(), 1, "close takes the sheet off screen")
    expectTrue(openP.liveSheet == nil, "close forgets the sheet")

    // A failure on another tab replaces the sheet rather than stacking one.
    let (swapP, swapOpened, swapClosed, swapDrain) = makePresenter(showCancelled: true)
    swapP.open(entries: [failure("a")], index: 0, tabId: "tab-1", delegate: delegate)
    swapP.failureDidArrive(failure("z", tabId: "tab-2"), entries: [failure("z", tabId: "tab-2")], delegate: delegate)
    expectInt(swapClosed(), 1, "the sheet for the other tab is closed first")
    swapDrain()
    expectInt(swapOpened(), 2, "then the new tab's sheet opens")

    // MARK: a suppressed cancellation still refreshes an open sheet

    let (refreshP, refreshOpened, _, _) = makePresenter(showCancelled: false)
    refreshP.open(entries: [failure("a")], index: 0, tabId: "tab-1", delegate: delegate)
    refreshP.failureDidArrive(
        failure("b", kind: .cancelled), entries: [failure("b", kind: .cancelled), failure("a")], delegate: delegate
    )
    expectInt(refreshOpened(), 1, "the suppressed cancellation opens no second sheet")
    expectInt(refreshP.liveSheet?.entries.count ?? -1, 2,
              "an open sheet still takes the new entry, so its counter is right")
    expectInt(refreshP.liveSheet?.index ?? -1, 1, "and it stays on the entry the user reads")

    // MARK: a suppressed cancellation on another tab swaps nothing

    let (otherP, otherOpened, otherClosed, _) = makePresenter(showCancelled: false)
    otherP.open(entries: [failure("a")], index: 0, tabId: "tab-1", delegate: delegate)
    otherP.failureDidArrive(
        failure("z", kind: .cancelled, tabId: "tab-2"), entries: [failure("z", kind: .cancelled, tabId: "tab-2")],
        delegate: delegate
    )
    expectInt(otherClosed(), 0, "a suppressed cancellation on another tab closes nothing")
    expectInt(otherOpened(), 1, "and opens no second sheet")
    expectTrue(otherP.liveSheet?.tabId == "tab-1", "the live sheet is still tab-1's")

    // MARK: a third open during a pending swap supersedes the second, never stacking two

    let (gapP, gapOpened, gapClosed, gapDrain) = makePresenter(showCancelled: true)
    gapP.open(entries: [failure("a")], index: 0, tabId: "tab-1", delegate: delegate)
    gapP.open(entries: [failure("b")], index: 0, tabId: "tab-2", delegate: delegate)   // defers, does not present yet
    let openedBeforeThird = gapOpened()
    gapP.open(entries: [failure("c")], index: 0, tabId: "tab-3", delegate: delegate)   // supersedes b's pending arrival
    gapDrain()
    expectInt(gapOpened() - openedBeforeThird, 1, "only one further presentation happens, not two")
    expectTrue(gapP.liveSheet?.tabId == "tab-3", "the live sheet is the third one, not the superseded second")
    // Only "a" was ever actually shown, so it is the only sheet closeSheet ever runs
    // for. "b" was superseded before AppKit ever saw it — dismissing it would be
    // dismissing a sheet that was never presented.
    expectInt(gapClosed(), 1, "the superseded, never-shown sheet is not separately dismissed")

    // MARK: closing during the gap cancels the pending arrival

    let (closeGapP, closeGapOpened, _, closeGapDrain) = makePresenter(showCancelled: true)
    closeGapP.open(entries: [failure("a")], index: 0, tabId: "tab-1", delegate: delegate)
    closeGapP.open(entries: [failure("b")], index: 0, tabId: "tab-2", delegate: delegate)   // defers
    let openedBeforeClose = closeGapOpened()
    closeGapP.close()
    closeGapDrain()
    expectInt(closeGapOpened() - openedBeforeClose, 0, "no sheet appears after the user closed during the gap")
    expectTrue(closeGapP.liveSheet == nil, "the live sheet is nil, not the one that was pending")

    // MARK: the invariant — after a drained swap, liveSheet is set and nothing is pending

    let (invP, invOpened, _, invDrain) = makePresenter(showCancelled: true)
    invP.open(entries: [failure("a")], index: 0, tabId: "tab-1", delegate: delegate)
    invP.open(entries: [failure("b")], index: 0, tabId: "tab-2", delegate: delegate)
    invDrain()
    expectTrue(invP.liveSheet != nil, "liveSheet is set after the swap drains")
    // Nothing was left pending by the drain above, so draining again — with no new
    // deferred blocks queued — must present nothing further.
    let openedAfterFirstDrain = invOpened()
    invDrain()
    expectInt(invOpened() - openedAfterFirstDrain, 0, "a second drain with nothing queued presents nothing: no sheet was left pending")

    print(failures == 0 ? "\nALL PASSED" : "\n\(failures) FAILURE(S)")
    exit(failures == 0 ? 0 : 1)
}
