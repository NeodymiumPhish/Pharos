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
        guard let catRef = config.mappings[.category], catRef.index < result.columns.count else {
            return .empty(.noColumns)
        }
        let valRef = config.mappings[.value]
        let isCount = config.aggregation == .count
        // Non-count aggregations require a value column.
        if !isCount, valRef == nil || (valRef!.index >= result.columns.count) { return .empty(.noColumns) }

        let seriesRef = config.mappings[.series]
        let catKind = ColumnClassifier.kind(forDataType: result.columns[catRef.index].dataType)

        // Decide numeric binning up front (needs a first pass for range + distinct).
        var numericBins: [(lo: Double, hi: Double)] = []
        var numericBinOf: ((Double) -> Int)? = nil
        if catKind == .numeric {
            var vals: [Double] = []
            var distinct = Set<Double>()
            for row in result.rows where catRef.index < row.count {
                if let d = ValueCoercion.double(from: row[catRef.index]) { vals.append(d); distinct.insert(d) }
            }
            if let count = numericBinCount(config.numericBin, distinct: distinct.count, n: vals.count),
               let lo = vals.min(), let hi = vals.max(), hi > lo {
                let width = (hi - lo) / Double(count)
                numericBins = (0..<count).map { (lo + Double($0) * width, lo + Double($0 + 1) * width) }
                numericBinOf = { v in min(count - 1, max(0, Int((v - lo) / width))) }
            }
            // else: falls through to discrete handling (low-cardinality / min==max).
        }

        struct Key: Hashable { let series: String; let cat: String }
        var sums: [Key: Double] = [:]; var counts: [Key: Int] = [:]
        var mins: [Key: Double] = [:]; var maxs: [Key: Double] = [:]
        var order: [String] = []; var seen = Set<String>()
        var seriesOrder: [String] = []; var seriesSeen = Set<String>()
        var drillOf: [String: DrillKey] = [:]      // category label → drill key
        var rawOf: [String: String] = [:]          // discrete label → raw displayString (for Other fold + anyOf)
        var labelIsNull: [String: Bool] = [:]
        var sawAnyValue = false; var plotted = 0

        for row in result.rows {
            guard catRef.index < row.count else { continue }
            let rawCat = row[catRef.index]
            let isNull = rawCat.isNull || rawCat.displayString.isEmpty

            // Determine the category label + its drill key.
            let label: String
            if let binOf = numericBinOf, let d = ValueCoercion.double(from: rawCat) {
                let i = binOf(d); let b = numericBins[i]
                label = binRangeLabel(b.lo, b.hi)
                drillOf[label] = .range(catRef, b.lo, b.hi, .numeric)
            } else if catKind == .temporal, config.temporalBin != .none, case let s as String = rawCat.value,
                      let date = ValueCoercion.date(from: s) {
                label = binLabel(date, bin: config.temporalBin)
                if let (lo, hi) = temporalBinBounds(date, bin: config.temporalBin) {
                    drillOf[label] = .range(catRef, lo, hi, .temporal)
                }
            } else {
                label = rawCat.displayString
                if isNull { drillOf[label] = .blank(catRef); labelIsNull[label] = true }
                else { rawOf[label] = rawCat.displayString }   // discrete drill built at emit (anyOf)
            }

            let seriesName = seriesRef.map { row[$0.index].displayString } ?? ""
            let key = Key(series: seriesName, cat: label)
            if !seen.contains(label) { seen.insert(label); order.append(label) }
            if !seriesSeen.contains(seriesName) { seriesSeen.insert(seriesName); seriesOrder.append(seriesName) }

            if isCount {
                counts[key, default: 0] += 1; sawAnyValue = true; plotted += 1; continue
            }
            guard let vr = valRef, vr.index < row.count, let y = ValueCoercion.double(from: row[vr.index]) else { continue }
            sawAnyValue = true; plotted += 1
            sums[key, default: 0] += y; counts[key, default: 0] += 1
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

        // Top-N — skip for binned numeric/temporal axes (bounded/ordered).
        var categories = order; var truncated = false; var otherCount = 0
        let axisIsBinned = (numericBinOf != nil) || (catKind == .temporal && config.temporalBin != .none)
        if !axisIsBinned && categories.count > config.display.topNCategories {
            let keys = sums.keys.isEmpty ? Array(counts.keys) : Array(sums.keys)
            let totals = Dictionary(grouping: keys) { $0.cat }
            func catTotal(_ c: String) -> Double { totals[c]?.reduce(0) { $0 + value($1) } ?? 0 }
            let ranked = categories.sorted { catTotal($0) > catTotal($1) }
            let kept = Array(ranked.prefix(config.display.topNCategories)); let keptSet = Set(kept)
            let dropped = ranked.filter { !keptSet.contains($0) }
            otherCount = dropped.count; truncated = otherCount > 0
            categories = kept
            if truncated {
                categories.append("Other")
                // Other drill = anyOf of dropped RAW labels (skip null/binned labels which can't appear here).
                drillOf["Other"] = .anyOf(catRef, dropped.compactMap { rawOf[$0] })
            }
            let foldSeries = Set(sums.keys.map { $0.series }).union(counts.keys.map { $0.series })
            for s in foldSeries {
                let otherKey = Key(series: s, cat: "Other")
                for c in dropped {
                    let src = Key(series: s, cat: c)
                    if let v = sums[src] { sums[otherKey, default: 0] += v }
                    if let n = counts[src] { counts[otherKey, default: 0] += n }
                    if let mn = mins[src] { mins[otherKey] = mins[otherKey].map { Swift.min($0, mn) } ?? mn }
                    if let mx = maxs[src] { maxs[otherKey] = maxs[otherKey].map { Swift.max($0, mx) } ?? mx }
                }
            }
        }

        // Build discrete anyOf drill keys now (label → [rawLabel]).
        for (label, raw) in rawOf where drillOf[label] == nil {
            drillOf[label] = .anyOf(catRef, [raw])
        }

        let seriesNames = seriesRef == nil ? [""] : seriesOrder
        var out = ChartData()
        for s in seriesNames {
            var pts: [ChartPoint] = []
            for c in categories {
                let k = Key(series: s, cat: c)
                let hasData = sums[k] != nil || counts[k] != nil || c == "Other"
                if hasData { pts.append(ChartPoint(xLabel: c, xValue: nil, y: value(k), drill: drillOf[c])) }
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

    /// Distinct-value threshold below which an .auto numeric axis stays discrete.
    private static let numericDiscreteThreshold = 12

    /// Resolve the effective numeric bin count for a column of coerced values,
    /// or nil if the axis should be treated as discrete categories.
    private static func numericBinCount(_ bin: NumericBin, distinct: Int, n: Int) -> Int? {
        switch bin {
        case .off: return nil
        case .b10: return 10
        case .b20: return 20
        case .b50: return 50
        case .auto:
            if distinct <= numericDiscreteThreshold { return nil }   // low-cardinality escape
            return max(1, min(50, Int(Double(n).squareRoot().rounded(.up))))
        }
    }

    /// Compact numeric bin label, e.g. "0–10".
    private static func binRangeLabel(_ lo: Double, _ hi: Double) -> String {
        func fmt(_ d: Double) -> String { d == d.rounded() ? String(Int(d)) : String(format: "%.2f", d) }
        return "\(fmt(lo))–\(fmt(hi))"
    }

    /// [startEpoch, lastInstantEpoch] for the temporal bin containing `date`.
    /// lastInstant = next bin start minus one microsecond, so an inclusive
    /// between over display strings includes the whole bucket.
    private static func temporalBinBounds(_ date: Date, bin: TemporalBin) -> (Double, Double)? {
        var cal = Calendar(identifier: .gregorian); cal.timeZone = TimeZone(identifier: "UTC")!
        let comp: Calendar.Component
        switch bin {
        case .hour: comp = .hour
        case .day, .auto: comp = .day
        case .week: comp = .weekOfYear
        case .month: comp = .month
        case .year: comp = .year
        case .none: return nil
        }
        guard let start = cal.dateInterval(of: comp, for: date)?.start,
              let next = cal.date(byAdding: comp, value: 1, to: start) else { return nil }
        return (start.timeIntervalSince1970, next.timeIntervalSince1970 - 0.000001)
    }

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
        let c = cal.dateComponents([.year, .yearForWeekOfYear, .month, .day, .hour, .weekOfYear], from: date)
        switch bin {
        case .year:  return String(format: "%04d", c.year ?? 0)
        case .month: return String(format: "%04d-%02d", c.year ?? 0, c.month ?? 0)
        case .week:  return String(format: "%04d-W%02d", c.yearForWeekOfYear ?? 0, c.weekOfYear ?? 0)
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
