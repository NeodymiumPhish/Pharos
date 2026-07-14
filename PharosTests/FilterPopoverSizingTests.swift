// Standalone test runner for FilterPopoverSizing — no Xcode project involvement.
// Compiled with Pharos/ViewControllers/ResultsGrid/FilterPopoverSizing.swift
// by scripts/test-filter-popover-sizing.sh.
import CoreGraphics

var failures = 0

func expectEqual(_ actual: CGFloat, _ expected: CGFloat, _ name: String) {
    if abs(actual - expected) < 0.0001 { print("PASS \(name)") } else {
        failures += 1
        print("FAIL \(name)\n  expected: \(expected)\n  actual:   \(actual)")
    }
}

func runTests() {
    // maxWidth: 60% of reference, floored at minWidth (260)
    expectEqual(FilterPopoverSizing.maxWidth(referenceWidth: 1000), 600, "maxWidth 1000 → 600")
    expectEqual(FilterPopoverSizing.maxWidth(referenceWidth: 300), 260, "maxWidth 300 → floor 260")

    // clampWidth into [260, maxWidth]
    expectEqual(FilterPopoverSizing.clampWidth(500, referenceWidth: 1000), 500, "clampWidth mid → 500")
    expectEqual(FilterPopoverSizing.clampWidth(100, referenceWidth: 1000), 260, "clampWidth below → 260")
    expectEqual(FilterPopoverSizing.clampWidth(900, referenceWidth: 1000), 600, "clampWidth above → 600")

    // maxListHeight: 60% of reference, floored at minListHeight (120)
    expectEqual(FilterPopoverSizing.maxListHeight(referenceHeight: 1000), 600, "maxListHeight 1000 → 600")
    expectEqual(FilterPopoverSizing.maxListHeight(referenceHeight: 100), 120, "maxListHeight 100 → floor 120")

    // clampListHeight into [120, maxListHeight]
    expectEqual(FilterPopoverSizing.clampListHeight(300, referenceHeight: 1000), 300, "clampListHeight mid → 300")
    expectEqual(FilterPopoverSizing.clampListHeight(50, referenceHeight: 1000), 120, "clampListHeight below → 120")
    expectEqual(FilterPopoverSizing.clampListHeight(900, referenceHeight: 1000), 600, "clampListHeight above → 600")

    if failures == 0 { print("\nAll tests passed.") } else { print("\n\(failures) failure(s)."); exit(1) }
}
