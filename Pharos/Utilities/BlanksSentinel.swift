import Foundation

/// The single canonical "match null / empty cells" sentinel, shared by the grid
/// filter (`ColumnFilter`), the pure drill-key merge (`DrillMerge`), and the SQL
/// translator (`DrillSqlTranslator`). Kept in one Foundation-only place so grid
/// and SQL null handling can never drift apart. NUL-prefixed so it cannot
/// collide with any rendered cell value.
enum PharosBlanks {
    static let sentinel = "\u{0}__pharos_blanks__"
}
