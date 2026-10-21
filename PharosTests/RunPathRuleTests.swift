// Standalone test for RunPathRule — which cards show rows and which show a
// count of changed rows.
import Foundation

var failures = 0
func expect(_ c: Bool, _ n: String) { if c { print("PASS \(n)") } else { failures += 1; print("FAIL \(n)") } }

func runTests() {
    // PostgreSQL: unchanged, the first word decides.
    for sql in ["SELECT 1", "with x as (select 1) select * from x", "  -- note\nEXPLAIN SELECT 1", "SHOW search_path",
                "TABLE t", "VALUES (1)", "/* a /* nested */ b */ SELECT 1", "select*from t"] {
        expect(RunPathRule.returnsRows(sql: sql, engine: .postgres), "PostgreSQL rows: \(sql)")
    }
    for sql in ["INSERT INTO t VALUES (1)", "FROM t", "DESCRIBE t", "UPDATE t SET a = 1", "-- only a comment"] {
        expect(!RunPathRule.returnsRows(sql: sql, engine: .postgres), "PostgreSQL statement: \(sql)")
    }

    // DuckDB: its own row statements show rows.
    for sql in ["FROM 'sales.csv'", "from t select a", "DESCRIBE t", "SUMMARIZE t", "PIVOT t ON a USING sum(b)",
                "UNPIVOT t ON a, b INTO NAME k VALUE v", "PRAGMA table_info('t')", "CALL duckdb_extensions()", "SELECT 1"] {
        expect(RunPathRule.returnsRows(sql: sql, engine: .duckdb), "DuckDB rows: \(sql)")
    }
    for sql in ["INSERT INTO t VALUES (1)", "UPDATE t SET a = 1", "DELETE FROM t", "CREATE TABLE t (a INT)", "FROMAGE"] {
        expect(!RunPathRule.returnsRows(sql: sql, engine: .duckdb), "DuckDB statement: \(sql)")
    }

    // DuckDB judges the LAST statement, whose result the core shows.
    expect(RunPathRule.returnsRows(sql: "CREATE TEMP TABLE x AS SELECT 1 AS a; FROM x", engine: .duckdb, lastStatement: "FROM x"),
           "DuckDB: CREATE …; FROM x shows the rows of FROM x")
    expect(!RunPathRule.returnsRows(sql: "SELECT 1; INSERT INTO t VALUES (1)", engine: .duckdb, lastStatement: "INSERT INTO t VALUES (1)"),
           "DuckDB: SELECT …; INSERT … shows the insert's count")
    expect(RunPathRule.firstWord("  -- x\n  describe t") == "DESCRIBE", "first word after a comment, upper-cased")

    print(failures == 0 ? "ALL PASS" : "\(failures) FAILURE(S)")
    exit(failures == 0 ? 0 : 1)
}
