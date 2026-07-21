// Standalone test for ChartPalette (pure/Foundation-only half). The SwiftUI
// Color bridge (ChartPalette+Color.swift) is build-gated and not tested here.
import Foundation

var failures = 0
func expect(_ c: Bool, _ n: String) { if c { print("PASS \(n)") } else { failures += 1; print("FAIL \(n)") } }

func runTests() {
    // Default palette is the agreed 6-color, red-led set.
    expect(ChartPalette.defaultHex.first == "#E12D48", "default palette leads with Cymru red")
    expect(ChartPalette.defaultHex.count == 6, "default palette has 6 colors")

    // hex -> RGB parsing, with and without leading '#'.
    expect(ChartPalette.rgb(fromHex: "#E12D48") == ChartPalette.RGB(r: 225, g: 45, b: 72), "parses #RRGGBB")
    expect(ChartPalette.rgb(fromHex: "3E7CC4") == ChartPalette.RGB(r: 62, g: 124, b: 196), "parses bare RRGGBB")

    // Malformed hex -> nil.
    expect(ChartPalette.rgb(fromHex: "#XYZ") == nil, "rejects non-hex")
    expect(ChartPalette.rgb(fromHex: "#1234") == nil, "rejects wrong length")
    expect(ChartPalette.rgb(fromHex: "") == nil, "rejects empty")

    // RGB -> hex round-trips (uppercase, zero-padded).
    expect(ChartPalette.hex(fromRGB: ChartPalette.RGB(r: 225, g: 45, b: 72)) == "#E12D48", "formats hex uppercase")
    expect(ChartPalette.hex(fromRGB: ChartPalette.RGB(r: 0, g: 5, b: 255)) == "#0005FF", "zero-pads components")

    // resolveHex: override wins over global.
    expect(
        ChartPalette.resolveHex(override: ["#000000"], global: ["#FFFFFF"], count: 1) == ["#000000"],
        "override wins over global"
    )
    // resolveHex: empty override falls back to global.
    expect(
        ChartPalette.resolveHex(override: [], global: ["#FFFFFF"], count: 1) == ["#FFFFFF"],
        "empty override uses global"
    )
    // resolveHex: empty override AND empty global falls back to defaults.
    expect(
        ChartPalette.resolveHex(override: [], global: [], count: 1) == ["#E12D48"],
        "empty override+global uses defaults"
    )
    // resolveHex: cycles when count exceeds palette length (series 7 == series 1).
    let cycled = ChartPalette.resolveHex(override: [], global: [], count: 7)
    expect(cycled.count == 7 && cycled[6] == cycled[0], "palette cycles past its length")
    // resolveHex: an invalid entry is replaced by the default at that index.
    expect(
        ChartPalette.resolveHex(override: ["#E12D48", "nothex"], global: [], count: 2) == ["#E12D48", ChartPalette.defaultHex[1]],
        "invalid entry falls back to default at that index"
    )
    // resolveHex: count 0 -> empty.
    expect(ChartPalette.resolveHex(override: [], global: [], count: 0) == [], "count 0 yields empty")

    if failures == 0 { print("\nAll tests passed.") } else { print("\n\(failures) failure(s)."); exit(1) }
}
