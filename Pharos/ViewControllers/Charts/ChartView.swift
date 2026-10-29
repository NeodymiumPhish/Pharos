import SwiftUI
import Charts
import AppKit

struct ChartCanvas: View {
    let data: ChartData
    /// The live config, so gestures can resolve x/y/category/label ColumnRefs
    /// (scatter points don't carry per-point drill keys).
    let config: ChartConfig
    /// Reports the current *staged* selection (post-merge) up to the host; the
    /// host/VC commit it when the action-bar button is pressed. `[]` = cleared.
    var onSelectionChanged: ([DrillKey]) -> Void = { _ in }
    /// The committed chart filter's keys (from the VC) — used to light marks when
    /// no live selection is staged.
    var committedKeys: [DrillKey] = []
    /// Bumped by the VC to clear the staged selection (post-commit / Esc).
    var clearToken: Int = 0
    /// Identity of the current config; changing it clears the staged selection.
    var configFingerprint: String = ""
    /// When false, the gantt shows every lane and the whole range with no
    /// chart scrolling, so ImageRenderer captures every bar on export (a
    /// scrolled region renders empty off-screen). On-screen use scrolls.
    var ganttScrollable: Bool = true

    /// The app-wide default series palette (hex). Per-chart overrides in
    /// `config.seriesColors` take precedence. Defaulted so non-updated call
    /// sites still compile.
    var globalPalette: [String] = ChartPalette.defaultHex

    private var chartType: ChartType { config.chartType }
    private var temporalBin: TemporalBin { config.temporalBin }

    /// Color domain for bar/line/area (delegates to the shared source of truth).
    private var categorySeriesNames: [String] { data.colorDomainLabels(for: chartType) }
    /// Pie color domain (delegates to the shared source of truth).
    private var pieLabels: [String] { data.colorDomainLabels(for: .pie) }
    /// The single resolved color for scatter (no per-series split).
    private var scatterColor: Color {
        resolvedColors(count: 1).first ?? .accentColor
    }
    /// Resolved series colors for `count` domain entries: the per-chart override
    /// (`config.seriesColors`) if set, else the global palette.
    private func resolvedColors(count: Int) -> [Color] {
        ChartPalette.resolveColors(override: config.seriesColors, global: globalPalette, count: count)
    }

    // Pie selection (native angle selection maps to the category label).
    @State private var pieSelection: String?
    // Scatter click callout (chart-local; not a drill — brushing filters instead).
    @State private var scatterSelection: XYPoint?
    // Hover tooltips: the category under the pointer (bar/line/area) and the
    // hovered heatmap cell id. Nil once the pointer leaves the plot.
    @State private var hoverCategory: String?
    @State private var hoverCellID: String?
    @State private var ganttHoverPoint: CGPoint?   // pointer in the chart's own space

    // Staged-selection scaffold (B1). Marks tracked by stable ID; range/brush
    // selections carried as a merged key set. B2 fleshes out per-type gestures.
    @State private var selectedIDs: Set<String> = []
    @State private var anchorID: String? = nil
    @State private var rangeSel: RangeSelection? = nil
    @State private var marquee: CGRect? = nil

    struct RangeSelection: Equatable {
        var keys: [DrillKey]
        var xLo: Double; var xHi: Double
        var yLo: Double?; var yHi: Double?
    }

    // MARK: - Selection model (B1 scaffold)

    private struct Mark { let id: String; let drill: DrillKey? }

    private var marks: [Mark] {
        switch chartType {
        case .bar, .line, .area:
            return data.series.flatMap { s in s.points.map { Mark(id: "\($0.xLabel)\u{1}\(s.name)", drill: $0.drill) } }
        case .pie:
            return (data.series.first?.points ?? []).map { Mark(id: "\($0.xLabel)\u{1}", drill: $0.drill) }
        case .heatmap:
            return data.heatmapCells.map { Mark(id: $0.id, drill: $0.drill) }
        case .gantt:
            // A lane (tap beside its bars) and each bar (tap on it) are marks.
            var laneMarks: [Mark] = []; var seen = Set<String>()
            for bar in data.ganttBars where seen.insert(bar.lane).inserted {
                laneMarks.append(Mark(id: Self.ganttLaneID(bar.lane), drill: bar.laneDrill))
            }
            return laneMarks + data.ganttBars.indices.map { Mark(id: Self.ganttBarID($0), drill: data.ganttBars[$0].drill) }
        case .scatter:
            return []
        }
    }

    private var stagedKeys: [DrillKey] {
        if let r = rangeSel { return r.keys }
        let keys = marks.filter { selectedIDs.contains($0.id) }.compactMap { $0.drill }
        return DrillMerge.merge(keys)
    }
    private var hasStagedSelection: Bool { !selectedIDs.isEmpty || rangeSel != nil }
    private func report() { onSelectionChanged(stagedKeys) }
    private func clearSelection() { selectedIDs = []; anchorID = nil; rangeSel = nil; marquee = nil; report() }

    private func stageSingle(_ ids: [String]) { selectedIDs = Set(ids); anchorID = ids.last; rangeSel = nil; report() }
    private func stageToggle(_ ids: [String]) {
        for id in ids { if selectedIDs.contains(id) { selectedIDs.remove(id) } else { selectedIDs.insert(id) } }
        anchorID = ids.last; rangeSel = nil; report()
    }
    /// Modifier dispatch: ⌘ toggles, Shift replaces with the range (via `rangeIDs`),
    /// plain replaces with `hitIDs`. `hitIDs` may expand a category to all its series.
    private func applyModifier(hitIDs: [String], rangeIDs: () -> [String]) {
        let m = NSEvent.modifierFlags
        if m.contains(.command) { stageToggle(hitIDs) }
        else if m.contains(.shift), anchorID != nil { selectedIDs = Set(rangeIDs()); rangeSel = nil; report() }
        else { stageSingle(hitIDs) }
    }

    // MARK: - Lit/dimmed preview (merged coverage)

    /// Keys driving dimming: the live staged selection if present, else the
    /// committed filter (so a committed filter stays visible on return to chart).
    private var effectiveKeys: [DrillKey] { hasStagedSelection ? stagedKeys : committedKeys }

