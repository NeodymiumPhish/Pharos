import Foundation

/// One uncommitted change to one cell.
///
/// `oldText` is the value as it was LOADED (nil for a SQL NULL) and `newText`
/// is what the user typed (nil for a deliberate NULL, "" for an empty string —
/// the two are different values and stay different all the way to the core).
///
/// Pure Foundation on purpose: the whole pending model is a value type with no
/// AppKit in it, so `scripts/test-pending-cell-edits.sh` links the real
/// production code rather than a copy of it.
struct PendingEdit: Equatable {
    /// Index into the result's `rows`, NOT the display row.
    ///
    /// This is the one decision the whole model rests on. A sort or a column
    /// filter only reorders `displayRows`; it never touches `rows`. So an edit
    /// addressed by data row is undisturbed by both, and `Load More` — which
    /// only appends to `rows` — cannot move it either. Keying on the display
    /// row would silently re-point every pending edit at a different row the
    /// moment a column header was clicked.
    let dataRow: Int
    /// Index into the result's `columns`, NOT the table column index (which
    /// moves when the user reorders columns, and counts the `#` column).
    let columnIndex: Int
    let oldText: String?
    let newText: String?

    init(dataRow: Int, columnIndex: Int, oldText: String?, newText: String?) {
        self.dataRow = dataRow
        self.columnIndex = columnIndex
        self.oldText = oldText
        self.newText = newText
    }

    /// True when the edit puts back exactly what was loaded, so it is not a
    /// change at all.
    var isNoOp: Bool { oldText == newText }
}

/// Every uncommitted cell change of one result, addressed by (data row, data
/// column).
///
/// Nothing here talks to the database. The set is built by the grid as the
/// user types, read by the review sheet, and turned into one
/// `RowUpdateRequest` by `RowUpdateSQLBuilder.makeRequest`.
struct PendingCellEdits: Equatable {

    private struct Key: Hashable {
        let dataRow: Int
        let columnIndex: Int
    }

    private var storage: [Key: PendingEdit] = [:]

    init() {}

    /// Record an edit. An edit that restores the loaded value REMOVES the
    /// entry rather than storing a no-op: the bar's count, the review sheet
    /// and the request must all agree that nothing is pending for that cell,
    /// and a stored no-op would make each of them say otherwise.
    mutating func set(_ edit: PendingEdit) {
        let key = Key(dataRow: edit.dataRow, columnIndex: edit.columnIndex)
        if edit.isNoOp {
            storage.removeValue(forKey: key)
        } else {
            storage[key] = edit
        }
    }

    /// Drop one cell's edit, whatever it holds. "Revert Edit" in the grid's
    /// context menu.
    mutating func remove(dataRow: Int, columnIndex: Int) {
        storage.removeValue(forKey: Key(dataRow: dataRow, columnIndex: columnIndex))
    }

    func edit(at dataRow: Int, columnIndex: Int) -> PendingEdit? {
        storage[Key(dataRow: dataRow, columnIndex: columnIndex)]
    }

    /// The number of CHANGED CELLS, which is what the bar counts and what the
    /// review sheet's title says. Not the number of rows.
    var count: Int { storage.count }

    var isEmpty: Bool { storage.isEmpty }

    /// The data rows that hold at least one edit, ascending. One UPDATE
    /// statement per entry, in this order.
    var rows: [Int] {
        Set(storage.keys.map(\.dataRow)).sorted()
    }

    /// One row's edits, ordered by data column so the rendered SET list is
    /// stable between runs.
    func edits(forDataRow dataRow: Int) -> [PendingEdit] {
        storage.values
            .filter { $0.dataRow == dataRow }
            .sorted { $0.columnIndex < $1.columnIndex }
    }

    /// Every edit, in (row, column) order.
    var all: [PendingEdit] {
        storage.values.sorted {
            $0.dataRow == $1.dataRow ? $0.columnIndex < $1.columnIndex : $0.dataRow < $1.dataRow
        }
    }

    /// The data columns any row has an edit in, ascending. These become the
    /// request's `columns`, so every row of the request writes the same list.
    var columnIndices: [Int] {
        Set(storage.keys.map(\.columnIndex)).sorted()
    }

    mutating func removeAll() {
        storage.removeAll()
    }
}

// MARK: - Cell Editability

/// Why one cell cannot be edited. The grid never shows these: a read-only cell
/// simply does not respond to a double-click, because a result is mostly
/// read-only cells and an explanation per cell would be noise. They exist so
/// the rule can be asserted case by case in
/// `scripts/test-cell-editability.sh`, and so a future "why not?" affordance
/// has something honest to say.
enum CellEditRefusal: Equatable {
    /// The core could not attribute the result to a table, or found no key it
    /// could match a row on. Without a key there is no safe WHERE clause.
    case noIdentity
    /// This row's key value is NULL or missing (an outer join's unmatched
    /// side), so the row cannot be named.
    case rowHasNoKey
    /// The result draws on more than one table. A join's row is not one
    /// table's row, and nothing here says which one an edit belongs to.
    case multipleTables
    /// The column is an aggregate, an expression, a literal, or a column of
    /// some OTHER table in the result — there is no `table.column` to write.
    case columnNotFromTable
    /// Arrays, composites, ranges, `bytea`, JSON, intervals: v1 refuses them
    /// rather than guess a text cast. A wrong cast on an array is a silent
    /// data change, which is the one outcome this feature must never have.
    case unsupportedType(String)
}

