import AppKit

/// How a `ResultsGridState` snapshot maps onto a table's columns: their order,
/// which of them are hidden, and how wide each one is.
///
/// Split out of `ResultsGridVC` so this half of capture/restore can be driven
/// against a real `NSTableView` in a standalone harness. The view controller
/// reaches most of the app and cannot be compiled into one, which left the
/// order/width/visibility rules — the part with an ordering constraint between
/// its three steps — with no way to be tested at all.
extension ResultsGridState {

    /// The row-number column. Not a data column: it carries no name, the grid's
    /// selection code relies on it staying at index 0, and it is never hidden.
    static let rowNumberColumnId = "__rownum__"

    /// Width, display order and hidden set of `tableView`'s columns as they are
    /// right now.
    ///
    /// A hidden column keeps its `width`, so it is recorded like any other and
    /// comes back at that width when the user shows it again.
    static func captureColumns(from tableView: NSTableView)
        -> (widths: [String: CGFloat], order: [String], hidden: Set<String>) {
        var widths: [String: CGFloat] = [:]
        var hidden: Set<String> = []
        for column in tableView.tableColumns where column.identifier.rawValue != rowNumberColumnId {
            let colId = column.identifier.rawValue
            widths[colId] = column.width
            if column.isHidden { hidden.insert(colId) }
        }
        return (widths, tableView.tableColumns.map { $0.identifier.rawValue }, hidden)
    }

    /// Put `tableView`'s columns back the way this snapshot found them: order,
    /// visibility, widths.
    ///
    /// The three steps are INDEPENDENT, which is worth saying because the
    /// sequence looks load-bearing and is not. Each is keyed by identifier, a
    /// hidden column keeps its slot in `tableColumns`, and `moveColumn` moves a
    /// hidden one like any other — measured by running the steps in the other
    /// two orders, which changed no result. They are written in capture order
    /// for reading, not because one depends on another.
    ///
    /// What IS load-bearing:
    ///
    /// - `__rownum__` is never moved and never hidden. The selection controller
    ///   and the row-number click path rely on it staying at index 0, and
    ///   `shouldReorderColumn` refuses a drag into or out of that slot — a saved
    ///   order from before that guard must not put it back.
    /// - The widths are applied to HIDDEN columns too. Skipping them leaves a
    ///   shown-again column at whatever width the fresh grid measured for it,
    ///   losing the one the user set.
    func applyColumns(to tableView: NSTableView) {
        if let order = columnOrder {
            for (targetIndex, colId) in order.enumerated() {
                guard targetIndex < tableView.tableColumns.count,
                      targetIndex != 0, colId != Self.rowNumberColumnId else { continue }
                if let currentIndex = tableView.tableColumns.firstIndex(where: { $0.identifier.rawValue == colId }),
                   currentIndex != targetIndex {
                    tableView.moveColumn(currentIndex, toColumn: targetIndex)
                }
            }
        }

        // The guard is the one the header's menu enforces: a snapshot that would
        // leave the grid with no data column at all is ignored rather than
        // applied, because no header click could undo it.
        let dataColumns = tableView.tableColumns.filter { $0.identifier.rawValue != Self.rowNumberColumnId }
        let wouldHideAll = !dataColumns.isEmpty
            && dataColumns.allSatisfy { hiddenColumns.contains($0.identifier.rawValue) }
        if !wouldHideAll {
            for column in dataColumns {
                column.isHidden = hiddenColumns.contains(column.identifier.rawValue)
            }
        }

        for column in tableView.tableColumns {
            if let saved = columnWidths[column.identifier.rawValue] {
                column.width = saved
            }
        }
    }
}
