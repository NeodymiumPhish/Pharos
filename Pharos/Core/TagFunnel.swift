import Foundation

// MARK: - TagFunnel

/// The `#` column funnel's pass rule. Pure; the filter engine asks it.
///
/// The funnel is stored as an ordinary `.isAnyOf` `ColumnFilter` under the
/// reserved id `__rownum__` — that placement buys the filter count, the reset
/// button and `clearAll` with no extra state — but it is EVALUATED as stage 1
/// of the display pipeline, not stage 2, because force-show must never
/// resurrect a row the funnel hid.
enum TagFunnel {

    /// The `#` column's identifier, which no data column can hold.
    static let columnId = "__rownum__"

    /// "Untagged" in the funnel's value set. Reuses the blanks sentinel — the
    /// same "absence" idea, and no second special value to escape.
    static let untaggedValue = ColumnFilter.blanksSentinel

    static func isTagFilter(columnId id: String) -> Bool { id == columnId }

    /// Does a row pass? `tagIds` is every tag matching that row, solid or
    /// dashed; an empty list means untagged.
    ///
    /// ANY is the rule, not ALL: a row carrying two tags is shown when either
    /// one is checked, because the funnel answers "show me this case", and a
    /// row belonging to two cases belongs to both.
    static func passes(tagIds: [String], allowed: Set<String>) -> Bool {
        guard !tagIds.isEmpty else { return allowed.contains(untaggedValue) }
        return tagIds.contains { allowed.contains($0) }
    }
}
