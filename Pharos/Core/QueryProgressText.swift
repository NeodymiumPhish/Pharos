import Foundation

/// A running query's progress, as `pharos_query_progress` reports it.
struct QueryProgress: Decodable, Equatable {
    /// 0–100, or nil when the engine has no estimate yet.
    let percentage: Double?
    let rowsProcessed: UInt64
    let totalRows: UInt64
}

/// The card header's line while a query runs.
///
/// "Running · 12 s" with no estimate (PostgreSQL, or DuckDB before its first
/// estimate); "Running · 42% · 1.2M of 3.0M rows · 12 s" with one. Pure and
/// Foundation-only, so `scripts/test-query-progress-text.sh` pins it.
enum QueryProgressText {

    static func meta(progress: QueryProgress?, elapsed: TimeInterval) -> String {
        var parts = [String(localized: "Running")]
        if let percentage = clampedPercentage(progress) {
            parts.append(String(localized: "\(Int(percentage.rounded(.down)))%"))
            if let progress, progress.totalRows > 0 {
                parts.append(String(localized: "\(compactCount(progress.rowsProcessed)) of \(compactCount(progress.totalRows)) rows"))
            }
        }
        parts.append(elapsedText(elapsed))
        return parts.joined(separator: " · ")
    }

    /// The fraction (0–100) for a determinate indicator, or nil for a spinner.
    ///
    /// 0% with no row processed is no estimate either: DuckDB reports exactly
    /// that for the whole run of a source that tracks no progress (measured
    /// 2026-10-20: `range()`, which its own CLI shows only at 100%).
    static func clampedPercentage(_ progress: QueryProgress?) -> Double? {
        guard let progress, let p = progress.percentage, p.isFinite else { return nil }
        if p <= 0 && progress.rowsProcessed == 0 { return nil }
        return min(max(p, 0), 100)
    }

    /// 950, 1.2K, 34K, 3.4M, 1.1B.
    static func compactCount(_ n: UInt64) -> String {
        let units: [(Double, String)] = [(1e9, "B"), (1e6, "M"), (1e3, "K")]
        let value = Double(n)
        for (size, suffix) in units where value >= size {
            let scaled = value / size
            let text = scaled >= 100 ? String(Int(scaled.rounded(.down)))
                                     : String(format: "%.1f", (scaled * 10).rounded(.down) / 10)
                                         .replacingOccurrences(of: ".0", with: "")
            return text + suffix
        }
        return String(n)
    }

    /// "0 s", "12 s", "1 min 5 s", "1 h 2 min".
    static func elapsedText(_ seconds: TimeInterval) -> String {
        let s = max(0, Int(seconds.rounded(.down)))
        if s < 60 { return String(localized: "\(s) s") }
        if s < 3600 { return String(localized: "\(s / 60) min \(s % 60) s") }
        return String(localized: "\(s / 3600) h \((s % 3600) / 60) min")
    }
}
