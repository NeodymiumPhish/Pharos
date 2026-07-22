import Foundation

/// Reorders a `ChartData`'s categories/points per a `ChartSort`. Pure and
/// Foundation-only (testable via the standalone swiftc harness). A no-op for
/// `.queryOrder`, for chart types outside the categorical set
/// (bar/line/area/pie), and for empty data. The top-N overflow bucket ("Other")
/// is always pinned last. Rendering needs no changes: bar/line/area use a
/// categorical String x-scale and pie slices follow point order, so reordering
/// `points` is exactly what the axis honors.
enum ChartSorter {
    static func sorted(_ data: ChartData, by sort: ChartSort, chartType: ChartType) -> ChartData {
        guard sort != .queryOrder else { return data }
        switch chartType {
        case .bar, .line, .area, .pie: break
        default: return data
        }
        guard !data.series.isEmpty else { return data }

        // Current distinct category order (union across series, first-seen).
        var order: [String] = []
        var seen = Set<String>()
        for s in data.series {
            for p in s.points where !seen.contains(p.xLabel) {
                seen.insert(p.xLabel); order.append(p.xLabel)
            }
        }
        guard !order.isEmpty else { return data }

        // Pin the top-N overflow bucket last, regardless of sort.
        let otherLabel = "Other"
        let hasOther = order.contains(otherLabel)
        var sortable = order.filter { $0 != otherLabel }

        // Stable tiebreak on original position (Swift's sort is not guaranteed stable).
        let origIndex = Dictionary(uniqueKeysWithValues: order.enumerated().map { ($0.element, $0.offset) })

        switch sort {
        case .categoryAsc:
            sortable.sort { $0 != $1 ? $0 < $1 : (origIndex[$0] ?? 0) < (origIndex[$1] ?? 0) }
        case .categoryDesc:
            sortable.sort { $0 != $1 ? $0 > $1 : (origIndex[$0] ?? 0) < (origIndex[$1] ?? 0) }
        case .valueAsc, .valueDesc:
            var totals: [String: Double] = [:]
            for s in data.series {
                for p in s.points { totals[p.xLabel, default: 0] += p.y }
            }
            sortable.sort {
                let a = totals[$0] ?? 0, b = totals[$1] ?? 0
                if a != b { return sort == .valueAsc ? a < b : a > b }
                return (origIndex[$0] ?? 0) < (origIndex[$1] ?? 0)
            }
        case .queryOrder:
            return data   // unreachable (guarded above), keeps the switch exhaustive
        }

        var newOrder = sortable
        if hasOther { newOrder.append(otherLabel) }
        let rank = Dictionary(uniqueKeysWithValues: newOrder.enumerated().map { ($0.element, $0.offset) })

        var result = data
        result.series = data.series.map { s in
            var s2 = s
            s2.points = s.points.sorted { (rank[$0.xLabel] ?? Int.max) < (rank[$1.xLabel] ?? Int.max) }
            return s2
        }
        return result
    }
}
