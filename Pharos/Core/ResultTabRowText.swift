import Foundation

/// Pure text formatting for the row's size caption. Kept out of the cell so the
/// strings are assertable without AppKit state.
enum ResultTabRowText {
    /// "240×46" — the grouped row count, then the column count. Rows first:
    /// that is the number the analyst is asking about, and it is how the
    /// status text below the grid already reads.
    static func countsText(columnCount: Int, rowCount: Int) -> String {
        "\(HistoryRowText.rowCountText(Int64(rowCount)))×\(columnCount)"
    }

    /// "2,500 rows" for statement results (INSERT/UPDATE/…).
    static func affectedText(rowsAffected: UInt64) -> String {
        CountedNounText.phrase(Int(clamping: rowsAffected), "row")
    }
}
