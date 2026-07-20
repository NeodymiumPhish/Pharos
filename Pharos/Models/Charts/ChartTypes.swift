import Foundation

/// The seven chart types.
enum ChartType: String, Codable, CaseIterable {
    case bar, line, area, scatter, pie, gantt, heatmap

    var displayName: String {
        switch self {
        case .bar: return "Bar"
        case .line: return "Line"
        case .area: return "Area"
        case .scatter: return "Scatter"
        case .pie: return "Pie"
        case .gantt: return "Gantt"
        case .heatmap: return "Heatmap"
        }
    }
}

/// The vocabulary of column roles across all chart types.
enum ChartColumnRole: String, Codable, CaseIterable {
    case category, value, series      // bar/line/area/pie
    case x, y, size, color            // scatter (color also reusable)
    case label, start, end            // gantt
}

/// A stable reference to a result column. Index is authoritative (duplicate
/// column names are legal in SQL); name is kept for display + validation.
struct ColumnRef: Codable, Equatable {
    var index: Int
    var name: String
}

enum AggregationFn: String, Codable, CaseIterable {
    case sum, avg, count, min, max
    var displayName: String { rawValue.capitalized }
}

/// Temporal bucketing for time-series category/x axes.
enum TemporalBin: String, Codable, CaseIterable {
    case none, auto, hour, day, week, month, year
}

/// Numeric-axis binning. `.off` = discrete categories; `.auto` = data-driven
/// count (subject to a low-cardinality escape); fixed counts otherwise.
/// (Uses `.off`, not `.none` like TemporalBin — see the phase-2 spec's naming note.)
enum NumericBin: String, Codable, CaseIterable {
    case off, auto, b10 = "10", b20 = "20", b50 = "50"
    var displayName: String {
        switch self { case .off: return "Off"; case .auto: return "Auto"; default: return rawValue }
    }
}

/// Independent per-axis bin granularity (heatmap X/Y). Absent ⇒ the chart's
/// global `temporalBin`/`numericBin` apply (see `ChartConfig.resolvedBin`).
struct AxisBin: Codable, Equatable {
    var temporal: TemporalBin = .auto
    var numeric: NumericBin = .auto
    init(temporal: TemporalBin = .auto, numeric: NumericBin = .auto) {
        self.temporal = temporal; self.numeric = numeric
    }
}

/// Result of classifying a column's data type.
enum ColumnKind: String, Codable {
    case numeric, temporal, categorical
}

/// Whether a result tab shows the grid or a chart.
enum ResultViewMode: String, Codable {
    case grid, chart
}

/// Non-mapping display options.
struct ChartDisplayOptions: Codable, Equatable {
    var title: String = ""
    var showLegend: Bool = true
    var stacked: Bool = false          // grouped vs stacked for series
    var topNCategories: Int = 25       // cardinality cap
}

/// Provenance of the last server-side (push-down) aggregation run for a chart.
struct LastServerRun: Codable, Equatable {
    var sql: String
    var executedAt: String
    var rowCount: Int
    var truncated: Bool
    var sampled: Bool = false
    init(sql: String, executedAt: String, rowCount: Int, truncated: Bool, sampled: Bool = false) {
        self.sql = sql; self.executedAt = executedAt; self.rowCount = rowCount; self.truncated = truncated; self.sampled = sampled
    }
    enum CodingKeys: String, CodingKey { case sql, executedAt, rowCount, truncated, sampled }
    init(from d: Decoder) throws {
        let c = try d.container(keyedBy: CodingKeys.self)
        sql = try c.decodeIfPresent(String.self, forKey: .sql) ?? ""
        executedAt = try c.decodeIfPresent(String.self, forKey: .executedAt) ?? ""
        rowCount = try c.decodeIfPresent(Int.self, forKey: .rowCount) ?? 0
        truncated = try c.decodeIfPresent(Bool.self, forKey: .truncated) ?? false
        sampled = try c.decodeIfPresent(Bool.self, forKey: .sampled) ?? false
    }
}
