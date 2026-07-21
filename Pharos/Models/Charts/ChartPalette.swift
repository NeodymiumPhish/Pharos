import Foundation

/// Series color palette: the default palette, hex↔RGB conversion, and
/// resolution of the effective ordered colors for a chart. Foundation-only (no
/// SwiftUI) so it runs in the standalone `swiftc` test harness; the thin SwiftUI
/// `Color` bridge lives in `ChartPalette+Color.swift`.
enum ChartPalette {
    /// Default series palette: red-led, validated for light+dark contrast and
    /// deutan/protan distinguishability (confusable hues kept non-adjacent).
    /// Series 1 — the single-series bar case — is the Cymru-leaning red.
    static let defaultHex: [String] = [
        "#E12D48", // red (primary)
        "#3E7CC4", // blue
        "#C9820E", // amber
        "#2A9C81", // teal
        "#9B57C9", // purple
        "#E05525", // orange
    ]

    struct RGB: Equatable { let r: Int; let g: Int; let b: Int }   // components 0...255

    /// Parse "#RRGGBB" or "RRGGBB" → RGB; `nil` for malformed input.
    static func rgb(fromHex hex: String) -> RGB? {
        var s = hex.trimmingCharacters(in: .whitespaces)
        if s.hasPrefix("#") { s.removeFirst() }
        guard s.count == 6, s.allSatisfy({ $0.isHexDigit }), let v = UInt32(s, radix: 16) else { return nil }
        return RGB(r: Int((v >> 16) & 0xFF), g: Int((v >> 8) & 0xFF), b: Int(v & 0xFF))
    }

    /// Format RGB → "#RRGGBB" (uppercase, zero-padded).
    static func hex(fromRGB c: RGB) -> String {
        String(format: "#%02X%02X%02X", c.r, c.g, c.b)
    }

    /// The effective ordered hex colors for a chart with `count` series/slices:
    /// the per-chart `override` when non-empty, else `global`, else the built-in
    /// defaults; the chosen list cycles to fill `count`; any entry that isn't
    /// valid hex is replaced by the default color at that index.
    static func resolveHex(override: [String], global: [String], count: Int) -> [String] {
        guard count > 0 else { return [] }
        let chosen = !override.isEmpty ? override : (!global.isEmpty ? global : defaultHex)
        return (0..<count).map { i in
            let candidate = chosen[i % chosen.count]
            if rgb(fromHex: candidate) != nil { return candidate }
            return defaultHex[i % defaultHex.count]
        }
    }
}