    private func isLit(_ drill: DrillKey?) -> Bool {
        if effectiveKeys.isEmpty { return true }   // nothing selected → all lit
        guard let d = drill else { return false }
        return DrillCoverage.covers(effectiveKeys, d)
    }

    /// A bar is lit when the selection covers the bar's rows, or covers its
    /// lane and says nothing about the segment columns (a lane selection).
    private func ganttBarLit(_ bar: GanttBar) -> Bool {
        if let r = rangeSel { return bar.start <= r.xHi && bar.end >= r.xLo }   // time-axis overlap window
        if effectiveKeys.isEmpty { return true }
        if let d = bar.drill, DrillCoverage.covers(effectiveKeys, d) { return true }
        let segmentColumns = Set(config.columns(for: .segment).map(\.index))
        let selectsSegment = effectiveKeys.flatMap(\.columnRefs).contains { segmentColumns.contains($0.index) }
        guard !selectsSegment, let lane = bar.laneDrill else { return false }
        return DrillCoverage.covers(effectiveKeys, lane)
    }

    @ViewBuilder private func marqueeOverlay(origin: CGPoint) -> some View {
        if let m = marquee {
            Rectangle().fill(Color.accentColor.opacity(0.12))
                .overlay(Rectangle().stroke(style: StrokeStyle(lineWidth: 1.5, dash: [4])).foregroundStyle(Color.accentColor))
                .frame(width: max(m.width, 1), height: max(m.height, 1))
                .position(x: origin.x + m.midX, y: origin.y + m.midY)
                .allowsHitTesting(false)
        }
    }

    var body: some View {
        if let reason = data.emptyReason {
            emptyState(reason)
        } else {
            VStack(alignment: .leading, spacing: 4) {
                if !chartTitle.isEmpty { Text(chartTitle).font(.headline).lineLimit(1) }
                chart
            }
            .padding(8)
            .onChange(of: clearToken) { _, _ in clearSelection() }
            .onChange(of: configFingerprint) { _, _ in clearSelection() }
        }
    }

    @ViewBuilder private var chart: some View {
        switch chartType {
        case .bar:
            // Multi-series bars stack by default; `.grouped` sets them side by side.
            let grouped = config.display.barLayout == .grouped && data.series.count > 1
            categoryChart { pt, name in
                if grouped {
                    BarMark(x: .value("Category", pt.xLabel), y: .value("Value", pt.y))
                        .position(by: .value("Series", name))
                } else {
                    BarMark(x: .value("Category", pt.xLabel), y: .value("Value", pt.y))
                }
            }
        case .line:
            categoryChart { pt, _ in LineMark(x: .value("Category", pt.xLabel), y: .value("Value", pt.y)) }
        case .area:
            categoryChart { pt, _ in AreaMark(x: .value("Category", pt.xLabel), y: .value("Value", pt.y)) }
        case .pie:     pieChart
        case .scatter: scatterChart
        case .gantt:   ganttChart
        case .heatmap: heatmapChart
        }
    }

    // MARK: - Display options (title, legend, axis titles, scales)

    private var chartTitle: String { config.display.title.trimmingCharacters(in: .whitespaces) }
    private var axisTitles: ChartAxisTitles.Titles { ChartAxisTitles.resolve(config) }

    /// Bar/line/area legend: hidden when asked, and also for a lone unnamed
    /// series — one entry reading "value" is noise.
    private var categoryLegendVisible: Bool {
        guard config.display.showLegend else { return false }
        return !(data.series.count == 1 && data.series[0].name.isEmpty)
    }

    /// True when the log-scale flag can be honoured: every plotted y is > 0.
    /// Pure, so the config rail can call it to enable/disable its toggle.
    static func canUseLogScale(_ data: ChartData, chartType: ChartType) -> Bool {
        switch chartType {
        case .bar, .line, .area, .scatter:
            let ys = data.series.flatMap { $0.points.map(\.y) }
            return !ys.isEmpty && ys.allSatisfy { $0 > 0 }
        case .pie, .gantt, .heatmap:
            return false
        }
    }
    private var useLogScale: Bool { config.display.logScale && Self.canUseLogScale(data, chartType: chartType) }

    /// The largest |y| the Y axis must label: stacked totals per category for
    /// multi-series stacked bars, else the largest single point.
    private var maxAbsY: Double {
        if chartType == .bar, data.series.count > 1, config.display.barLayout == .stacked {
            var totals: [String: Double] = [:]
            for s in data.series { for p in s.points { totals[p.xLabel, default: 0] += p.y } }
            return totals.values.map(abs).max() ?? 0
        }
        return data.series.flatMap { $0.points.map { abs($0.y) } }.max() ?? 0
    }

    /// Y axis on the leading edge with gridlines; compact notation ("12K")
    /// only once values reach 10,000 so small values keep their digits.
    private func yAxisMarks() -> some AxisContent {
        let compact = maxAbsY >= 10_000
        return AxisMarks(position: .leading) { _ in
            AxisGridLine()
            AxisTick()
            if compact {
                AxisValueLabel(format: FloatingPointFormatStyle<Double>.number.notation(.compactName))
            } else {
                AxisValueLabel()
            }
        }
    }

    private static let xLabelMaxChars = 24

    /// Many or long categories: turn the labels vertical so they stop
    /// colliding; long labels are cut to 24 characters with an ellipsis.
    private var xAxisRotated: Bool {
        let cats = orderedCategories
        return cats.count > 12 || cats.contains { $0.count > 12 }
    }
    private var xAxisNeedsCustomMarks: Bool {
        xAxisRotated || orderedCategories.contains { $0.count > Self.xLabelMaxChars }
    }
    private static func truncatedLabel(_ s: String) -> String {
        s.count > xLabelMaxChars ? String(s.prefix(xLabelMaxChars - 1)) + "\u{2026}" : s
    }
    private func xAxisMarks() -> some AxisContent {
        let orientation: AxisValueLabelOrientation = xAxisRotated ? .vertical : .automatic
        return AxisMarks { value in
            AxisGridLine()
            AxisTick()
            AxisValueLabel(orientation: orientation) {
                if let s = value.as(String.self) { Text(Self.truncatedLabel(s)) }
            }
        }
    }

