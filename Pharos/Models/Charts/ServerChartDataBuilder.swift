import Foundation

/// Pure transform from a server-aggregated `QueryResult` (the output of a
/// `SqlPushdownGenerator` query) into plot-ready `ChartData`. Unlike
/// `ChartAggregator`, no client-side aggregation happens here — rows already
/// carry one mark per row under the generator's fixed column aliases; this
/// just maps them (+ drill keys) into the renderer-agnostic shape.
enum ServerChartDataBuilder {

    static func build(_ result: QueryResult, layout: PushdownLayout, config: ChartConfig) -> ChartData {
        switch layout.kind {
        case .scatter:
            return buildScatter(result, layout: layout)
        case .heatmap:
            return buildHeatmap(result, layout: layout, config: config)
        case .categorical:
            if let n = layout.numericBins {
                return buildNumeric(result, binCount: n, config: config)
            }
            return buildCategorical(result, layout: layout, config: config)
        }
    }

    // MARK: - Categorical (`_cat[, _series], _val`)

    private static func buildCategorical(_ result: QueryResult, layout: PushdownLayout, config: ChartConfig) -> ChartData {
        guard let catRef = config.mappings[.category],
              let catIdx = colIndex(result, "_cat"), let valIdx = colIndex(result, "_val") else {
            return .empty(.noColumns)
        }
        let seriesIdx = layout.hasSeries ? colIndex(result, "_series") : nil

        var seriesOrder: [String] = []
        var seriesSeen = Set<String>()
        var pointsBySeries: [String: [ChartPoint]] = [:]
        var plotted = 0

        let rows = result.rows
        for r in rowRange(rows, catIdx, valIdx) {
            guard let y = ValueCoercion.double(from: rows.string(r, valIdx)) else { continue }
            let catText = rows.displayString(r, catIdx)
            let drill: DrillKey = catText.isEmpty ? .blank(catRef) : .anyOf(catRef, [catText])
            let seriesName = seriesIdx.map { rows.displayString(r, $0) } ?? ""
            if !seriesSeen.contains(seriesName) { seriesSeen.insert(seriesName); seriesOrder.append(seriesName) }
            pointsBySeries[seriesName, default: []].append(
                ChartPoint(xLabel: catText, xValue: nil, y: y, drill: drill))
            plotted += 1
        }
        if plotted == 0 { return .empty(.allNull) }

        var out = ChartData()
        for s in seriesOrder { out.series.append(ChartSeries(name: s, points: pointsBySeries[s] ?? [])) }
        out.plottedRowCount = plotted
        out.totalLoadedRowCount = result.rowCount
        out.wasTruncated = result.hasMore
        return out
    }

    // MARK: - Numeric bins (`_bucket, _lo, _hi, _val`)

    private static func buildNumeric(_ result: QueryResult, binCount: Int, config: ChartConfig) -> ChartData {
        guard let catRef = config.mappings[.category],
              let bucketIdx = colIndex(result, "_bucket"), let loIdx = colIndex(result, "_lo"),
              let hiIdx = colIndex(result, "_hi"), let valIdx = colIndex(result, "_val") else {
            return .empty(.noColumns)
        }

        struct Row { let bucket: Int; let lo: Double; let hi: Double; let y: Double }
        var parsed: [Row] = []
        let rows = result.rows
        for r in rowRange(rows, bucketIdx, loIdx, hiIdx, valIdx) {
            guard let b = intValue(rows.string(r, bucketIdx)), let lo = ValueCoercion.double(from: rows.string(r, loIdx)),
                  let hi = ValueCoercion.double(from: rows.string(r, hiIdx)),
                  let y = ValueCoercion.double(from: rows.string(r, valIdx)) else { continue }
            parsed.append(Row(bucket: b, lo: lo, hi: hi, y: y))
        }
        if parsed.isEmpty { return .empty(.allNull) }
        parsed.sort { $0.bucket < $1.bucket }

        // lo/hi are constant across rows (same _r CTE row repeated per group).
        let lo = parsed[0].lo, hi = parsed[0].hi
        // Server-chosen bucket count rides `_n`; fall back to the layout nominal.
        let nFromCol = colIndex(result, "_n").flatMap { i in rows.isEmpty ? nil : intValue(rows.string(0, i)) }
        let effectiveBins = (nFromCol ?? 0) > 0 ? nFromCol! : binCount
        let width = (hi - lo) / Double(effectiveBins)

        var pts: [ChartPoint] = []
        for r in parsed {
            let blo = lo + Double(r.bucket - 1) * width
            let bhi = lo + Double(r.bucket) * width
            pts.append(ChartPoint(xLabel: rangeLabel(blo, bhi), xValue: nil, y: r.y,
                                   drill: .range(catRef, blo, bhi, .numeric)))
        }

        var out = ChartData()
        out.series = [ChartSeries(name: "", points: pts)]
        out.plottedRowCount = pts.count
        out.totalLoadedRowCount = result.rowCount
        out.wasTruncated = result.hasMore
        return out
    }

