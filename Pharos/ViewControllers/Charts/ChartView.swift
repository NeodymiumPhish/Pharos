import SwiftUI
import Charts

struct ChartCanvas: View {
    let data: ChartData
    /// The live config, so gestures can resolve x/y/category/label ColumnRefs
    /// (scatter points don't carry per-point drill keys).
    let config: ChartConfig
    /// Reports a drill request (tap/brush/pie selection) up to the view model.
    var onDrill: ([DrillKey]) -> Void = { _ in }

    private var chartType: ChartType { config.chartType }
    private var temporalBin: TemporalBin { config.temporalBin }

    // Pie selection (native angle selection maps to the category label).
    @State private var pieSelection: String?
    // Scatter click callout (chart-local; not a drill — brushing filters instead).
    @State private var scatterSelection: XYPoint?

    var body: some View {
        if let reason = data.emptyReason {
            emptyState(reason)
        } else {
            chart.padding(8)
        }
    }

    @ViewBuilder private var chart: some View {
        switch chartType {
        case .bar:
            categoryChart { BarMark(x: .value("Category", $0.xLabel), y: .value("Value", $0.y)) }
                .chartOverlay { proxy in categoryOverlay(proxy) }
        case .line:
            categoryChart { LineMark(x: .value("Category", $0.xLabel), y: .value("Value", $0.y)) }
                .chartOverlay { proxy in categoryOverlay(proxy) }
        case .area:
            categoryChart { AreaMark(x: .value("Category", $0.xLabel), y: .value("Value", $0.y)) }
                .chartOverlay { proxy in categoryOverlay(proxy) }
        case .pie:     pieChart
        case .scatter: scatterChart
        case .gantt:   ganttChart
        case .heatmap: heatmapChart
        }
    }

    @ViewBuilder private var heatmapChart: some View {
        Chart(data.heatmapCells) { cell in     // HeatmapCell is Identifiable (Task 3)
            RectangleMark(
                x: .value("X", cell.x),
                y: .value("Y", cell.y)
            )
            .foregroundStyle(by: .value("Value", cell.value))
        }
        .chartForegroundStyleScale(range: Gradient(colors: [Color.blue.opacity(0.15), Color.blue]))
        .chartOverlay { proxy in heatmapOverlay(proxy) }
    }

    // Bar/line/area, one MarkContent per point, colored by series.
    @ViewBuilder private func categoryChart<M: ChartContent>(@ChartContentBuilder _ mark: @escaping (ChartPoint) -> M) -> some View {
        Chart {
            ForEach(Array(data.series.enumerated()), id: \.offset) { _, series in
                ForEach(Array(series.points.enumerated()), id: \.offset) { _, pt in
                    mark(pt).foregroundStyle(by: .value("Series", series.name.isEmpty ? "value" : series.name))
                }
            }
        }
    }

    @ViewBuilder private var pieChart: some View {
        Chart(data.series.first?.points ?? [], id: \.xLabel) { pt in
            SectorMark(angle: .value("Value", pt.y), innerRadius: .ratio(0.5))
                .foregroundStyle(by: .value("Category", pt.xLabel))
        }
        .chartAngleSelection(value: $pieSelection)
        .onChange(of: pieSelection) { _, newValue in
            guard let label = newValue,
                  let pt = (data.series.first?.points ?? []).first(where: { $0.xLabel == label }),
                  let drill = pt.drill else { return }
            onDrill([drill])
        }
    }

    // Vectorized scatter (macOS 15+). PointPlot takes the whole collection and
    // renders 100k+ points efficiently, so no per-point ForEach or sampling.
    private struct XYPoint: Identifiable { let id = UUID(); let x: Double; let y: Double }

    private var scatterPoints: [XYPoint] {
        (data.series.first?.points ?? []).map { XYPoint(x: $0.xValue ?? 0, y: $0.y) }
    }

