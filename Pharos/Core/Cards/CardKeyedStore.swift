import Foundation

/// Results by card id, with the tab each belongs to and the order they
/// arrived in. A card holds at most one result: a new one replaces it.
///
/// Generic so the rules are tested with plain values; the window session
/// holds a `CardKeyedStore<CardResult>`.
struct CardKeyedStore<Value> {
    private struct Entry {
        var value: Value
        let tabId: String
        let order: Int
    }

    private var entries: [String: Entry] = [:]
    /// The order the next deposit gets. Increases for the life of the store.
    private(set) var nextOrder = 0

    func value(for cardId: String) -> Value? { entries[cardId]?.value }
    func tabId(of cardId: String) -> String? { entries[cardId]?.tabId }
    func order(of cardId: String) -> Int? { entries[cardId]?.order }

    /// Store `value` as the card's result. Returns its order: a replacement is
    /// a new result and counts as the newest.
    @discardableResult
    mutating func deposit(_ value: Value, cardId: String, tabId: String) -> Int {
        let order = nextOrder
        nextOrder += 1
        entries[cardId] = Entry(value: value, tabId: tabId, order: order)
        return order
    }

    /// Change a stored result in place. Does nothing for a card without one.
    mutating func update(cardId: String, _ body: (inout Value) -> Void) {
        guard var entry = entries[cardId] else { return }
        body(&entry.value)
        entries[cardId] = entry
    }

    @discardableResult
    mutating func remove(cardId: String) -> Value? { entries.removeValue(forKey: cardId)?.value }

    /// The tab's cards that hold a result, oldest result first.
    func cardIds(inTab tabId: String) -> [String] {
        entries.filter { $0.value.tabId == tabId }.sorted { $0.value.order < $1.value.order }.map(\.key)
    }

    /// Drop the results of tabs that are gone.
    mutating func prune(keepingTabs tabIds: Set<String>) {
        entries = entries.filter { tabIds.contains($0.value.tabId) }
    }
}

/// Which results to let go when a tab holds more than Settings ▸ Results
/// allows. The card stays; it shows "Results removed" and can run again.
enum CardResultEviction {
    struct Candidate: Equatable {
        let cardId: String
        /// The result's age: lower is older.
        let order: Int
        let hasBeenViewed: Bool
        let isDisplayed: Bool
        let isPinned: Bool
    }

    /// The cards whose results go, oldest first, until the tab is at `limit`
    /// (0 = no limit). Only results nobody has looked at go: a result the
    /// user has seen, or is looking at, or has pinned, is theirs. When only
    /// those are left, the tab goes over the limit.
    static func toEvict(_ held: [Candidate], limit: Int) -> [String] {
        guard limit > 0, held.count > limit else { return [] }
        let removable = held
            .filter { !$0.hasBeenViewed && !$0.isDisplayed && !$0.isPinned }
            .sorted { $0.order < $1.order }
        return removable.prefix(held.count - limit).map(\.cardId)
    }
}
