import Foundation

struct ChartConfig: Codable, Equatable {
    var chartType: ChartType
    var mappings: [ChartColumnRole: ColumnRef]
    var aggregation: AggregationFn
    var temporalBin: TemporalBin
    var display: ChartDisplayOptions

    init(chartType: ChartType,
         mappings: [ChartColumnRole: ColumnRef] = [:],
         aggregation: AggregationFn = .sum,
         temporalBin: TemporalBin = .auto,
         display: ChartDisplayOptions = ChartDisplayOptions()) {
        self.chartType = chartType
        self.mappings = mappings
        self.aggregation = aggregation
        self.temporalBin = temporalBin
        self.display = display
    }

    /// Build a sensible default config from the result's columns.
    static func infer(from columns: [ColumnDef]) -> ChartConfig {
        func kind(_ c: ColumnDef) -> ColumnKind { ColumnClassifier.kind(forDataType: c.dataType) }
        let indexed = columns.enumerated().map { (idx, c) in (ref: ColumnRef(index: idx, name: c.name), kind: kind(c)) }

        let firstCategorical = indexed.first { $0.kind == .categorical || $0.kind == .temporal }
        let firstNumeric = indexed.first { $0.kind == .numeric }

        var cfg = ChartConfig(chartType: .bar)
        if let cat = firstCategorical { cfg.mappings[.category] = cat.ref }
        if let num = firstNumeric { cfg.mappings[.value] = num.ref }
        return cfg
    }

    /// After a re-run changes the column shape, drop any role whose referenced
    /// column no longer exists at the same index with a matching name.
    mutating func validate(against columns: [ColumnDef]) {
        for (role, ref) in mappings {
            let stillValid = ref.index < columns.count && columns[ref.index].name == ref.name
            if !stillValid { mappings[role] = nil }
        }
    }
}

/// The single blob persisted per workspace result: chart config + view mode.
struct PersistedResultViewState: Codable {
    var chartConfig: ChartConfig?
    var viewMode: ResultViewMode
}
