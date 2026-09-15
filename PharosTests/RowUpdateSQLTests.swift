// Standalone test for `RowUpdateSQLBuilder` — compiled by
// scripts/test-row-update-sql.sh.
//
// What this suite is FOR, in two halves.
//
// The REQUEST half is the one that can corrupt data: `rows[i].key`,
// `oldValues` and `newValues` have to align with `keyColumns` and `columns`
// position for position, because the core reads them by position and binds
// them. A request whose newValues are one place out writes a value into the
// wrong column, silently and inside a committed transaction. So the alignment
// is asserted with a fixture where the columns are DELIBERATELY not in result
// order and the values are distinguishable.
//
// The TEXT half is what the user reads before approving. It is never executed
// (see the file header of RowUpdateSQLBuilder), so a quoting bug there is not
// an injection — but a preview that does not match what runs is worse than no
// preview, so the statements mirror the core's shape exactly: one UPDATE per
// row, the key equality, then the old-value guard as IS NOT DISTINCT FROM.
import Foundation

var failures = 0

private func expect(_ actual: String, _ expected: String, _ name: String) {
    if actual == expected { print("PASS \(name)") }
    else { failures += 1; print("FAIL \(name)\n  expected: \(expected)\n  actual:   \(actual)") }
}

private func expect(_ actual: Int, _ expected: Int, _ name: String) {
    if actual == expected { print("PASS \(name)") }
    else { failures += 1; print("FAIL \(name)\n  expected: \(expected)\n  actual:   \(actual)") }
}

private func expect(_ actual: [String?], _ expected: [String?], _ name: String) {
    if actual == expected { print("PASS \(name)") }
    else { failures += 1; print("FAIL \(name)\n  expected: \(expected)\n  actual:   \(actual)") }
}

private func expectTrue(_ condition: Bool, _ name: String) {
    if condition { print("PASS \(name)") }
    else { failures += 1; print("FAIL \(name)") }
}

// MARK: - Fixtures

private let usersOid: UInt32 = 16_400

private func column(_ name: String, _ type: String, attno: Int16) -> ColumnDef {
    ColumnDef(name: name, dataType: type, relationOid: usersOid, relationAttno: attno)
}

private func identity(kind: String = "pk", keyColumns: [String] = ["id"], keys: [String],
                      display: String = "public.users") -> RowIdentity {
    RowIdentity(tableKey: "oid:\(usersOid)", tableDisplay: display, tableKeys: ["oid:\(usersOid)"],
                candidates: [KeySet(kind: kind, keyColumns: keyColumns, keys: keys)])
}

private func row(_ values: String?...) -> [AnyCodable] {
    values.map { AnyCodable($0) }
}

// MARK: - Literals

private func testLiteralRendering() {
    expect(RowUpdateSQLBuilder.literal(nil, dataType: "TEXT"), "NULL", "a nil renders as a bare NULL")
    expect(RowUpdateSQLBuilder.literal("", dataType: "TEXT"), "''", "an empty string renders as two quotes, not as NULL")
    expect(RowUpdateSQLBuilder.literal("alice", dataType: "TEXT"), "'alice'", "text is single-quoted")
    expect(RowUpdateSQLBuilder.literal("42", dataType: "INT4"), "42", "a number is bare")
    expect(RowUpdateSQLBuilder.literal("-3.5", dataType: "NUMERIC"), "-3.5", "a signed decimal is bare")
    expect(RowUpdateSQLBuilder.literal("t", dataType: "BOOL"), "true", "PostgreSQL's t becomes true")
    expect(RowUpdateSQLBuilder.literal("f", dataType: "BOOL"), "false", "PostgreSQL's f becomes false")
    expect(RowUpdateSQLBuilder.literal("2026-09-15", dataType: "DATE"), "'2026-09-15'", "a date is quoted")
    expect(RowUpdateSQLBuilder.literal("a9f4-1465", dataType: "UUID"), "'a9f4-1465'", "a uuid is quoted")
}

