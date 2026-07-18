import Foundation

/// Provenance caption rendered as an export footer and embedded into PNG/PDF
/// metadata (see `ChartExporter`). Kept Foundation-only, separate from the
/// SwiftUI/ImageRenderer export machinery, so it compiles and runs in a
/// standalone `swiftc` test harness (`scripts/test-chart-export-caption.sh`).
enum ChartExportCaption {
    /// e.g. "Client · mydb · 42 of 100 rows · 2026-07-17T12:00:00Z" (+ " · truncated").
    static func text(mode: String, connection: String, plotted: Int, total: Int,
                      truncated: Bool, timestamp: String) -> String {
        var s = "\(mode) · \(connection) · \(plotted) of \(total) rows · \(timestamp)"
        if truncated { s += " · truncated" }
        return s
    }
}
