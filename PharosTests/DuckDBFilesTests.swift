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

    // F5: a new record's name is unique among ALL record names.
    let data = ConnectionConfig.duckDB(path: "/Users/x/a/data.duckdb", id: "d1")
    expect(DuckDBFiles.uniqueName(forPath: "/Users/x/new/sales.duckdb", in: [data]) == "sales", "a free stem is the name")
    expect(DuckDBFiles.uniqueName(forPath: "/Users/x/b/data.duckdb", in: [data]) == "data (b)",
           "same stem in another folder: the folder is added")
    let dataB = ConnectionConfig.duckDB(path: "/Users/x/b/data.duckdb", name: "data (b)", id: "d2")
    expect(DuckDBFiles.uniqueName(forPath: "/Users/y/b/data.duckdb", in: [data, dataB]) == "data (y/b)",
           "same folder name in two parents: more folders are added")
    let upper = ConnectionConfig.duckDB(path: "/q/DATA.duckdb", id: "d3")
    expect(DuckDBFiles.uniqueName(forPath: "/r/data.duckdb", in: [upper]) == "data (r)", "names compare case-folded")
    expect(DuckDBFiles.uniqueName(forPath: "/r/In-memory DuckDB.duckdb", in: [mem]) == "In-memory DuckDB (r)",
           "an in-memory record's name counts too")
    let pgNamed = ConnectionConfig(id: "pg2", name: " sales ", host: "h", port: 5432, database: "d", username: "u")
    expect(DuckDBFiles.uniqueName(forPath: "/s/sales.duckdb", in: [pgNamed]) == "sales (s)",
           "a PostgreSQL record's name counts, trimmed")
    expect(DuckDBFiles.uniqueName(forPath: "/Users/x/a/data.duckdb", in: [data], excluding: "d1") == "data",
           "the record being edited does not clash with itself")
    let r1 = ConnectionConfig.duckDB(path: "/t.duckdb", id: "r1")
    expect(DuckDBFiles.uniqueName(forPath: "/t.duckdb", in: [r1]) == "t 2", "no folder left: a number is added")

    // F6: Open Recent keeps DuckDB files (by extension or by record) and
    // tells same-named files apart by folder.
    let dbRecord = ConnectionConfig.duckDB(path: "/w/legacy.db", id: "db1")
    let recents = [URL(fileURLWithPath: "/w/legacy.db"), URL(fileURLWithPath: "/w/notes.sql"),
                   URL(fileURLWithPath: "/a/data.duckdb"), URL(fileURLWithPath: "/b/data.duckdb"),
                   URL(fileURLWithPath: "/c/other.ddb")]
    let kept = DuckDBFiles.recentFiles(recents, in: [dbRecord]).map(\.path)
    expect(kept == ["/w/legacy.db", "/a/data.duckdb", "/b/data.duckdb", "/c/other.ddb"],
           "a .db file a record names is kept; a .sql file is not \(kept)")
    let titles = DuckDBFiles.recentTitles(Array(recents.dropFirst(2))) { $0.lastPathComponent }
    expect(titles == ["data.duckdb — a", "data.duckdb — b", "other.ddb"], "same names get their folder \(titles)")

    // F7: in-memory names.
    expect(DuckDBFiles.uniqueInMemoryName(in: [pg]) == "In-memory DuckDB", "the first in-memory name")
    let m1 = ConnectionConfig.duckDB(path: ":memory:", name: "in-memory duckdb", id: "x1")
    let m2 = ConnectionConfig.duckDB(path: ":memory:", name: "In-memory DuckDB 2", id: "x2")
    expect(DuckDBFiles.uniqueInMemoryName(in: [m1, m2]) == "In-memory DuckDB 3", "the next free number, case-folded")

    print(failures == 0 ? "ALL PASS" : "\(failures) FAILURE(S)")
    exit(failures == 0 ? 0 : 1)
}
