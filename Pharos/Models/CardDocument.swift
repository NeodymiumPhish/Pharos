import Foundation

// One editor tab's query cards, and the rules for what a run does to them.
//
// Foundation only, and no actor isolation, so the standalone test scripts can
// compile it beside anything that holds a `QueryTab`.

/// What a card holds. Only `.sql` cards run; the other two keep text from a
/// `.sql` file that Pharos cannot send (see `sql_lexer.rs` in pharos-core).
enum QueryCardKind: String, Codable, Equatable {
    case sql
    /// A psql meta-command line, such as `\set x 1`.
    case psqlMeta
    /// A `COPY … FROM STDIN` statement with its data lines.
    case copyData
}

/// The run that a card's results came from.
struct CardRunRecord: Equatable, Codable {
    /// What a run returned, in short: enough for the name row.
    enum Summary: Equatable, Codable {
        case rows(count: Int, hasMore: Bool)
        case affected(Int)
    }

    let runId: String
    /// The card's text when the run started, `{{var}}` tokens and all.
    let rawSQL: String
    /// What was sent: `rawSQL` with the variables substituted.
    let renderedSQL: String
    let finishedAt: Date
    let executionTimeMs: UInt64
    /// Load More and Load All grow a row count after the run (`rowsLoaded`).
    var summary: Summary
    /// The `query_history` row of this run, when it has one.
    var historyResultId: String?
}

/// One statement with a name, and the run its results came from.
struct QueryCard: Identifiable, Equatable, Codable {
    let id: String
    /// The id of version 1 of this query. Every version shares it.
    var lineageId: String
    /// 1-based. A run after an edit locks this card and makes version + 1.
    var version: Int
    /// nil shows as "Untitled query".
    var name: String?
    /// True when `name` came from the on-device model, not the user.
    var nameIsSuggested: Bool = false
    /// The text in the editor. For a locked card it is the SQL of `lastRun`
    /// and cannot change.
    var sql: String
    var isLocked: Bool = false
    var isCollapsed: Bool = false
    /// Index into the card palette; set at the first successful run.
    var colorIndex: Int?
    var lastRun: CardRunRecord?
    /// A failed run after `lastRun`. Its results, if any, are still `lastRun`'s.
    var lastFailureId: String?
    /// The results were let go (the result limit) or never restored. The card
    /// stays and can run again.
    var resultsRemoved: Bool = false
    var cursorPosition: Int = 0
    var kind: QueryCardKind = .sql
    // The three fields below are Optional on purpose: the synthesized decoder
    // requires every non-Optional key, so a default value would make each
    // document saved before notes fail to decode.
    /// Free text about the query. Every version of a query has the same
    /// notes (`CardDocument.setNotes`). nil or blank: no notes.
    var notes: String?
    /// The notes area is open beside the editor.
    var isNotesOpen: Bool?
    /// The part of the card's width the notes take, set by dragging the
    /// divider. nil: the default (`CardNotesView.defaultFraction`).
    var notesWidthFraction: Double?
    /// The card came from a `.sql` file with comments before its statement:
    /// the Notes button offers to move them into the notes.
    var offersCommentImport: Bool?

    /// True when the notes hold more than whitespace.
    var hasNotes: Bool {
        !(notes ?? "").trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    var showsNotes: Bool { isNotesOpen ?? false }

    init(id: String = UUID().uuidString, lineageId: String? = nil, version: Int = 1,
         name: String? = nil, sql: String = "", kind: QueryCardKind = .sql) {
        self.id = id
        self.lineageId = lineageId ?? id
        self.version = version
        self.name = name
        self.sql = sql
        self.kind = kind
    }
}

/// How a run was asked for.
enum CardRunMode: String, Codable, Equatable {
    /// Run: after an edit, the old card is locked and the edit becomes a new
    /// version below it.
    case run
    /// Run and Replace Results: the results are replaced, whatever the edit.
    case replace
}

/// What `beginRun` hands out and `completeRun` takes back: the card's state
/// when the run started, so typing during the run cannot change its meaning.
struct CardRunTicket: Equatable {
    let runId: String
    let cardId: String
    let mode: CardRunMode
    let rawSQL: String
    let renderedSQL: String
    /// The run splits the card when it succeeds.
    let splits: Bool
}

/// How a run ended.
enum CardRunOutcome: Equatable {
    case success(summary: CardRunRecord.Summary, finishedAt: Date, executionTimeMs: UInt64, historyResultId: String?)
    case failure(failureId: String)
    case cancelled
}

/// What `completeRun` did, for the views and the result store.
enum CardRunEffect: Equatable {
    /// The card's results were replaced; the new results belong to it.
    case replaced(cardId: String)
    /// The old card kept its id and its results and was locked; the new
    /// results belong to `newCardId`, the next version below it.
    case split(lockedCardId: String, newCardId: String)
    case failed(cardId: String)
    case cancelled(cardId: String)
    /// The card was deleted while it ran. Nothing changed.
    case dropped
}

struct CardDocument: Equatable, Codable {
    /// How many colours the card palette has. Colour indices cycle through it.
    static let paletteSize = 6

