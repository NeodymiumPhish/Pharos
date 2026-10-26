import Foundation

/// Where an open inline editor goes when the grid reloads under it.
///
/// A reload the user did not ask for — a Settings change, a tag change from
/// another window, a sort, a page of rows arriving — takes the field editor
/// away from the cell, and AppKit reports that as the edit ending (measured:
/// `controlTextDidEndEditing` fires BEFORE the row is drawn again). Treated as
/// an ending, it committed the half-typed text and closed the editor.
/// `ResultsGridVC.reloadKeepingEditor` opens it again instead, at the place
/// this rule names.
///
/// The editor is followed by its DATA row and DATA column, not its display
/// position: a sort, a filter, the tag funnel or find can each move the record
/// to a different display row, or a hidden column can move its neighbours.
/// Pure, so the harness can pin it without a view controller.
enum EditorReloadRule {
    enum Outcome: Equatable {
        /// Open the editor again at this DISPLAY row and TABLE column, with
        /// the user's own text.
        case reopen(row: Int, column: Int)
        /// The record or the column is no longer shown, or the cell is no
        /// longer editable: record the text as a pending edit, exactly as
        /// clicking away from the field does. Never thrown away.
        case commit
    }

    /// - Parameters:
    ///   - displayRows: the data row behind each display row, AFTER the reload.
    ///   - tableColumn: the table column showing a data column, or nil when it
    ///     is hidden — AFTER the reload.
    ///   - isEditable: whether the grid would let the user edit that cell now.
    static func outcome(dataRow: Int, dataColumn: Int,
                        displayRows: [Int],
                        tableColumn: (Int) -> Int?,
                        isEditable: (_ row: Int, _ column: Int) -> Bool) -> Outcome {
        guard let row = displayRows.firstIndex(of: dataRow),
              let column = tableColumn(dataColumn),
              isEditable(row, column)
        else { return .commit }
        return .reopen(row: row, column: column)
    }
}
