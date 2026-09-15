import Foundation

/// The result tabs one editor tab holds, which of them is selected, and the
/// next `result_order` slot for a result it produces.
struct EditorTabResults {
    var tabs: [ResultTab] = []
    var activeId: String?
    /// Monotonic per editor tab; used as `result_order` when a produced result
    /// is associated with the tab's workspace. Reseeded to
    /// `MAX(result_order) + 1` when a workspace is reopened.
    var nextOrder: Int = 0
}

/// Every editor tab's results, keyed by editor tab id — the active editor
/// tab's included.
///
/// This replaces a live `resultTabs` array for the active tab plus three
/// dictionaries for the others. The live array was written back to its
/// dictionary only on a tab switch, so every reader had to ask "live or
/// stored?" first, and a background path that answered wrongly worked on a
/// stale copy. With one store there is nothing to flush and nothing to ask:
/// the controller's `resultTabs` is a computed view onto the entry of the tab
/// the grid is showing.
///
/// Writes for a retired editor tab are the callers' concern: the subscript
/// setter creates an entry, so a late result for a closed tab must be
/// checked against the window session's `tabs` before it is deposited, as it
/// always was. `prune(keeping:)` drops the entries of closed tabs.
struct ResultTabStore {
    private var entries: [String: EditorTabResults] = [:]

    subscript(editorTabId: String) -> EditorTabResults {
        get { entries[editorTabId] ?? EditorTabResults() }
        set { entries[editorTabId] = newValue }
    }

    /// Drop every editor tab that is not in `live`. Each stored `ResultTab`
    /// holds a whole `QueryResult`, so a closed tab's rows would otherwise
    /// stay in memory until the app quits.
    mutating func prune(keeping live: Set<String>) {
        entries = entries.filter { live.contains($0.key) }
    }

    /// One result tab by id, whichever editor tab it belongs to.
    func tab(withId id: String) -> ResultTab? {
        for entry in entries.values {
            if let tab = entry.tabs.first(where: { $0.id == id }) { return tab }
        }
        return nil
    }

    /// The editor tab a result tab belongs to.
    func editorTabId(forResultTab id: String) -> String? {
        entries.first(where: { $0.value.tabs.contains(where: { $0.id == id }) })?.key
    }

    /// Apply a change to a result tab wherever it lives, and hand back the
    /// changed tab. Nil when no editor tab holds it.
    @discardableResult
    mutating func mutateTab(id: String, _ body: (inout ResultTab) -> Void) -> ResultTab? {
        for (editorTabId, entry) in entries {
            guard let idx = entry.tabs.firstIndex(where: { $0.id == id }) else { continue }
            body(&entries[editorTabId]!.tabs[idx])
            return entries[editorTabId]!.tabs[idx]
        }
        return nil
    }
}
