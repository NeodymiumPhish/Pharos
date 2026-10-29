import Foundation

/// Which of the grid's column filters a chart of the same result honours.
///
/// The chart plots the rows the grid's own filters keep, so the two views
/// agree. A chart drill ("Filter in Grid") also writes column filters, but
/// those stay out: the chart shows its own selection by dimming marks, and
/// filtering on it would hide every mark that was not selected. Where a drill
/// replaced a manual filter on a column, the manual filter counts instead.
enum ChartGridFilters {
    static func filters(active: [String: ColumnFilter],
                        drillColumns: [String],
                        displaced: [String: ColumnFilter]) -> [String: ColumnFilter] {
        var out = active
        for column in drillColumns { out[column] = displaced[column] }
        return out
    }

    /// The data rows, in query order, that pass `filters` through the grid's own
    /// pipeline: the tag funnel (from the controller's active filters), the
    /// column filters, then the force-show merge of `forceShowTagged`. Find and
    /// the sort are left out. Nil when no row is filtered out.
    static func rowIndices(rowCount: Int, controller: ResultsColumnFilterController,
                           filters: [String: ColumnFilter], forceShowTagged: Set<Int>?) -> [Int]? {
        let columnOnly = filters.filter { !TagFunnel.isTagFilter(columnId: $0.key) }
        let kept = DisplayRowPipeline.run(
            unfiltered: Array(0..<rowCount),
            stages: .init(
                tagFilter: { controller.applyTagFilter(inputDisplayRows: $0) },
                columnFilters: columnOnly.isEmpty ? nil : { controller.matchingRows(columnOnly, inputDisplayRows: $0) },
                forceShow: forceShowTagged.map { DisplayRowPipeline.forceShowAdmitting(taggedRows: $0) }))
        return kept.count == rowCount ? nil : kept
    }

    /// The banner sentence for a chart of `kept` rows out of `loaded`.
    static func bannerText(kept: Int, loaded: Int, total: Int) -> String {
        let ofTotal = total > loaded ? " (\(total) in all)" : ""
        if kept < loaded {
            return "Charting \(kept) of \(loaded) loaded rows\(ofTotal) that match the grid's filters."
        }
        return "Charting \(loaded)\(total > loaded ? " of \(total)" : "") loaded rows, aggregated client-side."
    }
}