    /// Compact numeric bin label, e.g. "0–10" (en-dash). Deliberately local —
    /// mirrors `ChartAggregator`'s private `binRangeLabel` format but this
    /// type stays self-contained rather than reaching into the aggregator.
    private static func rangeLabel(_ lo: Double, _ hi: Double) -> String {
        func fmt(_ d: Double) -> String { d == d.rounded() ? String(Int(d)) : String(format: "%.2f", d) }
        return "\(fmt(lo))\u{2013}\(fmt(hi))"
    }

    // MARK: - Heatmap (`_x, _y, _val`)

    private static func buildHeatmap(_ result: QueryResult, layout: PushdownLayout, config: ChartConfig) -> ChartData {
        guard let xRef = config.mappings[.x], let yRef = config.mappings[.y],
              let xIdx = colIndex(result, "_x"), let yIdx = colIndex(result, "_y"),
              let valIdx = colIndex(result, "_val") else { return .empty(.noColumns) }

        // Optional per-axis numeric bound columns.
        func bounds(_ tag: String) -> (lo: Int?, hi: Int?, n: Int?) {
            (colIndex(result, "_\(tag)lo"), colIndex(result, "_\(tag)hi"), colIndex(result, "_\(tag)n"))
        }
        let xb = bounds("x"), yb = bounds("y")

        let rows = result.rows
        /// `raw` is the axis cell's text, nil for a SQL NULL; `r` its row.
        func axisLabelDrill(_ raw: String?, _ r: Int, numeric: Bool,
                            _ bnd: (lo: Int?, hi: Int?, n: Int?), _ ref: ColumnRef) -> (String, DrillKey) {
            if numeric, let bucket = intValue(raw),
               let loC = bnd.lo.flatMap({ ValueCoercion.double(from: rows.string(r, $0)) }),
               let hiC = bnd.hi.flatMap({ ValueCoercion.double(from: rows.string(r, $0)) }),
               let nC = bnd.n.flatMap({ intValue(rows.string(r, $0)) }), nC > 0 {
                let width = (hiC - loC) / Double(nC)
                let blo = loC + Double(bucket - 1) * width, bhi = loC + Double(bucket) * width
                return (rangeLabel(blo, bhi), .range(ref, blo, bhi, .numeric))
            }
            guard let raw, !raw.isEmpty else { return ("(null)", .blank(ref)) }
            return (raw, .anyOf(ref, [raw]))
        }

        var cells: [HeatmapCell] = []
        for r in rowRange(rows, xIdx, yIdx, valIdx) {
            guard let v = ValueCoercion.double(from: rows.string(r, valIdx)) else { continue }
            let (xl, xk) = axisLabelDrill(rows.string(r, xIdx), r, numeric: layout.xNumericBinned, xb, xRef)
            let (yl, yk) = axisLabelDrill(rows.string(r, yIdx), r, numeric: layout.yNumericBinned, yb, yRef)
            cells.append(HeatmapCell(x: xl, y: yl, value: v, drill: .compound([xk, yk])))
        }
        if cells.isEmpty { return .empty(.allNull) }
        var out = ChartData()
        out.heatmapCells = cells
        out.plottedRowCount = cells.count
        out.totalLoadedRowCount = result.rowCount
        out.wasTruncated = result.hasMore
        return out
    }

    // MARK: - Scatter (`_x, _y` raw points)

    private static func buildScatter(_ result: QueryResult, layout: PushdownLayout) -> ChartData {
        guard let xIdx = colIndex(result, "_x"), let yIdx = colIndex(result, "_y") else {
            return .empty(.noColumns)
        }
        var pts: [ChartPoint] = []
        let rows = result.rows
        for r in rowRange(rows, xIdx, yIdx) {
            guard let x = ValueCoercion.double(from: rows.string(r, xIdx)),
                  let y = ValueCoercion.double(from: rows.string(r, yIdx)) else { continue }
            pts.append(ChartPoint(xLabel: "", xValue: x, y: y))
        }
        if pts.isEmpty { return .empty(.allNull) }
        var out = ChartData()
        out.series = [ChartSeries(name: "", points: pts)]
        out.plottedRowCount = pts.count
        out.totalLoadedRowCount = result.rowCount
        // Sampled when the DB paged more rows off, or the sample filled the cap.
        if let cap = layout.sampleCap { out.wasSampled = result.hasMore || pts.count >= cap }
        return out
    }

    // MARK: - Column lookup helpers

    private static func colIndex(_ result: QueryResult, _ alias: String) -> Int? {
        result.columns.firstIndex { $0.name == alias }
    }

    /// Every row, or none when a column the mark needs is past the table's
    /// last one.
    private static func rowRange(_ rows: ResultTable, _ needed: Int...) -> Range<Int> {
        needed.allSatisfy { $0 < rows.columnCount } ? 0..<rows.rowCount : 0..<0
    }

    /// A cell's text (nil = SQL NULL) as an integer.
    private static func intValue(_ v: String?) -> Int? {
        v.flatMap { Int($0.trimmingCharacters(in: .whitespaces)) }
    }
}
