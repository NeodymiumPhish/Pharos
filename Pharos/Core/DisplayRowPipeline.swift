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
        /// re-admits rows the tag filter removed. A caller once existed that reused a
        /// precomputed column-filter result this way (`columnFilterControllerDidUpdate`);
        /// it bypassed stages 1 and 4 and was removed along with its caller. If a reuse
        /// path is ever reintroduced, it must intersect with the stage input as shown
        /// above, never substitute for it.
        var columnFilters: (([Int]) -> [Int])?
        /// The find filter.
        var findFilter: (([Int]) -> [Int])?
        /// Re-admits tagged rows that stages 2 or 3 dropped.
        ///
        /// Called with `(gated, kept)` where `gated` is the stage-1 output, NOT the
        /// raw unfiltered list.
        ///
        /// It may return ANY set of row indices. The pipeline keeps only those also
        /// in `gated`, in `gated`'s order. That makes the tag-filter-wins rule hold
        /// STRUCTURALLY: the result is a subset of `gated` whatever the closure
        /// returns, so no caller can resurrect a row stage 1 removed.
        ///
        /// `gated` is therefore passed for MEANING, not for safety. A closure
        /// computes over its first argument and must see the list it may admit from.
        /// Given the raw list it would nominate rows that are then trimmed, and any
        /// shape-dependent logic — "the last two", "the first N" — would mean
        /// something different. A membership-style closure cannot tell the two apart;
        /// a shape-sensitive one can, and the test below pins that.
        ///
        /// A closure returning a wrong superset is trimmed silently rather than
        /// failing loudly. That is the right direction: the trimmed result is correct.
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

    /// The Phase 3 stage-4 closure: keep what the data stages kept, plus every
    /// tagged row. `run()` intersects the result with the stage-1 output, so
    /// the tag filter wins structurally — this closure does not need to know.
    static func forceShowAdmitting(taggedRows: Set<Int>) -> ([Int], [Int]) -> [Int] {
        { gated, kept in
            let keptSet = Set(kept)
            return gated.filter { keptSet.contains($0) || taggedRows.contains($0) }
        }
    }
}
