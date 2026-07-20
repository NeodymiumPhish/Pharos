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
    /// When false, the gantt renders all rows in a plain (non-scrolling) stack so
    /// ImageRenderer captures every bar on export (a ScrollView renders empty
    /// off-screen). On-screen use keeps the default (scrolling).
    var ganttScrollable: Bool = true

    private var chartType: ChartType { config.chartType }
    private var temporalBin: TemporalBin { config.temporalBin }

    // Pie selection (native angle selection maps to the category label).
    @State private var pieSelection: String?
    // Scatter click callout (chart-local; not a drill — brushing filters instead).
    @State private var scatterSelection: XYPoint?

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
            guard let ref = config.mappings[.label] else { return [] }
            return data.ganttBars.map { Mark(id: $0.label, drill: .anyOf(ref, [$0.label])) }
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

    private func ganttRowLit(_ bar: GanttBar) -> Bool {
        if let r = rangeSel { return bar.start <= r.xHi && bar.end >= r.xLo }   // time-axis overlap window
        if effectiveKeys.isEmpty { return true }
        guard let ref = config.mappings[.label] else { return true }
        return DrillCoverage.covers(effectiveKeys, .anyOf(ref, [bar.label]))
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
            chart.padding(8)
                .onChange(of: clearToken) { _, _ in clearSelection() }
                .onChange(of: configFingerprint) { _, _ in clearSelection() }
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
            .opacity(isLit(cell.drill) ? 1 : 0.2)
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
                        .opacity(isLit(pt.drill) ? 1 : 0.2)
                }
            }
        }
    }

    @ViewBuilder private var pieChart: some View {
        Chart(data.series.first?.points ?? [], id: \.xLabel) { pt in
            SectorMark(angle: .value("Value", pt.y), innerRadius: .ratio(0.5))
                .foregroundStyle(by: .value("Category", pt.xLabel))
                .opacity(isLit(pt.drill) ? 1 : 0.2)
        }
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
    private struct XYPoint: Identifiable { let id = UUID(); let x: Double; let y: Double }

    private var scatterPoints: [XYPoint] {
        (data.series.first?.points ?? []).map { XYPoint(x: $0.xValue ?? 0, y: $0.y) }
    }

    @ViewBuilder private var scatterChart: some View {
        let pts = scatterPoints
        Chart {
            if let r = rangeSel {
                let inR: (XYPoint) -> Bool = { r.xLo <= $0.x && $0.x <= r.xHi && (r.yLo == nil || (r.yLo! <= $0.y && $0.y <= r.yHi!)) }
                let inside = pts.filter(inR); let outside = pts.filter { !inR($0) }
                PointPlot(outside, x: .value("X", \.x), y: .value("Y", \.y)).foregroundStyle(.gray.opacity(0.2))
                PointPlot(inside, x: .value("X", \.x), y: .value("Y", \.y))
            } else {
                PointPlot(pts, x: .value("X", \.x), y: .value("Y", \.y))
            }
        }
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
            // Multi-series bars render stacked (Swift Charts stacks same-x marks by
            // series), so a click resolves to the band containing the tapped y —
            // regardless of the `display.stacked` flag — giving band-precise selection.
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
                .chartOverlay { proxy in
                    GeometryReader { g in
                        let origin = proxy.plotFrame.map { g[$0].origin } ?? .zero
                        let plotHeight = proxy.plotFrame.map { g[$0].height } ?? g.size.height
                        ZStack(alignment: .topLeading) {
                            Rectangle().fill(Color.clear).contentShape(Rectangle())
                                .gesture(DragGesture(minimumDistance: 6)
                                    .onChanged { v in
                                        let sx = v.startLocation.x - origin.x, ex = v.location.x - origin.x
                                        marquee = CGRect(x: min(sx, ex), y: 0, width: abs(ex - sx), height: plotHeight)
                                    }
                                    .onEnded { v in
                                        ganttBrush(v.startLocation.x - origin.x, v.location.x - origin.x, proxy: proxy, bars: bars)
                                        marquee = nil
                                    })
                            marqueeOverlay(origin: origin)
                        }
                    }
                }
            }
            .frame(height: Self.ganttAxisHeight)

            // Rows: label on top, bar beneath. Tapping a row drills to that row's
            // label. Scrolls on-screen; renders full-height (no ScrollView) for
            // export so ImageRenderer captures every bar.
            if ganttScrollable {
                ScrollView(.vertical) { ganttRows(domain: domain, bars: bars) }
            } else {
                ganttRows(domain: domain, bars: bars)
            }
        }
    }

    @ViewBuilder private func ganttRows(domain: ClosedRange<Date>, bars: [GanttBar]) -> some View {
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
                .opacity(ganttRowLit(bar) ? 1 : 0.2)
                .contentShape(Rectangle())
                .onTapGesture { ganttTap(bar) }
            }
        }
        .padding(.top, 6)
    }

    /// Full rendered height of a non-scrolling gantt (for export sizing).
    static func ganttContentHeight(rowCount: Int) -> CGFloat {
        let rowPitch = 18 + 2 + ganttBarHeight + ganttRowSpacing   // label + gap + bar + spacing
        return ganttAxisHeight + 6 + CGFloat(max(rowCount, 1)) * rowPitch
    }

    private func ganttTap(_ bar: GanttBar) {
        applyModifier(hitIDs: [bar.label]) {
            let order = data.ganttBars.map { $0.label }
            guard let a = anchorID, let ia = order.firstIndex(of: a), let ib = order.firstIndex(of: bar.label) else { return [bar.label] }
            return Array(order[min(ia, ib)...max(ia, ib)])
        }
    }

    private func ganttBrush(_ ax: CGFloat, _ bx: CGFloat, proxy: ChartProxy, bars: [GanttBar]) {
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
        case .noColumns: return "Pick columns to chart."
        case .allNull: return "The selected value column is all null."
        case .noData: return "This result's rows weren't saved. Re-run the query to chart it."
        }
    }
}
