import Foundation

// MARK: - DisplayRowPipeline

/// Composes the grid's visible row list from its sorted row list.
///
/// This replaces a hand-wired cascade that lived in `ResultsGridVC` and was
/// duplicated in `ResultsGridVC+Delegates.swift`. Pulling it out serves two ends:
/// the stage ORDER becomes testable without AppKit, and there is exactly one
/// place that knows it.
///
/// The stages, in order:
///
///     unfilteredDisplayRows      (the sort order, every loaded row)
///       1. tag filter            (the # funnel)
///       2. column filters
///       3. find filter
///       4. force-show merge
///       → displayRows
///
/// Stages 1 and 4 are Phase 3 features and are nil in Phase 2. A nil stage is
/// skipped, not run with an identity closure, so the phase that does not have the
/// feature pays nothing for it.
enum DisplayRowPipeline {

    /// The stages, each optional. Every closure takes a row-index list and returns
    /// a subset of it, preserving order.
    struct Stages {
        /// The `#` funnel. Runs FIRST, so that the tag filter beats force-show:
        /// the toggle protects a tagged row from a data filter, not from the tag
        /// filter itself.
        var tagFilter: (([Int]) -> [Int])?
        /// The column filter engine.
        ///
        /// A caller that already holds a computed filter result must INTERSECT it with
        /// the stage input, never substitute it:
        ///
        ///     columnFilters: { _ in precomputed }            // WRONG once stage 1 exists
        ///     columnFilters: { gated in                      // right
        ///         let reused = Set(precomputed)
        ///         return gated.filter { reused.contains($0) }
        ///     }
        ///
        /// `precomputed` was derived from the UNGATED list, so returning it verbatim
        /// re-admits rows the tag filter removed. This matters in Phase 3 for
        /// `columnFilterControllerDidUpdate`, which already holds the stage-2 output
        /// and must not run the engine twice.
        var columnFilters: (([Int]) -> [Int])?
        /// The find filter.
        var findFilter: (([Int]) -> [Int])?
        /// Re-admits tagged rows that stages 2 or 3 dropped.
        ///
        /// Called with `(gated, kept)` where `gated` is the stage-1 output — NOT
        /// the raw unfiltered list. Handing it the raw list would let it re-admit
        /// a row the tag filter had excluded, which breaks the rule that the tag
        /// filter wins.
        ///
        /// The closure may return any set of row indices — it does not have to be a
        /// subset of `gated`, and it does not have to preserve `gated`'s order. `run`
        /// intersects the result with `gated` and keeps `gated`'s order itself, so the
        /// tag-filter-wins rule cannot be broken by a caller, only documented against.
        /// A closure that returns a wrong superset (for example one that reads
        /// `unfilteredDisplayRows` from its enclosing scope instead of using its
        /// `gated` argument) is trimmed back silently rather than failing loudly —
        /// intentional, because the trimmed result is the correct one.
        var forceShow: (([Int], [Int]) -> [Int])?

        init(tagFilter: (([Int]) -> [Int])? = nil,
             columnFilters: (([Int]) -> [Int])? = nil,
             findFilter: (([Int]) -> [Int])? = nil,
             forceShow: (([Int], [Int]) -> [Int])? = nil) {
            self.tagFilter = tagFilter
            self.columnFilters = columnFilters
            self.findFilter = findFilter
            self.forceShow = forceShow
        }
    }

    static func run(unfiltered: [Int], stages: Stages) -> [Int] {
        let gated = stages.tagFilter?(unfiltered) ?? unfiltered
        var kept = gated
        if let columnFilters = stages.columnFilters { kept = columnFilters(kept) }
        if let findFilter = stages.findFilter { kept = findFilter(kept) }
        if let forceShow = stages.forceShow {
            // Intersect rather than substitute. The closure says WHICH rows to
            // re-admit; the pipeline owns subset-ness and order. That makes the
            // tag-filter-wins rule impossible to break from a caller, instead of
            // merely documented — a Phase 3 closure written inside ResultsGridVC has
            // `unfilteredDisplayRows` in scope, and reading that instead of `gated`
            // would otherwise resurrect a row stage 1 removed, silently.
            let admitted = Set(forceShow(gated, kept))
            kept = gated.filter { admitted.contains($0) }
        }
        return kept
    }
}
