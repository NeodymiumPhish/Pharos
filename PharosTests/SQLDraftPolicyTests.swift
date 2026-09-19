// The pure half of "Describe the query": the schema snapshot the two model
// tools read, the strings those tools hand back, and the policy that cleans
// and reviews whatever the model writes.
//
// Nothing here opens a `LanguageModelSession` or conforms to `Tool`. The
// tools themselves are three lines each — they turn arguments into a call on
// `SchemaSnapshot` — and everything that could be wrong about what the model
// SEES is in the functions compiled below.
import Foundation

private var failures = 0

private func expect(_ condition: Bool, _ name: String) {
    if condition { print("PASS \(name)") } else { failures += 1; print("FAIL \(name)") }
}

private func expectEqual<T: Equatable>(_ actual: T, _ expected: T, _ name: String) {
    if actual == expected {
        print("PASS \(name)")
    } else {
        failures += 1
        print("FAIL \(name) — expected \(expected), got \(actual)")
    }
}

// MARK: - Fixtures

/// A snapshot whose names are deliberately hostile: a column called
/// `password`, one called `secret_value`, and a table whose name reads like
/// data. If a formatter ever grew a row-value input, a fixture of plain
/// `id`/`name` columns would not show it — these do, because every string in
/// the output can be traced back to exactly one of them.
private func hostileSnapshot() -> SchemaSnapshot {
    SchemaSnapshot(schemas: [
        "public": [
            TableSummary(
                name: "accounts",
                columns: [
                    (name: "id", type: "integer"),
                    (name: "password", type: "text"),
                    (name: "secret_value", type: "jsonb"),
                ]),
            TableSummary(
                name: "orders",
                columns: [
                    (name: "id", type: "bigint"),
                    (name: "placed_at", type: "timestamp with time zone"),
                ]),
        ],
        "audit": [
            TableSummary(name: "events", columns: [(name: "kind", type: "text")])
        ],
    ])
}

// MARK: - Tool output: names and types only

private func testListTablesOutput() {
    let snapshot = hostileSnapshot()

    expectEqual(
        snapshot.tableLines(),
        "audit.events\npublic.accounts\npublic.orders",
        "list_tables names every table as schema.table, sorted")

    expectEqual(
        snapshot.tableLines(schema: "audit"),
        "audit.events",
        "list_tables narrows to one schema")

    expectEqual(
        snapshot.tableLines(schema: "PUBLIC"),
        "public.accounts\npublic.orders",
        "list_tables matches a schema without regard to case")

    expectEqual(
        snapshot.tableLines(schema: "nope"),
        SchemaSnapshot.noTables,
        "list_tables says so rather than echoing an unknown schema back")

    // Every token the model receives must be a name it gave us. A leak of any
    // other kind — a value, a count, a comment — fails here.
    let vocabulary: Set<String> = ["audit", "events", "public", "accounts", "orders"]
    let tokens = Set(
        snapshot.tableLines()
            .split(whereSeparator: { $0 == "\n" || $0 == "." })
            .map(String.init))
    expect(tokens.isSubset(of: vocabulary), "list_tables emits nothing but schema and table names")
}

private func testDescribeTableOutput() {
    let snapshot = hostileSnapshot()

    expectEqual(
        snapshot.columnLines(table: "public.accounts"),
        "id integer\npassword text\nsecret_value jsonb",
        "describe_table gives one 'column type' line per column, in catalogue order")

    expectEqual(
        snapshot.columnLines(table: "accounts"),
        "id integer\npassword text\nsecret_value jsonb",
        "describe_table accepts a bare table name")

    expectEqual(
        snapshot.columnLines(table: "\"public\".\"orders\";"),
        "id bigint\nplaced_at timestamp with time zone",
        "describe_table survives quotes and a trailing semicolon")

    expectEqual(
        snapshot.columnLines(table: "does_not_exist"),
        SchemaSnapshot.noSuchTable,
        "describe_table refuses an unknown table without echoing the name")

    // `password` is a column NAME here. The line that carries it must be the
    // name and its type and nothing else — no sample, no default, no count.
    let passwordLine = snapshot.columnLines(table: "accounts")
        .split(separator: "\n").first { $0.hasPrefix("password") }
    expectEqual(String(passwordLine ?? ""), "password text",
                "a column that reads like a secret still yields only its name and type")

    let vocabulary: Set<String> = ["id", "integer", "password", "text", "secret_value", "jsonb"]
    let tokens = Set(
        snapshot.columnLines(table: "accounts")
            .split(whereSeparator: { $0 == "\n" || $0 == " " })
            .map(String.init))
    expect(tokens.isSubset(of: vocabulary), "describe_table emits nothing but column names and types")
}

