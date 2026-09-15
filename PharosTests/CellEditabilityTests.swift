// Standalone test for `CellEditability` — compiled by
// scripts/test-cell-editability.sh.
//
// What this suite is FOR: this is the rule that decides whether the app will
// offer to WRITE to the user's database, and every one of its five points
// exists to stop a specific wrong write.
//
//   no identity          → there is no key, so no WHERE clause can name a row
//   this row has no key  → an outer join's unmatched row names nothing
//   two source tables    → a join's row is not one table's row
//   column not the table's → an aggregate/expression/literal has nothing to write to
//   unsupported type     → a wrong text cast on an array is a SILENT data change
//
// Each case below poses exactly one fault and asserts the refusal names it, so
// a rule that collapsed into "anything goes if there is a primary key" could
// not pass. The good case at the end proves the rule is not simply "no".
import Foundation

var failures = 0

private func expect(_ actual: CellEditRefusal?, _ expected: CellEditRefusal?, _ name: String) {
    if actual == expected { print("PASS \(name)") }
    else {
        failures += 1
        print("FAIL \(name)\n  expected: \(String(describing: expected))\n  actual:   \(String(describing: actual))")
    }
}

private func expectTrue(_ condition: Bool, _ name: String) {
    if condition { print("PASS \(name)") }
    else { failures += 1; print("FAIL \(name)") }
}

// MARK: - Fixtures

private let usersOid: UInt32 = 16_400
private let teamsOid: UInt32 = 16_500

/// `select id, name from public.users` — id is the primary key, two rows.
private func usersColumns() -> [ColumnDef] {
    [
        ColumnDef(name: "id", dataType: "INT4", relationOid: usersOid, relationAttno: 1),
        ColumnDef(name: "name", dataType: "TEXT", relationOid: usersOid, relationAttno: 2),
    ]
}

private func usersIdentity(
    keys: [String] = ["V1:1", "V1:2"],
    tableKeys: [String] = ["oid:16400"],
    candidates: [KeySet]? = nil
) -> RowIdentity {
    RowIdentity(
        tableKey: "oid:\(usersOid)",
        tableDisplay: "public.users",
        tableKeys: tableKeys,
        candidates: candidates ?? [KeySet(kind: "pk", keyColumns: ["id"], keys: keys)]
    )
}

// MARK: - The five points

private func testNoIdentityRefuses() {
    expect(CellEditability.reason(columns: usersColumns(), rowIdentity: nil, columnIndex: 1, dataRow: 0),
           .noIdentity, "a result the core could not attribute to a table is read-only")
}

private func testFingerprintTierRefuses() {
    // An identity block with an EMPTY candidates array is the fingerprint tier:
    // the table is known, but no key of it is complete in the result.
    let identity = usersIdentity(candidates: [])
    expect(CellEditability.reason(columns: usersColumns(), rowIdentity: identity, columnIndex: 1, dataRow: 0),
           .noIdentity, "a result with a table but no complete key is read-only")
}

private func testRowWithNoKeyRefuses() {
    // "" is the core's own "this row has no identity" sentinel — a NULL key
    // from an outer join. Row 0 has a key, row 1 does not, so the fixture also
    // proves the check is PER ROW and not per result.
    let identity = usersIdentity(keys: ["V1:1", ""])
    expect(CellEditability.reason(columns: usersColumns(), rowIdentity: identity, columnIndex: 1, dataRow: 1),
           .rowHasNoKey, "a row whose key value is NULL is read-only")
    expect(CellEditability.reason(columns: usersColumns(), rowIdentity: identity, columnIndex: 1, dataRow: 0),
           nil, "while its neighbour, which has a key, is not")
}

private func testRowBeyondTheKeyListRefuses() {
    let identity = usersIdentity(keys: ["V1:1"])
    expect(CellEditability.reason(columns: usersColumns(), rowIdentity: identity, columnIndex: 1, dataRow: 5),
           .rowHasNoKey, "a row with no entry in the key list at all is read-only")
}