    @ViewBuilder private var scatterChart: some View {
        let pts = scatterPoints
        Chart {
            PointPlot(pts, x: .value("X", \.x), y: .value("Y", \.y))
        }
        .chartOverlay { proxy in
            GeometryReader { geo in
                let origin = proxy.plotFrame.map { geo[$0].origin } ?? .zero
                ZStack(alignment: .topLeading) {
                    Rectangle().fill(Color.clear).contentShape(Rectangle())
                        .gesture(
                            DragGesture(minimumDistance: 0)
                                .onEnded { value in
                                    let sx = value.startLocation.x - origin.x
                                    let ex = value.location.x - origin.x
                                    let sy = value.startLocation.y - origin.y
                                    let ey = value.location.y - origin.y
                                    if abs(value.translation.width) < 6 && abs(value.translation.height) < 6 {
                                        scatterTap(ex, ey, pts: pts, proxy: proxy)
                                    } else {
                                        scatterBrush(sx, ex, sy, ey, proxy: proxy)
                                    }
                                }
                        )
                    if let sel = scatterSelection,
                       let cx = proxy.position(forX: sel.x),
                       let cy = proxy.position(forY: sel.y) {
                        scatterCallout(sel)
                            .position(x: origin.x + cx, y: origin.y + cy - 16)
                    }
                }
            }
        }
    }

    // MARK: - Category (bar/line/area) gesture overlay

    // A single DragGesture(minimumDistance:0) doubles as tap (no travel) and
    // brush (dragged x-span). Locations are converted to plot-relative x via the
    // resolved plot frame, then mapped to category labels through the proxy.
    @ViewBuilder private func categoryOverlay(_ proxy: ChartProxy) -> some View {
        GeometryReader { geo in
            let origin = proxy.plotFrame.map { geo[$0].origin } ?? .zero
            Rectangle().fill(Color.clear).contentShape(Rectangle())
                .gesture(
                    DragGesture(minimumDistance: 0)
                        .onEnded { value in
                            let sx = value.startLocation.x - origin.x
                            let ex = value.location.x - origin.x
                            if abs(value.translation.width) < 6 {
                                if let label = proxy.value(atX: ex, as: String.self) {
                                    categoryTap(label)
                                }
                            } else {
                                categoryBrush(min(sx, ex), max(sx, ex), proxy)
                            }
                        }
                )
        }
    }

    private func categoryTap(_ label: String) {
        for series in data.series {
            if let pt = series.points.first(where: { $0.xLabel == label }), let drill = pt.drill {
                onDrill([drill]); return
            }
        }
    }

    // Collect the distinct categories whose mark falls inside the dragged x-span
    // and emit their drill keys (the translator coalesces same-column anyOf keys).
    private func categoryBrush(_ lo: CGFloat, _ hi: CGFloat, _ proxy: ChartProxy) {
        var keys: [DrillKey] = []
        var seen = Set<String>()
        for series in data.series {
            for pt in series.points where !seen.contains(pt.xLabel) {
                if let px = proxy.position(forX: pt.xLabel), px >= lo, px <= hi, let drill = pt.drill {
                    seen.insert(pt.xLabel); keys.append(drill)
                }
            }
        }
        if !keys.isEmpty { onDrill(keys) }
    }

    // MARK: - Heatmap gesture overlay (two category axes → compound drill)

    @ViewBuilder private func heatmapOverlay(_ proxy: ChartProxy) -> some View {
        GeometryReader { geo in
            let origin = proxy.plotFrame.map { geo[$0].origin } ?? .zero
            Rectangle().fill(Color.clear).contentShape(Rectangle())
                .onTapGesture { location in
                    let px = location.x - origin.x
                    let py = location.y - origin.y
                    guard let xl = proxy.value(atX: px, as: String.self),
                          let yl = proxy.value(atY: py, as: String.self),
                          let cell = data.heatmapCells.first(where: { $0.x == xl && $0.y == yl }),
                          let drill = cell.drill else { return }
                    onDrill([drill])
                }
        }
    }

