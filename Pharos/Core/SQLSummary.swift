import Foundation

/// A SQL statement on one line, for a row or a folded card that has room for
/// a hint of the query, not the query.
enum SQLSummary {
    /// Characters a summary keeps; the label shows what fits.
    static let limit = 200

    /// Every run of whitespace, line breaks included, becomes one space, so a
    /// statement that starts with a lone `SELECT` line still shows its
    /// columns and tables. Longer than `limit`: cut, with an ellipsis.
    static func oneLine(_ sql: String) -> String {
        var summary = ""
        for word in sql.split(whereSeparator: { $0.isWhitespace }) {
            if !summary.isEmpty { summary += " " }
            summary += word
            if summary.count > limit {
                return String(summary.prefix(limit)) + "…"
            }
        }
        return summary
    }
}
