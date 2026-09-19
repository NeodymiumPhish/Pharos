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

    /// How loudly a failure interrupts, and when the sheet opens by itself.
    /// Closures for the same reason as above: the presenter is tested without
    /// a settings store behind it.
    var failureAlertStyle: () -> FailureAlertStyle = { .sheet }
    var errorSheetTrigger: () -> ErrorSheetTrigger = { .secondFailure }

    /// Post a system notification for one failure. The owner fills this with
    /// its `QueryNotifier`.
    var postNotification: (QueryFailure) -> Void = { _ in }

    /// Put the sheet on screen. The owner fills this with `presentAsSheet`.
    var showSheet: (QueryErrorSheet) -> Void = { _ in }

    /// Take the sheet off screen. The owner fills this with `dismiss`.
    var closeSheet: (QueryErrorSheet) -> Void = { _ in }

    /// Put the inline banner on screen for one failure. The owner fills this
    /// with its `QueryErrorBanner`.
    var showBanner: (QueryFailure) -> Void = { _ in }

    /// Runs a block after the current turn of the run loop. Injected so a test
    /// stays deterministic — a test replaces it with one that runs the block at
    /// once. Production needs the wait: AppKit ends a sheet asynchronously.
    var afterCurrentTurn: (@escaping () -> Void) -> Void = { block in
        DispatchQueue.main.async(execute: block)
    }

    /// The sheet on screen, or nil when none is. The owner must call `close()`
    /// whenever the sheet leaves the screen by ANY path — Done, Escape, the
    /// window closing — not only through `open`'s own swap. Miss one and this
    /// keeps pointing at a sheet nobody can see: the next failure on that tab
    /// calls `update` on it instead of opening a new one, so the user gets no
    /// sheet and no other sign the failure happened.
    private(set) var liveSheet: QueryErrorSheet?

    /// A sheet waiting for the previous one to finish leaving. At most one of
    /// this and `liveSheet` is ever set. A later `open` supersedes it, so a burst
    /// of failures cannot stack two sheets on the window.
    private var pendingSheet: QueryErrorSheet?

    /// A failure has just arrived on the tab the user is looking at.
    ///
    /// `unreadBefore` is how many entries the tab's log already held unread
    /// BEFORE this one went in. It is the whole of the banner rule: the first
    /// failure the user has not read gets the inline banner, because a line is
    /// enough to say "this run failed" and the editor stays usable behind it. A
    /// second unread failure means the user now has a list to read rather than a
    /// message, so the sheet opens as it always did.
    func failureDidArrive(
        _ failure: QueryFailure,
        entries: [QueryFailure],
        unreadBefore: Int,
        delegate: QueryErrorSheetDelegate
    ) {
        if let sheet = liveSheet, sheet.tabId == failure.tabId {
            // The new entry went in at index 0, so the entry the user reads moved
            // down by one. Follow it. Pulling the view to the new entry would take
            // the text away mid-read.
            sheet.update(entries: entries, index: min(sheet.index + 1, max(entries.count - 1, 0)))
            return
        }

        // The whole of the rule now lives in one pure decision (Settings ▸
        // Query ▸ Errors). It used to be spread through this method, where it
        // could not be changed without touching the sheet bookkeeping above.
        // The defaults reproduce exactly what this method did before:
        // banner for the first unread error, sheet for the second, nothing
        // for a cancellation the user asked not to hear about.
        switch FailurePresentationRule.decide(
            style: failureAlertStyle(),
            trigger: errorSheetTrigger(),
            kind: failure.kind == .cancelled ? .cancelled : .error,
            unreadBefore: unreadBefore,
            showCancelledDialog: showCancelledDialog()
        ) {
        case .nothing:
            return
        case .banner:
            showBanner(failure)
        case .notification:
            postNotification(failure)
        case .sheet:
            open(entries: entries, index: 0, tabId: failure.tabId, delegate: delegate)
        }
    }

    /// Open the sheet from the toolbar button or from a banner click.
    func open(
        entries: [QueryFailure],
        index: Int,
        tabId: String,
        delegate: QueryErrorSheetDelegate
    ) {
        guard !entries.isEmpty else { return }
        let sheet = QueryErrorSheet(
            entries: entries, index: index, tabId: tabId, delegate: delegate
        )

        // One sheet at a time. A swap must let the old sheet finish leaving before
        // the new one arrives, or AppKit can drop the second presentation.
        if liveSheet != nil || pendingSheet != nil {
            close()
            pendingSheet = sheet
            afterCurrentTurn { [weak self] in
                guard let self, self.pendingSheet === sheet else { return }
                self.pendingSheet = nil
                self.liveSheet = sheet
                self.showSheet(sheet)
            }
            return
        }

        liveSheet = sheet
        showSheet(sheet)
    }

    /// Hand a changed entry list to the sheet on screen, if it belongs to `tabId`.
    func refresh(entries: [QueryFailure], index: Int, tabId: String) {
        guard let sheet = liveSheet, sheet.tabId == tabId else { return }
        sheet.update(entries: entries, index: index)
    }

    func close() {
        // A pending arrival must be cancelled here too, or a `Done` pressed during
        // the gap would be followed by a sheet appearing out of nowhere once the
        // deferred block runs.
        pendingSheet = nil
        guard let sheet = liveSheet else { return }
        liveSheet = nil
        closeSheet(sheet)
    }
}