    // MARK: - Scatter gestures + callout

    // Toggle-style: a tap dismisses an existing callout, otherwise selects the
    // nearest point. No drill on click — brushing a region filters instead.
    private func scatterTap(_ px: CGFloat, _ py: CGFloat, pts: [XYPoint], proxy: ChartProxy) {
        if scatterSelection != nil { scatterSelection = nil; return }
        var best: XYPoint?
        var bestDist = CGFloat.greatestFiniteMagnitude
        for p in pts {
            guard let cx = proxy.position(forX: p.x), let cy = proxy.position(forY: p.y) else { continue }
            let dist = hypot(cx - px, cy - py)
            if dist < bestDist { bestDist = dist; best = p }
        }
        scatterSelection = best
    }

    private func scatterBrush(_ sx: CGFloat, _ ex: CGFloat, _ sy: CGFloat, _ ey: CGFloat, proxy: ChartProxy) {
        guard let xRef = config.mappings[.x],
              let x0 = proxy.value(atX: min(sx, ex), as: Double.self),
              let x1 = proxy.value(atX: max(sx, ex), as: Double.self) else { return }
        var keys: [DrillKey] = [.range(xRef, Swift.min(x0, x1), Swift.max(x0, x1), .numeric)]
        // Optional y-range (screen-y is inverted, so resolve both ends and sort).
        if let yRef = config.mappings[.y],
           let ya = proxy.value(atY: sy, as: Double.self),
           let yb = proxy.value(atY: ey, as: Double.self) {
            keys.append(.range(yRef, Swift.min(ya, yb), Swift.max(ya, yb), .numeric))
        }
        onDrill(keys)
    }

    @ViewBuilder private func scatterCallout(_ p: XYPoint) -> some View {
        Text("(\(fmtNum(p.x)), \(fmtNum(p.y)))")
            .font(.caption2)
            .padding(.horizontal, 5).padding(.vertical, 2)
            .background(RoundedRectangle(cornerRadius: 4).fill(Color(nsColor: .controlBackgroundColor)))
            .overlay(RoundedRectangle(cornerRadius: 4).stroke(Color.secondary.opacity(0.3)))
            .fixedSize()
    }

    private func fmtNum(_ d: Double) -> String {
        d == d.rounded() ? String(Int(d)) : String(format: "%.3g", d)
    }

    // Gantt: each row shows its label on one line with the bar just beneath it,
    // so long labels stay fully readable. The time (x) axis is PINNED to the top
    // of the pane; rows scroll underneath. Bars are full-width, and the pinned
    // header shares the same x-domain, so ticks line up with the bars without any
    // gutter to align. Each row is its own single-bar chart (a few dozen light
    // charts) — fine for typical result sizes.
    private static let ganttBarHeight: CGFloat = 16
    private static let ganttRowSpacing: CGFloat = 12
    private static let ganttAxisHeight: CGFloat = 24
    private static let ganttTickLabelWidth: CGFloat = 72   // est. width of one date label

    private func ganttDomain(_ bars: [GanttBar]) -> ClosedRange<Date> {
        let lo = bars.map(\.start).min() ?? 0
        let hi = bars.map(\.end).max() ?? 1
        return Date(timeIntervalSince1970: lo)...Date(timeIntervalSince1970: max(hi, lo + 1))
    }

    private func binComponent(_ bin: TemporalBin) -> Calendar.Component? {
        switch bin {
        case .hour: return .hour
        case .day: return .day
        case .week: return .weekOfYear
        case .month: return .month
        case .year: return .year
        case .auto, .none: return nil
        }
    }

    /// Snap a raw stride up to a natural multiple so the tick cadence reads cleanly.
    private func niceStep(_ raw: Int, for bin: TemporalBin) -> Int {
        let ladder: [Int]
        switch bin {
        case .hour:  ladder = [1, 2, 3, 6, 12, 24]
        case .day:   ladder = [1, 2, 5, 10, 15, 30]
        case .week:  ladder = [1, 2, 4, 8, 13, 26]
        case .month: ladder = [1, 2, 3, 6, 12, 24, 60]
        case .year:  ladder = [1, 2, 5, 10, 25, 50, 100]
        case .auto, .none: return max(raw, 1)
        }
        return ladder.first(where: { $0 >= raw }) ?? ladder.last ?? max(raw, 1)
    }

