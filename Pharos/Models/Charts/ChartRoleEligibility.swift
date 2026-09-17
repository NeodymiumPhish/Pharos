import Foundation

/// Which roles a chart type has, and which column kinds each role takes.
///
/// One table, read by the rail's pickers, the recommender and the model-answer
/// validator, so the three can never disagree about what a legal mapping is.
enum ChartRoleEligibility {

    /// The roles a chart type shows, in rail order. Pie has no series: the
    /// renderer draws one ring from one series, so offering the role only let
    /// a user map a column that changed nothing.
    static func roles(for chartType: ChartType) -> [ChartColumnRole] {
        switch chartType {
        case .bar, .line, .area: return [.category, .value, .series]
        case .pie: return [.category, .value]
        case .scatter: return [.x, .y, .size]
        case .gantt: return [.label, .start, .end]
        case .heatmap: return [.x, .y, .value]
        }
    }

    /// Whether a column of `kind` may fill `role` on `chartType`.
    ///
    /// Measures (value, y, size) take numbers. Start, end and scatter X take
    /// numbers or times. Heatmap axes and every dimension role take anything.
    static func accepts(_ role: ChartColumnRole, kind: ColumnKind, chartType: ChartType) -> Bool {
        if chartType == .heatmap, role == .x || role == .y { return true }
        switch role {
        case .value, .y, .size:
            return kind == .numeric
        case .x, .start, .end:
            return kind == .numeric || kind == .temporal
        case .category, .series, .label:
            return true
        }
    }

    /// Whether the chart type reduces rows (so an Aggregate control applies).
    static func usesAggregation(_ chartType: ChartType) -> Bool {
        switch chartType {
        case .scatter, .gantt: return false
        default: return true
        }
    }
}