/// The strongest statement available about row data: the ONLY input either
/// formatter takes is a `SchemaSnapshot`, and a snapshot is built from names
/// and types. Rebuilding the same snapshot from names and types alone and
/// getting byte-identical output proves no other input reached the strings.
private func testFormattersTakeSchemaOnly() {
    let original = hostileSnapshot()

    // Re-derive a snapshot from nothing but the names and types readable in
    // the first one. Anything the formatter reads that is not a name or a
    // type would have to differ here.
    var rebuilt: [String: [TableSummary]] = [:]
    for (schema, tables) in original.schemas {
        rebuilt[schema] = tables.map { table in
            TableSummary(
                name: table.name,
                columns: table.columns.map { (name: $0.name, type: $0.type) })
        }
    }
    let copy = SchemaSnapshot(schemas: rebuilt)

    expectEqual(copy.tableLines(), original.tableLines(),
                "list_tables output is a function of names alone")
    expectEqual(copy.columnLines(table: "accounts"), original.columnLines(table: "accounts"),
                "describe_table output is a function of names and types alone")
    expect(copy == original, "a snapshot carries names and types and nothing else")
}

private func testTableCap() {
    var tables: [TableSummary] = []
    for i in 0..<250 {
        tables.append(TableSummary(name: String(format: "t%03d", i), columns: []))
    }
    let snapshot = SchemaSnapshot(schemas: ["big": tables])

    let lines = snapshot.tableLines().split(separator: "\n").map(String.init)
    let tableLines = lines.filter { $0.hasPrefix("big.") }
    expectEqual(tableLines.count, SchemaSnapshot.tableLineLimit,
                "list_tables caps the answer at 200 tables")
    expectEqual(tableLines.first, "big.t000", "the cap keeps the first tables in sorted order")
    expectEqual(tableLines.last, "big.t199", "the cap stops at the 200th")
    expect(lines.last == SchemaSnapshot.truncationNote,
           "a truncated list says it was truncated")

    // Exactly at the limit there is nothing to say.
    let exact = SchemaSnapshot(schemas: ["big": Array(tables.prefix(200))])
    expectEqual(exact.tableLines().split(separator: "\n").count, 200,
                "a list of exactly 200 tables carries no truncation note")
}

private func testDefaultSchemaWins() {
    let snapshot = SchemaSnapshot(schemas: [
        "analytics": [TableSummary(name: "orders", columns: [(name: "total", type: "numeric")])],
        "public": [TableSummary(name: "orders", columns: [(name: "id", type: "bigint")])],
    ])

    // Sorted order would answer `analytics` first, so a default of `public`
    // that did nothing would still pass a fixture ordered the other way.
    expectEqual(snapshot.columnLines(table: "orders", defaultSchema: "public"),
                "id bigint",
                "a bare name resolves in the tab's default schema first")
    expectEqual(snapshot.columnLines(table: "orders", defaultSchema: "analytics"),
                "total numeric",
                "the other default resolves the other way")
    expectEqual(snapshot.columnLines(table: "orders"),
                "total numeric",
                "with no default the first schema alphabetically wins")
}

// MARK: - Cleaning

private func testFenceStripping() {
    expectEqual(SQLDraftPolicy.clean("```sql\nSELECT 1\n```"), "SELECT 1",
                "a fenced answer loses its fence and its info string")
    expectEqual(SQLDraftPolicy.clean("```\nSELECT 1\n```"), "SELECT 1",
                "a bare fence is stripped too")
    expectEqual(SQLDraftPolicy.clean("   SELECT 1   "), "SELECT 1",
                "an unfenced answer is only trimmed")
    expectEqual(SQLDraftPolicy.clean("```sql\nSELECT 'a```b'\n```"), "SELECT 'a",
                "the first closing fence ends the block")
}