    // Tick values for the gantt time axis. Keeps the Time Bucket's unit but widens
    // the stride so the label count fits `maxLabels`, preventing the "…" collapse
    // when a fine bucket spans a long range (e.g. Month over 10 years → yearly).
    private func ganttAxisValues(domain: ClosedRange<Date>, maxLabels: Int) -> AxisMarkValues {
        guard let unit = binComponent(temporalBin) else { return .automatic }
        var cal = Calendar(identifier: .gregorian)
        cal.timeZone = TimeZone(identifier: "UTC")!
        let total = max(cal.dateComponents([unit], from: domain.lowerBound, to: domain.upperBound).value(for: unit) ?? 1, 1)
        let rawStep = max(Int((Double(total) / Double(max(maxLabels, 1))).rounded(.up)), 1)
        return .stride(by: unit, count: niceStep(rawStep, for: temporalBin))
    }

    @ViewBuilder private var ganttChart: some View {
        let bars = data.ganttBars
        let domain = ganttDomain(bars)
        VStack(spacing: 0) {
            // Pinned time-axis header. A height-constrained GeometryReader supplies
            // the pane width so tick density adapts to the space available.
            GeometryReader { geo in
                let maxLabels = max(Int(geo.size.width / Self.ganttTickLabelWidth), 2)
                Chart {
                    RectangleMark(
                        xStart: .value("Start", domain.lowerBound),
                        xEnd: .value("End", domain.upperBound)
                    )
                    .foregroundStyle(.clear)
                }
                .chartXScale(domain: domain)
                .chartXAxis { AxisMarks(position: .top, values: ganttAxisValues(domain: domain, maxLabels: maxLabels)) }
                .chartYAxis(.hidden)
            }
            .frame(height: Self.ganttAxisHeight)

            // Scrolling rows: label on top, bar beneath. Tapping a row drills to
            // that row's label (via the mapped Label column).
            ScrollView(.vertical) {
                VStack(alignment: .leading, spacing: Self.ganttRowSpacing) {
                    ForEach(Array(bars.enumerated()), id: \.offset) { _, bar in
                        VStack(alignment: .leading, spacing: 2) {
                            Text(bar.label).font(.callout).lineLimit(1)
                            Chart {
                                BarMark(
                                    xStart: .value("Start", Date(timeIntervalSince1970: bar.start)),
                                    xEnd: .value("End", Date(timeIntervalSince1970: bar.end))
                                )
                            }
                            .chartXScale(domain: domain)
                            .chartXAxis(.hidden)
                            .chartYAxis(.hidden)
                            .frame(height: Self.ganttBarHeight)
                        }
                        .contentShape(Rectangle())
                        .onTapGesture { ganttTap(bar) }
                    }
                }
                .padding(.top, 6)
            }
        }
    }

    private func ganttTap(_ bar: GanttBar) {
        guard let labelRef = config.mappings[.label] else { return }
        onDrill([.anyOf(labelRef, [bar.label])])
    }

    @ViewBuilder private func emptyState(_ reason: EmptyReason) -> some View {
        VStack(spacing: 6) {
            Image(systemName: "chart.bar.xaxis").font(.largeTitle).foregroundStyle(.tertiary)
            Text(message(reason)).foregroundStyle(.secondary).multilineTextAlignment(.center)
        }.frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private func message(_ reason: EmptyReason) -> String {
        switch reason {
        case .noColumns: return "Pick columns to chart."
        case .allNull: return "The selected value column is all null."
        case .noData: return "This result's rows weren't saved. Re-run the query to chart it."
        }
    }
}