    var cards: [QueryCard]
    /// Where the user types, and what ⌘↩ runs.
    var focusedCardId: String?
    /// Whose results the results area shows.
    var displayedCardId: String?
    /// Queries whose older versions the user has opened. All others fold.
    var expandedLineages: Set<String> = []

    /// One blank draft, with focus.
    init() {
        let draft = QueryCard()
        cards = [draft]
        focusedCardId = draft.id
    }

    init(cards: [QueryCard]) {
        self.cards = cards.isEmpty ? [QueryCard()] : cards
        focusedCardId = self.cards.first?.id
    }

    // MARK: - Lookup

    func index(of cardId: String) -> Int? { cards.firstIndex { $0.id == cardId } }
    func card(_ cardId: String) -> QueryCard? { index(of: cardId).map { cards[$0] } }

    /// Whitespace-insensitive form of a statement, for the edit comparison.
    static func normalized(_ sql: String) -> String {
        sql.split(whereSeparator: { $0.isWhitespace }).joined(separator: " ")
    }

    /// True when the card has run and `renderedSQL` (its text with today's
    /// variable values) is not what ran. A draft is never edited.
    func isEdited(cardId: String, renderedSQL: String) -> Bool {
        guard let run = card(cardId)?.lastRun else { return false }
        return Self.normalized(renderedSQL) != Self.normalized(run.renderedSQL)
    }

    // MARK: - Editing

    /// Insert a card after `cardId` (at the end when nil or not found) and give
    /// it focus. Returns its id.
    @discardableResult
    mutating func insertCard(after cardId: String?, sql: String = "", name: String? = nil,
                             kind: QueryCardKind = .sql) -> String {
        let card = QueryCard(name: name, sql: sql, kind: kind)
        let at = cardId.flatMap { index(of: $0) }.map { $0 + 1 } ?? cards.count
        cards.insert(card, at: at)
        focusedCardId = card.id
        return card.id
    }

    /// Set a card's text. Refused (false) for a locked or missing card.
    @discardableResult
    mutating func updateSQL(cardId: String, _ sql: String) -> Bool {
        guard let i = index(of: cardId), !cards[i].isLocked else { return false }
        cards[i].sql = sql
        return true
    }

    /// Name every version of the card's query. A blank name clears it.
    @discardableResult
    mutating func rename(cardId: String, name: String?) -> Bool {
        guard let lineage = card(cardId)?.lineageId else { return false }
        let trimmed = name?.trimmingCharacters(in: .whitespacesAndNewlines)
        let final = (trimmed?.isEmpty ?? true) ? nil : trimmed
        for i in cards.indices where cards[i].lineageId == lineage {
            cards[i].name = final
            cards[i].nameIsSuggested = false
        }
        return true
    }

    /// Name the card's query with a suggested name, only if it has no name
    /// yet. Returns whether it was applied.
    @discardableResult
    mutating func applySuggestedName(_ name: String, to cardId: String) -> Bool {
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let lineage = card(cardId)?.lineageId, !trimmed.isEmpty,
              !cards.contains(where: { $0.lineageId == lineage && $0.name != nil }) else { return false }
        for i in cards.indices where cards[i].lineageId == lineage {
            cards[i].name = trimmed
            cards[i].nameIsSuggested = true
        }
        return true
    }

    /// Load More or Load All changed how many rows the result of `runId`
    /// holds. The name row and the results header read the count from the
    /// run record, so it takes the new count. A later run of the card owns
    /// the record by then and keeps its own count. Returns whether it changed.
    @discardableResult
    mutating func rowsLoaded(cardId: String, runId: String, count: Int, hasMore: Bool) -> Bool {
        guard let i = index(of: cardId), let run = cards[i].lastRun, run.runId == runId,
              case .rows = run.summary else { return false }
        let summary = CardRunRecord.Summary.rows(count: count, hasMore: hasMore)
        guard run.summary != summary else { return false }
        cards[i].lastRun?.summary = summary
        return true
    }

    mutating func setCollapsed(cardId: String, _ collapsed: Bool) {
        guard let i = index(of: cardId) else { return }
        cards[i].isCollapsed = collapsed
    }

    // MARK: - Notes

