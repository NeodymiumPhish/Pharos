import Foundation

// MARK: - TagCopyScope

/// The "Tagged rows only" copy/export scope rule, shared by `gatherData()`
/// and `selectionSummary()` in `ResultsCopyExport` so the popover caption and
/// the produced output cannot disagree.
///
/// "Tagged" means: matches at least one tag, solid OR dashed — the funnel's
/// definition ("Untagged means no tag matched at any state"), not the removal
/// path's solid-only rule.
///
/// With the toggle on and NO tagged rows at all, every row passes: the tag
/// map blanks briefly during an async recompute, and a copy landing in that
/// window must not silently produce nothing. The menu item disables in that
/// state as well.
enum TagCopyScope {
    static func include(dataRow: Int, taggedOnly: Bool, taggedRows: Set<Int>) -> Bool {
        !taggedOnly || taggedRows.isEmpty || taggedRows.contains(dataRow)
    }
}
