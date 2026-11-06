import Foundation

/// Pure transform from a loaded QueryResult + ChartConfig into plot-ready ChartData.
enum ChartAggregator {

    static func aggregate(_ result: QueryResult, _ config: ChartConfig) -> ChartData {
        switch config.chartType {
        case .gantt:   return aggregateGantt(result, config)
        case .scatter: return aggregateScatter(result, config)
        case .heatmap: return aggregateHeatmap(result, config)
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
        let catKind = ColumnClassifier.kind(of: catRef.index, in: result)
        let rows = result.rows
        // A category column past the table's last one plots no row.
        let rowRange = catRef.index < rows.columnCount ? 0..<rows.rowCount : 0..<0

        // Decide numeric binning up front (needs a first pass for range + distinct).
        var numericBins: [(lo: Double, hi: Double)] = []
        var numericBinOf: ((Double) -> Int)? = nil
        if catKind == .numeric {
            var vals: [Double] = []
            var distinct = Set<Double>()
            for r in rowRange {
                if let d = ValueCoercion.double(from: rows.string(r, catRef.index)) { vals.append(d); distinct.insert(d) }
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
        var rawOf: [String: String] = [:]          // discrete label → raw cell text (for Other fold + anyOf)
        var labelIsNull: [String: Bool] = [:]
        var sawAnyValue = false; var plotted = 0

        for r in rowRange {
            let rawCat = rows.string(r, catRef.index)
            let isNull = rawCat?.isEmpty ?? true

            // Determine the category label + its drill key.
            let label: String
            if let binOf = numericBinOf, let d = ValueCoercion.double(from: rawCat) {
                let i = binOf(d); let b = numericBins[i]
                label = binRangeLabel(b.lo, b.hi)
                drillOf[label] = .range(catRef, b.lo, b.hi, .numeric)
            } else if catKind == .temporal, config.temporalBin != .none, let s = rawCat,
                      let date = ValueCoercion.date(from: s) {
                label = binLabel(date, bin: config.temporalBin)
                if let (lo, hi) = temporalBinBounds(date, bin: config.temporalBin) {
                    drillOf[label] = .range(catRef, lo, hi, .temporal)
                }
            } else {
                label = rawCat ?? ""
                if isNull { drillOf[label] = .blank(catRef); labelIsNull[label] = true }
                else { rawOf[label] = label }   // discrete drill built at emit (anyOf)
            }

            let seriesName = seriesRef.map { rows.displayString(r, $0.index) } ?? ""
            let key = Key(series: seriesName, cat: label)
            if !seen.contains(label) { seen.insert(label); order.append(label) }
            if !seriesSeen.contains(seriesName) { seriesSeen.insert(seriesName); seriesOrder.append(seriesName) }

            if isCount {
                counts[key, default: 0] += 1; sawAnyValue = true; plotted += 1; continue
            }
            guard let vr = valRef, let y = ValueCoercion.double(from: rows.string(r, vr.index)) else { continue }
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
        // Numeric bins must render ascending by bin (bar/line/area set no
        // chartXScale domain, so emit order IS the axis order). order[] is
        // first-appearance, which is arbitrary for an unsorted numeric column.
        if numericBinOf != nil {
            categories = numericBins.map { binRangeLabel($0.lo, $0.hi) }.filter { seen.contains($0) }
        }
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
                // Other drill = the dropped RAW labels; if the null bucket was
                // among the dropped, include it via .blank so clicking "Other"
                // also selects the null rows folded into the bar.
                let droppedRaw = dropped.compactMap { rawOf[$0] }
                let droppedNull = dropped.contains { labelIsNull[$0] == true }
                drillOf["Other"] = droppedNull
                    ? .compound([.anyOf(catRef, droppedRaw), .blank(catRef)])
                    : .anyOf(catRef, droppedRaw)
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
                guard hasData else { continue }
                var drill = drillOf[c]
                if seriesRef != nil, let base = drill {
                    // Null/empty series name → .blank on the series column.
                    let seriesKey: DrillKey = s.isEmpty ? .blank(seriesRef!) : .anyOf(seriesRef!, [s])
                    drill = .compound([base, seriesKey])
                }
                pts.append(ChartPoint(xLabel: c, xValue: nil, y: value(k), drill: drill))
            }
            out.series.append(ChartSeries(name: s, points: pts))
        }
        out.plottedRowCount = plotted
        out.totalLoadedRowCount = result.rows.rowCount
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
        // Optional size column (bubble radius); only read when it maps to a real column.
        let sizeRef = config.mappings[.size].flatMap { $0.index < result.columns.count ? $0 : nil }
        var pts: [ChartPoint] = []
        let rows = result.rows
        for r in 0..<rows.rowCount {
            // A column past the table's last one reads as NULL: no point.
            guard let x = ValueCoercion.double(from: rows.string(r, xRef.index)),
                  let y = ValueCoercion.double(from: rows.string(r, yRef.index)) else { continue }
            let size = sizeRef.flatMap { ValueCoercion.double(from: rows.string(r, $0.index)) }
            pts.append(ChartPoint(xLabel: "", xValue: x, y: y, size: size))
        }
        if pts.isEmpty { return .empty(.allNull) }

        var out = ChartData()
        // macOS 15+ renders scatter via the vectorized PointPlot API (Task 11),
        // which handles 100k+ points, so no sampling is needed in normal use.
        // Keep only a high safety cap to bound worst-case memory; it flags
        // wasSampled so the UI can note it in the rare case it trips.
        // A sized scatter renders one PointMark per point instead, so it is
        // capped far lower.
        let safetyCap = sizeRef == nil ? 100_000 : 5_000
        if pts.count > safetyCap {
            // Exact index per slot (no accumulating float error), so the cap holds.
            let stride = Double(pts.count) / Double(safetyCap)
            let sampled = (0..<safetyCap).map { pts[min(Int(Double($0) * stride), pts.count - 1)] }
            out.wasSampled = true
            out.series = [ChartSeries(name: "", points: sampled)]
        } else {
            out.series = [ChartSeries(name: "", points: pts)]
        }
        out.plottedRowCount = out.series.first?.points.count ?? 0
        out.totalLoadedRowCount = result.rows.rowCount
        return out
    }

    // MARK: - Gantt

    /// The most Gantt bars drawn. Each bar is a mark and each lane a label
    /// in one SwiftUI layout pass. Measured on a 60,000-lane result: 5,000
    /// bars held the main thread ~8 s, 1,000 bars ~7.8 s, 250 bars 2.8 s —
    /// against ~2.0 s for a 200-row chart, the cost of opening any chart. A
    /// chart of more lanes cannot be read anyway; the view says how many are
    /// left out.
    static let ganttBarCap = 250

    /// Joins a lane's or segment's column values into one key.
    static let ganttValueSeparator = " · "

    private static func aggregateGantt(_ result: QueryResult, _ config: ChartConfig) -> ChartData {
        let labelRefs = config.columns(for: .label)
        let segmentRefs = config.columns(for: .segment)
        guard !labelRefs.isEmpty, let startRef = config.mappings[.start], let endRef = config.mappings[.end],
              (labelRefs + segmentRefs + [startRef, endRef]).allSatisfy({ $0.index < result.columns.count }) else {
            return .empty(.noColumns)
        }
        let maxIndex = (labelRefs + segmentRefs + [startRef, endRef]).map(\.index).max() ?? 0

        // One observation per usable row, grouped by lane in first-seen order.
        struct Obs { var bar: GanttBar; var order: Int }
        var lanes: [String: [Obs]] = [:]
        var laneOrder: [String] = []
        let rows = result.rows
        // A mapped column past the table's last one plots no row.
        let rowRange = maxIndex < rows.columnCount ? 0..<rows.rowCount : 0..<0
        for i in rowRange {
            guard let a = epoch(from: rows.string(i, startRef.index)),
                  let b = epoch(from: rows.string(i, endRef.index)) else { continue }
            let lane = labelRefs.map { rows.displayString(i, $0.index) }.joined(separator: ganttValueSeparator)
            let segmentValues = segmentRefs.map { rows.displayString(i, $0.index) }
            let laneKeys = labelRefs.map { drillKey($0, rows.string(i, $0.index)) }
            let segmentKeys = segmentRefs.map { drillKey($0, rows.string(i, $0.index)) }
            let bar = GanttBar(lane: lane,
                               segment: segmentValues.joined(separator: ganttValueSeparator),
                               segmentValues: segmentValues,
                               start: Swift.min(a, b), end: Swift.max(a, b),
                               laneDrill: compound(laneKeys),
                               drill: compound(laneKeys + segmentKeys))
            if lanes[lane] == nil { laneOrder.append(lane) }
            lanes[lane, default: []].append(Obs(bar: bar, order: i))
        }
        if laneOrder.isEmpty { return .empty(.allNull) }

        var bars: [GanttBar] = []
        for lane in laneOrder {
            let obs = lanes[lane] ?? []
            switch config.ganttMerge {
            case .span:
                // One bar per segment value (per lane with no segment column).
                var bySegment: [String: GanttBar] = [:]
                var order: [String] = []
                for o in obs {
                    if var b = bySegment[o.bar.segment] {
                        b.start = Swift.min(b.start, o.bar.start); b.end = Swift.max(b.end, o.bar.end); b.rowCount += 1
                        bySegment[o.bar.segment] = b
                    } else {
                        bySegment[o.bar.segment] = o.bar; order.append(o.bar.segment)
                    }
                }
                bars += order.compactMap { bySegment[$0] }
            case .runs:
                // No segment column: one bar per row, as before segments existed.
                guard !segmentRefs.isEmpty else { bars += obs.map(\.bar); continue }
                // Start order (row order breaks ties); a change of segment opens a bar.
                let sorted = obs.sorted { ($0.bar.start, $0.order) < ($1.bar.start, $1.order) }
                var current: GanttBar? = nil
                for o in sorted {
                    if var c = current, c.segment == o.bar.segment {
                        c.end = Swift.max(c.end, o.bar.end); c.rowCount += 1
                        current = c
                    } else {
                        if let c = current { bars.append(c) }
                        current = o.bar
                    }
                }
                if let c = current { bars.append(c) }
            }
        }

        // Each bar is one mark in a SwiftUI ForEach: a bar per row of a large
        // result put 60,000 marks into one layout pass, which held the main
        // thread for minutes at ~2 GB (measured). Keep whole lanes, in their
        // order, up to `ganttBarCap` bars, and say how many lanes are left out.
        var keptLanes = laneOrder
        if bars.count > ganttBarCap {
            var perLane: [String: Int] = [:]
            for bar in bars { perLane[bar.lane, default: 0] += 1 }
            var total = 0
            keptLanes = []
            for lane in laneOrder {
                let n = perLane[lane] ?? 0
                if total + n > ganttBarCap && !keptLanes.isEmpty { break }
                keptLanes.append(lane)
                total += n
            }
            let kept = Set(keptLanes)
            bars = bars.filter { kept.contains($0.lane) }
        }

        var out = ChartData()
        out.ganttBars = bars
        out.ganttLanes = keptLanes
        out.wasTruncated = keptLanes.count < laneOrder.count
        out.otherBucketCount = laneOrder.count - keptLanes.count
        out.plottedRowCount = keptLanes.reduce(0) { $0 + (lanes[$1]?.count ?? 0) }
        out.totalLoadedRowCount = result.rows.rowCount
        let startKind = ColumnClassifier.kind(of: startRef.index, in: result)
        out.ganttAxisKind = startKind == .temporal ? .temporal : .numeric
        return out
    }

    /// The drill key for one cell (nil = SQL NULL): its exact value, or the
    /// blank mark.
    private static func drillKey(_ ref: ColumnRef, _ v: String?) -> DrillKey {
        guard let v, !v.isEmpty else { return .blank(ref) }
        return .anyOf(ref, [v])
    }

    private static func compound(_ keys: [DrillKey]) -> DrillKey? {
        keys.count > 1 ? .compound(keys) : keys.first
    }

    // MARK: - Heatmap

    private static func aggregateHeatmap(_ result: QueryResult, _ config: ChartConfig) -> ChartData {
        guard let xRef = config.mappings[.x], let yRef = config.mappings[.y],
              xRef.index < result.columns.count, yRef.index < result.columns.count else {
            return .empty(.noColumns)
        }
        let valRef = config.mappings[.value]
        let isCount = config.aggregation == .count || valRef == nil
        struct Key: Hashable { let x: String; let y: String }
        var sums: [Key: Double] = [:]; var counts: [Key: Int] = [:]
        var mins: [Key: Double] = [:]; var maxs: [Key: Double] = [:]
        var xOrder: [String] = []; var xSeen = Set<String>()
        var yOrder: [String] = []; var ySeen = Set<String>()
        var drillOf: [Key: DrillKey] = [:]
        var saw = false

        let xKind = ColumnClassifier.kind(of: xRef.index, in: result)
        let yKind = ColumnClassifier.kind(of: yRef.index, in: result)

        // Build a per-axis labeller: numeric binning (first pass for range +
        // distinct, with the low-cardinality escape) mirrors the categorical
        // path; temporal binning uses the axis's resolved TemporalBin; otherwise
        // discrete. Returns (label, drill sub-key) for a raw cell (nil = NULL).
        let rows = result.rows
        func makeAxisLabeller(_ ref: ColumnRef, _ kind: ColumnKind, _ bin: AxisBin) -> (String?) -> (String, DrillKey) {
            if kind == .numeric {
                var vals: [Double] = []; var distinct = Set<Double>()
                for r in 0..<rows.rowCount {
                    if let d = ValueCoercion.double(from: rows.string(r, ref.index)) { vals.append(d); distinct.insert(d) }
                }
                if let count = numericBinCount(bin.numeric, distinct: distinct.count, n: vals.count),
                   let lo = vals.min(), let hi = vals.max(), hi > lo {
                    let width = (hi - lo) / Double(count)
                    let bins = (0..<count).map { (lo: lo + Double($0) * width, hi: lo + Double($0 + 1) * width) }
                    let binOf: (Double) -> Int = { v in Swift.min(count - 1, Swift.max(0, Int((v - lo) / width))) }
                    return { v in
                        guard let d = ValueCoercion.double(from: v) else {
                            guard let v, !v.isEmpty else { return ("(null)", .blank(ref)) }
                            return (v, .anyOf(ref, [v]))
                        }
                        let b = bins[binOf(d)]
                        return (binRangeLabel(b.lo, b.hi), .range(ref, b.lo, b.hi, .numeric))
                    }
                }
                // else: fall through to discrete handling below.
            }
            return { v in
                if kind == .temporal, bin.temporal != .none, let s = v, let d = ValueCoercion.date(from: s) {
                    let label = binLabel(d, bin: bin.temporal)
                    if let (blo, bhi) = temporalBinBounds(d, bin: bin.temporal) { return (label, .range(ref, blo, bhi, .temporal)) }
                    return (label, .anyOf(ref, [label]))
                }
                guard let v, !v.isEmpty else { return ("(null)", .blank(ref)) }
                return (v, .anyOf(ref, [v]))
            }
        }
        let xLabeller = makeAxisLabeller(xRef, xKind, config.resolvedBin(for: .x))
        let yLabeller = makeAxisLabeller(yRef, yKind, config.resolvedBin(for: .y))

        // An axis column past the table's last one plots no row.
        let rowRange = xRef.index < rows.columnCount && yRef.index < rows.columnCount ? 0..<rows.rowCount : 0..<0
        for r in rowRange {
            let (xl, xk) = xLabeller(rows.string(r, xRef.index))
            let (yl, yk) = yLabeller(rows.string(r, yRef.index))
            let key = Key(x: xl, y: yl)
            if !xSeen.contains(xl) { xSeen.insert(xl); xOrder.append(xl) }
            if !ySeen.contains(yl) { ySeen.insert(yl); yOrder.append(yl) }
            drillOf[key] = .compound([xk, yk])
            if isCount { counts[key, default: 0] += 1; saw = true; continue }
            guard let vr = valRef, let val = ValueCoercion.double(from: rows.string(r, vr.index)) else { continue }
            saw = true
            sums[key, default: 0] += val; counts[key, default: 0] += 1
            mins[key] = mins[key].map { Swift.min($0, val) } ?? val
            maxs[key] = maxs[key].map { Swift.max($0, val) } ?? val
        }
        if !saw { return .empty(.allNull) }

        func value(_ k: Key) -> Double {
            switch config.aggregation {
            case .sum: return sums[k] ?? 0
            case .count: return Double(counts[k] ?? 0)
            case .avg: return (counts[k] ?? 0) > 0 ? (sums[k] ?? 0) / Double(counts[k]!) : 0
            case .min: return mins[k] ?? 0
            case .max: return maxs[k] ?? 0
            }
        }

        // Top-N per axis by marginal total.
        func topN(_ labels: [String], axisIsX: Bool) -> [String] {
            let cap = config.display.topNCategories
            guard labels.count > cap else { return labels }
            func total(_ l: String) -> Double {
                labels.isEmpty ? 0 : (axisIsX ? yOrder : xOrder).reduce(0) { acc, other in
                    acc + value(axisIsX ? Key(x: l, y: other) : Key(x: other, y: l))
                }
            }
            return Array(labels.sorted { total($0) > total($1) }.prefix(cap))
        }
        let xs = topN(xOrder, axisIsX: true); let ys = topN(yOrder, axisIsX: false)
        let truncated = xs.count < xOrder.count || ys.count < yOrder.count

        var out = ChartData()
        for x in xs { for y in ys {
            let key = Key(x: x, y: y)
            guard sums[key] != nil || counts[key] != nil else { continue }   // blank cells not drawn
            out.heatmapCells.append(HeatmapCell(x: x, y: y, value: value(key), drill: drillOf[key]))
        } }
        out.plottedRowCount = out.heatmapCells.count
        out.totalLoadedRowCount = result.rows.rowCount
        out.wasTruncated = truncated
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

    /// A cell's text (nil = SQL NULL) as seconds: a date, else a number.
    private static func epoch(from v: String?) -> Double? {
        guard let s = v else { return nil }
        if let d = ValueCoercion.date(from: s) { return d.timeIntervalSince1970 }
        return ValueCoercion.double(from: s)   // numeric gantt axis
    }
}