    /// Set the notes of every version of the card's query, locked versions
    /// too: notes describe the query, not one version's SQL. Empty text clears
    /// them. Notes with content end the comment-import offer. Returns whether
    /// anything changed.
    @discardableResult
    mutating func setNotes(cardId: String, _ notes: String?) -> Bool {
        guard let lineage = card(cardId)?.lineageId else { return false }
        let value = (notes ?? "").isEmpty ? nil : notes
        var changed = false
        for i in cards.indices where cards[i].lineageId == lineage {
            if cards[i].notes != value {
                cards[i].notes = value
                changed = true
            }
            if cards[i].hasNotes, cards[i].offersCommentImport != nil {
                cards[i].offersCommentImport = nil
                changed = true
            }
        }
        return changed
    }

    /// Open or close the card's notes area.
    mutating func setNotesOpen(cardId: String, _ open: Bool) {
        guard let i = index(of: cardId) else { return }
        cards[i].isNotesOpen = open ? true : nil
    }

    /// Set how wide the card's notes are, as a part of the card's width.
    /// nil goes back to the default.
    mutating func setNotesWidth(cardId: String, fraction: Double?) {
        guard let i = index(of: cardId) else { return }
        cards[i].notesWidthFraction = fraction
    }

    /// Stop offering to move the card's leading comments into its notes.
    mutating func dismissCommentImport(cardId: String) {
        guard let i = index(of: cardId) else { return }
        cards[i].offersCommentImport = nil
    }

    /// Move comments into the notes: `notes` become the query's notes, the
    /// card's text becomes `sql`, the notes area opens and the offer ends.
    /// Refused (false) for a locked or missing card.
    @discardableResult
    mutating func importCommentsToNotes(cardId: String, notes: String, sql: String) -> Bool {
        guard let i = index(of: cardId), !cards[i].isLocked else { return false }
        cards[i].sql = sql
        cards[i].isNotesOpen = true
        cards[i].offersCommentImport = nil
        setNotes(cardId: cardId, notes)
        return true
    }

    /// Remove a card. Returns it with its index, for undo. The document never
    /// goes empty: deleting the last card leaves one blank draft.
    @discardableResult
    mutating func deleteCard(cardId: String) -> (card: QueryCard, index: Int)? {
        guard let i = index(of: cardId) else { return nil }
        let removed = cards.remove(at: i)
        if cards.isEmpty { cards = [QueryCard()] }
        if focusedCardId == cardId { focusedCardId = cards[min(i, cards.count - 1)].id }
        if displayedCardId == cardId { displayedCardId = nil }
        return (removed, i)
    }

    /// Put back a card `deleteCard` removed (undo).
    mutating func restoreCard(_ card: QueryCard, at index: Int) {
        // The blank draft that stood in for an emptied document goes again.
        if cards.count == 1, cards[0].lastRun == nil, cards[0].sql.isEmpty, cards[0].id != card.id {
            cards.removeAll()
        }
        cards.insert(card, at: min(max(0, index), cards.count))
        focusedCardId = card.id
    }

    /// A new, unlocked, never-run copy of the card's text as the next version
    /// of its query, placed after the query's last version. Returns its id.
    @discardableResult
    mutating func editAsNewCard(from cardId: String) -> String? {
        guard let source = card(cardId) else { return nil }
        var copy = QueryCard(lineageId: source.lineageId, version: nextVersion(of: source.lineageId),
                             name: source.name, sql: source.sql, kind: source.kind)
        copy.nameIsSuggested = source.nameIsSuggested
        copy.notes = source.notes
        copy.isNotesOpen = source.isNotesOpen
        copy.notesWidthFraction = source.notesWidthFraction
        cards.insert(copy, at: indexAfterLineage(source.lineageId))
        focusedCardId = copy.id
        return copy.id
    }

    // MARK: - Runs

    /// Start a run of the card, or nil when it cannot run (missing, blank, or
    /// not SQL).
    func beginRun(cardId: String, mode: CardRunMode, renderedSQL: String) -> CardRunTicket? {
        guard let c = card(cardId), c.kind == .sql,
              !c.sql.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return nil }
        return CardRunTicket(
            runId: UUID().uuidString, cardId: cardId, mode: mode, rawSQL: c.sql, renderedSQL: renderedSQL,
            splits: mode == .run && isEdited(cardId: cardId, renderedSQL: renderedSQL))
    }

