import Foundation

/// Pure transform from a loaded QueryResult + ChartConfig into plot-ready ChartData.
enum ChartAggregator {

    static func aggregate(_ result: QueryResult, _ config: ChartConfig) -> ChartData {
        switch config.chartType {
        case .gantt:   return aggregateGantt(result, config)
        case .scatter: return aggregateScatter(result, config)
        default:       return aggregateCategorical(result, config)
        }
    }

    // MARK: - Categorical (bar/line/area/pie)

    private static func aggregateCategorical(_ result: QueryResult, _ config: ChartConfig) -> ChartData {
        guard let catRef = config.mappings[.category], let valRef = config.mappings[.value],
              catRef.index < result.columns.count, valRef.index < result.columns.count else {
            return .empty(.noColumns)
        }
        let seriesRef = config.mappings[.series]
        let catKind = ColumnClassifier.kind(forDataType: result.columns[catRef.index].dataType)

        // Accumulator keyed by (seriesName, categoryLabel).
        struct Key: Hashable { let series: String; let cat: String }
        var sums: [Key: Double] = [:]
        var counts: [Key: Int] = [:]
        var mins: [Key: Double] = [:]
        var maxs: [Key: Double] = [:]
        var order: [String] = []           // category label first-seen order
        var seen = Set<String>()
        var seriesOrder: [String] = []     // series name first-seen order
        var seriesSeen = Set<String>()
        var sawAnyValue = false
        var plotted = 0

        for row in result.rows {
            guard catRef.index < row.count, valRef.index < row.count else { continue }
            let rawCat = row[catRef.index]
            let catLabel = categoryLabel(rawCat, kind: catKind, bin: config.temporalBin)
            let seriesName = seriesRef.map { row[$0.index].displayString } ?? ""

            let key = Key(series: seriesName, cat: catLabel)
            if !seen.contains(catLabel) { seen.insert(catLabel); order.append(catLabel) }
            if !seriesSeen.contains(seriesName) { seriesSeen.insert(seriesName); seriesOrder.append(seriesName) }

            if config.aggregation == .count {
                counts[key, default: 0] += 1
                sawAnyValue = true
                plotted += 1
                continue
            }
            guard let y = ValueCoercion.double(from: row[valRef.index]) else { continue }
            sawAnyValue = true
            plotted += 1
            sums[key, default: 0] += y
            counts[key, default: 0] += 1
            mins[key] = mins[key].map { Swift.min($0, y) } ?? y
            maxs[key] = maxs[key].map { Swift.max($0, y) } ?? y
        }

        if !sawAnyValue { return .empty(.allNull) }

        func value(_ k: Key) -> Double {
            switch config.aggregation {
            case .sum: return sums[k] ?? 0
            case .count: return Double(counts[k] ?? 0)
            case .avg: return (counts[k] ?? 0) > 0 ? (sums[k] ?? 0) / Double(counts[k]!) : 0
            case .min: return mins[k] ?? 0
            case .max: return maxs[k] ?? 0
            }
        }

        // Top-N capping (skip for temporal axes — buckets are bounded/ordered).
        var categories = order
        var truncated = false
        var otherCount = 0
        if catKind != .temporal && categories.count > config.display.topNCategories {
            // Rank by total value across series.
            let totals = Dictionary(grouping: sums.keys.isEmpty ? counts.keys.map { $0 } : sums.keys.map { $0 }) { $0.cat }
            func catTotal(_ c: String) -> Double {
                totals[c]?.reduce(0) { $0 + value($1) } ?? 0
            }
            let ranked = categories.sorted { catTotal($0) > catTotal($1) }
            let kept = Array(ranked.prefix(config.display.topNCategories))
            let keptSet = Set(kept)
            otherCount = categories.count - kept.count
            truncated = otherCount > 0
            categories = kept
            if truncated { categories.append("Other") }
            // Fold dropped categories into Other per series.
            let seriesNames = Set(sums.keys.map { $0.series }).union(counts.keys.map { $0.series })
            for s in seriesNames {
                var otherVal = 0.0
                for c in ranked where !keptSet.contains(c) { otherVal += value(Key(series: s, cat: c)) }
                if otherVal != 0 { sums[Key(series: s, cat: "Other")] = otherVal }
            }
        }

        // Build series.
        let seriesNames = seriesRef == nil ? [""] : seriesOrder
        var out = ChartData()
        for s in seriesNames {
            var pts: [ChartPoint] = []
            for c in categories {
                let k = Key(series: s, cat: c)
                let hasData = sums[k] != nil || counts[k] != nil || c == "Other"
                if hasData { pts.append(ChartPoint(xLabel: c, xValue: nil, y: value(k))) }
            }
            out.series.append(ChartSeries(name: s, points: pts))
        }
        out.plottedRowCount = plotted
        out.totalLoadedRowCount = result.rows.count
        out.wasTruncated = truncated
        out.otherBucketCount = otherCount
        return out
    }

