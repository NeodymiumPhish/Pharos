import Foundation

/// Pure text formatting for the row's size caption. Kept out of the cell so the
/// strings are assertable without AppKit state.
enum ResultTabRowText {
    /// "46×240" — column count, then the grouped row count.
    static func countsText(columnCount: Int, rowCount: Int) -> String {
        "\(columnCount)×\(HistoryRowText.rowCountText(Int64(rowCount)))"
    }

    /// "2,500 rows" for statement results (INSERT/UPDATE/…).
    static func affectedText(rowsAffected: UInt64) -> String {
        CountedNounText.phrase(Int(clamping: rowsAffected), "row")
    }
}