    /// Apply a finished run. The rule: the card id stays with the results it
    /// already has; an edit that ran goes on as a new card.
    mutating func completeRun(_ ticket: CardRunTicket, outcome: CardRunOutcome) -> CardRunEffect {
        guard let i = index(of: ticket.cardId) else { return .dropped }
        switch outcome {
        case .cancelled:
            return .cancelled(cardId: ticket.cardId)
        case let .failure(failureId):
            cards[i].lastFailureId = failureId
            return .failed(cardId: ticket.cardId)
        case let .success(summary, finishedAt, executionTimeMs, historyResultId):
            let record = CardRunRecord(
                runId: ticket.runId, rawSQL: ticket.rawSQL, renderedSQL: ticket.renderedSQL,
                finishedAt: finishedAt, executionTimeMs: executionTimeMs, summary: summary,
                historyResultId: historyResultId)
            guard ticket.splits, let previous = cards[i].lastRun else {
                cards[i].lastRun = record
                cards[i].lastFailureId = nil
                cards[i].resultsRemoved = false
                if cards[i].colorIndex == nil { cards[i].colorIndex = nextColorIndex() }
                return .replaced(cardId: ticket.cardId)
            }
            var next = QueryCard(lineageId: cards[i].lineageId, version: nextVersion(of: cards[i].lineageId),
                                 name: cards[i].name, sql: cards[i].sql, kind: cards[i].kind)
            next.nameIsSuggested = cards[i].nameIsSuggested
            next.notes = cards[i].notes
            next.isNotesOpen = cards[i].isNotesOpen
            next.notesWidthFraction = cards[i].notesWidthFraction
            next.lastRun = record
            next.cursorPosition = cards[i].cursorPosition
            next.colorIndex = nextColorIndex()
            // The old card goes back to the SQL its results came from, and is
            // locked so that stays true. The failure, if any, was the edit's.
            cards[i].sql = previous.rawSQL
            cards[i].isLocked = true
            cards[i].lastFailureId = nil
            cards.insert(next, at: indexAfterLineage(cards[i].lineageId))
            // Older versions fold above the new run, even when the user had
            // opened them: the new results are what they look at now.
            expandedLineages.remove(cards[i].lineageId)
            if focusedCardId == ticket.cardId { focusedCardId = next.id }
            return .split(lockedCardId: ticket.cardId, newCardId: next.id)
        }
    }

    // MARK: - Copies

    /// The same cards for another tab: fresh ids (results are filed by card
    /// id, across every tab of a window), no runs, no results, no failures.
    /// Names, versions, locks and SQL stay. A duplicated tab and a saved
    /// query opened twice use this.
    func forReuse() -> CardDocument {
        copied(keepingRuns: false)
    }

    /// The same cards for a restored Session: fresh ids, as `forReuse`, but
    /// each card keeps its run record and colour, so the results saved with
    /// the Session go back on it (a restore matches them by `lastRun.runId`,
    /// which stays). The run's history link does not come along: the Session
    /// has its own copy of the rows, and a rename or chart change must not
    /// write to a history row the Session does not own. Failures do not
    /// come along either; the failure log is the old tab's.
    func forRestore() -> CardDocument {
        copied(keepingRuns: true)
    }

    private func copied(keepingRuns: Bool) -> CardDocument {
        var lineageMap: [String: String] = [:]
        var idMap: [String: String] = [:]
        var copy = self
        copy.cards = cards.map { old in
            var c = QueryCard(id: UUID().uuidString, version: old.version, name: old.name, sql: old.sql, kind: old.kind)
            c.lineageId = lineageMap[old.lineageId] ?? c.id
            lineageMap[old.lineageId] = c.lineageId
            idMap[old.id] = c.id
            c.nameIsSuggested = old.nameIsSuggested
            c.isLocked = old.isLocked
            c.isCollapsed = old.isCollapsed
            c.cursorPosition = old.cursorPosition
            c.notes = old.notes
            c.isNotesOpen = old.isNotesOpen
            c.notesWidthFraction = old.notesWidthFraction
            c.offersCommentImport = old.offersCommentImport
            if keepingRuns {
                c.lastRun = old.lastRun
                c.lastRun?.historyResultId = nil
                c.colorIndex = old.colorIndex
            }
            return c
        }
        copy.focusedCardId = focusedCardId.flatMap { idMap[$0] } ?? copy.cards.first?.id
        copy.displayedCardId = keepingRuns ? displayedCardId.flatMap { idMap[$0] } : nil
        copy.expandedLineages = Set(expandedLineages.compactMap { lineageMap[$0] })
        return copy
    }

    // MARK: - Helpers

    private func nextVersion(of lineageId: String) -> Int {
        (cards.filter { $0.lineageId == lineageId }.map(\.version).max() ?? 0) + 1
    }

    /// The position just after the last card of the lineage.
    private func indexAfterLineage(_ lineageId: String) -> Int {
        (cards.lastIndex { $0.lineageId == lineageId } ?? (cards.count - 1)) + 1
    }

    /// The next colour in the tab's cycle: cards take them in the order they
    /// first succeed.
    private func nextColorIndex() -> Int {
        cards.filter { $0.colorIndex != nil }.count % Self.paletteSize
    }
}
