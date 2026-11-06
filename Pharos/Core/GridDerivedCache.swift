import Foundation

/// What a results grid computed for one result that is worth keeping across a
/// card switch: the sort order of every row and the tag map. Both cost a pass
/// over every cell (a sort is O(n log n) string or number work; a tag match
/// reads each cell), so computing them again each time the user comes back to
/// a card made the switch lag on a large result.
///
/// Kept in memory only, on the card's `ResultsGridState`, so it is freed with
/// the result. A value is reused only for the SAME rows (`contentToken`) and,
/// for the tag map, the same tag rules (`TagStore.generation`); anything else
/// computes again. Pure, so `scripts/test-grid-derived-cache.sh` can test the
/// rule with any map type.
struct GridDerivedCache<TagMap> {
    /// `QueryResult.contentToken` of the rows these values were computed from.
    let contentToken: UUID
    let sortColumn: String?
    let sortAscending: Bool
    /// Every data row in sorted order. Nil when the grid was not sorted.
    let sortedRows: [Int]?
    /// The complete tag map. Nil when no complete map was on hand (a match
    /// was still running in the background).
    let tagMap: TagMap?
    /// `TagStore.generation` the tag map was matched under.
    let tagGeneration: Int?

    /// The sorted rows for a sort by `column` of the rows `contentToken` names,
    /// or nil when they must be sorted again.
    func sortedRows(contentToken: UUID, column: String, ascending: Bool) -> [Int]? {
        guard contentToken == self.contentToken, column == sortColumn, ascending == sortAscending else { return nil }
        return sortedRows
    }

    /// The tag map for the rows `contentToken` names under the tag rules of
    /// `tagGeneration`, or nil when it must be matched again.
    func tagMap(contentToken: UUID, tagGeneration: Int) -> TagMap? {
        guard contentToken == self.contentToken, let generation = self.tagGeneration,
              generation == tagGeneration else { return nil }
        return tagMap
    }
}
