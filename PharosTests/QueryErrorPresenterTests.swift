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

/// One presenter with its three outlets replaced by counters. The sheet and the
/// banner are the two things the presenter decides between, so a test reads
/// both counts and never a window.
private final class Harness {
    let presenter = QueryErrorPresenter()
    private(set) var opened = 0
    private(set) var closed = 0
    /// The failures the presenter chose to put on the inline banner, in order.
    private(set) var banners: [QueryFailure] = []
    private var deferred: [() -> Void] = []

    init(showCancelled: Bool) {
        presenter.showCancelledDialog = { showCancelled }
        // Collected, not run at once: the gap between a close and the next present is
        // exactly where the swap bug lived, so a test must be able to stand inside it.
        presenter.afterCurrentTurn = { [weak self] in self?.deferred.append($0) }
        presenter.showSheet = { [weak self] sheet in
            self?.opened += 1
            // The real owner presents the sheet, which loads the view. Touch the view
            // here for the same reason: the sheet reports its first entry on load.
            _ = sheet.view
        }
        presenter.closeSheet = { [weak self] _ in self?.closed += 1 }
        presenter.showBanner = { [weak self] failure in self?.banners.append(failure) }
    }

    func drain() {
        let blocks = deferred
        deferred = []
        blocks.forEach { $0() }
    }

    var liveSheet: QueryErrorSheet? { presenter.liveSheet }
}

