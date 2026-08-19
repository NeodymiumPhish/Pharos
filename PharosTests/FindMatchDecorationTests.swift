// Standalone test runner for FindMatchDecoration — the rule that gives a find
// match a border so it cannot be mistaken for a tag's matched-cell tint.
// Compiled with the implementation by scripts/test-find-decoration.sh.
import AppKit

var failures = 0

func expectEqual<T: Equatable>(_ actual: T, _ expected: T, _ name: String) {
    if actual == expected { print("PASS \(name)") } else {
        failures += 1
        print("FAIL \(name)\n  expected: \(expected)\n  actual:   \(actual)")
    }
}

func expectTrue(_ actual: Bool, _ name: String) {
    if actual { print("PASS \(name)") } else { failures += 1; print("FAIL \(name) — expected true") }
}

func expectNil<T>(_ actual: T?, _ name: String) {
    if actual == nil { print("PASS \(name)") } else {
        failures += 1
        print("FAIL \(name)\n  expected: nil\n  actual:   \(String(describing: actual))")
    }
}

/// sRGB components of a colour, for the border-contrast assertions. Both
/// inputs convert, so the fallback is only there to keep the helper total.
private func rgb(_ color: NSColor) -> (r: CGFloat, g: CGFloat, b: CGFloat) {
    guard let c = color.usingColorSpace(.sRGB) else { return (0, 0, 0) }
    return (c.redComponent, c.greenComponent, c.blueComponent)
}

/// Rough perceived lightness, enough to assert "darker than" / "lighter than".
private func luminance(_ color: NSColor) -> CGFloat {
    let c = rgb(color)
    return 0.2126 * c.r + 0.7152 * c.g + 0.0722 * c.b
}

func runTests() {

    // MARK: - 1. state(): the current match is never demoted by the match set

    expectEqual(FindMatchDecoration.state(isCurrent: false, isOther: false), .none,
                "no match at all is .none")
    expectEqual(FindMatchDecoration.state(isCurrent: false, isOther: true), .other,
                "a plain match is .other")
    expectEqual(FindMatchDecoration.state(isCurrent: true, isOther: false), .current,
                "the current match is .current")
    // The caller derives isOther from a set that may also hold the current
    // address. If that overlap won, the current match would draw the thin
    // border and the user would lose track of where they are in the results.
    expectEqual(FindMatchDecoration.state(isCurrent: true, isOther: true), .current,
                "current WINS when the match set also contains the current address")

    // MARK: - 2. Border width: every match is outlined, the current one heavier

    expectEqual(FindMatchDecoration.borderWidth(.none), 0,
                "a non-match draws NO border — this is what clears a recycled cell")
    expectTrue(FindMatchDecoration.borderWidth(.other) > 0,
               "every find match is outlined, not just the current one")
    expectTrue(FindMatchDecoration.borderWidth(.current) > FindMatchDecoration.borderWidth(.other),
               "the CURRENT match's border is thicker than the others'")

    // A CALayer border draws inside the cell's bounds on all four sides. The
    // grid's rows are 22pt and hold a centred 12pt monospaced label, so a
    // border past 2pt starts eating descenders. This is the layout guard.
    expectTrue(FindMatchDecoration.borderWidth(.current) <= 2,
               "the thickest border stays within the 22pt row's text clearance")

    // MARK: - 3. Fill alpha: find no longer competes with the tag paints

    expectNil(FindMatchDecoration.fillAlpha(.none),
              "a non-match has no find fill, so the caller falls through to selection/tint")

    guard let currentAlpha = FindMatchDecoration.fillAlpha(.current),
          let otherAlpha = FindMatchDecoration.fillAlpha(.other)
    else {
        print("FAIL a matched state returned no fill alpha")
        exit(1)
    }

    expectTrue(currentAlpha > otherAlpha,
               "the CURRENT match's fill is heavier than the others'")

    // The ordering the whole design rests on. The tag paints are the 0.15 row
    // wash (TaggedRowView.tintAlpha) and the 0.2 matched-cell tint
    // (TagPalette.cellTintAlpha); those two files are not compiled here, so
    // the numbers are named as literals on purpose — this suite pins find's
    // side of the relationship, and TagAppearanceTests pins the tag side
    // against these same constants.
    expectTrue(otherAlpha < 0.15,
               "a non-current find match is LIGHTER than the row wash — its border identifies it")
    expectTrue(currentAlpha > 0.2,
               "the CURRENT find match is HEAVIER than a matched-cell tag tint")

    // Both came down when the border arrived. If someone restores the old
    // washes, find goes back to being a shade of the same mark as a tag.
    expectTrue(currentAlpha < 0.4,
               "the current fill is below the pre-border 0.4 — the border carries the signal now")

    // MARK: - 4. Border colour reads against BOTH grounds

    let lightBorder = FindMatchDecoration.borderColor(isDark: false)
    let darkBorder = FindMatchDecoration.borderColor(isDark: true)

    expectTrue(luminance(lightBorder) < luminance(FindMatchDecoration.hue),
               "the light-appearance border is DARKER than bare system yellow, which a white grid would swallow")
    expectTrue(luminance(darkBorder) > luminance(lightBorder),
               "the dark-appearance border is lighter than the light-appearance one")
    expectTrue(luminance(lightBorder) < 0.6,
               "the light-appearance border is dark enough to read on a white grid")
    expectTrue(luminance(darkBorder) > 0.5,
               "the dark-appearance border is light enough to read on a dark grid")

    // Still recognisably the find hue rather than a new colour a tag might
    // own: red stays the dominant-to-green channel pair of yellow, and blue
    // stays the weakest of the three in both appearances.
    for (border, label) in [(lightBorder, "light"), (darkBorder, "dark")] {
        let c = rgb(border)
        expectTrue(c.b < c.r && c.b < c.g,
                   "the \(label)-appearance border is still in the yellow family")
    }

    if failures == 0 {
        print("\nAll FindMatchDecoration tests passed.")
    } else {
        print("\n\(failures) failure(s).")
        exit(1)
    }
}
