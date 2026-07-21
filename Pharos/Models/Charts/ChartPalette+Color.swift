import SwiftUI
import AppKit

extension ChartPalette {
    /// SwiftUI `Color` from a hex string (sRGB). Falls back to `.gray` for bad
    /// hex — callers normally pass validated hex from `resolveHex`.
    static func color(fromHex hex: String) -> Color {
        guard let c = rgb(fromHex: hex) else { return .gray }
        return Color(.sRGB, red: Double(c.r) / 255, green: Double(c.g) / 255, blue: Double(c.b) / 255, opacity: 1)
    }

    /// "#RRGGBB" for a SwiftUI `Color`, via its sRGB `NSColor` components.
    static func hex(from color: Color) -> String {
        let ns = NSColor(color).usingColorSpace(.sRGB) ?? NSColor(color)
        return hex(fromRGB: RGB(
            r: Int((ns.redComponent * 255).rounded()),
            g: Int((ns.greenComponent * 255).rounded()),
            b: Int((ns.blueComponent * 255).rounded())
        ))
    }

    /// Resolved SwiftUI colors sized to `count` (see `resolveHex`).
    static func resolveColors(override: [String], global: [String], count: Int) -> [Color] {
        resolveHex(override: override, global: global, count: count).map(color(fromHex:))
    }
}
