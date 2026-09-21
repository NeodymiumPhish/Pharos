import AppKit

/// One searchable thing in the Settings window: a row, named by the pane and
/// section it sits in.
///
/// The pane is a `String`, not a `SettingsPaneID`: that type lives outside
/// `Furniture/`, and this file has to compile with nothing but this directory
/// so `scripts/test-settings-furniture.sh` can test the matching rules with no
/// window and no FFI. The string is `paneId.rawValue`, which is what
/// `SettingsFormBuilder` already uses.
struct SettingsSearchEntry: Equatable {
    let paneId: String
    let paneTitle: String
    let sectionTitle: String?
    /// nil for the entry that stands for the pane itself.
    let itemId: String?
    let itemTitle: String?
    let itemCaption: String?
}

/// Turns declared sections into searchable entries, and matches a query
/// against them. Pure: no view, no store, no app state.
enum SettingsSearchIndex {

    /// Every searchable entry in one pane — the pane itself, then one per row.
    static func entries(for sections: [SettingsSection],
                        paneId: String,
                        paneTitle: String) -> [SettingsSearchEntry] {
        var out = [SettingsSearchEntry(paneId: paneId, paneTitle: paneTitle,
                                       sectionTitle: nil, itemId: nil,
                                       itemTitle: nil, itemCaption: nil)]
        for section in sections {
            for item in section.items {
                // A placeholder is not a setting; it names nothing the user
                // could be looking for.
                if case .empty = item.kind { continue }
                out.append(SettingsSearchEntry(
                    paneId: paneId, paneTitle: paneTitle,
                    sectionTitle: section.title, itemId: item.id,
                    itemTitle: item.title, itemCaption: item.caption))
            }
        }
        return out
    }

    /// One pane that matched, and the best row in it to show for the query.
    struct Hit: Equatable {
        let paneId: String
        let paneTitle: String
        /// The row to reveal, or nil when only the pane's own name matched.
        let itemId: String?
        /// What to show under the pane's name in the sidebar.
        let subtitle: String?
    }

    /// Panes matching `query`, in the order their entries were given, each
    /// with its best row. An empty or whitespace-only query matches nothing,
    /// which the caller reads as "show everything".
    static func hits(in entries: [SettingsSearchEntry], query: String) -> [Hit] {
        let words = tokens(query)
        guard !words.isEmpty else { return [] }

        var best: [String: (rank: Int, hit: Hit)] = [:]
        var order: [String] = []

        for entry in entries {
            guard let rank = rank(entry, words) else { continue }
            if best[entry.paneId] == nil { order.append(entry.paneId) }
            // Lower rank wins. A row match beats the pane's own name, because
            // the row is the thing the user can be shown.
            if let current = best[entry.paneId], current.rank <= rank { continue }
            best[entry.paneId] = (rank, Hit(
                paneId: entry.paneId,
                paneTitle: entry.paneTitle,
                itemId: entry.itemId,
                subtitle: entry.itemTitle))
        }
        return order.compactMap { best[$0]?.hit }
    }

    // MARK: - Matching

    /// How good a match this entry is, or nil for none. Lower is better.
    ///
    /// EVERY word must be found somewhere in the entry, so "null grid" finds
    /// the row whose title says NULL and whose caption says grid — but the
    /// rank comes from the best field any single word hit, which is what puts
    /// a title match above a caption match.
    private static func rank(_ entry: SettingsSearchEntry, _ words: [String]) -> Int? {
        let fields: [(Int, String?)] = [
            (0, entry.itemTitle),
            (1, entry.paneTitle),
            (2, entry.sectionTitle),
            (3, entry.itemCaption),
        ]
        let folded = fields.map { ($0.0, $0.1.map(fold) ?? "") }
        var bestRank = Int.max
        for word in words {
            var hit: Int?
            for (rank, text) in folded where !text.isEmpty && text.contains(word) {
                hit = min(hit ?? rank, rank)
            }
            guard let hit else { return nil }
            bestRank = min(bestRank, hit)
        }
        return bestRank == .max ? nil : bestRank
    }

    /// Case- and diacritic-insensitive, so "connexions" typed with an accent
    /// and "CONNECTIONS" both find Connections.
    static func fold(_ text: String) -> String {
        text.folding(options: [.caseInsensitive, .diacriticInsensitive], locale: .current)
    }

    static func tokens(_ query: String) -> [String] {
        fold(query).split(whereSeparator: { $0.isWhitespace }).map(String.init)
    }
}
