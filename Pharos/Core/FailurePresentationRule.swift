import Foundation

/// What a failed query does on screen.
///
/// This closes the question the HIG work left open (item F5): the rule was
/// spread over `QueryErrorPresenter.failureDidArrive`, where it could not be
/// changed without touching sheet bookkeeping. It is one pure decision here,
/// and the presenter obeys it.
enum FailurePresentationRule {

    /// The kinds of failure the rule tells apart. `QueryFailure.Kind` maps
    /// onto it; the enum is repeated so this file needs no AppKit.
    enum FailureKind: Equatable {
        /// The server (or the client) refused the query.
        case error
        /// The user cancelled it.
        case cancelled
    }

    enum Presentation: Equatable {
        case sheet
        case banner
        case notification
        case nothing
    }

    /// - Parameters:
    ///   - style: the user's choice of how loud a failure is.
    ///   - trigger: when the sheet may open by itself.
    ///   - kind: error or cancellation.
    ///   - unreadBefore: how many unread failures the tab held BEFORE this one.
    ///   - showCancelledDialog: the "Show details when you cancel a query"
    ///     setting, which silences a cancellation on its own.
    static func decide(style: FailureAlertStyle,
                       trigger: ErrorSheetTrigger,
                       kind: FailureKind,
                       unreadBefore: Int,
                       showCancelledDialog: Bool) -> Presentation {
        // A cancellation the user asked not to hear about says nothing, at
        // any style: the entry is in the tab's log either way.
        if kind == .cancelled && !showCancelledDialog { return .nothing }

        switch style {
        case .silent:
            return .nothing
        case .notification:
            return .notification
        case .banner:
            // A cancellation is never a banner: the user asked for it, so a
            // line saying it happened is noise. The sheet, when the setting
            // wants one, is the acknowledgement.
            return kind == .cancelled ? .nothing : .banner
        case .sheet:
            break
        }

        // Style is `.sheet`: the trigger decides whether THIS failure is the
        // one that opens it.
        //
        // "The second failure" applies to an ERROR only. The rule it encodes
        // is "show the quiet thing first, the modal thing if it happens
        // again" — and a cancellation has no quiet thing, because a banner
        // for something the user just asked for is noise. So a cancellation
        // that is not silenced opens the sheet at once, which is what the app
        // has always done (pinned by `scripts/test-query-error-presenter.sh`,
        // "it opens the dialog the setting asked for").
        let sheetNow: Bool
        switch trigger {
        case .firstFailure: sheetNow = true
        case .secondFailure: sheetNow = kind == .cancelled || unreadBefore > 0
        case .never: sheetNow = false
        }
        if sheetNow { return .sheet }
        // Not yet the sheet. An error still gets the inline banner, which is
        // what makes "the second failure" readable: the first one is visible,
        // it is simply not modal.
        return kind == .error ? .banner : .nothing
    }
}
