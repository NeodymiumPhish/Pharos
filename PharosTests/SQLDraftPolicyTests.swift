// The policy that cleans and reviews whatever the "Describe the query" model
// writes. What the model SEES is tested in SQLDraftPipelineTests.swift.
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