private func testSingleStatement() {
    expectEqual(SQLDraftPolicy.clean("SELECT 1; DROP TABLE t;"), "SELECT 1;",
                "everything after the first top-level semicolon is dropped")
    expectEqual(SQLDraftPolicy.clean("SELECT ';' AS x"), "SELECT ';' AS x",
                "a semicolon inside a string literal does not end the statement")
    expectEqual(SQLDraftPolicy.clean("SELECT 1 -- ; and a note\nFROM t"),
                "SELECT 1 -- ; and a note\nFROM t",
                "a semicolon inside a comment does not end the statement")
    expectEqual(SQLDraftPolicy.clean("SELECT 1"), "SELECT 1",
                "a statement with no semicolon is left alone")
}

// MARK: - Review

/// Settings ▸ Intelligence ▸ "Allow drafts that write", cleared.
///
/// The switch changes the VERDICT, not the reading: the same statement is
/// still recognised the same way, and only the question "may this be offered"
/// answers differently. `allowWriteStatements` defaults to true, which is what
/// the popover did before the switch existed, so every other test in this file
/// keeps pinning today's behaviour.
private func testWriteDraftsRefusedWhenNotAllowed() {
    for sql in [
        "DELETE FROM orders WHERE id = 1",
        "UPDATE orders SET total = 0",
        "CREATE TABLE t (id int)",
        "WITH gone AS (DELETE FROM orders RETURNING *) SELECT * FROM gone",
    ] {
        let allowed = SQLDraftPolicy.review(sql, allowWriteStatements: true)
        let refused = SQLDraftPolicy.review(sql, allowWriteStatements: false)

        expect(allowed.needsConfirmation, "allowed, it is offered behind a confirmation: \(sql.prefix(24))")
        expect(!allowed.isRefused, "allowed, it is not refused: \(sql.prefix(24))")

        expect(refused.isRefused, "refused when writes are not allowed: \(sql.prefix(24))")
        expect(!refused.needsConfirmation,
               "a refused draft is never offered to confirm: \(sql.prefix(24))")
        expect(refused.warning?.contains("Settings") == true,
               "the refusal says where to change it: \(sql.prefix(24))")
        expectEqual(refused.sql, allowed.sql, "the cleaning is unchanged: \(sql.prefix(24))")
        expectEqual(refused.leadingKeyword, allowed.leadingKeyword,
                    "the reading is unchanged: \(sql.prefix(24))")
    }

    // A read is a read whichever way the switch is set.
    for sql in ["SELECT * FROM orders", "EXPLAIN SELECT 1"] {
        let refused = SQLDraftPolicy.review(sql, allowWriteStatements: false)
        expect(!refused.isRefused, "a plain read is never refused: \(sql.prefix(24))")
        expect(refused.warning == nil, "and carries no warning: \(sql.prefix(24))")
    }

    // An empty draft is empty, not a refused write: the popover has its own
    // sentence for it, and must not be told to blame the setting.
    let empty = SQLDraftPolicy.review("", allowWriteStatements: false)
    expect(empty.isEmpty, "an empty draft is still empty")
    expect(!empty.isRefused, "an empty draft is not a refused write")
    expect(empty.warning == nil, "and has no warning")
}

private func testEmptyDraftRejected() {
    for raw in ["", "   \n  ", "```\n```"] {
        let review = SQLDraftPolicy.review(raw)
        expect(review.isEmpty, "an empty draft is empty: \(raw.debugDescription)")
        expect(!review.needsConfirmation,
               "an empty draft is refused rather than confirmed: \(raw.debugDescription)")
        expect(review.warning == nil, "an empty draft has no warning: \(raw.debugDescription)")
    }
}