private func testHostileLiteralsStayOneValue() {
    expect(RowUpdateSQLBuilder.literal("O'Brien", dataType: "TEXT"), "'O''Brien'",
           "an embedded quote is doubled")
    expect(RowUpdateSQLBuilder.literal("x'; DROP TABLE users; --", dataType: "TEXT"),
           "'x''; DROP TABLE users; --'",
           "a whole injection attempt stays inside one quoted literal")
    // A numeric COLUMN holding something that is not a number: quoted, so the
    // preview cannot read as an identifier or an operator.
    expect(RowUpdateSQLBuilder.literal("1; DROP TABLE users", dataType: "INT4"),
           "'1; DROP TABLE users'", "a non-numeric value in a numeric column is quoted")
    expect(RowUpdateSQLBuilder.literal("maybe", dataType: "BOOL"), "'maybe'",
           "a non-boolean value in a boolean column is quoted")
}

// MARK: - Key description and footnote

private func testKeyDescription() {
    expect(RowUpdateSQLBuilder.keyDescription(kind: "pk", columns: ["id"]),
           "primary key (id)", "a primary key names itself")
    expect(RowUpdateSQLBuilder.keyDescription(kind: "unique", columns: ["email"]),
           "unique index (email)", "a unique index names itself")
    expect(RowUpdateSQLBuilder.keyDescription(kind: "pk", columns: ["tenant", "id"]),
           "primary key (tenant, id)", "a compound key lists every column")
}

private func testFootnoteNamesTheUniqueIndex() {
    // Open decision 3: a unique index may stand in for a missing primary key,
    // but ONLY because the sheet says so. This is that sentence.
    let columns = [column("email", "TEXT", attno: 3), column("name", "TEXT", attno: 2)]
    var pending = PendingCellEdits()
    pending.set(PendingEdit(dataRow: 0, columnIndex: 1, oldText: "alice", newText: "Zed"))
    guard let request = RowUpdateSQLBuilder.makeRequest(
        pending: pending, columns: columns,
        rows: [row("a@b.c", "alice")],
        rowIdentity: identity(kind: "unique", keyColumns: ["email"], keys: ["V5:a@b.c"]))
    else { failures += 1; print("FAIL a unique-index request is built"); return }
    expect(RowUpdateSQLBuilder.footnote(for: request),
           "Rows are matched on the unique index (email).",
           "the footnote names the unique index the rows are matched on")

    guard let pkRequest = RowUpdateSQLBuilder.makeRequest(
        pending: pending, columns: [column("id", "INT4", attno: 1), column("name", "TEXT", attno: 2)],
        rows: [row("1", "alice")],
        rowIdentity: identity(keys: ["V1:1"]))
    else { failures += 1; print("FAIL a primary-key request is built"); return }
    expect(RowUpdateSQLBuilder.footnote(for: pkRequest),
           "Rows are matched on the primary key (id).",
           "and names the primary key when that is what was used")
}

// MARK: - Statement text

private func testOneStatementPerRow() {
    let columns = [column("id", "INT4", attno: 1), column("name", "TEXT", attno: 2)]
    var pending = PendingCellEdits()
    pending.set(PendingEdit(dataRow: 0, columnIndex: 1, oldText: "alice", newText: "Zed"))
    pending.set(PendingEdit(dataRow: 2, columnIndex: 1, oldText: "carol", newText: "Cara"))
    guard let request = RowUpdateSQLBuilder.makeRequest(
        pending: pending, columns: columns,
        rows: [row("1", "alice"), row("2", "bob"), row("3", "carol")],
        rowIdentity: identity(keys: ["V1:1", "V1:2", "V1:3"]))
    else { failures += 1; print("FAIL a two-row request is built"); return }

    let statements = RowUpdateSQLBuilder.statements(for: request)
    expect(statements.count, 2, "two edited rows make two statements")
    expect(statements[0],
           #"UPDATE "public"."users" SET "name" = 'Zed' WHERE "id" = 1 AND "name" IS NOT DISTINCT FROM 'alice';"#,
           "the first statement carries the key equality and the old-value guard")
    expect(statements[1],
           #"UPDATE "public"."users" SET "name" = 'Cara' WHERE "id" = 3 AND "name" IS NOT DISTINCT FROM 'carol';"#,
           "and the second names its own row")
    expect(RowUpdateSQLBuilder.text(for: request), statements.joined(separator: "\n"),
           "the block is the statements, one per line")
    expect(RowUpdateSQLBuilder.changeCount(for: request), 2, "two changed cells count two")
    expect(RowUpdateSQLBuilder.title(for: request), "Apply 2 changes to public.users?",
           "the title counts the changes and names the table")
}

