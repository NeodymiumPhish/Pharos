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

    @ViewBuilder private var ganttChart: some View {
        Chart(Array(data.ganttBars.enumerated()), id: \.offset) { _, bar in
            BarMark(
                xStart: .value("Start", Date(timeIntervalSince1970: bar.start)),
                xEnd: .value("End", Date(timeIntervalSince1970: bar.end)),
                y: .value("Task", bar.label)
            )
        }
        .chartScrollableAxes(.vertical)
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
