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
    var plottedRowCount: Int = 0
    var totalLoadedRowCount: Int = 0
    var wasTruncated: Bool = false     // top-N cap applied
    var wasSampled: Bool = false       // scatter sampling applied
    var otherBucketCount: Int = 0
    var emptyReason: EmptyReason? = nil

    static func empty(_ reason: EmptyReason) -> ChartData {
        var d = ChartData(); d.emptyReason = reason; return d
    }
}
