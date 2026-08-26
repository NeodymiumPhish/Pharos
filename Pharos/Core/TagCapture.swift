import Foundation

// MARK: - TagCapture

/// What a grid selection offers the Tag Manager, before any of it is captured.
///
/// It holds the INPUTS, never the answer. The rules a save would write are
/// derived from it plus the columns the analyst has ticked, so a tick and the
/// draft cannot drift apart: there is no second copy of the draft to go stale.
///
/// The analyst ticks VALUES, not column names. When you are tagging a row you
/// are looking at, `107.8.8.1` is what you are deciding about — the column name
/// takes no part in matching at all, so a checklist of names would be asking
/// about the wrong thing. `familyText` is what a row says instead, because a
/// family is the one description every condition can share.
struct TagCapture {

    /// The result's columns, in result order.
    let columns: [ColumnDef]
    /// The selected rows' values as text, in column order. One entry per row.
    let selectedRows: [[String?]]
    let originConnection: String
    /// "public.certs", or "" when the result has no source table. Provenance
    /// only — an empty string never stops a finding being captured.
    let originTable: String

    init(columns: [ColumnDef], selectedRows: [[String?]],
         originConnection: String, originTable: String) {
        self.columns = columns
        self.selectedRows = selectedRows
        self.originConnection = originConnection
        self.originTable = originTable
    }

    /// This column's value in each selected row, in selection order.
    ///
    /// A row too short for the index yields nil rather than trapping: the
    /// modal's checklist and the grid could disagree about the result's shape
    /// after a Load More, and `TagDraft.rules` takes the same care for the same
    /// reason.
    func texts(forColumn index: Int) -> [String?] {
        selectedRows.map { row in
            index >= 0 && index < row.count ? row[index] : nil
        }
    }

    /// The human family label for one column — "Address", "Number", "Text".
    ///
    /// NOT the column's name. A column name never takes part in matching, and a
    /// hand-authored condition has no column at all, so the family is what the
    /// captured condition will actually be described by everywhere else in the
    /// app. Showing the name here would promise a precision the tag does not
    /// have. `TagFamilyLabel` escapes an exotic family on the way out, because
    /// that carries a PostgreSQL type name, which is somebody else's data.
    func familyText(forColumn index: Int) -> String {
        guard columns.indices.contains(index) else { return "" }
        return TagFamilyLabel.text(
            for: TagValueNormalizer.family(forDataType: columns[index].dataType))
    }

    /// What the checklist row shows for one column, ready to draw.
    ///
    /// Three answers, in the order they are asked:
    ///
    ///  - Every selected row holds ONE non-NULL value: that value, escaped. This
    ///    is the whole point with one row selected, and with several it says the
    ///    column is constant across the selection — a strong indicator, worth
    ///    seeing at a glance.
    ///  - No selected row holds a value at all: "NULL". A NULL is the ABSENCE of
    ///    a value, so nothing would be captured from this column; saying so is
    ///    better than an empty cell that reads as a rendering fault.
    ///  - Otherwise: how many DISTINCT values the selection would contribute,
    ///    which is what the old per-column sheet's count was for. NULLs are not
    ///    counted, because `TagDraft` drops them — so a column holding "x", "x"
    ///    and NULL says "1 value" rather than showing "x": one value, but not
    ///    one every selected row shares.
    ///
    /// ESCAPED, because it is captured data drawn in a label this app owns. A
    /// bidi override in a cell would otherwise make the checklist row read as a
    /// different value than the one being ticked.
    func valueText(forColumn index: Int) -> String {
        let texts = texts(forColumn: index)
        let present = texts.compactMap { $0 }
        let distinct = Set(present)
        if distinct.count == 1, present.count == texts.count, let only = distinct.first {
            return DisplayEscape.escaped(only)
        }
        guard !distinct.isEmpty else { return "NULL" }
        return "\(distinct.count) value\(distinct.count == 1 ? "" : "s")"
    }

    /// The rules the ticked columns would write.
    ///
    /// One rule PER SELECTED ROW, never a cross product — `TagDraft.rules` owns
    /// that reasoning, and this is the only producer of a captured draft so
    /// there is nowhere for a second interpretation to live.
    func rules(checkedColumns: Set<Int>) -> [NewTagRule] {
        // Sorted, so the conditions of a rule arrive in result-column order
        // whatever order the analyst ticked the boxes in.
        TagDraft.rules(selectedRows: selectedRows, columns: columns,
                       checkedColumns: checkedColumns.sorted(),
                       originConnection: originConnection,
                       originTable: originTable)
    }
}

// MARK: - Equatable

/// Hand-written because `ColumnDef` is not `Equatable` — it is a decoded wire
/// type shared by twenty harnesses, and this one comparison is not reason enough
/// to change it. Every field of every column is compared, so this is no kinder
/// than a synthesised one would be.
extension TagCapture: Equatable {
    static func == (a: TagCapture, b: TagCapture) -> Bool {
        a.originConnection == b.originConnection
            && a.originTable == b.originTable
            && a.selectedRows == b.selectedRows
            && a.columns.count == b.columns.count
            && zip(a.columns, b.columns).allSatisfy {
                $0.name == $1.name && $0.dataType == $1.dataType
                    && $0.relationOid == $1.relationOid
                    && $0.relationAttno == $1.relationAttno
            }
    }
}
