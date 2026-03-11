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

    var customLabel: String?
    var queryResult: QueryResult?
    var executeResult: ExecuteResult?
    var executionTimeMs: UInt64 = 0

    /// Captured grid state (column widths, scroll position, sort, filters, selection).
    var gridState: ResultsGridState?

    /// Whether the editor text has been modified since this result was produced.
    var isStale: Bool = false

    /// Short label for the tab, e.g. "L1-3: users" or a custom name for browse actions.
    var label: String {
        if let custom = customLabel { return custom }
        let lineStr: String
        if lineRange.count == 1 {
            lineStr = "L\(lineRange.lowerBound)"
        } else {
            lineStr = "L\(lineRange.lowerBound)-\(lineRange.upperBound)"
        }
        if let table = Self.extractTableName(from: sql) {
            return "\(lineStr): \(table)"
        }
        let sqlPreview = sql.trimmingCharacters(in: .whitespacesAndNewlines)
            .components(separatedBy: .newlines).first ?? ""
        let truncated = sqlPreview.count > 30 ? String(sqlPreview.prefix(30)) + "…" : sqlPreview
        return "\(lineStr): \(truncated)"
    }

    /// Extract the primary table name from a SQL statement.
    /// Handles SELECT/DELETE FROM, INSERT INTO, UPDATE, with optional schema prefix and quoted identifiers.
    private static func extractTableName(from sql: String) -> String? {
        let pattern = #"(?i)(?:FROM|INTO|UPDATE)\s+(?:(?:"[^"]+"|[\w]+)\s*\.\s*)?(?:"([^"]+)"|(\w+))"#
        guard let regex = try? NSRegularExpression(pattern: pattern),
              let match = regex.firstMatch(in: sql, range: NSRange(sql.startIndex..., in: sql)) else {
            return nil
        }
        // Group 1: quoted table name, Group 2: unquoted table name
        if let range1 = Range(match.range(at: 1), in: sql), !sql[range1].isEmpty {
            return String(sql[range1])
        }
        if let range2 = Range(match.range(at: 2), in: sql), !sql[range2].isEmpty {
            return String(sql[range2])
        }
        return nil
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
