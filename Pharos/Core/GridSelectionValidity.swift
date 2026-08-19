import Foundation

// MARK: - GridSelectionValidity

/// Whether the results grid's selection still means what it meant, once the
/// visible row list has been rebuilt.
///
/// The selection — row mode and cell mode alike — is held in DISPLAY
/// coordinates, while `displayRows` maps each display position to the data row
/// that occupies it. Re-sorting rewrites that map, so the same display index
/// addresses a different record and the selection becomes a lie: the highlight
/// points at one record while the Inspector shows another.
///
/// The rule is about IDENTITY, not about whether the list changed. Loading
/// more rows appends to the list and moves nothing, so a selection above the
/// join survives it; a sort moves everything, so nothing survives.
enum GridSelectionValidity {

    /// True when every selected DISPLAY index still addresses the same data
    /// row it did before the rebuild.
    ///
    /// An empty selection survives trivially — there is nothing to invalidate,
    /// and reporting otherwise would make every reload blank the Inspector.
    /// An index past the end of EITHER list does not survive: the row it named
    /// is no longer on screen at all. (`IndexSet` cannot hold a negative, so
    /// only the upper bounds are checked.)
    static func survivesRebuild(selected: IndexSet, before: [Int], after: [Int]) -> Bool {
        for index in selected {
            guard index < before.count, index < after.count,
                  before[index] == after[index]
            else { return false }
        }
        return true
    }
}
