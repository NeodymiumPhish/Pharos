import Foundation

/// Whether a card is in its tab's run queue.
enum CardActivity: Equatable {
    case idle
    /// Queued behind another card on the tab's connection.
    case waiting
    case running(startedAt: Date)
}

/// What a card's name row shows, from the card's state. Pure, so every state
/// is tested without a view.
///
/// Precedence: activity, then a failure, then removed results, then an edit,
/// then results, then draft. The lock is shown in every state.
struct CardPresentation: Equatable {
    enum State: Equatable {
        case draft, waiting, running, hasResults, edited, failed, resultsRemoved
        /// A psql meta-command or COPY data card: kept, never sent.
        case notRunnable
    }

    enum Tone: Equatable { case neutral, caution, error }

    struct Badge: Equatable {
        let text: String
        let tone: Tone
    }

    /// The large button in the name row.
    struct ResultsButton: Equatable {
        let title: String
        let detail: String?
        /// This card's results are the ones in the results area.
        let isShowing: Bool
        let isError: Bool
    }

    let state: State
    let title: String
    let titleIsPlaceholder: Bool
    /// "v2", only when the query has more than one version.
    let versionChip: String?
    let isLocked: Bool
    let badge: Badge?
    let resultsButton: ResultsButton?
    let canRun: Bool
    /// Run and Replace Results sits next to Run only while the card is edited:
    /// in any other state it does what Run does.
    let showsRunAndReplace: Bool
    let showsCancel: Bool
    let accessibilityLabel: String

    /// Characters a folded card's summary keeps; the name row shows what fits.
    static let sqlSummaryLimit = 200

    /// A folded card's SQL on one line: every run of whitespace, line breaks
    /// included, becomes one space, so a statement that starts with a lone
    /// `SELECT` line still shows its columns and tables.
    static func sqlSummary(_ sql: String) -> String {
        let words = sql.split(whereSeparator: { $0.isWhitespace })
        var summary = ""
        for word in words {
            if !summary.isEmpty { summary += " " }
            summary += word
            if summary.count > sqlSummaryLimit {
                return String(summary.prefix(sqlSummaryLimit)) + "…"
            }
        }
        return summary
    }

    static func make(card: QueryCard, position: Int, lineageCount: Int, isEdited: Bool,
                     activity: CardActivity, resultInMemory: Bool, isDisplayed: Bool) -> CardPresentation {
        let state: State
        if card.kind != .sql {
            state = .notRunnable
        } else {
            switch activity {
            case .waiting: state = .waiting
            case .running: state = .running
            case .idle:
                if card.lastFailureId != nil { state = .failed }
                else if card.lastRun != nil && (card.resultsRemoved || !resultInMemory) { state = .resultsRemoved }
                else if card.lastRun != nil && isEdited { state = .edited }
                else if card.lastRun != nil { state = .hasResults }
                else { state = .draft }
            }
        }

        let badge: Badge?
        switch state {
        case .draft: badge = Badge(text: String(localized: "Not run"), tone: .neutral)
        case .waiting: badge = Badge(text: String(localized: "Waiting"), tone: .neutral)
        case .edited: badge = Badge(text: String(localized: "Edited since run"), tone: .caution)
        case .resultsRemoved: badge = Badge(text: String(localized: "Results removed"), tone: .neutral)
        case .notRunnable:
            badge = Badge(text: card.kind == .copyData ? String(localized: "COPY data") : String(localized: "psql command"),
                          tone: .neutral)
        case .running, .hasResults, .failed: badge = nil
        }

        let button: ResultsButton?
        switch state {
        case .failed:
            button = ResultsButton(title: String(localized: "View Error"), detail: nil, isShowing: isDisplayed, isError: true)
        case .hasResults, .edited:
            button = ResultsButton(
                title: isDisplayed ? String(localized: "Showing Results") : String(localized: "View Results"),
                detail: card.lastRun.map { summaryText($0.summary) }, isShowing: isDisplayed, isError: false)
        case .running:
            // The earlier results stay reachable while the card runs again.
            button = (card.lastRun != nil && resultInMemory && !card.resultsRemoved)
                ? ResultsButton(title: isDisplayed ? String(localized: "Showing Results") : String(localized: "View Results"),
                                detail: card.lastRun.map { summaryText($0.summary) }, isShowing: isDisplayed, isError: false)
                : nil
        case .draft, .waiting, .resultsRemoved, .notRunnable:
            button = nil
        }

        let name = card.name
        let title = name ?? String(localized: "Untitled query")
        var label = [String(localized: "Card \(position)"), title]
        if lineageCount > 1 { label.append(String(localized: "version \(card.version)")) }
        if card.isLocked { label.append(String(localized: "locked")) }
        label.append(stateWords(state))

        return CardPresentation(
            state: state,
            title: title,
            titleIsPlaceholder: name == nil,
            versionChip: lineageCount > 1 ? "v\(card.version)" : nil,
            isLocked: card.isLocked,
            badge: badge,
            resultsButton: button,
            canRun: state != .running && state != .waiting && state != .notRunnable,
            showsRunAndReplace: state == .edited,
            showsCancel: state == .running || state == .waiting,
            accessibilityLabel: label.joined(separator: ", "))
    }

    /// "1,420 rows", "1,000+ rows", "1 row", "4,882 rows affected".
    static func summaryText(_ summary: CardRunRecord.Summary) -> String {
        switch summary {
        case let .rows(count, hasMore):
            let n = count.formatted(.number)
            if hasMore { return String(localized: "\(n)+ rows") }
            return count == 1 ? String(localized: "1 row") : String(localized: "\(n) rows")
        case let .affected(count):
            let n = count.formatted(.number)
            return count == 1 ? String(localized: "1 row affected") : String(localized: "\(n) rows affected")
        }
    }

    private static func stateWords(_ state: State) -> String {
        switch state {
        case .draft: return String(localized: "not run")
        case .waiting: return String(localized: "waiting")
        case .running: return String(localized: "running")
        case .hasResults: return String(localized: "has results")
        case .edited: return String(localized: "edited since run")
        case .failed: return String(localized: "failed")
        case .resultsRemoved: return String(localized: "results removed")
        case .notRunnable: return String(localized: "cannot run")
        }
    }
}
