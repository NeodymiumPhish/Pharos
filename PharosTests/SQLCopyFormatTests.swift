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

private func data(_ names: [String], _ rows: [[String?]]) -> CopyData {
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
        data: data(["Row Count"], [[nil], ["7"]]),
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

/// NULL, the empty string and the text `NULL` are three different values.
/// `CopyData` used to carry all three as `""`/`"NULL"`, so an empty string
/// exported as SQL NULL and a text value that read `NULL` did too.
private func testNullEmptyAndNullTextAreDistinct() {
    let out = ResultsCopyExport.sqlInsertStatements(
        data: data(["a", "b", "c"], [[nil, "", "NULL"]]),
        categories: cats(["text", "text", "text"]))
    expect(out, #"INSERT INTO table_name ("a", "b", "c") VALUES (NULL, '', 'NULL');"#,
           "INSERT tells NULL from '' from 'NULL'")

    let with = ResultsCopyExport.sqlWithStatement(
        data: data(["a", "b"], [["", nil], [nil, "NULL"]]),
        categories: cats(["text", "text"]), columns: cols(["text", "text"]))
    expectContains(with, "(''::text, NULL::text)", "WITH keeps an empty string as ''")
    expectContains(with, "(NULL, 'NULL')", "WITH keeps the text NULL as a literal")
}

/// Text formats: NULL is an empty field; a field holding the separator or a
/// line break is quoted so it stays one cell on paste.
private func testTextFieldRendering() {
    expect(ResultsCopyExport.tsvField(nil), "", "TSV NULL is an empty field")
    expect(ResultsCopyExport.tsvField("plain"), "plain", "TSV plain value is untouched")
    expect(ResultsCopyExport.tsvField("a\tb"), "\"a\tb\"", "TSV quotes an embedded tab")
    expect(ResultsCopyExport.tsvField("a\nb"), "\"a\nb\"", "TSV quotes an embedded newline")
    expect(ResultsCopyExport.tsvField("say \"hi\""), "\"say \"\"hi\"\"\"", "TSV doubles an embedded quote")
    expect(ResultsCopyExport.csvEscape("a\rb"), "\"a\rb\"", "CSV quotes a bare carriage return")
    expect(ResultsCopyExport.markdownField(nil), "", "Markdown NULL is an empty cell")
    expect(ResultsCopyExport.markdownField("x|y"), "x\\|y", "Markdown escapes a pipe")
    expect(ResultsCopyExport.markdownField("a\r\nb"), "a<br>b", "Markdown folds CRLF to one <br>")
}

/// The four characters HTML markup is sensitive to, each escaped to its
/// entity — in both a header cell and a data cell, so neither path was missed.
private func testHtmlEscapesTheFourCharacters() {
    let out = ResultsCopyExport.htmlTable(
        data: data(["a&b<c>"], [[#"<script>x</script> & "quoted""#]]),
        includeHeaders: true)
    expectContains(out, "<th>a&amp;b&lt;c&gt;</th>", "HTML escapes & < > in a header")
    expectContains(out, "<td>&lt;script&gt;x&lt;/script&gt; &amp; &quot;quoted&quot;</td>",
                   "HTML escapes & < > \" in a cell")
}

/// A SQL NULL is an empty `<td></td>`, not the text "NULL" and not a missing
/// cell — the same nil-is-a-distinct-value rule the SQL and text builders
/// already follow (see `testNullEmptyAndNullTextAreDistinct` above).
private func testHtmlNullIsEmptyCell() {
    let out = ResultsCopyExport.htmlTable(data: data(["a", "b"], [[nil, ""]]), includeHeaders: false)
    expect(out, "<table><tbody><tr><td></td><td></td></tr></tbody></table>",
           "HTML NULL and empty-string both render, NULL as an empty cell")
}

/// The "Include Headers" toggle governs the HTML table exactly like the other
/// formats: a `<thead>` when on, none when off.
private func testHtmlHeadersToggle() {
    let withHeaders = ResultsCopyExport.htmlTable(data: data(["a"], [["1"]]), includeHeaders: true)
    expectContains(withHeaders, "<thead><tr><th>a</th></tr></thead>", "headers on emits a <thead>")

    let withoutHeaders = ResultsCopyExport.htmlTable(data: data(["a"], [["1"]]), includeHeaders: false)
    if withoutHeaders.contains("<thead>") {
        failures += 1
        print("FAIL headers off omits <thead>\n  actual: \(withoutHeaders)")
    } else {
        print("PASS headers off omits <thead>")
    }
}

/// The `.tabularText` pasteboard representation is always TSV, no matter which
/// format button the analyst pressed — "Copy as SQL WITH" still carries a TSV
/// table alongside the SQL text.
private func testTabularRepresentationIsAlwaysTSV() {
    let d = data(["a", "b"], [["1", "2"], [nil, "x\ty"]])
    let tsv = ResultsCopyExport.tsvText(data: d)
    expect(tsv, "a\tb\n1\t2\n\t\"x\ty\"", "the tabular payload is TSV regardless of the chosen format")
}

/// The pasteboard write itself needs a window-backed NSPasteboard.general to
/// observe headlessly, so this composes one `NSPasteboardItem` the same way
/// `copyOnBackground` now does and reads all three types back — proving the
/// three payloads coexist on one item rather than clobbering each other.
private func testPasteboardItemCarriesThreeTypes() {
    let d = data(["a"], [["chosen"]])
    let item = NSPasteboardItem()
    item.setString("SELECT 1", forType: .string)
    item.setString(ResultsCopyExport.tsvText(data: d), forType: .tabularText)
    item.setString(ResultsCopyExport.htmlTable(data: d, includeHeaders: d.includeHeaders), forType: .html)

    expect(item.string(forType: .string) ?? "", "SELECT 1", "the .string type carries the chosen format")
    expect(item.string(forType: .tabularText) ?? "", "a\nchosen", "the .tabularText type carries TSV")
    expectContains(item.string(forType: .html) ?? "", "<table>", "the .html type carries a <table>")
}

func runTests() {
    testAliasWithSpaceIsQuoted()
    testUnnamedExpressionColumnIsQuoted()
    testMixedCaseNameKeepsItsCase()
    testEmbeddedQuoteIsDoubled()
    testWholeStatementShape()
    testNullFirstRowKeepsCast()
    testInsertQuotesTheSameWay()
    testNullEmptyAndNullTextAreDistinct()
    testTextFieldRendering()
    testHtmlEscapesTheFourCharacters()
    testHtmlNullIsEmptyCell()
    testHtmlHeadersToggle()
    testTabularRepresentationIsAlwaysTSV()
    testPasteboardItemCarriesThreeTypes()

    print(failures == 0 ? "\nAll tests passed" : "\n\(failures) test(s) failed")
    exit(failures == 0 ? 0 : 1)
}
