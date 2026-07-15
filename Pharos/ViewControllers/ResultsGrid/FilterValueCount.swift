/// A per-value row tally for the column filter checklist. Pure (no AppKit) so it
/// is unit-testable via scripts/test-filter-value-counts.sh.
struct FilterValueCount {
    /// Rows with this value that pass the other columns' active filters.
    let filtered: Int
    /// Rows with this value ignoring all filters (the denominator).
    let total: Int

    /// "total" when nothing narrows the value (filtered == total),
    /// otherwise "filtered/total".
    var display: String {
        filtered == total ? "\(total)" : "\(filtered)/\(total)"
    }
}
