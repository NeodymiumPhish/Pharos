import Foundation

/// The axis titles a chart shows when the user has typed none.
///
/// Every serious charting tool titles both axes by default (ggplot2 names the
/// variables; Excel and Tableau name the field and the aggregate), because an
/// untitled Y axis is a number with no unit. Derived from the mapping alone —
/// a `ColumnRef` carries its name — so the canvas needs no column list.
enum ChartAxisTitles {

    struct Titles: Equatable {
        var x: String
        var y: String
    }

    /// The effective titles: the typed ones where present, else derived.
    static func resolve(_ config: ChartConfig) -> Titles {
        let derived = derive(config)
        let x = config.display.xAxisTitle.trimmingCharacters(in: .whitespaces)
        let y = config.display.yAxisTitle.trimmingCharacters(in: .whitespaces)
        return Titles(x: x.isEmpty ? derived.x : x, y: y.isEmpty ? derived.y : y)
    }

    /// Titles from the mapping. Empty when the role that would name an axis
    /// is unmapped, so the canvas draws nothing rather than "Sum of".
    static func derive(_ config: ChartConfig) -> Titles {
        let m = config.mappings
        switch config.chartType {
        case .bar, .line, .area, .pie:
            return Titles(x: m[.category]?.name ?? "",
                          y: aggregateTitle(config.aggregation, valueName: m[.value]?.name))
        case .scatter:
            return Titles(x: m[.x]?.name ?? "", y: m[.y]?.name ?? "")
        case .heatmap:
            return Titles(x: m[.x]?.name ?? "", y: m[.y]?.name ?? "")
        case .gantt:
            return Titles(x: m[.start]?.name ?? "", y: m[.label]?.name ?? "")
        }
    }

    /// "Sum of revenue", "Average of price", "Count", "Minimum of age".
    static func aggregateTitle(_ fn: AggregationFn, valueName: String?) -> String {
        if fn == .count { return "Count" }
        guard let valueName, !valueName.isEmpty else { return "" }
        let verb: String
        switch fn {
        case .sum: verb = "Sum of"
        case .avg: verb = "Average of"
        case .min: verb = "Minimum of"
        case .max: verb = "Maximum of"
        case .count: verb = ""
        }
        return "\(verb) \(valueName)"
    }
}
