// Standalone test runner for MCPStatementPolicy. Not part of the app target —
// compiled together with the implementation by scripts/test-mcp-statement-policy.sh.
import Foundation

var failures = 0

private func expect(_ sql: String, duckDB: Bool = false, _ expected: [String], _ name: String) {
    let actual = MCPStatementPolicy.reasons(in: sql, duckDB: duckDB)
    if actual == expected { print("PASS \(name)") } else {
        failures += 1
        print("FAIL \(name)\n  sql:      \(sql)\n  expected: \(expected)\n  actual:   \(actual)")
    }
}

private func expectRead(_ sql: String, duckDB: Bool = false) {
    expect(sql, duckDB: duckDB, [], "a read: \(sql)")
}

private func expectNotRead(_ sql: String, duckDB: Bool = false) {
    let actual = MCPStatementPolicy.reasons(in: sql, duckDB: duckDB)
    if !actual.isEmpty { print("PASS not a read: \(sql)") } else {
        failures += 1
        print("FAIL allowed as a read: \(sql)")
    }
}

func runTests() {
    // MARK: Reads

    for sql in [
        "SELECT * FROM users",
        "select id, name from users where action = 'delete' limit 10;",
        "WITH c AS (SELECT 1) SELECT * FROM c",
        "VALUES (1), (2)",
        "TABLE users",
        "(SELECT 1) UNION ALL (SELECT 2)",
        "EXPLAIN SELECT * FROM users",
        "EXPLAIN ANALYZE SELECT * FROM users",
        "SHOW work_mem",
        "-- a note\nSELECT 1",
        "/* DROP TABLE t */ SELECT 1",
        "SELECT \"delete\", \"into\" FROM t",
        "SELECT $$drop table x$$",
        "SELECT deleted_at, updated_by, created FROM t",
        "SELECT count(*), max(n), coalesce(a, b), now() FROM t",
        "SELECT u & 1 FROM t",
        "SELECT 1;",
        "SELECT pg_size_pretty(pg_total_relation_size('t'))",
    ] { expectRead(sql) }

    for sql in [
        "FROM t",
        "DESCRIBE t",
        "SUMMARIZE t",
        "SELECT * FROM range(10)",
        "SELECT * FROM duckdb_tables()",
        "SELECT 'x.csv' AS name, i FROM t",
    ] { expectRead(sql, duckDB: true) }

    // MARK: The seven keywords still count

    expect("DELETE FROM t", ["DELETE"], "DELETE")
    expect("WITH d AS (DELETE FROM t RETURNING *) SELECT * FROM d", ["DELETE"], "a data-modifying CTE")
    expect("EXPLAIN ANALYZE UPDATE t SET a = 1", ["UPDATE"], "EXPLAIN ANALYZE of a write")
    expect("SELECT * FROM t FOR UPDATE", ["UPDATE"], "a row lock")

    // MARK: What the seven keywords missed (PostgreSQL)

    expect("DO $$ BEGIN DELETE FROM users; END $$", ["DO"], "a DO block hides its body in a dollar quote")
    expect("CREATE TABLE x AS SELECT * FROM t", ["CREATE"], "CREATE TABLE AS")
    expect("SELECT * INTO x FROM t", ["INTO"], "SELECT INTO")
    expect("CALL wipe()", ["CALL"], "CALL")
    expect("REVOKE ALL ON t FROM u", ["REVOKE"], "REVOKE")
    expect("COPY t TO PROGRAM 'curl …'", ["COPY"], "COPY TO PROGRAM")
    expect("COPY t FROM '/etc/passwd'", ["COPY"], "COPY FROM a server file")
    expect("SET ROLE postgres", ["SET"], "SET ROLE")
    expect("SET default_transaction_read_only = off", ["SET"], "SET")
    expect("/**/ BEGIN READ WRITE; CREATE TABLE x(i int); COMMIT;",
           ["more than one statement", "BEGIN", "CREATE", "COMMIT"], "a comment before BEGIN READ WRITE")
    expect("SELECT 1; SELECT 2", ["more than one statement"], "two reads are still two statements")
    expect("MERGE INTO t USING s ON true WHEN MATCHED THEN DO NOTHING", ["MERGE", "INTO"], "MERGE that names no write")
    expect("VACUUM t", ["VACUUM"], "VACUUM")
    expect("LOCK TABLE t", ["LOCK"], "LOCK")
    expect("EXPLAIN ANALYZE CREATE TABLE x AS SELECT 1", ["CREATE"], "EXPLAIN ANALYZE CREATE TABLE AS")
    expect("EXPLAIN ANALYZE EXECUTE wipe", ["EXECUTE"], "EXPLAIN ANALYZE EXECUTE")
    expect("SELECT pg_terminate_backend(123)", ["pg_terminate_backend()"], "a function that ends a session")
    expect("SELECT PG_READ_FILE('/etc/passwd')", ["pg_read_file()"], "a server file, any case")
    expect("SELECT pg_catalog.pg_read_file ('/etc/passwd')", ["pg_read_file()"], "schema-qualified, space before (")
    expect("SELECT \"pg_read_file\"('/etc/passwd')", ["pg_read_file()"], "a quoted function name")
    expect("SELECT lo_export(1, '/tmp/x')", ["lo_export()"], "lo_export")
    expect("SELECT * FROM dblink('host=evil', 'select 1') AS t(i int)", ["dblink()"], "dblink")
    expect("SELECT dblink_exec('host=evil', 'drop table t')", ["dblink_exec()"], "dblink_exec")
    expect("SELECT setval('s', 1)", ["setval()"], "setval")
    expect("SELECT set_config('transaction_read_only', 'off', false)", ["set_config()"], "set_config")
    expect("SELECT pg_advisory_lock(1)", ["pg_advisory_lock()"], "a lock that outlives the transaction")
    expect("SELECT query_to_xml('delete from t returning *', true, true, '')", ["query_to_xml()"], "SQL in a string")
    expect("SELECT U&\"\\0070g_read_file\"('/etc/passwd')", ["a Unicode-escaped name"], "a Unicode-escaped function name")

    // MARK: What the seven keywords missed (DuckDB)

    expect("SELECT content FROM read_text('/Users/me/.ssh/id_ed25519')", duckDB: true, ["read_text()"], "read_text")
    expect("SELECT * FROM READ_CSV('https://example.com/x.csv')", duckDB: true, ["read_csv()"], "read_csv of an address")
    expect("SELECT * FROM glob('/Users/me/**')", duckDB: true, ["glob()"], "glob")
    expect("SELECT * FROM '/tmp/x.csv'", duckDB: true, ["a file or address read as a table"], "a file in FROM")
    expect("SELECT * FROM t JOIN 'x.parquet' USING (i)", duckDB: true, ["a file or address read as a table"], "a file in JOIN")
    expect("FROM \"/tmp/x.parquet\"", duckDB: true, ["a file or address read as a table"], "a quoted path in FROM")
    expect("SUMMARIZE 'x.csv'", duckDB: true, ["a file or address read as a table"], "SUMMARIZE of a file")
    expect("ATTACH '/Users/me/Library/Application Support/com.pharos.client/pharos.db' AS p (TYPE sqlite, READ_ONLY)",
           duckDB: true, ["ATTACH"], "ATTACH of Pharos's own store")
    expect("COPY (SELECT 'curl … | sh') TO '/Users/me/.zshenv' (FORMAT csv)", duckDB: true, ["COPY"], "COPY TO a file")
    expect("CREATE OR REPLACE TABLE t AS SELECT 1", duckDB: true, ["CREATE"], "CREATE OR REPLACE TABLE")
    expect("INSTALL httpfs", duckDB: true, ["INSTALL"], "INSTALL")
    expect("LOAD httpfs", duckDB: true, ["LOAD"], "LOAD")
    expect("EXPORT DATABASE '/tmp/out'", duckDB: true, ["EXPORT"], "EXPORT DATABASE")
    expect("SET enable_external_access = true", duckDB: true, ["SET"], "SET")
    expect("PRAGMA database_size", duckDB: true, ["PRAGMA"], "PRAGMA")
    expect("SELECT * FROM sqlite_scan('/tmp/pharos.db', 'query_variables')", duckDB: true, ["sqlite_scan()"], "sqlite_scan")
    expect("SELECT * FROM query('DELETE FROM t')", duckDB: true, ["query()"], "query()")

    // DuckDB's own heads are not PostgreSQL's.
    expect("FROM t", ["FROM"], "FROM-first is not a PostgreSQL read")
    expectNotRead("DESCRIBE t")

    // MARK: What reaches outside the database is asked about even "without asking"

    func expectOutside(_ sql: String, duckDB: Bool = false, _ expected: [String], _ name: String) {
        let actual = MCPStatementPolicy.finding(in: sql, duckDB: duckDB).outside
        if actual == expected { print("PASS \(name)") } else {
            failures += 1
            print("FAIL \(name)\n  sql:      \(sql)\n  expected: \(expected)\n  actual:   \(actual)")
        }
    }
    // Changes to the database: "without asking" covers them.
    for sql in ["INSERT INTO t VALUES (1)", "UPDATE t SET a = 1", "DELETE FROM t", "DROP TABLE t", "CREATE TABLE x AS SELECT 1",
                "INSERT INTO t SELECT * FROM u; DELETE FROM u", "SELECT nextval('s')", "SELECT setval('s', 1)",
                "DO $$ BEGIN DELETE FROM t; END $$", "CALL p()", "BEGIN"] {
        expectOutside(sql, [], "inside the database: \(sql)")
    }
    for sql in ["INSERT INTO t VALUES (1)", "CREATE OR REPLACE TABLE t AS SELECT 1", "SELECT nextval('s')"] {
        expectOutside(sql, duckDB: true, [], "inside the database (DuckDB): \(sql)")
    }
    expectOutside("COPY t TO PROGRAM 'curl …'", ["COPY"], "outside: COPY TO PROGRAM")
    expectOutside("SELECT pg_read_file('/etc/passwd')", ["pg_read_file()"], "outside: a server file")
    expectOutside("INSERT INTO t SELECT * FROM dblink('host=x', 'select 1') AS d(i int)", ["dblink()"], "outside: dblink inside a write")
    expectOutside("SET ROLE postgres", ["SET"], "outside: SET")
    expectOutside("COPY t TO '/Users/me/.zshenv'", duckDB: true, ["COPY"], "outside: COPY TO a file")
    expectOutside("ATTACH '/tmp/pharos.db' AS p (TYPE sqlite)", duckDB: true, ["ATTACH"], "outside: ATTACH")
    expectOutside("INSTALL httpfs; LOAD httpfs", duckDB: true, ["INSTALL", "LOAD"], "outside: INSTALL and LOAD")
    expectOutside("EXPORT DATABASE '/tmp/out'", duckDB: true, ["EXPORT"], "outside: EXPORT")
    expectOutside("SET enable_external_access = true", duckDB: true, ["SET"], "outside: SET")
    expectOutside("CREATE TABLE x AS SELECT * FROM read_csv('/tmp/x.csv')", duckDB: true, ["read_csv()"], "outside: a file inside a write")
    expectOutside("INSERT INTO t SELECT * FROM '/tmp/x.csv'", duckDB: true, ["a file or address read as a table"],
                  "outside: a file in FROM inside a write")
    expectOutside("DELETE FROM t; COPY t TO '/tmp/x'", duckDB: true, ["COPY"], "outside: the second statement")

    // MARK: Empty

    expect("", [], "empty input")
    expect("-- only a comment", [], "a comment alone")

    if failures == 0 { print("\nALL PASSED") } else { print("\n\(failures) FAILED"); exit(1) }
}
