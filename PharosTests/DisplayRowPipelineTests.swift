// Standalone test runner for DisplayRowPipeline — the four-stage row composition.
// Compiled with the implementation by scripts/test-display-row-pipeline.sh.
import Foundation

var failures = 0

func expectRows(_ actual: [Int], _ expected: [Int], _ name: String) {
    if actual == expected { print("PASS \(name)") } else {
        failures += 1
        print("FAIL \(name)\n  expected: \(expected)\n  actual:   \(actual)")
    }
}

func runTests() {
    let all = [0, 1, 2, 3, 4]

    // MARK: Phase 2 shape — stages 1 and 4 inert

    // With no stage at all the input passes through unchanged. This is the state
    // of a fresh result before any filter.
    expectRows(DisplayRowPipeline.run(unfiltered: all, stages: .init()), all,
               "no stage changes the list")

    // Stage 2 alone: the column filters.
    expectRows(
        DisplayRowPipeline.run(unfiltered: all, stages: .init(
            columnFilters: { $0.filter { $0 % 2 == 0 } })),
        [0, 2, 4], "the column filters alone")

    // Stage 3 alone: find.
    expectRows(
        DisplayRowPipeline.run(unfiltered: all, stages: .init(
            findFilter: { $0.filter { $0 > 2 } })),
        [3, 4], "the find filter alone")

    // Stages 2 then 3, in that order. Find sits DOWNSTREAM of the column filters,
    // which is the behaviour the app has today
    // (ResultsGridVC+Delegates.swift:8 feeds find from columnFilteredDisplayRows).
    expectRows(
        DisplayRowPipeline.run(unfiltered: all, stages: .init(
            columnFilters: { $0.filter { $0 % 2 == 0 } },
            findFilter: { $0.filter { $0 > 1 } })),
        [2, 4], "find runs after the column filters, not before")

    // Order matters and must be provable: swapping the two stages would give the
    // same answer for the case above, so use a pair that discriminates.
    expectRows(
        DisplayRowPipeline.run(unfiltered: all, stages: .init(
            columnFilters: { Array($0.prefix(3)) },
            findFilter: { Array($0.suffix(1)) })),
        [2], "prefix-then-suffix proves the stage order")

    // The sort order of the input is preserved through every stage.
    expectRows(
        DisplayRowPipeline.run(unfiltered: [4, 3, 2, 1, 0], stages: .init(
            columnFilters: { $0.filter { $0 % 2 == 0 } })),
        [4, 2, 0], "the incoming sort order holds")

    // MARK: Phase 3 shape — the stages Phase 2 leaves nil

    // Stage 1, the tag funnel, runs FIRST — before the data filters.
    expectRows(
        DisplayRowPipeline.run(unfiltered: all, stages: .init(
            tagFilter: { $0.filter { $0 < 3 } },
            columnFilters: { $0.filter { $0 % 2 == 0 } })),
        [0, 2], "the tag filter runs before the column filters")

    // Stage 4, force-show, re-admits a row that stage 2 or 3 dropped, and keeps
    // the sort order of the unfiltered list rather than appending.
    expectRows(
        DisplayRowPipeline.run(unfiltered: all, stages: .init(
            columnFilters: { $0.filter { $0 == 4 } },
            forceShow: { unfiltered, kept in
                let keptSet = Set(kept)
                return unfiltered.filter { keptSet.contains($0) || $0 == 1 }
            })),
        [1, 4], "force-show re-admits a dropped row in sort order")

    // The tag filter BEATS force-show: the toggle protects a tagged row from a
    // DATA filter, not from the tag filter. Stage 4 therefore receives the stage-1
    // OUTPUT, not the raw list — so a closure that re-admits everything it is given
    // still cannot resurrect a row the tag filter excluded.
    //
    // The closure USES its first argument, and that is what makes the check
    // discriminate: if `run` passed `unfiltered` to stage 4 instead of the gated
    // list, this would return row 1 and the rule would break.
    expectRows(
        DisplayRowPipeline.run(unfiltered: all, stages: .init(
            tagFilter: { $0.filter { $0 != 1 } },
            columnFilters: { $0.filter { $0 == 4 } },
            forceShow: { gated, _ in gated })),
        [0, 2, 3, 4], "stage 4 receives the stage-1 output, so the tag filter still wins")

    // MARK: Degenerate inputs

    expectRows(DisplayRowPipeline.run(unfiltered: [], stages: .init(
        columnFilters: { $0 })), [], "an empty input gives an empty result")
    expectRows(DisplayRowPipeline.run(unfiltered: all, stages: .init(
        columnFilters: { _ in [] })), [], "a stage may remove everything")

    if failures == 0 {
        print("\nAll DisplayRowPipeline tests passed.")
    } else {
        print("\n\(failures) failure(s).")
        exit(1)
    }
}