private func testDestructiveDrafts() {
    for (sql, keyword) in [
        ("DELETE FROM orders WHERE id = 1", "DELETE"),
        ("DROP TABLE orders", "DROP"),
        ("TRUNCATE orders", "TRUNCATE"),
        ("WITH gone AS (DELETE FROM orders RETURNING *) SELECT * FROM gone", "DELETE"),
    ] {
        let review = SQLDraftPolicy.review(sql)
        expect(review.isDestructive, "\(keyword) is destructive")
        expect(review.destructiveKeywords.contains(keyword),
               "\(keyword) is named in the review")
        expect(review.needsConfirmation, "\(keyword) needs confirmation")
        expect(review.warning?.contains(keyword) == true,
               "the warning for \(keyword) names the keyword")
        expect(SQLDraftPolicy.isDestructive(sql), "the convenience check agrees for \(keyword)")
    }

    // The writing CTE is the case that separates "reads the first word" from
    // "reads the statement": it STARTS with WITH, so a head-only check would
    // wave it through.
    let cte = SQLDraftPolicy.review("WITH gone AS (DELETE FROM orders RETURNING *) SELECT * FROM gone")
    expect(cte.isSelect, "a writing CTE still starts with WITH")
    expect(cte.needsConfirmation, "a writing CTE is caught by the destructive scan, not by its head")
}

private func testNotASelect() {
    // Not a SELECT, and NOT in the scanner's keyword set either: the warning
    // has to come from the leading keyword alone.
    for (sql, keyword) in [
        ("CREATE TABLE t (id int)", "CREATE"),
        ("VACUUM orders", "VACUUM"),
    ] {
        let review = SQLDraftPolicy.review(sql)
        expect(!review.isSelect, "\(keyword) is not a SELECT")
        expect(!review.isDestructive, "\(keyword) is not scanned as destructive")
        expect(review.needsConfirmation, "\(keyword) needs confirmation")
        expect(review.warning?.contains(keyword) == true,
               "the warning for \(keyword) names the keyword")
    }

    // Writes and permission changes ARE scanned, since 2026-09-16 — the gutter's
    // run target is a full-width band now, and an accidental UPDATE is no easier
    // to undo than an accidental DELETE.
    for (sql, keyword) in [
        ("UPDATE orders SET total = 0", "UPDATE"),
        ("INSERT INTO orders (id) VALUES (1)", "INSERT"),
        ("ALTER TABLE orders ADD COLUMN note text", "ALTER"),
        ("GRANT SELECT ON orders TO analyst", "GRANT"),
    ] {
        let review = SQLDraftPolicy.review(sql)
        expect(!review.isSelect, "\(keyword) is not a SELECT")
        expect(review.isDestructive, "\(keyword) is scanned as destructive")
        expect(review.needsConfirmation, "\(keyword) needs confirmation")
        expect(review.warning?.contains(keyword) == true,
               "the warning for \(keyword) names the keyword")
    }
}

private func testReadingStatementsAccepted() {
    for sql in [
        "SELECT * FROM orders",
        "select 1",
        "WITH recent AS (SELECT 1) SELECT * FROM recent",
        "EXPLAIN SELECT * FROM orders",
        "-- orders per region\nSELECT region FROM orders",
        "/* a note */ SELECT 1",
    ] {
        let review = SQLDraftPolicy.review(sql)
        expect(review.isSelect, "accepted: \(sql.prefix(24))")
        expect(!review.needsConfirmation, "no confirmation for: \(sql.prefix(24))")
        expect(review.warning == nil, "no warning for: \(sql.prefix(24))")
    }

    expectEqual(SQLDraftPolicy.leadingKeyword(of: "-- note\n  select 1"), "SELECT",
                "a leading comment does not become the leading keyword")
    expectEqual(SQLDraftPolicy.leadingKeyword(of: "   "), "",
                "nothing at all has no leading keyword")
}

// MARK: - Entry point

func runTests() {
    testListTablesOutput()
    testDescribeTableOutput()
    testFormattersTakeSchemaOnly()
    testTableCap()
    testDefaultSchemaWins()
    testFenceStripping()
    testSingleStatement()
    testEmptyDraftRejected()
    testDestructiveDrafts()
    testNotASelect()
    testReadingStatementsAccepted()
    testWriteDraftsRefusedWhenNotAllowed()

    if failures == 0 {
        print("\nAll SQL draft policy tests passed.")
    } else {
        print("\n\(failures) test(s) FAILED.")
        exit(1)
    }
}
