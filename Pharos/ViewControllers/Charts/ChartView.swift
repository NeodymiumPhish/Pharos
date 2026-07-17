import SwiftUI
import Charts

struct ChartCanvas: View {
    let data: ChartData
    let chartType: ChartType
    var temporalBin: TemporalBin = .auto

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

    // Gantt: each row shows its label on one line with the bar just beneath it,
    // so long labels stay fully readable. The time (x) axis is PINNED to the top
    // of the pane; rows scroll underneath. Bars are full-width, and the pinned
    // header shares the same x-domain, so ticks line up with the bars without any
    // gutter to align. Each row is its own single-bar chart (a few dozen light
    // charts) — fine for typical result sizes.
    private static let ganttBarHeight: CGFloat = 16
    private static let ganttRowSpacing: CGFloat = 12
    private static let ganttAxisHeight: CGFloat = 24

    private func ganttDomain(_ bars: [GanttBar]) -> ClosedRange<Date> {
        let lo = bars.map(\.start).min() ?? 0
        let hi = bars.map(\.end).max() ?? 1
        return Date(timeIntervalSince1970: lo)...Date(timeIntervalSince1970: max(hi, lo + 1))
    }

    // Tick granularity for the gantt time axis, driven by the Time Bucket control.
    private var ganttAxisValues: AxisMarkValues {
        switch temporalBin {
        case .hour:  return .stride(by: .hour)
        case .day:   return .stride(by: .day)
        case .week:  return .stride(by: .weekOfYear)
        case .month: return .stride(by: .month)
        case .year:  return .stride(by: .year)
        case .auto, .none: return .automatic
        }
    }

    @ViewBuilder private var ganttChart: some View {
        let bars = data.ganttBars
        let domain = ganttDomain(bars)
        VStack(spacing: 0) {
            // Pinned time-axis header (full width, same domain as the bars).
            Chart {
                RectangleMark(
                    xStart: .value("Start", domain.lowerBound),
                    xEnd: .value("End", domain.upperBound)
                )
                .foregroundStyle(.clear)
            }
            .chartXScale(domain: domain)
            .chartXAxis { AxisMarks(position: .top, values: ganttAxisValues) }
            .chartYAxis(.hidden)
            .frame(height: Self.ganttAxisHeight)

            // Scrolling rows: label on top, bar beneath.
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
                    }
                }
                .padding(.top, 6)
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
