// Standalone test runner for DestructiveSQLScanner. Not part of the app target —
// compiled together with the implementation by scripts/test-destructive-sql-scanner.sh.
import Foundation

var failures = 0

func expectKeywords(_ sql: String, _ expected: [String], _ name: String) {
    let actual = DestructiveSQLScanner.destructiveKeywords(in: sql)
    if actual == expected { print("PASS \(name)") } else {
        failures += 1
        print("FAIL \(name)\n  expected: \(expected)\n  actual:   \(actual)")
    }
}

func runTests() {
    // MARK: - Positive detection

    expectKeywords("DROP TABLE users", ["DROP"], "plain DROP")
    expectKeywords("delete from users where id = 1", ["DELETE"], "lowercase DELETE")
    expectKeywords("TRUNCATE TABLE logs", ["TRUNCATE"], "plain TRUNCATE")
    expectKeywords("Delete From t; dRoP view v", ["DELETE", "DROP"], "mixed case, multi-statement, first-seen order")
    expectKeywords("WITH gone AS (DELETE FROM t RETURNING *) SELECT count(*) FROM gone",
                   ["DELETE"], "data-modifying CTE caught")
    expectKeywords("EXPLAIN ANALYZE DELETE FROM t", ["DELETE"], "EXPLAIN ANALYZE DELETE caught")
    expectKeywords("SELECT 1;\nDROP TABLE t;", ["DROP"], "destructive after benign statement")
    expectKeywords("/* leading */ TRUNCATE t", ["TRUNCATE"], "keyword after block comment")

    // MARK: - Negative: strings, comments, identifiers

    expectKeywords("SELECT * FROM audit WHERE action = 'delete'", [], "keyword inside string literal")
    expectKeywords("SELECT * FROM t -- drop this later\nWHERE id = 1", [], "keyword inside line comment")
    expectKeywords("SELECT 1 /* TRUNCATE t */", [], "keyword inside block comment")
    expectKeywords("SELECT \"delete\" FROM t", [], "keyword as quoted identifier")
    expectKeywords("SELECT $$drop table x$$", [], "keyword inside dollar-quoted string")
    expectKeywords("SELECT deleted_at, undropped FROM t", [], "keyword as substring of identifier")
    expectKeywords("SELECT delete_old_rows()", [], "keyword joined by underscore")
    expectKeywords("SELECT * FROM users", [], "plain SELECT")
    expectKeywords("", [], "empty input")

    // MARK: - Writes and permission changes (added 2026-09-16)
    //
    // The gutter's run target grew from a 4pt bar to a band the full width of
    // the gutter, so a mis-click became far easier — and an accidental UPDATE
    // is no easier to undo than an accidental DELETE. These four must obey the
    // same string/comment/identifier rules the original three do, which is the
    // whole reason the scan runs through the lexer's state map.

    expectKeywords("UPDATE orders SET total = 0", ["UPDATE"], "plain UPDATE")
    expectKeywords("insert into t values (1)", ["INSERT"], "lowercase INSERT")
    expectKeywords("ALTER TABLE t ADD COLUMN c int", ["ALTER"], "plain ALTER")
    expectKeywords("GRANT SELECT ON t TO analyst", ["GRANT"], "plain GRANT")
    expectKeywords("INSERT INTO t VALUES (1) ON CONFLICT (id) DO UPDATE SET n = 1",
                   ["INSERT", "UPDATE"], "an upsert names both keywords, in order")
    expectKeywords("WITH w AS (UPDATE t SET n = 1 RETURNING *) SELECT * FROM w",
                   ["UPDATE"], "writing CTE with UPDATE caught")

    expectKeywords("SELECT * FROM updates", [], "a table called updates is not an UPDATE")
    expectKeywords("SELECT 'please UPDATE me'", [], "UPDATE inside a string literal")
    expectKeywords("SELECT 1 -- INSERT", [], "INSERT inside a line comment")
    expectKeywords("SELECT \"grant\" FROM t", [], "a quoted identifier called grant")
    expectKeywords("SELECT inserted_at FROM t", [], "INSERT is not a prefix match")

    // MARK: - Order and dedup

    expectKeywords("DELETE FROM a; DELETE FROM b; DROP TABLE c",
                   ["DELETE", "DROP"], "duplicates collapsed, order preserved")

    if failures > 0 {
        print("\n\(failures) failure(s)")
        exit(1)
    }
    print("\nAll tests passed")
}
