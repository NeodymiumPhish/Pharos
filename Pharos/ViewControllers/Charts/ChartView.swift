import SwiftUI
import Charts

struct ChartCanvas: View {
    let data: ChartData
    let chartType: ChartType

    var body: some View {
        if let reason = data.emptyReason {
            emptyState(reason)
        } else {
            chart.padding(8)
        }
    }

    @ViewBuilder private var chart: some View {
        switch chartType {
        case .bar:     categoryChart { BarMark(x: .value("Category", $0.xLabel), y: .value("Value", $0.y)) }
        case .line:    categoryChart { LineMark(x: .value("Category", $0.xLabel), y: .value("Value", $0.y)) }
        case .area:    categoryChart { AreaMark(x: .value("Category", $0.xLabel), y: .value("Value", $0.y)) }
        case .pie:     pieChart
        case .scatter: scatterChart
        case .gantt:   ganttChart
        }
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
    }

    // Vectorized scatter (macOS 15+). PointPlot takes the whole collection and
    // renders 100k+ points efficiently, so no per-point ForEach or sampling.
    private struct XYPoint: Identifiable { let id = UUID(); let x: Double; let y: Double }

    @ViewBuilder private var scatterChart: some View {
        let pts = (data.series.first?.points ?? []).map { XYPoint(x: $0.xValue ?? 0, y: $0.y) }
        Chart {
            PointPlot(pts, x: .value("X", \.x), y: .value("Y", \.y))
        }
    }

    // Gantt: fixed-height rows, drawn top-down, with the time (x) axis PINNED to
    // the top of the pane while the rows scroll underneath. To keep the pinned
    // ruler aligned with the bars, the layout is split into a fixed label gutter +
    // a shared time scale: a header row (gutter spacer + x-axis-only chart) stays
    // put, and a scrolling body (labels column + bars chart, x-axis hidden) shares
    // the same left offset and x-domain so ticks line up with bars.
    private static let ganttRowHeight: CGFloat = 50
    private static let ganttLabelWidth: CGFloat = 210
    private static let ganttAxisHeight: CGFloat = 24

    private func ganttDomain(_ bars: [GanttBar]) -> ClosedRange<Date> {
        let lo = bars.map(\.start).min() ?? 0
        let hi = bars.map(\.end).max() ?? 1
        return Date(timeIntervalSince1970: lo)...Date(timeIntervalSince1970: max(hi, lo + 1))
    }

    @ViewBuilder private var ganttChart: some View {
        let bars = data.ganttBars
        let rowCount = max(bars.count, 1)
        let domain = ganttDomain(bars)
        VStack(spacing: 0) {
            // Pinned time-axis header, offset by the label gutter so its ticks
            // sit above the bars (not the labels).
            HStack(spacing: 0) {
                Color.clear.frame(width: Self.ganttLabelWidth)
                Chart {
                    RectangleMark(
                        xStart: .value("Start", domain.lowerBound),
                        xEnd: .value("End", domain.upperBound)
                    )
                    .foregroundStyle(.clear)
                }
                .chartXScale(domain: domain)
                .chartXAxis { AxisMarks(position: .top) }
                .chartYAxis(.hidden)
                .frame(height: Self.ganttAxisHeight)
            }
            // Scrolling body: label gutter + bars, both fixed-height rows.
            ScrollView(.vertical) {
                HStack(alignment: .top, spacing: 0) {
                    VStack(alignment: .leading, spacing: 0) {
                        ForEach(Array(bars.enumerated()), id: \.offset) { _, bar in
                            Text(bar.label)
                                .font(.callout)
                                .lineLimit(1)
                                .truncationMode(.tail)
                                .frame(width: Self.ganttLabelWidth,
                                       height: Self.ganttRowHeight, alignment: .leading)
                        }
                    }
                    Chart(Array(bars.enumerated()), id: \.offset) { _, bar in
                        BarMark(
                            xStart: .value("Start", Date(timeIntervalSince1970: bar.start)),
                            xEnd: .value("End", Date(timeIntervalSince1970: bar.end)),
                            y: .value("Task", bar.label)
                        )
                    }
                    .chartXScale(domain: domain)
                    .chartXAxis(.hidden)
                    .chartYAxis(.hidden)
                    .frame(height: CGFloat(rowCount) * Self.ganttRowHeight)
                }
            }
        }
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
