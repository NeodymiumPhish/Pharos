import Foundation

/// The decisions of a Session save and restore, apart from the views and the
/// database. Foundation only, so a standalone harness tests them
/// (scripts/test-session-snapshot.sh).
///
/// A stored result is keyed by its card's `lastRun.runId`, not the card id:
/// `CardDocument.forRestore()` gives the cards fresh ids, and the run id is
/// what stays. It is also exact where a card id is not: a card that has run
/// again since the save has a new run id, so an old result never lands on it.
enum SessionSnapshot {

    /// A card whose result is in memory at save time.
    struct Held: Equatable {
        let cardId: String
        let timestamp: Date
    }

    /// A result in memory that the save writes.
    struct SaveItem: Equatable {
        let cardId: String
        let runId: String
        /// 0 keeps its rows first when the Session is over its budget.
        let priority: Int
    }

    struct SavePlan: Equatable {
        var stage: [SaveItem] = []
        /// Results a previous save stored that are no longer in memory (the
        /// result limit let them go). Their stored rows stay.
        var keep: [KeepSavedQueryResult] = []
    }

    /// What a save writes. The displayed result keeps its rows first, then
    /// the newest; results only on disk come last, in card order.
    static func plan(document: CardDocument, held: [Held], storedRunIds: Set<String>) -> SavePlan {
        let heldByCard = Dictionary(held.map { ($0.cardId, $0) }, uniquingKeysWith: { a, _ in a })
        var inMemory: [(card: QueryCard, held: Held, order: Int)] = []
        var onDisk: [String] = []
        var seen = Set<String>()
        for (order, card) in document.cards.enumerated() {
            guard let runId = card.lastRun?.runId, seen.insert(runId).inserted else { continue }
            if let h = heldByCard[card.id] {
                inMemory.append((card, h, order))
            } else if storedRunIds.contains(runId) {
                onDisk.append(runId)
            }
        }
        inMemory.sort { a, b in
            let aShown = a.card.id == document.displayedCardId, bShown = b.card.id == document.displayedCardId
            if aShown != bShown { return aShown }
            if a.held.timestamp != b.held.timestamp { return a.held.timestamp > b.held.timestamp }
            return a.order < b.order
        }
        var plan = SavePlan()
        for (i, item) in inMemory.enumerated() {
            plan.stage.append(SaveItem(cardId: item.card.id, runId: item.card.lastRun!.runId, priority: i))
        }
        for (i, runId) in onDisk.enumerated() {
            plan.keep.append(KeepSavedQueryResult(runId: runId, priority: inMemory.count + i))
        }
        return plan
    }

    struct RestoreMatch: Equatable {
        /// Card id → the stored result that goes back on it.
        var results: [String: SavedQueryResultMeta] = [:]
        /// Cards with a run and no stored rows: they show "Results removed".
        var removed: Set<String> = []
    }

    /// Which stored result goes back on which card.
    static func match(document: CardDocument, metas: [SavedQueryResultMeta]) -> RestoreMatch {
        let byRun = Dictionary(metas.map { ($0.runId, $0) }, uniquingKeysWith: { a, _ in a })
        var match = RestoreMatch()
        for card in document.cards {
            guard let runId = card.lastRun?.runId else { continue }
            if let meta = byRun[runId], meta.kind == .affected || meta.hasRows {
                match.results[card.id] = meta
            } else {
                match.removed.insert(card.id)
            }
        }
        return match
    }

    /// "3 results · 12.4 MB", for the navigator and the inspector. Nil when
    /// the Session holds no results.
    static func caption(resultCount: Int?, bytes: Int64?) -> String? {
        guard let count = resultCount, count > 0 else { return nil }
        let results = count == 1 ? String(localized: "1 result") : String(localized: "\(count) results")
        guard let bytes, bytes > 0 else { return results }
        return results + " · " + ByteCountFormatter.string(fromByteCount: bytes, countStyle: .file)
    }
}
