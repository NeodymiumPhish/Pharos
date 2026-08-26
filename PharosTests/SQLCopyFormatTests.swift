// Standalone test for the SQL text that "Copy as SQL WITH" and "Copy as SQL
// INSERT" put on the pasteboard. Compiled by scripts/test-sql-copy-format.sh.
//
// What this suite is FOR: a result column is NOT a bare identifier. An analyst
// writes `min(timestamp) AS "First Seen"`, so the column name arrives with a
// space in it; PG names an unnamed expression `?column?`; a name can hold an
// uppercase letter, or a `"` of its own. Emitted raw into `WITH cte(...)` every
// one of those is a syntax error, and the paste the whole feature exists for
// does not run. So each name must go through `quotedSqlIdentifier`.
//
// The builders are asserted directly rather than through the pasteboard: the
// copy runs on a background queue and lands on NSPasteboard, which the sweep
// has no way to read deterministically.
import AppKit

var failures = 0

private func expect(_ actual: String, _ expected: String, _ name: String) {
    if actual == expected { print("PASS \(name)") }
    else { failures += 1; print("FAIL \(name)\n  expected: \(expected)\n  actual:   \(actual)") }
}

private func expectContains(_ haystack: String, _ needle: String, _ name: String) {
    if haystack.contains(needle) { print("PASS \(name)") }
    else { failures += 1; print("FAIL \(name)\n  missing: \(needle)\n  in:      \(haystack)") }
}

// MARK: - Fixtures

private func data(_ names: [String], _ rows: [[String]]) -> CopyData {
    CopyData(columnNames: names,
             columnIndices: Array(names.indices),
             rows: rows,
             includeHeaders: true)
}

private func cols(_ types: [String]) -> [ColumnDef] {
    types.map { ColumnDef(name: "c", dataType: $0) }
}

private func cats(_ types: [String]) -> [PGTypeCategory] {
    types.map { PGTypeCategory(dataType: $0) }
}

// MARK: - Tests

/// The reported bug: an aliased aggregate gives a column name with a space in
/// it, and the emitted `WITH cte(First Seen, ...)` does not parse.
private func testAliasWithSpaceIsQuoted() {
    let types = ["timestamptz", "timestamptz"]
    let out = ResultsCopyExport.sqlWithStatement(
        data: data(["First Seen", "Last Seen"], [["2026-01-01 00:00:00+00", "2026-02-01 00:00:00+00"]]),
        categories: cats(types), columns: cols(types))

    expectContains(out, "WITH cte(\"First Seen\", \"Last Seen\") AS (",
                   "aliased columns are quoted, so the paste parses")
}

/// PG's own name for an unnamed expression column is `?column?`, which is not a
/// bare identifier either.
private func testUnnamedExpressionColumnIsQuoted() {
    let out = ResultsCopyExport.sqlWithStatement(
        data: data(["?column?"], [["1"]]),
        categories: cats(["int4"]), columns: cols(["int4"]))

    expectContains(out, "WITH cte(\"?column?\") AS (", "?column? is quoted")
}

/// A quoted name preserves case; unquoted, PG folds it to lower case and the
/// follow-on `SELECT "FirstSeen"` then finds no such column.
private func testMixedCaseNameKeepsItsCase() {
    let out = ResultsCopyExport.sqlWithStatement(
        data: data(["FirstSeen"], [["x"]]),
        categories: cats(["text"]), columns: cols(["text"]))

    expectContains(out, "WITH cte(\"FirstSeen\") AS (", "mixed case survives quoting")
}

/// A `"` inside the name is doubled, so a hostile alias stays one identifier
/// instead of closing the column list.
private func testEmbeddedQuoteIsDoubled() {
    let out = ResultsCopyExport.sqlWithStatement(
        data: data([#"a") AS (SELECT 1); DROP TABLE t; --"#], [["x"]]),
        categories: cats(["text"]), columns: cols(["text"]))

    expectContains(out, #"WITH cte("a"") AS (SELECT 1); DROP TABLE t; --") AS ("#,
                   "embedded quote doubled — no breakout from the column list")
}

/// A plain name still comes out as one quoted identifier, and the rest of the
/// statement — the VALUES block, the first-row casts, the trailing SELECT —
/// is unchanged by the quoting work.
private func testWholeStatementShape() {
    let types = ["int4", "text"]
    let out = ResultsCopyExport.sqlWithStatement(
        data: data(["id", "name"], [["1", "alice"], ["2", "bob"]]),
        categories: cats(types), columns: cols(types))

    expect(out, """
    WITH cte("id", "name") AS (
      VALUES
        (1::int4, 'alice'::text),
        (2, 'bob')
    )
    SELECT * FROM cte;
    """, "whole statement: quoted names, first-row casts, trailing SELECT")
}

/// NULL in the first row keeps its cast, and the name beside it is still
/// quoted — the two paths are built in the same loop.
private func testNullFirstRowKeepsCast() {
    let types = ["int4"]
    let out = ResultsCopyExport.sqlWithStatement(
        data: data(["Row Count"], [["NULL"], ["7"]]),
        categories: cats(types), columns: cols(types))

    expect(out, """
    WITH cte("Row Count") AS (
      VALUES
        (NULL::int4),
        (7)
    )
    SELECT * FROM cte;
    """, "first-row NULL keeps its cast beside a quoted name")
}

/// INSERT quoted its names already, but with a raw `"` wrapper that does not
/// double an embedded quote. It shares the quoter now.
private func testInsertQuotesTheSameWay() {
    let out = ResultsCopyExport.sqlInsertStatements(
        data: data(["First Seen", #"a"b"#], [["2026-01-01", "x"]]),
        categories: cats(["timestamptz", "text"]))

    expect(out, #"INSERT INTO table_name ("First Seen", "a""b") VALUES ('2026-01-01', 'x');"#,
           "INSERT quotes an aliased name and doubles an embedded quote")
}

func runTests() {
    testAliasWithSpaceIsQuoted()
    testUnnamedExpressionColumnIsQuoted()
    testMixedCaseNameKeepsItsCase()
    testEmbeddedQuoteIsDoubled()
    testWholeStatementShape()
    testNullFirstRowKeepsCast()
    testInsertQuotesTheSameWay()

    print(failures == 0 ? "\nAll tests passed" : "\n\(failures) test(s) failed")
    exit(failures == 0 ? 0 : 1)
}