private func testTwoSourceTablesRefuse() {
    // A join. Every other point is satisfied — the primary key is complete,
    // the row has a key, the column is `users.name`, the type is TEXT — so the
    // ONLY thing this case can be refused for is the second table.
    let identity = usersIdentity(tableKeys: ["oid:16400", "oid:16500"])
    expect(CellEditability.reason(columns: usersColumns(), rowIdentity: identity, columnIndex: 1, dataRow: 0),
           .multipleTables, "a join result is read-only even with a complete key")
}

private func testAggregateColumnRefuses() {
    // `select id, count(*) from users group by id` — the aggregate has no
    // source table at all.
    let columns = [
        ColumnDef(name: "id", dataType: "INT4", relationOid: usersOid, relationAttno: 1),
        ColumnDef(name: "count", dataType: "INT8", relationOid: nil, relationAttno: nil),
    ]
    expect(CellEditability.reason(columns: columns, rowIdentity: usersIdentity(), columnIndex: 1, dataRow: 0),
           .columnNotFromTable, "an aggregate column is read-only")
}

private func testColumnOfAnotherTableRefuses() {
    // The identity names `users`, and the column belongs to `teams`. Distinct
    // from the aggregate case: this column HAS a source table, just not the
    // one an edit would be written to.
    let columns = [
        ColumnDef(name: "id", dataType: "INT4", relationOid: usersOid, relationAttno: 1),
        ColumnDef(name: "team", dataType: "TEXT", relationOid: teamsOid, relationAttno: 2),
    ]
    expect(CellEditability.reason(columns: columns, rowIdentity: usersIdentity(), columnIndex: 1, dataRow: 0),
           .columnNotFromTable, "a column of a different table is read-only")
}

private func testColumnWithNoAttnoRefuses() {
    let columns = [
        ColumnDef(name: "id", dataType: "INT4", relationOid: usersOid, relationAttno: 1),
        ColumnDef(name: "name", dataType: "TEXT", relationOid: usersOid, relationAttno: nil),
    ]
    expect(CellEditability.reason(columns: columns, rowIdentity: usersIdentity(), columnIndex: 1, dataRow: 0),
           .columnNotFromTable, "a column with a table but no attnum is read-only")
}

private func testColumnIndexOutOfRangeRefuses() {
    expect(CellEditability.reason(columns: usersColumns(), rowIdentity: usersIdentity(), columnIndex: 9, dataRow: 0),
           .columnNotFromTable, "a column index past the end is read-only")
}

private func testUnsupportedTypesRefuse() {
    for type in ["TEXT[]", "JSONB", "BYTEA", "INTERVAL", "INT4RANGE", "my_enum", "POINT", "TIMETZ"] {
        let columns = [
            ColumnDef(name: "id", dataType: "INT4", relationOid: usersOid, relationAttno: 1),
            ColumnDef(name: "value", dataType: type, relationOid: usersOid, relationAttno: 2),
        ]
        expect(CellEditability.reason(columns: columns, rowIdentity: usersIdentity(), columnIndex: 1, dataRow: 0),
               .unsupportedType(type), "a \(type) column is read-only in v1")
    }
}

private func testSupportedTypesAreAccepted() {
    // Every family the design admits, in the spelling sqlx's PgTypeInfo
    // actually reports, plus the lower-case spellings a cached history entry
    // can carry.
    for type in ["TEXT", "VARCHAR", "BPCHAR", "INT2", "INT4", "INT8",
                 "NUMERIC", "FLOAT4", "FLOAT8", "BOOL", "DATE",
                 "TIMESTAMP", "TIMESTAMPTZ", "UUID", "text", "timestamptz"] {
        let columns = [
            ColumnDef(name: "id", dataType: "INT4", relationOid: usersOid, relationAttno: 1),
            ColumnDef(name: "value", dataType: type, relationOid: usersOid, relationAttno: 2),
        ]
        expect(CellEditability.reason(columns: columns, rowIdentity: usersIdentity(), columnIndex: 1, dataRow: 0),
               nil, "a \(type) column is editable")
    }
}

