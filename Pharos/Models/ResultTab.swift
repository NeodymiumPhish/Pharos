import AppKit

/// Represents a single result produced by executing a SQL segment.
/// Distinct from QueryTab (which is an editor tab).
struct ResultTab: Identifiable {
    let id: String
    let segmentIndex: Int
    let sql: String
    let lineRange: ClosedRange<Int>  // 1-based, captured at execution time
    let color: NSColor
    let timestamp: Date

    var queryResult: QueryResult?
    var executeResult: ExecuteResult?
    var executionTimeMs: UInt64 = 0

    /// Whether the editor text has been modified since this result was produced.
    var isStale: Bool = false

    /// Short label for the tab, e.g. "L1-3: SELECT..."
    var label: String {
        let lineStr: String
        if lineRange.count == 1 {
            lineStr = "L\(lineRange.lowerBound)"
        } else {
            lineStr = "L\(lineRange.lowerBound)-\(lineRange.upperBound)"
        }
        let sqlPreview = sql.trimmingCharacters(in: .whitespacesAndNewlines)
            .components(separatedBy: .newlines).first ?? ""
        let truncated = sqlPreview.count > 30 ? String(sqlPreview.prefix(30)) + "…" : sqlPreview
        return "\(lineStr): \(truncated)"
    }

    // MARK: - Color Palette

    /// Cycling color palette for result tab indicators.
    static let palette: [NSColor] = [
        .systemBlue,
        .systemPurple,
        .systemTeal,
        .systemIndigo,
        .systemMint,
        .systemCyan,
        .systemBrown,
        .systemPink,
    ]

    private static var colorIndex = 0

    /// Returns the next color in the cycling palette.
    static func nextColor() -> NSColor {
        let color = palette[colorIndex % palette.count]
        colorIndex += 1
        return color
    }

    /// Reset the color cycle (e.g. when all result tabs are cleared).
    static func resetColorCycle() {
        colorIndex = 0
    }
}
