import Foundation

enum EmptyReason: String, Codable {
    case noColumns    // no type-compatible columns for the chart type
    case allNull      // value column is entirely null
    case noData       // restored result whose rows were demoted; re-run to chart
}

/// One (x, y) style point. `xLabel` is the display/category string; `xValue`
/// is a numeric position when the axis is numeric/temporal (epoch seconds).
struct ChartPoint {
    var xLabel: String
    var xValue: Double?
    var y: Double
    var drill: DrillKey? = nil
}

/// A heatmap cell at the intersection of a discrete X and Y axis value.
struct HeatmapCell: Identifiable {
    var x: String
    var y: String
    var value: Double
    var drill: DrillKey?
    var id: String { x + "\u{1}" + y }   // stable per-cell id for Chart(_:) / ForEach
}

/// A gantt bar: a labelled lane spanning [start, end] as epoch seconds.
struct GanttBar {
    var label: String
    var start: Double
    var end: Double
}

/// A named series of points (multi-series when a `series` role is mapped).
struct ChartSeries {
    var name: String            // "" for single-series charts
    var points: [ChartPoint]
}

/// Renderer-agnostic, plot-ready output. Holds no AnyCodable, no ChartConfig.
struct ChartData {
    var series: [ChartSeries] = []
    var ganttBars: [GanttBar] = []
    var heatmapCells: [HeatmapCell] = []
    var plottedRowCount: Int = 0
    var totalLoadedRowCount: Int = 0
    var wasTruncated: Bool = false     // top-N cap applied
    var wasSampled: Bool = false       // scatter sampling applied
    var ganttAxisKind: RangeKind = .temporal   // gantt start/end axis: temporal (epoch) or numeric
    var otherBucketCount: Int = 0
    var emptyReason: EmptyReason? = nil

    static func empty(_ reason: EmptyReason) -> ChartData {
        var d = ChartData(); d.emptyReason = reason; return d
    }
}
