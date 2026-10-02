import Foundation

/// The results one editor tab holds, by card, and the next `result_order`
/// slot for a result it produces.
struct EditorTabResults {
    /// Oldest result first.
    var results: [CardResult] = []
    /// Monotonic per editor tab; used as `result_order` when a produced result
    /// is associated with the tab's workspace. Reseeded to
    /// `MAX(result_order) + 1` when a workspace is reopened.
    var nextOrder: Int = 0

    func result(forCard cardId: String) -> CardResult? { results.first { $0.id == cardId } }

    /// Put `result` on its card: it replaces the card's old result and counts
    /// as the newest.
    mutating func deposit(_ result: CardResult) {
        results.removeAll { $0.id == result.id }
        results.append(result)
    }
}

/// Every editor tab's card results, keyed by editor tab id.
///
/// Writes for a retired editor tab are the callers' concern: the subscript
/// setter creates an entry, so a late result for a closed tab must be checked
/// against the window session's `tabs` before it is deposited.
/// `prune(keeping:)` drops the entries of closed tabs.
struct CardResultStore {
    private var entries: [String: EditorTabResults] = [:]

    subscript(editorTabId: String) -> EditorTabResults {
        get { entries[editorTabId] ?? EditorTabResults() }
        set { entries[editorTabId] = newValue }
    }

    /// Drop every editor tab that is not in `live`. Each result holds a whole
    /// `QueryResult`, so a closed tab's rows would otherwise stay in memory
    /// until the app quits.
    mutating func prune(keeping live: Set<String>) {
        entries = entries.filter { live.contains($0.key) }
    }

    /// A card's result, whichever editor tab holds it.
    func result(forCard cardId: String) -> CardResult? {
        for entry in entries.values {
            if let r = entry.result(forCard: cardId) { return r }
        }
        return nil
    }

    /// The editor tab a card's result belongs to.
    func editorTabId(forCard cardId: String) -> String? {
        entries.first(where: { $0.value.result(forCard: cardId) != nil })?.key
    }

    /// Apply a change to a card's result wherever it lives, and hand back the
    /// changed result. Nil when no editor tab holds one for the card.
    @discardableResult
    mutating func mutateResult(cardId: String, _ body: (inout CardResult) -> Void) -> CardResult? {
        for (editorTabId, entry) in entries {
            guard let idx = entry.results.firstIndex(where: { $0.id == cardId }) else { continue }
            body(&entries[editorTabId]!.results[idx])
            return entries[editorTabId]!.results[idx]
        }
        return nil
    }

    /// Remove a card's result and hand it back.
    @discardableResult
    mutating func removeResult(cardId: String) -> CardResult? {
        for (editorTabId, entry) in entries {
            guard let idx = entry.results.firstIndex(where: { $0.id == cardId }) else { continue }
            return entries[editorTabId]!.results.remove(at: idx)
        }
        return nil
    }
}
