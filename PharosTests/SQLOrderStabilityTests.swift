// Standalone test for SQLOrderStability. Compiled by scripts/test-sql-order-stability.sh.
import Foundation

var failures = 0

func expect(_ condition: Bool, _ name: String) {
    if condition { print("PASS \(name)") } else { failures += 1; print("FAIL \(name)") }
}

func runTests() {
    let has = SQLOrderStability.hasTopLevelOrderBy
    expect(has("SELECT * FROM t ORDER BY id"), "plain ORDER BY")
    expect(has("select * from t order by id desc;"), "lower case, trailing semicolon")
    expect(has("SELECT * FROM t\n  ORDER\n  BY id"), "ORDER and BY split across lines")
    expect(has("WITH x AS (SELECT 1) SELECT * FROM x ORDER BY 1"), "CTE with an outer ORDER BY")
    expect(has("SELECT a FROM t UNION SELECT a FROM u ORDER BY a"), "UNION with an outer ORDER BY")
    expect(!has("SELECT * FROM t"), "no ORDER BY")
    expect(!has("SELECT * FROM (SELECT * FROM t ORDER BY id) s"), "ORDER BY only inside a subquery does not count")
    expect(!has("SELECT * FROM t WHERE note = 'ORDER BY id'"), "ORDER BY inside a string does not count")
    expect(!has("SELECT * FROM t -- ORDER BY id"), "ORDER BY inside a line comment does not count")
    expect(!has("SELECT * FROM t /* ORDER BY id */"), "ORDER BY inside a block comment does not count")
    expect(!has("SELECT * FROM t WHERE x = $$ORDER BY$$"), "ORDER BY inside a dollar quote does not count")
    expect(!has("SELECT order_by, orderby FROM t"), "identifiers containing the words do not count")
    expect(!has("SELECT \"ORDER BY\" FROM t"), "a quoted identifier does not count")
    expect(!has(""), "empty text")
    expect(has("SELECT count(*) FROM t GROUP BY a ORDER BY count(*) DESC LIMIT 10"), "ORDER BY before LIMIT")

    if failures == 0 { print("\nAll SQLOrderStability tests passed.") } else { print("\n\(failures) failure(s)."); exit(1) }
}
