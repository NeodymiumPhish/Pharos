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
    case x, y, size                   // scatter
    case label, start, end, segment   // gantt
}

/// How a gantt draws the bars of one lane: all on the lane's line (they may
/// overlap), or a header line for the lane and one line per Bars by value
/// under it, so no bar hides another.
enum GanttLayout: String, Codable, CaseIterable {
    case oneLine, linePerValue
    var displayName: String {
        switch self {
        case .oneLine: return "One Line"
        case .linePerValue: return "Line per Value"
        }
    }
}

/// How a gantt lane's rows become bars. `runs` walks the lane in Start order
/// and opens a new bar each time the segment value changes, so a value that
/// comes back later gets a bar of its own; `span` draws one bar per segment
/// value, from its earliest Start to its latest End.
enum GanttMerge: String, Codable, CaseIterable {
    case runs, span
    var displayName: String { rawValue.capitalized }
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

/// How a categorical chart's points are ordered. `queryOrder` preserves the
/// order produced by aggregation (today's behavior); the others sort by the
/// X-axis label or the per-category Y total.
enum ChartSort: String, Codable, CaseIterable {
    case queryOrder     // as returned (default; preserves today's behavior)
    case categoryAsc    // by X-axis label, ascending
    case categoryDesc   // by X-axis label, descending
    case valueAsc       // by Y-axis total, ascending
    case valueDesc      // by Y-axis total, descending

    var displayName: String {
        switch self {
        case .queryOrder:  return "Query order"
        case .categoryAsc: return "Category \u{2191}"
        case .categoryDesc: return "Category \u{2193}"
        case .valueAsc:    return "Value \u{2191}"
        case .valueDesc:   return "Value \u{2193}"
        }
    }
}

/// How multi-series bars share a category slot.
enum BarLayout: String, Codable, CaseIterable {
    case stacked, grouped
    var displayName: String { rawValue.capitalized }
}

/// Non-mapping display options.
struct ChartDisplayOptions: Codable, Equatable {
    var title: String = ""
    var showLegend: Bool = true
    var barLayout: BarLayout = .stacked   // multi-series bars: stacked (the historical look) or side by side
    var logScale: Bool = false            // Y axis on a log scale; the canvas ignores it unless every plotted y > 0
    var xAxisTitle: String = ""           // empty = derived from the mapping (see ChartAxisTitles)
    var yAxisTitle: String = ""           // empty = derived from the mapping
    var topNCategories: Int = 25          // cardinality cap
    var sort: ChartSort = .queryOrder     // categorical point ordering
    /// Gantt horizontal zoom, relative to the automatic width per time unit:
    /// 1 = automatic, 2 = twice as wide, 0.5 = half. 0 = fit the whole range.
    var ganttZoom: Double = 1
    /// Gantt bars on the lane's line, or one line per Bars by value.
    var ganttLayout: GanttLayout = .oneLine

    init(title: String = "", showLegend: Bool = true, barLayout: BarLayout = .stacked,
         logScale: Bool = false, xAxisTitle: String = "", yAxisTitle: String = "",
         topNCategories: Int = 25, sort: ChartSort = .queryOrder, ganttZoom: Double = 1,
         ganttLayout: GanttLayout = .oneLine) {
        self.title = title
        self.showLegend = showLegend
        self.barLayout = barLayout
        self.logScale = logScale
        self.xAxisTitle = xAxisTitle
        self.yAxisTitle = yAxisTitle
        self.topNCategories = topNCategories
        self.sort = sort
        self.ganttZoom = ganttZoom
        self.ganttLayout = ganttLayout
    }

    // Tolerant decode: every field decodeIfPresent with a default, so a persisted
    // `display` blob written before a field existed still decodes (Swift's
    // synthesized decoder would otherwise throw keyNotFound on the missing key).
    // The retired `stacked` key is ignored on purpose: bars always stacked before
    // it was read, so `.stacked` — the default — keeps every saved chart's look.
    enum CodingKeys: String, CodingKey { case title, showLegend, barLayout, logScale, xAxisTitle, yAxisTitle, topNCategories, sort, ganttZoom, ganttLayout }
    init(from d: Decoder) throws {
        let c = try d.container(keyedBy: CodingKeys.self)
        title = try c.decodeIfPresent(String.self, forKey: .title) ?? ""
        showLegend = try c.decodeIfPresent(Bool.self, forKey: .showLegend) ?? true
        barLayout = try c.decodeIfPresent(BarLayout.self, forKey: .barLayout) ?? .stacked
        logScale = try c.decodeIfPresent(Bool.self, forKey: .logScale) ?? false
        xAxisTitle = try c.decodeIfPresent(String.self, forKey: .xAxisTitle) ?? ""
        yAxisTitle = try c.decodeIfPresent(String.self, forKey: .yAxisTitle) ?? ""
        topNCategories = try c.decodeIfPresent(Int.self, forKey: .topNCategories) ?? 25
        sort = try c.decodeIfPresent(ChartSort.self, forKey: .sort) ?? .queryOrder
        ganttZoom = try c.decodeIfPresent(Double.self, forKey: .ganttZoom) ?? 1
        ganttLayout = try c.decodeIfPresent(GanttLayout.self, forKey: .ganttLayout) ?? .oneLine
    }
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