private func testTitleIsSingularForOneChange() {
    let columns = [column("id", "INT4", attno: 1), column("name", "TEXT", attno: 2)]
    var pending = PendingCellEdits()
    pending.set(PendingEdit(dataRow: 0, columnIndex: 1, oldText: "alice", newText: "Zed"))
    guard let request = RowUpdateSQLBuilder.makeRequest(
        pending: pending, columns: columns, rows: [row("1", "alice")],
        rowIdentity: identity(keys: ["V1:1"]))
    else { failures += 1; print("FAIL a one-change request is built"); return }
    expect(RowUpdateSQLBuilder.title(for: request), "Apply 1 change to public.users?",
           "one change reads as a change, not as changes")
}

private func testHostileIdentifiersStayOneIdentifier() {
    // A column literally named `a"; DROP TABLE x; --`. `quotedSqlIdentifier`
    // doubles the quote, so the whole thing is still ONE identifier.
    let nasty = #"a"; DROP TABLE x; --"#
    let columns = [column("id", "INT4", attno: 1), column(nasty, "TEXT", attno: 2)]
    var pending = PendingCellEdits()
    pending.set(PendingEdit(dataRow: 0, columnIndex: 1, oldText: "old", newText: "new"))
    guard let request = RowUpdateSQLBuilder.makeRequest(
        pending: pending, columns: columns, rows: [row("1", "old")],
        rowIdentity: identity(keys: ["V1:1"], display: #"pub"lic.us"ers"#))
    else { failures += 1; print("FAIL a hostile-name request is built"); return }
    expect(RowUpdateSQLBuilder.statements(for: request)[0],
           #"UPDATE "pub""lic"."us""ers" SET "a""; DROP TABLE x; --" = 'new' WHERE "id" = 1 AND "a""; DROP TABLE x; --" IS NOT DISTINCT FROM 'old';"#,
           "every quote in a schema, table or column name is doubled")
}

private func testCompoundKeyAndNulls() {
    // Compound key, a NULL new value (Set NULL) and a NULL old value (the cell
    // was NULL when loaded). The old-value guard has to be IS NOT DISTINCT
    // FROM for exactly this: with `=` a NULL old value would compare unknown,
    // the row would match nothing, and an ordinary edit of a NULL cell would
    // roll the whole transaction back.
    let columns = [
        column("tenant", "INT4", attno: 1),
        column("id", "INT4", attno: 2),
        column("note", "TEXT", attno: 3),
        column("nick", "TEXT", attno: 4),
    ]
    var pending = PendingCellEdits()
    pending.set(PendingEdit(dataRow: 0, columnIndex: 2, oldText: "hi", newText: nil))
    pending.set(PendingEdit(dataRow: 0, columnIndex: 3, oldText: nil, newText: "zed"))
    guard let request = RowUpdateSQLBuilder.makeRequest(
        pending: pending, columns: columns, rows: [row("7", "1", "hi", nil)],
        rowIdentity: identity(keyColumns: ["tenant", "id"], keys: ["V1:7V1:1"]))
    else { failures += 1; print("FAIL a compound-key request is built"); return }

    expect(request.keyColumns.map(\.name).joined(separator: ","), "tenant,id",
           "both key columns travel, in key order")
    expect(request.rows[0].key, ["7", "1"], "and so do both key values, aligned with them")
    expect(RowUpdateSQLBuilder.statements(for: request)[0],
           #"UPDATE "public"."users" SET "note" = NULL, "nick" = 'zed' WHERE "tenant" = 7 AND "id" = 1 AND "note" IS NOT DISTINCT FROM 'hi' AND "nick" IS NOT DISTINCT FROM NULL;"#,
           "a NULL new value and a NULL old value both render bare, under IS NOT DISTINCT FROM")
    expect(RowUpdateSQLBuilder.footnote(for: request),
           "Rows are matched on the primary key (tenant, id).",
           "the footnote lists both key columns")
}

// MARK: - Request construction

/// The alignment assertion. The key column is at result index 2 and the edited
/// columns at 0 and 3, so a builder that assumed result order, or that reused
/// one index for both lists, gives visibly different values here.
private func testRequestAlignment() {
    let columns = [
        column("name", "TEXT", attno: 2),
        column("note", "TEXT", attno: 5),
        column("id", "INT4", attno: 1),
        column("nick", "TEXT", attno: 4),
    ]
    var pending = PendingCellEdits()
    pending.set(PendingEdit(dataRow: 1, columnIndex: 3, oldText: "nick-b", newText: "NICK-B"))
    pending.set(PendingEdit(dataRow: 1, columnIndex: 0, oldText: "bob", newText: "BOB"))
    guard let request = RowUpdateSQLBuilder.makeRequest(
        pending: pending, columns: columns,
        rows: [row("alice", "note-a", "1", "nick-a"), row("bob", "note-b", "2", "nick-b")],
        rowIdentity: identity(keys: ["V1:1", "V1:2"]))
    else { failures += 1; print("FAIL an out-of-order request is built"); return }

    expect(request.schema, "public", "the schema is split off the table display name")
    expect(request.table, "users", "and so is the table")
    expect(request.columns.map(\.name).joined(separator: ","), "name,nick",
           "the edited columns travel in RESULT order, not in edit order")
    expect(request.columns.map(\.dataType).joined(separator: ","), "TEXT,TEXT",
           "each with its own data type, for the core's cast")
    expect(request.keyColumns.map(\.name).joined(separator: ","), "id",
           "the key column is found by name even though it is not first")
    expect(request.rows.count, 1, "only the edited row travels")
    expect(request.rows[0].key, ["2"], "the key value is read from the key column's position")
    expect(request.rows[0].oldValues, ["bob", "nick-b"], "the old values align with columns")
    expect(request.rows[0].newValues, ["BOB", "NICK-B"], "and so do the new ones")
    expect(request.keyDescription, "primary key (id)", "the request carries the key's name for the sheet")
}

private func testAnUneditedColumnOfAnEditedRowIsWrittenBackUnchanged() {
    // Row 0 edits `name`; row 1 edits `nick`. Both rows carry both columns, so
    // every statement has the same shape — and the cell each row did NOT edit
    // is written back with the value it already has, which the count must not
    // mistake for a change.
    let columns = [column("id", "INT4", attno: 1), column("name", "TEXT", attno: 2),
                   column("nick", "TEXT", attno: 3)]
    var pending = PendingCellEdits()
    pending.set(PendingEdit(dataRow: 0, columnIndex: 1, oldText: "alice", newText: "Zed"))
    pending.set(PendingEdit(dataRow: 1, columnIndex: 2, oldText: "bee", newText: "Bea"))
    guard let request = RowUpdateSQLBuilder.makeRequest(
        pending: pending, columns: columns,
        rows: [row("1", "alice", "ali"), row("2", "bob", "bee")],
        rowIdentity: identity(keys: ["V1:1", "V1:2"]))
    else { failures += 1; print("FAIL a mixed-column request is built"); return }
    expect(request.rows[0].newValues, ["Zed", "ali"], "row 0 keeps its own nick")
    expect(request.rows[1].newValues, ["bob", "Bea"], "row 1 keeps its own name")
    expect(RowUpdateSQLBuilder.changeCount(for: request), 2,
           "the count is of CHANGED cells, not of written ones")
}

private func testRefusals() {
    let columns = [column("id", "INT4", attno: 1), column("name", "TEXT", attno: 2)]
    var pending = PendingCellEdits()
    pending.set(PendingEdit(dataRow: 0, columnIndex: 1, oldText: "alice", newText: "Zed"))
    let rows = [row("1", "alice")]

    expectTrue(RowUpdateSQLBuilder.makeRequest(pending: PendingCellEdits(), columns: columns,
                                               rows: rows, rowIdentity: identity(keys: ["V1:1"])) == nil,
               "an empty pending set builds no request")
    expectTrue(RowUpdateSQLBuilder.makeRequest(pending: pending, columns: columns,
                                               rows: rows, rowIdentity: nil) == nil,
               "no identity builds no request")

    let joined = RowIdentity(tableKey: "oid:\(usersOid)", tableDisplay: "public.users",
                             tableKeys: ["oid:\(usersOid)", "oid:99"],
                             candidates: [KeySet(kind: "pk", keyColumns: ["id"], keys: ["V1:1"])])
    expectTrue(RowUpdateSQLBuilder.makeRequest(pending: pending, columns: columns,
                                               rows: rows, rowIdentity: joined) == nil,
               "a join builds no request even if a key is complete")

    let unknown = RowIdentity(tableKey: "oid:\(usersOid)", tableDisplay: "unknown table (oid 16400)",
                              tableKeys: ["oid:\(usersOid)"],
                              candidates: [KeySet(kind: "pk", keyColumns: ["id"], keys: ["V1:1"])])
    expectTrue(RowUpdateSQLBuilder.makeRequest(pending: pending, columns: columns,
                                               rows: rows, rowIdentity: unknown) == nil,
               "a table the core could not name builds no request")

    expectTrue(RowUpdateSQLBuilder.makeRequest(pending: pending, columns: columns,
                                               rows: [row(nil, "alice")],
                                               rowIdentity: identity(keys: ["V1:1"])) == nil,
               "a NULL key value builds no request")

    let missingKey = [column("name", "TEXT", attno: 2)]
    expectTrue(RowUpdateSQLBuilder.makeRequest(pending: pending, columns: missingKey,
                                               rows: [row("alice")],
                                               rowIdentity: identity(keys: ["V1:1"])) == nil,
               "a key column that is not in the result builds no request")
}

private func testSplitQualifiedName() {
    expectTrue(RowUpdateSQLBuilder.splitQualifiedName("public.users")! == ("public", "users"),
               "schema.table splits at the dot")
    // Split at the FIRST dot: a dot is far likelier inside a table name than
    // inside a schema name, and the core builds the string as nspname || '.' || relname.
    expectTrue(RowUpdateSQLBuilder.splitQualifiedName("public.my.table")! == ("public", "my.table"),
               "a dotted table name keeps its dot")
    expectTrue(RowUpdateSQLBuilder.splitQualifiedName("users") == nil, "no dot means no split")
    expectTrue(RowUpdateSQLBuilder.splitQualifiedName(".users") == nil, "an empty schema is refused")
    expectTrue(RowUpdateSQLBuilder.splitQualifiedName("public.") == nil, "an empty table is refused")
}

func runTests() {
    testLiteralRendering()
    testHostileLiteralsStayOneValue()
    testKeyDescription()
    testFootnoteNamesTheUniqueIndex()
    testOneStatementPerRow()
    testTitleIsSingularForOneChange()
    testHostileIdentifiersStayOneIdentifier()
    testCompoundKeyAndNulls()
    testRequestAlignment()
    testAnUneditedColumnOfAnEditedRowIsWrittenBackUnchanged()
    testRefusals()
    testSplitQualifiedName()

    print(failures == 0 ? "\nAll tests passed" : "\n\(failures) test(s) failed")
    exit(failures == 0 ? 0 : 1)
}