    // MARK: - Scatter

    private static func aggregateScatter(_ result: QueryResult, _ config: ChartConfig) -> ChartData {
        guard let xRef = config.mappings[.x], let yRef = config.mappings[.y],
              xRef.index < result.columns.count, yRef.index < result.columns.count else {
            return .empty(.noColumns)
        }
        var pts: [ChartPoint] = []
        for row in result.rows {
            guard xRef.index < row.count, yRef.index < row.count,
                  let x = ValueCoercion.double(from: row[xRef.index]),
                  let y = ValueCoercion.double(from: row[yRef.index]) else { continue }
            pts.append(ChartPoint(xLabel: "", xValue: x, y: y))
        }
        if pts.isEmpty { return .empty(.allNull) }

        var out = ChartData()
        // macOS 15+ renders scatter via the vectorized PointPlot API (Task 11),
        // which handles 100k+ points, so no sampling is needed in normal use.
        // Keep only a high safety cap to bound worst-case memory; it flags
        // wasSampled so the UI can note it in the rare case it trips.
        let safetyCap = 100_000
        if pts.count > safetyCap {
            let stride = Double(pts.count) / Double(safetyCap)
            var sampled: [ChartPoint] = []
            var i = 0.0
            while Int(i) < pts.count { sampled.append(pts[Int(i)]); i += stride }
            out.wasSampled = true
            out.series = [ChartSeries(name: "", points: sampled)]
        } else {
            out.series = [ChartSeries(name: "", points: pts)]
        }
        out.plottedRowCount = out.series.first?.points.count ?? 0
        out.totalLoadedRowCount = result.rows.count
        return out
    }

    // MARK: - Gantt

    private static func aggregateGantt(_ result: QueryResult, _ config: ChartConfig) -> ChartData {
        guard let labelRef = config.mappings[.label], let startRef = config.mappings[.start],
              let endRef = config.mappings[.end],
              labelRef.index < result.columns.count,
              startRef.index < result.columns.count,
              endRef.index < result.columns.count else {
            return .empty(.noColumns)
        }
        var bars: [GanttBar] = []
        for row in result.rows {
            guard labelRef.index < row.count, startRef.index < row.count, endRef.index < row.count,
                  let start = epoch(from: row[startRef.index]),
                  let end = epoch(from: row[endRef.index]) else { continue }
            bars.append(GanttBar(label: row[labelRef.index].displayString, start: start, end: end))
        }
        if bars.isEmpty { return .empty(.allNull) }
        var out = ChartData()
        out.ganttBars = bars
        out.plottedRowCount = bars.count
        out.totalLoadedRowCount = result.rows.count
        return out
    }

    // MARK: - Helpers

    /// A category's display label, applying temporal binning when applicable.
    private static func categoryLabel(_ v: AnyCodable, kind: ColumnKind, bin: TemporalBin) -> String {
        if kind == .temporal, bin != .none, case let s as String = v.value, let date = ValueCoercion.date(from: s) {
            return binLabel(date, bin: bin)
        }
        return v.displayString
    }

    private static func binLabel(_ date: Date, bin: TemporalBin) -> String {
        var cal = Calendar(identifier: .gregorian)
        cal.timeZone = TimeZone(identifier: "UTC")!
        let c = cal.dateComponents([.year, .month, .day, .hour, .weekOfYear], from: date)
        switch bin {
        case .year:  return String(format: "%04d", c.year ?? 0)
        case .month: return String(format: "%04d-%02d", c.year ?? 0, c.month ?? 0)
        case .week:  return String(format: "%04d-W%02d", c.year ?? 0, c.weekOfYear ?? 0)
        case .day:   return String(format: "%04d-%02d-%02d", c.year ?? 0, c.month ?? 0, c.day ?? 0)
        case .hour:  return String(format: "%04d-%02d-%02d %02d:00", c.year ?? 0, c.month ?? 0, c.day ?? 0, c.hour ?? 0)
        case .auto:  return String(format: "%04d-%02d-%02d", c.year ?? 0, c.month ?? 0, c.day ?? 0) // resolved upstream; default day
        case .none:  return ""
        }
    }

    private static func epoch(from v: AnyCodable) -> Double? {
        if case let s as String = v.value {
            if let d = ValueCoercion.date(from: s) { return d.timeIntervalSince1970 }
            return ValueCoercion.double(from: s)   // numeric gantt axis
        }
        return ValueCoercion.double(from: v)
    }
}
