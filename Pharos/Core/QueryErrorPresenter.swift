import AppKit

/// Decides when a `QueryErrorSheet` opens, and keeps at most one on screen.
///
/// It puts nothing on screen itself: `showSheet` and `closeSheet` are injected by
/// the owner. That keeps the presenter free of window work, so its rules can be
/// tested without a window.
///
/// Not marked `@MainActor`: this project's standalone `swiftc` test binaries call
/// into it from the nonisolated top-level scope of `PharosTests/main.swift`, which
/// cannot satisfy a global-actor-isolated entry point. Every other AppKit-adjacent
/// type exercised by these tests (e.g. `QueryErrorSheet`) is unannotated for the
/// same reason; the owner is still expected to touch this only from the main
/// thread, same as those types.
final class QueryErrorPresenter {

    /// Whether a cancellation may open a sheet. Set by the owner from the
    /// `showCancelledQueryDialog` setting, as a closure so the presenter never
    /// reads global state.
    var showCancelledDialog: () -> Bool = { true }

    /// Put the sheet on screen. The owner fills this with `presentAsSheet`.
    var showSheet: (QueryErrorSheet) -> Void = { _ in }

    /// Take the sheet off screen. The owner fills this with `dismiss`.
    var closeSheet: (QueryErrorSheet) -> Void = { _ in }

    private(set) var liveSheet: QueryErrorSheet?

    /// A failure has just arrived on the tab the user is looking at.
    func failureDidArrive(
        _ failure: QueryFailure,
        entries: [QueryFailure],
        delegate: QueryErrorSheetDelegate
    ) {
        if let sheet = liveSheet, sheet.tabId == failure.tabId {
            // The new entry went in at index 0, so the entry the user reads moved
            // down by one. Follow it. Pulling the view to the new entry would take
            // the text away mid-read.
            sheet.update(entries: entries, index: min(sheet.index + 1, max(entries.count - 1, 0)))
            return
        }

        // The setting only holds back the automatic sheet for a cancellation. The
        // entry is in the log either way, so the tab button still shows it.
        if failure.kind == .cancelled, !showCancelledDialog() { return }

        open(entries: entries, index: 0, tabId: failure.tabId, delegate: delegate)
    }

    /// Open the sheet from the toolbar button or from a banner click.
    func open(
        entries: [QueryFailure],
        index: Int,
        tabId: String,
        delegate: QueryErrorSheetDelegate
    ) {
        guard !entries.isEmpty else { return }
        // One sheet at a time. The user cannot reach this state today, because a
        // sheet stops the window, but the rule keeps the presenter safe.
        if liveSheet != nil { close() }

        let sheet = QueryErrorSheet(
            entries: entries, index: index, tabId: tabId, delegate: delegate
        )
        liveSheet = sheet
        showSheet(sheet)
    }

    /// Hand a changed entry list to the sheet on screen, if it belongs to `tabId`.
    func refresh(entries: [QueryFailure], index: Int, tabId: String) {
        guard let sheet = liveSheet, sheet.tabId == tabId else { return }
        sheet.update(entries: entries, index: index)
    }

    func close() {
        guard let sheet = liveSheet else { return }
        liveSheet = nil
        closeSheet(sheet)
    }
}