private func testTheGoodCase() {
    expect(CellEditability.reason(columns: usersColumns(), rowIdentity: usersIdentity(), columnIndex: 1, dataRow: 0),
           nil, "a single-table result with a complete primary key is editable")
    expectTrue(CellEditability.isEditable(columns: usersColumns(), rowIdentity: usersIdentity(),
                                          columnIndex: 1, dataRow: 0),
               "and isEditable agrees")
    // The key column itself is editable too: the WHERE clause is built from the
    // value as LOADED, so changing a primary key is a legitimate edit.
    expect(CellEditability.reason(columns: usersColumns(), rowIdentity: usersIdentity(), columnIndex: 0, dataRow: 0),
           nil, "the key column is editable as well")
}

private func testAUniqueIndexMayStandInForAMissingPrimaryKey() {
    // `choose_candidates` puts the strongest candidate first; when there is no
    // primary key in the result, that is the unique index.
    let identity = usersIdentity(
        candidates: [KeySet(kind: "unique", keyColumns: ["name"], keys: ["V5:alice", "V3:bob"])])
    expect(CellEditability.reason(columns: usersColumns(), rowIdentity: identity, columnIndex: 1, dataRow: 0),
           nil, "a unique index is enough to make a result editable")
}

private func testTheStrongestCandidateIsTheFirst() {
    let pk = KeySet(kind: "pk", keyColumns: ["id"], keys: ["V1:1", ""])
    let unique = KeySet(kind: "unique", keyColumns: ["name"], keys: ["V5:alice", "V3:bob"])
    let identity = usersIdentity(candidates: [pk, unique])
    expectTrue(CellEditability.strongestCandidate(of: identity)?.kind == "pk",
               "the first candidate is the one used")
    // Row 1 has no PRIMARY KEY value, but does have a unique one. The rule must
    // still refuse it: the WHERE clause is built from the strongest candidate,
    // and falling back per row would match on a key the request does not carry.
    expect(CellEditability.reason(columns: usersColumns(), rowIdentity: identity, columnIndex: 1, dataRow: 1),
           .rowHasNoKey, "a row missing the STRONGEST key is refused, not quietly demoted")
}

private func testTableOidParsing() {
    expectTrue(CellEditability.tableOid(of: usersIdentity()) == usersOid, "oid:N parses to N")
    let odd = RowIdentity(tableKey: "unknown", tableDisplay: "x.y", tableKeys: ["unknown"],
                          candidates: [KeySet(kind: "pk", keyColumns: ["id"], keys: ["V1:1"])])
    expectTrue(CellEditability.tableOid(of: odd) == nil, "any other table_key shape parses to nil")
    // And a table key it cannot parse must refuse every column rather than
    // match one whose relationOid is also absent.
    let columns = [ColumnDef(name: "id", dataType: "INT4", relationOid: nil, relationAttno: nil)]
    expect(CellEditability.reason(columns: columns, rowIdentity: odd, columnIndex: 0, dataRow: 0),
           .columnNotFromTable, "an unparseable table key does not match a column with no table")
}

func runTests() {
    testNoIdentityRefuses()
    testFingerprintTierRefuses()
    testRowWithNoKeyRefuses()
    testRowBeyondTheKeyListRefuses()
    testTwoSourceTablesRefuse()
    testAggregateColumnRefuses()
    testColumnOfAnotherTableRefuses()
    testColumnWithNoAttnoRefuses()
    testColumnIndexOutOfRangeRefuses()
    testUnsupportedTypesRefuse()
    testSupportedTypesAreAccepted()
    testTheGoodCase()
    testAUniqueIndexMayStandInForAMissingPrimaryKey()
    testTheStrongestCandidateIsTheFirst()
    testTableOidParsing()

    print(failures == 0 ? "\nAll tests passed" : "\n\(failures) test(s) failed")
    exit(failures == 0 ? 0 : 1)
}
