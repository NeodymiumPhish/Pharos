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
