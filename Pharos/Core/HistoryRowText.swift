import Foundation

/// Text shown on the rows of the workspace-history list and its preview pane.
/// Pure formatting — no AppKit, no FFI — so `scripts/test-workspace-history-match.sh`
/// can assert it directly.
enum HistoryRowText {
    /// The leading clause of a workspace row's second line, before the relative
    /// date and the connection name.
    ///
    /// While the filter is active, the clause reports how many of the
    /// workspace's queries matched. A workspace with no matching query keeps
    /// the plain clause: it was listed because its name, its editor text, or
    /// its connection name matched, not because a query did.
    ///
    /// - Parameters:
    ///   - total: every query in the workspace.
    ///   - matches: the queries whose SQL matched the active filter.
    ///   - isFiltering: whether the sidebar filter holds any text.
    static func queryClause(total: Int, matches: Int, isFiltering: Bool) -> String {
        let noun = total == 1 ? "query" : "queries"
        guard isFiltering, matches > 0 else {
            return "\(total) \(noun)"
        }
        // The noun agrees with the total; the verb agrees with the match count.
        let verb = matches == 1 ? "matches" : "match"
        return "\(matches) of \(total) \(noun) \(verb)"
    }

    /// Hoisted because this runs once per row on every reload. Both call sites
    /// are on the main thread, and nothing mutates the formatter after this
    /// initialiser, so sharing one instance is safe.
    private static let rowCountFormatter: NumberFormatter = {
        let formatter = NumberFormatter()
        formatter.numberStyle = .decimal
        formatter.groupingSeparator = ","
        return formatter
    }()

    /// A row count with thousands grouping, for both history rows and preview
    /// rows.
    static func rowCountText(_ count: Int64) -> String {
        rowCountFormatter.string(from: NSNumber(value: count)) ?? "\(count)"
    }
}
