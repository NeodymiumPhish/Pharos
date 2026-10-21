// Standalone test for DuckDBFiles — which record opens a DuckDB file.
import Foundation

var failures = 0
func expect(_ c: Bool, _ n: String) { if c { print("PASS \(n)") } else { failures += 1; print("FAIL \(n)") } }

func runTests() {
    expect(DuckDBFiles.isDuckDBFile(URL(fileURLWithPath: "/a/b.duckdb")), ".duckdb is a DuckDB file")
    expect(DuckDBFiles.isDuckDBFile(URL(fileURLWithPath: "/a/b.DDB")), ".ddb counts, in any case")
    expect(!DuckDBFiles.isDuckDBFile(URL(fileURLWithPath: "/a/b.sql")), ".sql does not")
    expect(!DuckDBFiles.isDuckDBFile(URL(string: "postgres://h/d")!), "a URL that is not a file does not")

    let pg = ConnectionConfig(id: "pg", name: "p", host: "h", port: 5432, database: "/tmp/sales.duckdb", username: "u")
    let mem = ConnectionConfig.duckDB(path: ":memory:", id: "mem")
    let a = ConnectionConfig.duckDB(path: "/tmp/sales.duckdb", id: "a")
    let b = ConnectionConfig.duckDB(path: "/private/tmp/sales.duckdb", id: "b")
    let list = [pg, mem, a, b]
    expect(DuckDBFiles.record(for: "/tmp/sales.duckdb", in: list)?.id == "a", "the record naming the file is found")
    expect(DuckDBFiles.record(for: "/private/tmp/./sales.duckdb", in: list)?.id == "a",
           "another spelling of the same file finds the same record (the first)")
    expect(DuckDBFiles.record(for: "/tmp/other.duckdb", in: list) == nil, "a new file has no record")
    expect(DuckDBFiles.record(for: "/tmp/sales.duckdb", in: [pg, mem]) == nil, "a PostgreSQL database NAME is never a file match")
    expect(DuckDBFiles.canonicalPath("~/x.duckdb") == NSHomeDirectory() + "/x.duckdb" ||
           DuckDBFiles.canonicalPath("~/x.duckdb").hasSuffix("/x.duckdb"), "~ is expanded")

    // File ▸ New on a path Pharos has open: every record that names it counts.
    let open: Set<String> = ["b"]
    expect(DuckDBFiles.openRecords(for: "/tmp/sales.duckdb", in: list, isOpen: { open.contains($0) }).map(\.id) == ["b"],
           "an open record under another spelling (not the first) is found")
    expect(DuckDBFiles.openRecords(for: "/tmp/sales.duckdb", in: list, isOpen: { _ in false }).isEmpty,
           "no open record: the file may be replaced")
    expect(DuckDBFiles.openRecords(for: "/tmp/sales.duckdb", in: [pg], isOpen: { _ in true }).isEmpty,
           "a PostgreSQL record never counts")

    print(failures == 0 ? "ALL PASS" : "\(failures) FAILURE(S)")
    exit(failures == 0 ? 0 : 1)
}
