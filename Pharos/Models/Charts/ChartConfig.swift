import Foundation

struct ChartConfig: Codable, Equatable {
    var chartType: ChartType
    var mappings: [ChartColumnRole: ColumnRef]
    var aggregation: AggregationFn
    var temporalBin: TemporalBin
    var numericBin: NumericBin
    var display: ChartDisplayOptions
    var serverAggregation: Bool
    var lastServerRun: LastServerRun?
    var axisBins: [ChartColumnRole: AxisBin] = [:]
    /// Per-chart color override: hex colors applied positionally to the chart's
    /// color domain (series for bar/line/area, slices for pie, index 0 for
    /// scatter). Empty = inherit the global palette. Positional by index, so if
    /// the domain's order/membership changes between runs an override reattaches
    /// to whatever now sits at that index; the rail's "Reset to palette" clears it.
    var seriesColors: [String] = []

    init(chartType: ChartType,
         mappings: [ChartColumnRole: ColumnRef] = [:],
         aggregation: AggregationFn = .sum,
         temporalBin: TemporalBin = .auto,
         numericBin: NumericBin = .auto,
         display: ChartDisplayOptions = ChartDisplayOptions(),
         serverAggregation: Bool = false,
         lastServerRun: LastServerRun? = nil,
         axisBins: [ChartColumnRole: AxisBin] = [:],
         seriesColors: [String] = []) {
        self.chartType = chartType
        self.mappings = mappings
        self.aggregation = aggregation
        self.temporalBin = temporalBin
        self.numericBin = numericBin
        self.display = display
        self.serverAggregation = serverAggregation
        self.lastServerRun = lastServerRun
        self.axisBins = axisBins
        self.seriesColors = seriesColors
    }

    // Tolerant decode: every field decodeIfPresent with a default, so phase-1
    // blobs (no numericBin) still decode and future additions stay compatible.
    enum CodingKeys: String, CodingKey {
        case chartType, mappings, aggregation, temporalBin, numericBin, display, serverAggregation, lastServerRun, axisBins, seriesColors
    }
    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        chartType   = try c.decodeIfPresent(ChartType.self, forKey: .chartType) ?? .bar
        mappings    = try c.decodeIfPresent([ChartColumnRole: ColumnRef].self, forKey: .mappings) ?? [:]
        aggregation = try c.decodeIfPresent(AggregationFn.self, forKey: .aggregation) ?? .sum
        temporalBin = try c.decodeIfPresent(TemporalBin.self, forKey: .temporalBin) ?? .auto
        numericBin  = try c.decodeIfPresent(NumericBin.self, forKey: .numericBin) ?? .auto
        display     = try c.decodeIfPresent(ChartDisplayOptions.self, forKey: .display) ?? ChartDisplayOptions()
        serverAggregation = try c.decodeIfPresent(Bool.self, forKey: .serverAggregation) ?? false
        lastServerRun     = try c.decodeIfPresent(LastServerRun.self, forKey: .lastServerRun) ?? nil
        axisBins    = try c.decodeIfPresent([ChartColumnRole: AxisBin].self, forKey: .axisBins) ?? [:]
        seriesColors = try c.decodeIfPresent([String].self, forKey: .seriesColors) ?? []
    }

    /// The effective bin granularity for a role: the per-axis override if set,
    /// else the chart's global temporal/numeric bins. Centralizes the fallback so
    /// the aggregator and generator never sprinkle it.
    func resolvedBin(for role: ChartColumnRole) -> AxisBin {
        axisBins[role] ?? AxisBin(temporal: temporalBin, numeric: numericBin)
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