    @ViewBuilder private var heatmapChart: some View {
        Chart {
            ForEach(data.heatmapCells) { cell in     // HeatmapCell is Identifiable (Task 3)
                RectangleMark(
                    x: .value("X", cell.x),
                    y: .value("Y", cell.y)
                )
                .foregroundStyle(by: .value("Value", cell.value))
                .opacity(isLit(cell.drill) ? 1 : 0.2)
            }
            // Hover tooltip: a clear mark over the hovered cell carries the callout.
            if let id = hoverCellID, let cell = data.heatmapCells.first(where: { $0.id == id }) {
                RectangleMark(x: .value("X", cell.x), y: .value("Y", cell.y))
                    .foregroundStyle(.clear)
                    .annotation(position: .top, alignment: .center, spacing: 4,
                                overflowResolution: .init(x: .fit(to: .chart), y: .disabled)) {
                        callout { Text("\(cell.x) \u{00B7} \(cell.y) \u{2014} \(fmtNum(cell.value))") }
                    }
            }
        }
        .chartForegroundStyleScale(range: Gradient(colors: [Color.blue.opacity(0.15), Color.blue]))
        .chartLegend(config.display.showLegend ? .visible : .hidden)
        .axisTitles(axisTitles)
        .chartOverlay { proxy in heatmapOverlay(proxy) }
    }

    // Bar/line/area, one MarkContent per point, colored by series. The mark
    // builder receives the point and its legend series name.
    private func categoryChart<M: ChartContent>(@ChartContentBuilder _ mark: @escaping (ChartPoint, String) -> M) -> some View {
        let names = categorySeriesNames
        let colors = resolvedColors(count: names.count)
        return Chart {
            ForEach(Array(data.series.enumerated()), id: \.offset) { _, series in
                let name = series.name.isEmpty ? "value" : series.name
                ForEach(Array(series.points.enumerated()), id: \.offset) { _, pt in
                    mark(pt, name).foregroundStyle(by: .value("Series", name))
                        .opacity(isLit(pt.drill) ? 1 : 0.2)
                }
            }
            if let cat = hoverCategory { hoverRule(cat) }
        }
        .chartForegroundStyleScale(domain: names, range: colors)
        .chartLegend(categoryLegendVisible ? .visible : .hidden)
        .axisTitles(axisTitles)
        .chartYAxis { yAxisMarks() }
        .when(xAxisNeedsCustomMarks) { $0.chartXAxis { xAxisMarks() } }
        .when(useLogScale) { $0.chartYScale(type: .log) }
        .chartOverlay { proxy in categoryOverlay(proxy) }
    }

    // MARK: - Hover callouts (bar/line/area)

    // A faint vertical rule at the hovered category, with the values of every
    // series at that category pinned to the top of the plot.
    @ChartContentBuilder private func hoverRule(_ cat: String) -> some ChartContent {
        RuleMark(x: .value("Category", cat))
            .foregroundStyle(.secondary.opacity(0.35))
            .annotation(position: .top, alignment: .center, spacing: 4,
                        overflowResolution: .init(x: .fit(to: .chart), y: .disabled)) {
                categoryCallout(cat)
            }
    }

    @ViewBuilder private func categoryCallout(_ cat: String) -> some View {
        let rows: [(String, Double)] = data.series.compactMap { s in
            s.points.first(where: { $0.xLabel == cat }).map { (s.name, $0.y) }
        }
        callout {
            VStack(alignment: .leading, spacing: 1) {
                Text(cat).font(.caption.bold())
                if rows.count == 1 {
                    Text(fmtNum(rows[0].1))
                } else {
                    ForEach(Array(rows.enumerated()), id: \.offset) { _, row in
                        Text("\(row.0)  \(fmtNum(row.1))")
                    }
                }
            }
        }
    }

    /// The shared callout chrome: rounded, control-background fill, thin stroke.
    private func callout<V: View>(@ViewBuilder _ content: () -> V) -> some View {
        content()
            .font(.caption2)
            .padding(.horizontal, 5).padding(.vertical, 2)
            .background(RoundedRectangle(cornerRadius: 4).fill(Color(nsColor: .controlBackgroundColor)))
            .overlay(RoundedRectangle(cornerRadius: 4).stroke(Color.secondary.opacity(0.3)))
            .fixedSize()
    }

    @ViewBuilder private var pieChart: some View {
        Chart(data.series.first?.points ?? [], id: \.xLabel) { pt in
            SectorMark(angle: .value("Value", pt.y), innerRadius: .ratio(0.5))
                .foregroundStyle(by: .value("Category", pt.xLabel))
                .opacity(isLit(pt.drill) ? 1 : 0.2)
        }
        .chartForegroundStyleScale(
            domain: pieLabels,
            range: resolvedColors(count: pieLabels.count)
        )
        .chartLegend(config.display.showLegend ? .visible : .hidden)
        .chartAngleSelection(value: $pieSelection)
        .onChange(of: pieSelection) { _, newValue in
            guard let label = newValue else { clearSelection(); return }
            let id = "\(label)\u{1}"
            let order = (data.series.first?.points ?? []).map { "\($0.xLabel)\u{1}" }
            applyModifier(hitIDs: [id]) {
                guard let a = anchorID, let ia = order.firstIndex(of: a), let ib = order.firstIndex(of: id) else { return [id] }
                return Array(order[min(ia, ib)...max(ia, ib)])
            }
        }
    }

    // Vectorized scatter (macOS 15+). PointPlot takes the whole collection and
    // renders 100k+ points efficiently, so no per-point ForEach or sampling.
    // With a mapped size column the points render one by one (PointMark +
    // symbolSize), so the aggregator caps that path at 5,000 points.
    private struct XYPoint: Identifiable { let id = UUID(); let x: Double; let y: Double; var size: Double? = nil }

    private var scatterPoints: [XYPoint] {
        (data.series.first?.points ?? []).map { XYPoint(x: $0.xValue ?? 0, y: $0.y, size: $0.size) }
    }

