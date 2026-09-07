import Foundation

/// Whether a statement's row order is guaranteed between two executions.
///
/// Load More re-runs the statement wrapped in `LIMIT/OFFSET`. PostgreSQL
/// promises a stable order between executions only when the OUTERMOST query
/// has an `ORDER BY`; without one, a later page can repeat rows the first
/// page already showed, or skip rows neither page shows. The grid uses this
/// to say so beside the row count, rather than presenting the pages as one
/// continuous result.
///
/// The check is lexical: an `ORDER BY` at parenthesis depth 0, outside
/// strings and comments. A subquery's `ORDER BY` (depth ≥ 1) does not order
/// the outer result and does not count. A `WITH … SELECT … ORDER BY` and a
/// `UNION … ORDER BY` both put the clause at depth 0, and both count.
enum SQLOrderStability {

    /// True when the statement ends with an outermost `ORDER BY`.
    static func hasTopLevelOrderBy(_ sql: String) -> Bool {
        let snapshot = SQLLexSnapshot.shared(for: sql)
        let chars = snapshot.chars
        let length = snapshot.length
        let stateMap = snapshot.stateMap
        var depth = 0
        var i = 0
        while i < length {
            guard stateMap[i].isNormal else { i += 1; continue }
            let ch = chars[i]
            if ch == SQLLexer.uc("(") { depth += 1; i += 1; continue }
            if ch == SQLLexer.uc(")") { depth = max(0, depth - 1); i += 1; continue }
            if depth == 0,
               SQLLexer.isWordStart(chars: chars, at: i),
               SQLLexer.matchesKeyword("ORDER", chars: chars, at: i, length: length) {
                let afterOrder = SQLLexer.skipWhitespace(chars: chars, from: i + 5, length: length)
                if afterOrder < length,
                   stateMap[afterOrder].isNormal,
                   SQLLexer.matchesKeyword("BY", chars: chars, at: afterOrder, length: length) {
                    return true
                }
            }
            i += 1
        }
        return false
    }
}