func runTests() {
    let delegate = NullDelegate()

    // MARK: the setting gates a cancellation only
    //
    // `unreadBefore: 1` throughout this section: these cases are about the
    // sheet, and the banner rule only takes the FIRST unread failure. The
    // banner cases have a section of their own further down.

    let off = Harness(showCancelled: false)
    off.presenter.failureDidArrive(failure("a", kind: .cancelled), entries: [failure("a", kind: .cancelled)], unreadBefore: 1, delegate: delegate)
    expectInt(off.opened, 0, "a cancellation opens no sheet when the setting is off")

    let on = Harness(showCancelled: true)
    on.presenter.failureDidArrive(failure("a", kind: .cancelled), entries: [failure("a", kind: .cancelled)], unreadBefore: 1, delegate: delegate)
    expectInt(on.opened, 1, "a cancellation opens a sheet when the setting is on")

    let err = Harness(showCancelled: false)
    err.presenter.failureDidArrive(failure("a"), entries: [failure("a")], unreadBefore: 1, delegate: delegate)
    expectInt(err.opened, 1, "an error always opens a sheet, whatever the setting says")

    // MARK: banner or sheet — the first unread failure gets the line

    let firstH = Harness(showCancelled: true)
    firstH.presenter.failureDidArrive(failure("a"), entries: [failure("a")], unreadBefore: 0, delegate: delegate)
    expectInt(firstH.opened, 0, "the first unread error opens no sheet")
    expectInt(firstH.banners.count, 1, "it goes on the banner instead")
    expectTrue(firstH.banners.first?.id == "a", "and the banner is given that failure")

    // The same presenter, a second failure arriving while the first is unread.
    // No sheet is live (the first one only made a banner), so this is the plain
    // "second unread" case, not the update-in-place case.
    firstH.presenter.failureDidArrive(failure("b"), entries: [failure("b"), failure("a")], unreadBefore: 1, delegate: delegate)
    expectInt(firstH.banners.count, 1, "a second unread failure does not replace the banner")
    expectInt(firstH.opened, 1, "it opens the sheet, as before")
    expectInt(firstH.liveSheet?.index ?? -1, 0, "the sheet opens on the newest entry")

    // A cancellation is never a banner, whichever way the setting is set.
    let cancelBanner = Harness(showCancelled: true)
    cancelBanner.presenter.failureDidArrive(failure("a", kind: .cancelled), entries: [failure("a", kind: .cancelled)], unreadBefore: 0, delegate: delegate)
    expectInt(cancelBanner.banners.count, 0, "a first cancellation is not a banner")
    expectInt(cancelBanner.opened, 1, "it opens the dialog the setting asked for")

    let cancelOff = Harness(showCancelled: false)
    cancelOff.presenter.failureDidArrive(failure("a", kind: .cancelled), entries: [failure("a", kind: .cancelled)], unreadBefore: 0, delegate: delegate)
    expectInt(cancelOff.banners.count, 0, "a suppressed cancellation is not a banner either")
    expectInt(cancelOff.opened, 0, "and still opens nothing")

    // A sheet already on screen for this tab wins over the banner rule: the
    // user is reading the log, so the new entry joins it.
    let liveH = Harness(showCancelled: true)
    liveH.presenter.open(entries: [failure("a")], index: 0, tabId: "tab-1", delegate: delegate)
    liveH.presenter.failureDidArrive(failure("b"), entries: [failure("b"), failure("a")], unreadBefore: 0, delegate: delegate)
    expectInt(liveH.banners.count, 0, "no banner appears behind an open sheet for the same tab")
    expectInt(liveH.opened, 1, "and no second sheet opens")
    expectInt(liveH.liveSheet?.entries.count ?? -1, 2, "the open sheet takes the new entry")

    // MARK: a second failure keeps the reader in place

    let keep = Harness(showCancelled: true)
    keep.presenter.failureDidArrive(failure("b"), entries: [failure("b"), failure("a")], unreadBefore: 1, delegate: delegate)
    expectInt(keep.opened, 1, "the first failure opens the sheet")
    expectInt(keep.liveSheet?.index ?? -1, 0, "the sheet starts on the newest entry")

    // A new failure goes in at index 0, so the entry on screen moves down one.
    keep.presenter.failureDidArrive(failure("c"), entries: [failure("c"), failure("b"), failure("a")], unreadBefore: 2, delegate: delegate)
    expectInt(keep.opened, 1, "a second failure opens no second sheet")
    expectInt(keep.liveSheet?.index ?? -1, 1, "the sheet stays on the entry the user reads")
    expectInt(keep.liveSheet?.entries.count ?? -1, 3, "the sheet takes the longer list")

    // MARK: explicit open, and close

    let openH = Harness(showCancelled: true)
    openH.presenter.open(entries: [failure("c"), failure("b")], index: 1, tabId: "tab-1", delegate: delegate)
    expectInt(openH.opened, 1, "open puts a sheet on screen")
    expectInt(openH.liveSheet?.index ?? -1, 1, "open starts at the index it was given")

    openH.presenter.close()
    expectInt(openH.closed, 1, "close takes the sheet off screen")
    expectTrue(openH.liveSheet == nil, "close forgets the sheet")

    // A failure on another tab replaces the sheet rather than stacking one.
    let swap = Harness(showCancelled: true)
    swap.presenter.open(entries: [failure("a")], index: 0, tabId: "tab-1", delegate: delegate)
    swap.presenter.failureDidArrive(failure("z", tabId: "tab-2"), entries: [failure("z", tabId: "tab-2")], unreadBefore: 1, delegate: delegate)
    expectInt(swap.closed, 1, "the sheet for the other tab is closed first")
    swap.drain()
    expectInt(swap.opened, 2, "then the new tab's sheet opens")

    // MARK: a suppressed cancellation still refreshes an open sheet

    let refresh = Harness(showCancelled: false)
    refresh.presenter.open(entries: [failure("a")], index: 0, tabId: "tab-1", delegate: delegate)
    refresh.presenter.failureDidArrive(
        failure("b", kind: .cancelled), entries: [failure("b", kind: .cancelled), failure("a")],
        unreadBefore: 1, delegate: delegate
    )
    expectInt(refresh.opened, 1, "the suppressed cancellation opens no second sheet")
    expectInt(refresh.liveSheet?.entries.count ?? -1, 2,
              "an open sheet still takes the new entry, so its counter is right")
    expectInt(refresh.liveSheet?.index ?? -1, 1, "and it stays on the entry the user reads")

    // MARK: a suppressed cancellation on another tab swaps nothing

    let other = Harness(showCancelled: false)
    other.presenter.open(entries: [failure("a")], index: 0, tabId: "tab-1", delegate: delegate)
    other.presenter.failureDidArrive(
        failure("z", kind: .cancelled, tabId: "tab-2"), entries: [failure("z", kind: .cancelled, tabId: "tab-2")],
        unreadBefore: 0, delegate: delegate
    )
    expectInt(other.closed, 0, "a suppressed cancellation on another tab closes nothing")
    expectInt(other.opened, 1, "and opens no second sheet")
    expectTrue(other.liveSheet?.tabId == "tab-1", "the live sheet is still tab-1's")

    // MARK: a third open during a pending swap supersedes the second, never stacking two

    let gap = Harness(showCancelled: true)
    gap.presenter.open(entries: [failure("a")], index: 0, tabId: "tab-1", delegate: delegate)
    gap.presenter.open(entries: [failure("b")], index: 0, tabId: "tab-2", delegate: delegate)   // defers, does not present yet
    let openedBeforeThird = gap.opened
    gap.presenter.open(entries: [failure("c")], index: 0, tabId: "tab-3", delegate: delegate)   // supersedes b's pending arrival
    gap.drain()
    expectInt(gap.opened - openedBeforeThird, 1, "only one further presentation happens, not two")
    expectTrue(gap.liveSheet?.tabId == "tab-3", "the live sheet is the third one, not the superseded second")
    // Only "a" was ever actually shown, so it is the only sheet closeSheet ever runs
    // for. "b" was superseded before AppKit ever saw it — dismissing it would be
    // dismissing a sheet that was never presented.
    expectInt(gap.closed, 1, "the superseded, never-shown sheet is not separately dismissed")

    // MARK: closing during the gap cancels the pending arrival

    let closeGap = Harness(showCancelled: true)
    closeGap.presenter.open(entries: [failure("a")], index: 0, tabId: "tab-1", delegate: delegate)
    closeGap.presenter.open(entries: [failure("b")], index: 0, tabId: "tab-2", delegate: delegate)   // defers
    let openedBeforeClose = closeGap.opened
    closeGap.presenter.close()
    closeGap.drain()
    expectInt(closeGap.opened - openedBeforeClose, 0, "no sheet appears after the user closed during the gap")
    expectTrue(closeGap.liveSheet == nil, "the live sheet is nil, not the one that was pending")

    // MARK: the invariant — after a drained swap, liveSheet is set and nothing is pending

    let inv = Harness(showCancelled: true)
    inv.presenter.open(entries: [failure("a")], index: 0, tabId: "tab-1", delegate: delegate)
    inv.presenter.open(entries: [failure("b")], index: 0, tabId: "tab-2", delegate: delegate)
    inv.drain()
    expectTrue(inv.liveSheet != nil, "liveSheet is set after the swap drains")
    // Nothing was left pending by the drain above, so draining again — with no new
    // deferred blocks queued — must present nothing further.
    let openedAfterFirstDrain = inv.opened
    inv.drain()
    expectInt(inv.opened - openedAfterFirstDrain, 0, "a second drain with nothing queued presents nothing: no sheet was left pending")

    print(failures == 0 ? "\nALL PASSED" : "\n\(failures) FAILURE(S)")
    exit(failures == 0 ? 0 : 1)
}
