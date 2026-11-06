import Foundation

// MARK: - Match results

enum TagMatchState: String, Equatable {
    /// Some tuple of this tag is entirely present in the row.
    case solid
    /// At least one captured value is present, but no single tuple is complete.
    case dashed
}

/// One tag's verdict on one row.
struct TagRowMatch: Equatable {
    let tagId: String
    let state: TagMatchState
    /// Result column INDICES whose value matched, ascending. Phase 5 tints them.
    let matchedColumns: [Int]
    /// Every tuple that contributed a matched value, sorted. Phase 5's Inspector
    /// explains a partial match from these.
    let matchedRuleIds: [String]
    /// Tuples entirely present in this row, sorted. Empty when dashed. The
    /// "Remove From Tag" action deletes exactly these.
    let solidRuleIds: [String]
}
