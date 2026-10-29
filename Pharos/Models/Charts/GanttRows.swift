import Foundation

/// One line of a gantt's Y axis: a lane, a lane's header, or one Bars by value
/// of a lane (`GanttLayout.linePerValue`).
struct GanttRow: Equatable {
    var title: String
    var lane: String
    var segment: String?     // nil for a lane line or a header line
    var isHeader: Bool = false
}

/// Lays a gantt's bars out on lines. Pure, so the layout rule is testable
/// without drawing.
enum GanttRows {
    /// The lines top to bottom, and the line each bar sits on (index-aligned
    /// with `bars`). One Line, or no Bars by column: one line per lane. Line
    /// per Value: per lane, a header line with no bars, then one line per
    /// distinct value in the order the lane first shows it.
    static func build(bars: [GanttBar], lanes: [String], layout: GanttLayout) -> (rows: [GanttRow], barRow: [Int]) {
        let laneIndex = Dictionary(lanes.enumerated().map { ($1, $0) }, uniquingKeysWith: { a, _ in a })
        let hasSegments = bars.contains { !$0.segment.isEmpty }
        guard layout == .linePerValue, hasSegments else {
            return (lanes.map { GanttRow(title: $0, lane: $0, segment: nil) },
                    bars.map { laneIndex[$0.lane] ?? 0 })
        }
        // Each lane's distinct values, first-seen.
        var valuesOf: [String: [String]] = [:]
        for bar in bars where !(valuesOf[bar.lane]?.contains(bar.segment) ?? false) {
            valuesOf[bar.lane, default: []].append(bar.segment)
        }
        let shortOf = titles(bars)
        var rows: [GanttRow] = []
        var rowOf: [String: Int] = [:]   // lane \u{1} segment → line
        for lane in lanes {
            rows.append(GanttRow(title: lane, lane: lane, segment: nil, isHeader: true))
            for seg in valuesOf[lane] ?? [] {
                rowOf[lane + "\u{1}" + seg] = rows.count
                rows.append(GanttRow(title: shortOf[seg] ?? seg, lane: lane, segment: seg))
            }
        }
        return (rows, bars.map { rowOf[$0.lane + "\u{1}" + $0.segment] ?? 0 })
    }
}

extension GanttRows {
    /// A short title per segment value that tells the values apart: the first
    /// line of each column (`shortSegment`), and where two values share that,
    /// " … " plus the first line where they differ — banners that all start
    /// "HTTP/1.1 200 OK" read "HTTP/1.1 200 OK … Server: nginx".
    static func titles(_ bars: [GanttBar]) -> [String: String] {
        var linesOf: [String: [String]] = [:]
        var baseOf: [String: String] = [:]
        for bar in bars where !bar.segment.isEmpty && baseOf[bar.segment] == nil {
            baseOf[bar.segment] = bar.shortSegment
            linesOf[bar.segment] = bar.segmentValues.flatMap { $0.split(separator: "\n", omittingEmptySubsequences: false).map(String.init) }
        }
        var out = baseOf
        for group in Dictionary(grouping: baseOf.keys, by: { baseOf[$0] ?? "" }).values where group.count > 1 {
            for seg in group {
                let mine = linesOf[seg] ?? []
                let others = group.filter { $0 != seg }.map { linesOf[$0] ?? [] }
                guard let i = mine.indices.first(where: { i in others.contains { i >= $0.count || $0[i] != mine[i] } }) else { continue }
                let line = mine[i].trimmingCharacters(in: .whitespaces)
                out[seg] = (baseOf[seg] ?? "") + " … " + (line.count > 40 ? String(line.prefix(39)) + "…" : line)
            }
        }
        return out
    }
}

extension GanttBar {
    /// The first line of each Bars by value, each cut to 40 characters, joined —
    /// for a legend entry or an axis line where the whole banner will not fit.
    var shortSegment: String {
        segmentValues.map { v in
            let line = v.split(separator: "\n", maxSplits: 1, omittingEmptySubsequences: false).first.map(String.init) ?? ""
            return line.count > 40 ? String(line.prefix(39)) + "…" : line
        }.joined(separator: ChartAggregator.ganttValueSeparator)
    }
}

/// One legend entry for a gantt shown in the Inspector: the colour, every
/// Bars by column with its whole value, and how many bars and rows carry it.
struct GanttLegendEntry: Equatable {
    var hex: String
    var title: String
    var values: [(column: String, value: String)]
    var barCount: Int
    var rowCount: Int

    static func == (a: GanttLegendEntry, b: GanttLegendEntry) -> Bool {
        a.hex == b.hex && a.title == b.title && a.barCount == b.barCount && a.rowCount == b.rowCount
            && a.values.map(\.column) == b.values.map(\.column) && a.values.map(\.value) == b.values.map(\.value)
    }
}

enum GanttLegend {
    /// Every segment value in colour-domain order, with the colour the chart
    /// draws it in (`colors` index-aligned with the domain).
    static func entries(data: ChartData, segmentColumns: [String], colors: [String]) -> [GanttLegendEntry] {
        let domain = data.colorDomainLabels(for: .gantt)
        let titles = GanttRows.titles(data.ganttBars)
        var first: [String: GanttBar] = [:]
        var bars: [String: Int] = [:], rows: [String: Int] = [:]
        for bar in data.ganttBars where !bar.segment.isEmpty {
            if first[bar.segment] == nil { first[bar.segment] = bar }
            bars[bar.segment, default: 0] += 1
            rows[bar.segment, default: 0] += bar.rowCount
        }
        return domain.enumerated().compactMap { i, seg in
            guard let bar = first[seg] else { return nil }
            return GanttLegendEntry(hex: i < colors.count ? colors[i] : ChartPalette.defaultHex[i % ChartPalette.defaultHex.count],
                                    title: titles[seg] ?? bar.shortSegment,
                                    values: Array(zip(segmentColumns, bar.segmentValues)).map { (column: $0.0, value: $0.1) },
                                    barCount: bars[seg] ?? 0, rowCount: rows[seg] ?? 0)
        }
    }
}
