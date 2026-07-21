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

    // MARK: - Order and dedup

    expectKeywords("DELETE FROM a; DELETE FROM b; DROP TABLE c",
                   ["DELETE", "DROP"], "duplicates collapsed, order preserved")

    if failures > 0 {
        print("\n\(failures) failure(s)")
        exit(1)
    }
    print("\nAll tests passed")
}