    @ViewBuilder private var scatterChart: some View {
        let pts = scatterPoints
        let sized = pts.contains { $0.size != nil }
        let inR: (XYPoint) -> Bool = { p in
            guard let r = rangeSel else { return true }
            return r.xLo <= p.x && p.x <= r.xHi && (r.yLo == nil || (r.yLo! <= p.y && p.y <= r.yHi!))
        }
        Chart {
            if sized {
                ForEach(pts) { p in
                    PointMark(x: .value("X", p.x), y: .value("Y", p.y))
                        .symbolSize(by: .value("Size", p.size ?? 0))
                        .foregroundStyle(scatterColor)
                        .opacity(inR(p) ? 1 : 0.2)
                }
            } else if rangeSel != nil {
                let inside = pts.filter(inR); let outside = pts.filter { !inR($0) }
                PointPlot(outside, x: .value("X", \.x), y: .value("Y", \.y)).foregroundStyle(.gray.opacity(0.2))
                PointPlot(inside, x: .value("X", \.x), y: .value("Y", \.y)).foregroundStyle(scatterColor)
            } else {
                PointPlot(pts, x: .value("X", \.x), y: .value("Y", \.y)).foregroundStyle(scatterColor)
            }
        }
        .when(sized) { $0.chartSymbolSizeScale(range: 20...400) }
        .axisTitles(axisTitles)
        .chartYAxis { yAxisMarks() }
        .when(useLogScale) { $0.chartYScale(type: .log) }
        .chartOverlay { proxy in
            GeometryReader { geo in
                let origin = proxy.plotFrame.map { geo[$0].origin } ?? .zero
                ZStack(alignment: .topLeading) {
                    Rectangle().fill(Color.clear).contentShape(Rectangle())
                        .gesture(
                            DragGesture(minimumDistance: 0)
                                .onChanged { value in
                                    let sx = value.startLocation.x - origin.x, ex = value.location.x - origin.x
                                    let sy = value.startLocation.y - origin.y, ey = value.location.y - origin.y
                                    marquee = CGRect(x: min(sx, ex), y: min(sy, ey), width: abs(ex - sx), height: abs(ey - sy))
                                }
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
                                    marquee = nil
                                }
                        )
                    marqueeOverlay(origin: origin)
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
            let plotHeight = proxy.plotFrame.map { geo[$0].height } ?? geo.size.height
            ZStack(alignment: .topLeading) {
                Rectangle().fill(Color.clear).contentShape(Rectangle())
                    // Hover and drag share one rectangle so tooltips never steal clicks.
                    .onContinuousHover { phase in
                        switch phase {
                        case .active(let p):
                            let cat = proxy.value(atX: p.x - origin.x, as: String.self)
                            if hoverCategory != cat { hoverCategory = cat }
                        case .ended:
                            hoverCategory = nil
                        }
                    }
                    .gesture(
                        DragGesture(minimumDistance: 0)
                            .onChanged { value in
                                let sx = value.startLocation.x - origin.x, ex = value.location.x - origin.x
                                marquee = CGRect(x: min(sx, ex), y: 0, width: abs(ex - sx), height: plotHeight)
                            }
                            .onEnded { value in
                                let sx = value.startLocation.x - origin.x
                                let ex = value.location.x - origin.x
                                if abs(value.translation.width) < 6 {
                                    if let label = proxy.value(atX: ex, as: String.self) {
                                        categoryTap(label, atY: value.location.y - origin.y, proxy: proxy)
                                    } else {
                                        clearSelection()
                                    }
                                } else {
                                    categoryBrush(min(sx, ex), max(sx, ex), proxy)
                                }
                                marquee = nil
                            }
                    )
                marqueeOverlay(origin: origin)
            }
        }
    }

    // Resolve which series (if any) the tap hit, then drill that series' point
    // (category AND series). Stacked bars: map the tapped y-value to the
    // cumulative series band. Line/area: nearest series by value. Single-series
    // or grouped/ambiguous: category-only.
    private var orderedCategories: [String] {
        var seen = Set<String>(); var out: [String] = []
        for s in data.series { for p in s.points where !seen.contains(p.xLabel) { seen.insert(p.xLabel); out.append(p.xLabel) } }
        return out
    }
    private func idsForCategory(_ cat: String) -> [String] { data.series.map { "\(cat)\u{1}\($0.name)" } }
    private func categoryOf(_ id: String) -> String { String(id.split(separator: "\u{1}", maxSplits: 1, omittingEmptySubsequences: false).first ?? "") }

    private func categoryTap(_ label: String, atY py: CGFloat, proxy: ChartProxy) {
        let series = resolveHitSeries(label: label, atY: py, proxy: proxy)
        let hitIDs = series.isEmpty ? idsForCategory(label) : ["\(label)\u{1}\(series)"]
        applyModifier(hitIDs: hitIDs) {
            let cats = orderedCategories
            guard let a = anchorID.map({ categoryOf($0) }), let ia = cats.firstIndex(of: a), let ib = cats.firstIndex(of: label) else { return hitIDs }
            return cats[min(ia, ib)...max(ia, ib)].flatMap { idsForCategory($0) }
        }
    }

    private func resolveHitSeries(label: String, atY py: CGFloat, proxy: ChartProxy) -> String {
        guard data.series.count > 1, let tv = proxy.value(atY: py, as: Double.self) else {
            return data.series.count == 1 ? data.series[0].name : ""
        }
        switch chartType {
        case .bar:
            // Stacked bars: a click resolves to the band containing the tapped y,
            // giving band-precise selection. Grouped bars sit side by side, so the
            // y alone cannot name a series — fall back to category-only.
            if config.display.barLayout == .grouped { return "" }
            var acc = 0.0
            for s in data.series { if let pt = s.points.first(where: { $0.xLabel == label }) { acc += pt.y; if tv <= acc { return s.name } } }
            return ""
        case .line, .area:
            return data.series.min(by: { s1, s2 in
                let y1 = s1.points.first(where: { $0.xLabel == label })?.y ?? .infinity
                let y2 = s2.points.first(where: { $0.xLabel == label })?.y ?? .infinity
                return abs(y1 - tv) < abs(y2 - tv)
            })?.name ?? ""
        default:
            return ""
        }
    }

    // Collect the distinct categories whose mark falls inside the dragged x-span
    // and stage all their series IDs.
    private func categoryBrush(_ lo: CGFloat, _ hi: CGFloat, _ proxy: ChartProxy) {
        var ids: [String] = []
        for cat in orderedCategories {
            if let px = proxy.position(forX: cat), px >= lo, px <= hi { ids.append(contentsOf: idsForCategory(cat)) }
        }
        selectedIDs = Set(ids); anchorID = ids.last; rangeSel = nil; report()
    }

    // MARK: - Heatmap gesture overlay (two category axes → compound drill)

    @ViewBuilder private func heatmapOverlay(_ proxy: ChartProxy) -> some View {
        GeometryReader { geo in
            let origin = proxy.plotFrame.map { geo[$0].origin } ?? .zero
            ZStack(alignment: .topLeading) {
                Rectangle().fill(Color.clear).contentShape(Rectangle())
                    // Hover and drag share one rectangle so tooltips never steal clicks.
                    .onContinuousHover { phase in
                        switch phase {
                        case .active(let p):
                            var id: String? = nil
                            if let xl = proxy.value(atX: p.x - origin.x, as: String.self),
                               let yl = proxy.value(atY: p.y - origin.y, as: String.self) {
                                id = data.heatmapCells.first(where: { $0.x == xl && $0.y == yl })?.id
                            }
                            if hoverCellID != id { hoverCellID = id }
                        case .ended:
                            hoverCellID = nil
                        }
                    }
                    .gesture(DragGesture(minimumDistance: 0)
                        .onChanged { v in
                            let sx = v.startLocation.x - origin.x, ex = v.location.x - origin.x
                            let sy = v.startLocation.y - origin.y, ey = v.location.y - origin.y
                            marquee = CGRect(x: min(sx, ex), y: min(sy, ey), width: abs(ex - sx), height: abs(ey - sy))
                        }
                        .onEnded { v in
                            let sx = v.startLocation.x - origin.x, ex = v.location.x - origin.x
                            let sy = v.startLocation.y - origin.y, ey = v.location.y - origin.y
                            if abs(v.translation.width) < 6 && abs(v.translation.height) < 6 {
                                heatmapTap(ex, ey, proxy)
                            } else {
                                heatmapBrush(min(sx, ex), max(sx, ex), min(sy, ey), max(sy, ey), proxy)
                            }
                            marquee = nil
                        })
                marqueeOverlay(origin: origin)
            }
        }
    }

    private var orderedHeatX: [String] { var s = Set<String>(); var o: [String] = []; for c in data.heatmapCells where !s.contains(c.x) { s.insert(c.x); o.append(c.x) }; return o }
    private var orderedHeatY: [String] { var s = Set<String>(); var o: [String] = []; for c in data.heatmapCells where !s.contains(c.y) { s.insert(c.y); o.append(c.y) }; return o }

    private func heatmapTap(_ px: CGFloat, _ py: CGFloat, _ proxy: ChartProxy) {
        guard let xl = proxy.value(atX: px, as: String.self), let yl = proxy.value(atY: py, as: String.self),
              let cell = data.heatmapCells.first(where: { $0.x == xl && $0.y == yl }) else { clearSelection(); return }
        applyModifier(hitIDs: [cell.id]) {
            guard let a = anchorID, let ac = data.heatmapCells.first(where: { $0.id == a }) else { return [cell.id] }
            let xs = orderedHeatX, ys = orderedHeatY
            guard let ax = xs.firstIndex(of: ac.x), let bx = xs.firstIndex(of: xl),
                  let ay = ys.firstIndex(of: ac.y), let by = ys.firstIndex(of: yl) else { return [cell.id] }
            let xset = Set(xs[min(ax, bx)...max(ax, bx)]); let yset = Set(ys[min(ay, by)...max(ay, by)])
            return data.heatmapCells.filter { xset.contains($0.x) && yset.contains($0.y) }.map { $0.id }
        }
    }

    private func heatmapBrush(_ xlo: CGFloat, _ xhi: CGFloat, _ ylo: CGFloat, _ yhi: CGFloat, _ proxy: ChartProxy) {
        var ids: [String] = []
        for cell in data.heatmapCells {
            if let cx = proxy.position(forX: cell.x), let cy = proxy.position(forY: cell.y),
               cx >= xlo, cx <= xhi, cy >= ylo, cy <= yhi { ids.append(cell.id) }
        }
        selectedIDs = Set(ids); anchorID = ids.last; rangeSel = nil; report()
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
        clearSelection()   // a click (no drag) clears any prior staged range selection
    }

    private func scatterBrush(_ sx: CGFloat, _ ex: CGFloat, _ sy: CGFloat, _ ey: CGFloat, proxy: ChartProxy) {
        guard let xRef = config.mappings[.x],
              let x0 = proxy.value(atX: min(sx, ex), as: Double.self),
              let x1 = proxy.value(atX: max(sx, ex), as: Double.self) else { return }
        var keys: [DrillKey] = [.range(xRef, Swift.min(x0, x1), Swift.max(x0, x1), .numeric)]
        // Optional y-range (screen-y is inverted, so resolve both ends and sort).
        var yLo: Double? = nil, yHi: Double? = nil
        if let yRef = config.mappings[.y],
           let ya = proxy.value(atY: sy, as: Double.self),
           let yb = proxy.value(atY: ey, as: Double.self) {
            keys.append(.range(yRef, Swift.min(ya, yb), Swift.max(ya, yb), .numeric))
            yLo = Swift.min(ya, yb); yHi = Swift.max(ya, yb)
        }
        rangeSel = RangeSelection(keys: keys, xLo: Swift.min(x0, x1), xHi: Swift.max(x0, x1), yLo: yLo, yHi: yHi)
        selectedIDs = []; anchorID = nil; report()
    }

    @ViewBuilder private func scatterCallout(_ p: XYPoint) -> some View {
        callout {
            if let s = p.size {
                Text("(\(fmtNum(p.x)), \(fmtNum(p.y))) \u{00B7} \(fmtNum(s))")
            } else {
                Text("(\(fmtNum(p.x)), \(fmtNum(p.y)))")
            }
        }
    }

    private func fmtNum(_ d: Double) -> String {
        d == d.rounded() ? String(Int(d)) : String(format: "%.3g", d)
    }

    // Gantt: ONE chart, a lane per row on the Y axis and bars along a time X
    // axis pinned to the top. Lanes sit on a NUMERIC Y axis (lane i spans
    // -i-1...-i, so lane 0 is at the top) with a label at each lane's centre:
    // a categorical Y axis put its labels on the band edge, half a lane above
    // their bars, and drew them inside the plot. Swift Charts scrolls the plot on both axes while
    // the lane labels (Y axis) and the time axis stay in place. Each Time Bucket
    // unit gets a minimum width (times the rail's zoom); a range wider than the
    // pane scrolls instead of being squeezed. Export renders every lane and the
    // whole range (no scrolling: ImageRenderer cannot capture a scroll view).
    private static let ganttBarHeight: CGFloat = 16
    private static let ganttLanePitch: CGFloat = 28
    private static let ganttAxisHeight: CGFloat = 24
    private static let ganttLegendHeight: CGFloat = 22
    private static let ganttTickLabelWidth: CGFloat = 72   // est. width of one date label
    private static let ganttPointsPerUnit: CGFloat = 12    // automatic width of one Time Bucket unit
    private static let ganttMinBarWidth: CGFloat = 3       // a one-instant bar stays visible
    private static let ganttLaneLabelMaxWidth: CGFloat = 220

    static func ganttLaneID(_ lane: String) -> String { "L\u{1}" + lane }
    static func ganttBarID(_ index: Int) -> String { "B\u{1}\(index)" }

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

    /// Average length of one Time Bucket unit in seconds (nil = no bucket: fit).
    private func unitSeconds(_ bin: TemporalBin) -> Double? {
        switch bin {
        case .hour: return 3_600
        case .day: return 86_400
        case .week: return 604_800
        case .month: return 2_629_746
        case .year: return 31_556_952
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
    // the stride so the labels in the VISIBLE span fit `maxLabels`. A stride
    // longer than the ladder allows (a fine bucket over a long fitted range)
    // falls back to automatic ticks instead of crowding hundreds of labels.
    private func ganttAxisValues(visibleSeconds: Double, maxLabels: Int) -> AxisMarkValues {
        guard let unit = binComponent(temporalBin), let secs = unitSeconds(temporalBin) else { return .automatic }
        let total = max(Int((visibleSeconds / secs).rounded(.up)), 1)
        let rawStep = max(Int((Double(total) / Double(max(maxLabels, 1))).rounded(.up)), 1)
        let step = niceStep(rawStep, for: temporalBin)
        if step < rawStep { return .automatic(desiredCount: maxLabels) }
        return .stride(by: unit, count: step)
    }

    /// The span of X the pane shows at once, in axis units (seconds or raw
    /// numbers): the whole range at Fit (zoom 0) or with no Time Bucket, else the
    /// automatic width per unit times the zoom — never more than the whole range.
    private func ganttVisibleSeconds(domain: ClosedRange<Date>, plotWidth: CGFloat) -> Double {
        let whole = domain.upperBound.timeIntervalSince(domain.lowerBound)
        let zoom = config.display.ganttZoom
        guard zoom > 0, data.ganttAxisKind == .temporal, let secs = unitSeconds(temporalBin) else { return whole }
        let units = Double(plotWidth / (Self.ganttPointsPerUnit * CGFloat(zoom)))
        return min(whole, max(units * secs, 1))
    }

    /// Estimated Y-axis label width: the longest lane, capped.
    private func ganttLaneLabelWidth(_ lanes: [String]) -> CGFloat {
        let longest = lanes.map(\.count).max() ?? 0
        return min(CGFloat(longest) * 7 + 12, Self.ganttLaneLabelMaxWidth)
    }

    /// A lane label short enough for the Y axis (the middle goes first).
    private func truncatedLane(_ lane: String) -> String {
        let limit = Int(Self.ganttLaneLabelMaxWidth / 7)
        guard lane.count > limit else { return lane }
        return String(lane.prefix(limit / 2 - 1)) + "…" + String(lane.suffix(limit / 2 - 1))
    }

    /// Segment value colours: the per-chart override, else the global palette.
    private var ganttSegments: [String] { data.colorDomainLabels(for: .gantt) }
    private var ganttLegendVisible: Bool { config.display.showLegend && !ganttSegments.isEmpty }

    /// A short legend / tooltip title for a segment: first line of each value.
    private func shortSegment(_ bar: GanttBar) -> String {
        bar.segmentValues.map { v in
            let line = v.split(separator: "\n", maxSplits: 1).first.map(String.init) ?? ""
            return line.count > 40 ? String(line.prefix(39)) + "…" : line
        }.joined(separator: ChartAggregator.ganttValueSeparator)
    }

    private func ganttValueText(_ v: Double) -> String {
        data.ganttAxisKind == .temporal
            ? Date(timeIntervalSince1970: v).formatted(date: .abbreviated, time: .shortened)
            : fmtNum(v)
    }

    @ViewBuilder private var ganttChart: some View {
        let bars = data.ganttBars
        let lanes = data.ganttLanes
        let domain = ganttDomain(bars)
        GeometryReader { geo in
            let legend: CGFloat = ganttLegendVisible ? Self.ganttLegendHeight : 0
            let plotWidth = max(geo.size.width - ganttLaneLabelWidth(lanes) - 8, 40)
            let visible = ganttVisibleSeconds(domain: domain, plotWidth: plotWidth)
            let maxLabels = max(Int(plotWidth / Self.ganttTickLabelWidth), 2)
            let fitLanes = max(Int((geo.size.height - Self.ganttAxisHeight - legend) / Self.ganttLanePitch), 1)
            let shownLanes = ganttScrollable ? min(lanes.count, fitLanes) : lanes.count
            let chartHeight = Self.ganttAxisHeight + legend + CGFloat(max(shownLanes, 1)) * Self.ganttLanePitch
            let minSpan = visible * Double(Self.ganttMinBarWidth / plotWidth)
            ganttPlot(bars: bars, lanes: lanes, domain: domain, visible: visible, maxLabels: maxLabels,
                      shownLanes: shownLanes, minSpan: minSpan)
                .frame(height: min(chartHeight, ganttScrollable ? geo.size.height : chartHeight))
        }
    }

    @ViewBuilder private func ganttPlot(bars: [GanttBar], lanes: [String], domain: ClosedRange<Date>, visible: Double,
                                        maxLabels: Int, shownLanes: Int, minSpan: Double) -> some View {
        let segments = ganttSegments
        let scrollX = ganttScrollable && visible < domain.upperBound.timeIntervalSince(domain.lowerBound)
        let scrollY = ganttScrollable && shownLanes < lanes.count
        let laneIndex = Dictionary(lanes.enumerated().map { ($1, $0) }, uniquingKeysWith: { a, _ in a })
        Chart {
            ForEach(bars.indices, id: \.self) { i in
                ganttMark(bars[i], lane: laneIndex[bars[i].lane] ?? 0, minSpan: minSpan)
                    .foregroundStyle(by: .value("Segment", bars[i].segment))
                    .opacity(ganttBarLit(bars[i]) ? 1 : 0.2)
            }
        }
        .chartXScale(domain: domain)
        .chartYScale(domain: -Double(max(lanes.count, 1))...0)
        .chartForegroundStyleScale(domain: segments.isEmpty ? [""] : segments,
                                   range: segments.isEmpty ? [Color.accentColor] : resolvedColors(count: segments.count))
        .chartXAxis { AxisMarks(position: .top, values: ganttAxisValues(visibleSeconds: visible, maxLabels: maxLabels)) }
        .chartYAxis {
            AxisMarks(preset: .extended, position: .leading, values: lanes.indices.map { -Double($0) - 0.5 }) { value in
                AxisValueLabel(truncatedLane(Self.ganttLane(at: value.as(Double.self), lanes) ?? ""))
            }
        }
        .when(ganttLegendVisible) { $0.chartLegend(position: .bottom, alignment: .leading) { ganttLegend(segments) } }
        .when(!ganttLegendVisible) { $0.chartLegend(.hidden) }
        .when(scrollX && scrollY) { $0.chartScrollableAxes([.horizontal, .vertical]) }
        .when(scrollX && !scrollY) { $0.chartScrollableAxes(.horizontal) }
        .when(!scrollX && scrollY) { $0.chartScrollableAxes(.vertical) }
        .when(scrollX) { $0.chartXVisibleDomain(length: visible) }
        .when(scrollY) { $0.chartYVisibleDomain(length: Double(shownLanes)).chartScrollPosition(initialY: 0) }
        // Clicks and drags go through chartGesture and the pointer through
        // onContinuousHover on the chart itself: a hit-testable overlay view
        // takes the scroll-wheel events and stops the chart from scrolling.
        // chartGesture locations are in the whole (scrolled) plot's space.
        .chartGesture { proxy in
            DragGesture(minimumDistance: 0)
                .onChanged { v in
                    guard abs(v.translation.width) >= 6 else { marquee = nil; return }
                    marquee = CGRect(x: min(v.startLocation.x, v.location.x), y: 0,
                                     width: abs(v.location.x - v.startLocation.x), height: proxy.plotSize.height)
                }
                .onEnded { v in
                    if abs(v.translation.width) < 6 && abs(v.translation.height) < 6 {
                        ganttTap(v.location, proxy, bars: bars, minSpan: minSpan)
                    } else {
                        ganttBrush(v.startLocation.x, v.location.x, proxy: proxy)
                    }
                    marquee = nil
                }
        }
        .onContinuousHover { phase in
            switch phase {
            case .active(let p): ganttHoverPoint = p
            case .ended: ganttHoverPoint = nil
            }
        }
        .chartOverlay { proxy in ganttOverlay(proxy, bars: bars, minSpan: minSpan) }
    }

    /// Legend: a swatch and the short text of each segment value, capped at the
    /// Top-N setting so a column of long banners cannot fill the pane.
    @ViewBuilder private func ganttLegend(_ segments: [String]) -> some View {
        let cap = max(config.display.topNCategories, 1)
        let colors = resolvedColors(count: segments.count)
        let shortOf: [String: String] = Dictionary(data.ganttBars.map { ($0.segment, shortSegment($0)) },
                                                    uniquingKeysWith: { a, _ in a })
        // A plain row, clipped at the pane edge (a ScrollView renders empty in an export).
        HStack(spacing: 10) {
            ForEach(Array(segments.prefix(cap).enumerated()), id: \.offset) { i, seg in
                HStack(spacing: 4) {
                    Circle().fill(colors[i]).frame(width: 8, height: 8)
                    Text(shortOf[seg] ?? seg).lineLimit(1).foregroundStyle(Color.primary)
                }
                .fixedSize()
                .help(seg)
            }
            if segments.count > cap { Text("+\(segments.count - cap) more").foregroundStyle(Color.secondary).fixedSize() }
        }
        .font(.caption)
        .frame(maxWidth: .infinity, alignment: .leading)
        .clipped()
        .frame(height: Self.ganttLegendHeight - 6)
    }

    @ViewBuilder private func ganttCallout(_ bar: GanttBar) -> some View {
        let names = config.columns(for: .segment).map(\.name)
        callout {
            VStack(alignment: .leading, spacing: 2) {
                Text(bar.lane).font(.caption.bold())
                ForEach(Array(zip(names, bar.segmentValues).enumerated()), id: \.offset) { _, pair in
                    Text("\(pair.0): \(pair.1)").lineLimit(8).frame(maxWidth: 360, alignment: .leading)
                }
                Text("\(ganttValueText(bar.start)) – \(ganttValueText(bar.end))")
                if bar.rowCount > 1 { Text("\(bar.rowCount) rows").foregroundStyle(.secondary) }
            }
        }
    }

    /// One bar: a rectangle centred in its lane, `ganttBarHeight` of the lane pitch.
    private func ganttMark(_ bar: GanttBar, lane: Int, minSpan: Double) -> some ChartContent {
        let half = Double(Self.ganttBarHeight / Self.ganttLanePitch) / 2
        let mid = -Double(lane) - 0.5
        return RectangleMark(xStart: .value("Start", Date(timeIntervalSince1970: bar.start)),
                             xEnd: .value("End", Date(timeIntervalSince1970: max(bar.end, bar.start + minSpan))),
                             yStart: .value("Lane", mid + half),
                             yEnd: .value("Lane", mid - half))
            .cornerRadius(3)
    }

    /// The lane at a Y axis value (lane i spans -i-1...-i).
    static func ganttLane(at y: Double?, _ lanes: [String]) -> String? {
        guard let y, y <= 0 else { return nil }
        let i = Int((-y).rounded(.down))
        return lanes.indices.contains(i) ? lanes[i] : nil
    }

    /// The bar under a plot point: the lane from Y, then the top-most bar whose
    /// span (widened to the minimum bar width) holds X.
    private func ganttBarIndex(at p: CGPoint, _ proxy: ChartProxy, bars: [GanttBar], minSpan: Double) -> (lane: String?, bar: Int?) {
        guard let lane = Self.ganttLane(at: proxy.value(atY: p.y, as: Double.self), data.ganttLanes) else { return (nil, nil) }
        guard let x = proxy.value(atX: p.x, as: Date.self)?.timeIntervalSince1970 else { return (lane, nil) }
        let hit = bars.indices.last { i in
            bars[i].lane == lane && bars[i].start - minSpan / 2 <= x && x <= max(bars[i].end, bars[i].start + minSpan) + minSpan / 2
        }
        return (lane, hit)
    }

    /// Draws only (no hit testing): the brush marquee and the hover callout.
    /// The plot frame's origin moves with the scroll position, so an overlay
    /// point minus that origin is a point in the whole plot, as chartGesture gives.
    @ViewBuilder private func ganttOverlay(_ proxy: ChartProxy, bars: [GanttBar], minSpan: Double) -> some View {
        GeometryReader { geo in
            let origin = proxy.plotFrame.map { geo[$0].origin } ?? .zero
            ZStack(alignment: .topLeading) {
                marqueeOverlay(origin: origin)
                if let p = ganttHoverPoint,
                   let i = ganttBarIndex(at: CGPoint(x: p.x - origin.x, y: p.y - origin.y), proxy, bars: bars, minSpan: minSpan).bar {
                    // Below-right of the pointer; flipped to stay inside the pane.
                    let right = p.x > geo.size.width / 2, below = p.y < geo.size.height / 2
                    ganttCallout(bars[i])
                        .fixedSize()
                        .alignmentGuide(.leading) { d in right ? d[.trailing] : d[.leading] }
                        .alignmentGuide(.top) { d in below ? d[.top] : d[.bottom] }
                        .offset(x: p.x + (right ? -12 : 12), y: p.y + (below ? 14 : -8))
                }
            }
            .frame(width: geo.size.width, height: geo.size.height, alignment: .topLeading)
            .allowsHitTesting(false)
        }
    }

    /// Full rendered height of a non-scrolling gantt (for export sizing).
    static func ganttContentHeight(laneCount: Int, legend: Bool) -> CGFloat {
        ganttAxisHeight + (legend ? ganttLegendHeight : 0) + CGFloat(max(laneCount, 1)) * ganttLanePitch + 8
    }

    /// Tap a bar: its rows (lane AND segment). Tap beside the bars: the lane.
    /// Shift extends over lanes in order; ⌘ toggles.
    private func ganttTap(_ p: CGPoint, _ proxy: ChartProxy, bars: [GanttBar], minSpan: Double) {
        let hit = ganttBarIndex(at: p, proxy, bars: bars, minSpan: minSpan)
        guard let lane = hit.lane else { clearSelection(); return }
        let id = hit.bar.map(Self.ganttBarID) ?? Self.ganttLaneID(lane)
        applyModifier(hitIDs: [id]) {
            let order = data.ganttLanes
            guard let a = anchorID, a.hasPrefix("L\u{1}"), let ia = order.firstIndex(of: String(a.dropFirst(2))),
                  let ib = order.firstIndex(of: lane) else { return [id] }
            return order[min(ia, ib)...max(ia, ib)].map(Self.ganttLaneID)
        }
    }

    private func ganttBrush(_ ax: CGFloat, _ bx: CGFloat, proxy: ChartProxy) {
        guard let startRef = config.mappings[.start], let endRef = config.mappings[.end],
              let d0 = proxy.value(atX: min(ax, bx), as: Date.self),
              let d1 = proxy.value(atX: max(ax, bx), as: Date.self) else { return }
        // Domain is epoch-seconds-as-Date for both temporal and numeric axes;
        // .timeIntervalSince1970 recovers the epoch/raw value. Kind picks formatting.
        let ov: DrillKey = .overlap(startRef, endRef, d0.timeIntervalSince1970, d1.timeIntervalSince1970, data.ganttAxisKind)
        rangeSel = RangeSelection(keys: [ov], xLo: d0.timeIntervalSince1970, xHi: d1.timeIntervalSince1970, yLo: nil, yHi: nil)
        selectedIDs = []; anchorID = nil; report()
    }

    @ViewBuilder private func emptyState(_ reason: EmptyReason) -> some View {
        VStack(spacing: 6) {
            Image(systemName: "chart.bar.xaxis").font(.largeTitle).foregroundStyle(.tertiary)
            Text(message(reason)).foregroundStyle(.secondary).multilineTextAlignment(.center)
        }.frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private func message(_ reason: EmptyReason) -> String {
        switch reason {
        case .noColumns: return "Pick columns to chart, or press Suggest."
        case .allNull: return "The selected value column is all null."
        case .noData: return "This result's rows weren't saved. Re-run the query to chart it."
        }
    }
}

// MARK: - Conditional chart modifiers

private extension View {
    /// Applies `transform` only when `condition` holds; otherwise the view is unchanged.
    @ViewBuilder func when<T: View>(_ condition: Bool, _ transform: (Self) -> T) -> some View {
        if condition { transform(self) } else { self }
    }

    /// Axis titles: X centred beneath the plot, Y at the axis's default spot;
    /// an empty title draws nothing (no reserved space).
    @ViewBuilder func axisTitles(_ t: ChartAxisTitles.Titles) -> some View {
        self.when(!t.x.isEmpty) { $0.chartXAxisLabel(t.x, position: .bottom, alignment: .center) }
            .when(!t.y.isEmpty) { $0.chartYAxisLabel(t.y) }
    }
}