/// The five-point rule that decides whether one cell of a result may be
/// edited, with every input injected so a fixture can pose each case.
///
/// Pure Foundation, no AppKit and no view state: the grid asks it, and so does
/// `scripts/test-cell-editability.sh`. "Not a plan tab" is the sixth condition
/// and is the CALLER's — a plan tab shows the plan view, not this grid, so
/// there is no cell to ask about.
enum CellEditability {

    /// The PostgreSQL type names v1 can round-trip through text without
    /// guessing: text, numeric, boolean, date, timestamp and uuid.
    ///
    /// A whitelist, not a blacklist. `data_type` comes from sqlx's own
    /// `PgTypeInfo` display (`TEXT`, `INT4`, `TIMESTAMPTZ`, `NUMERIC`,
    /// `UUID`, and `TEXT[]` for an array), so an unknown or exotic type —
    /// an enum, a composite, a domain, an extension type — falls out as
    /// unsupported by default instead of being edited on a guess. Arrays are
    /// excluded for free: `TEXT[]` is not a member.
    static let supportedTypeNames: Set<String> = [
        // text
        "text", "varchar", "character varying", "bpchar", "char", "character", "name",
        // numeric
        "int2", "smallint", "int4", "integer", "int", "int8", "bigint",
        "numeric", "decimal", "float4", "real", "float8", "double precision",
        // boolean
        "bool", "boolean",
        // date and timestamp
        "date",
        "timestamp", "timestamptz",
        "timestamp without time zone", "timestamp with time zone",
        // uuid
        "uuid",
    ]

    /// The broad family a supported type belongs to. Only the literal
    /// RENDERING in the review sheet reads this — numbers and booleans print
    /// bare, everything else prints quoted.
    enum Family: Equatable {
        case text
        case numeric
        case boolean
        case temporal
        case uuid
    }

    static func family(of dataType: String) -> Family? {
        let name = normalizedTypeName(dataType)
        guard supportedTypeNames.contains(name) else { return nil }
        switch name {
        case "int2", "smallint", "int4", "integer", "int", "int8", "bigint",
             "numeric", "decimal", "float4", "real", "float8", "double precision":
            return .numeric
        case "bool", "boolean":
            return .boolean
        case "date", "timestamp", "timestamptz",
             "timestamp without time zone", "timestamp with time zone":
            return .temporal
        case "uuid":
            return .uuid
        default:
            return .text
        }
    }

    static func isSupportedType(_ dataType: String) -> Bool {
        supportedTypeNames.contains(normalizedTypeName(dataType))
    }

    /// Lower-cased and trimmed. A parameterised name keeps its parameters
    /// (`numeric(10,2)` is not in the set) — deliberately: the core reports
    /// the bare type name, so anything carrying a modifier did not come from
    /// the path this feature supports.
    private static func normalizedTypeName(_ dataType: String) -> String {
        dataType.trimmingCharacters(in: .whitespaces).lowercased()
    }

    /// The OID the identity block names as the result's table, parsed out of
    /// its `oid:{n}` form. nil for any other shape, which then refuses every
    /// column (`columnNotFromTable`) rather than matching a column with no
    /// source table.
    static func tableOid(of identity: RowIdentity) -> UInt32? {
        guard identity.tableKey.hasPrefix("oid:") else { return nil }
        return UInt32(identity.tableKey.dropFirst(4))
    }

    /// The candidate a WHERE clause should be built from: the STRONGEST one,
    /// which `choose_candidates` puts first (the primary key when the result
    /// carries all of it, else the narrowest all-NOT-NULL unique index).
    static func strongestCandidate(of identity: RowIdentity?) -> KeySet? {
        identity?.candidates.first
    }

    /// nil means the cell is editable. Any other answer says why not.
    ///
    /// The order of the checks is the order of the rule, so the FIRST thing
    /// wrong is what is reported.
    static func reason(
        columns: [ColumnDef],
        rowIdentity: RowIdentity?,
        columnIndex: Int,
        dataRow: Int
    ) -> CellEditRefusal? {
        // 1. An identity with at least one key candidate.
        guard let identity = rowIdentity, let candidate = strongestCandidate(of: identity) else {
            return .noIdentity
        }

        // 2. This row's key string is not the "no identity" sentinel. The core
        //    writes "" for a NULL, missing or non-text key value, so an outer
        //    join's unmatched row cannot be named and must not be edited.
        guard dataRow >= 0, dataRow < candidate.keys.count,
              !candidate.keys[dataRow].isEmpty else {
            return .rowHasNoKey
        }

        // 3. Exactly one source table. A join's row belongs to several, and
        //    nothing in the result says which one an edit is meant for.
        guard identity.tableKeys.count == 1 else { return .multipleTables }

        // 4. The column is a real column OF THAT TABLE. An aggregate, an
        //    expression or a literal has no `relationOid`; a column of the
        //    other table in a (single-table-keyed) result has the wrong one.
        guard columnIndex >= 0, columnIndex < columns.count else { return .columnNotFromTable }
        let column = columns[columnIndex]
        guard let oid = tableOid(of: identity),
              column.relationOid == oid,
              column.relationAttno != nil else {
            return .columnNotFromTable
        }

        // 5. A type v1 can carry as text without guessing.
        guard isSupportedType(column.dataType) else {
            return .unsupportedType(column.dataType)
        }

        return nil
    }

    static func isEditable(
        columns: [ColumnDef],
        rowIdentity: RowIdentity?,
        columnIndex: Int,
        dataRow: Int
    ) -> Bool {
        reason(columns: columns, rowIdentity: rowIdentity, columnIndex: columnIndex, dataRow: dataRow) == nil
    }
}
