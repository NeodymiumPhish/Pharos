// Standalone test for DuckDBCloseRule — when a DuckDB file closes.
import Foundation

var failures = 0
func expect(_ c: Bool, _ n: String) { if c { print("PASS \(n)") } else { failures += 1; print("FAIL \(n)") } }

func runTests() {
    let a = ConnectionConfig.duckDB(path: "/d/a.duckdb", id: "a")
    let a2 = ConnectionConfig.duckDB(path: "/d/./a.duckdb", id: "a2")
    let b = ConnectionConfig.duckDB(path: "/d/b.duckdb", id: "b")
    let mem = ConnectionConfig.duckDB(path: ":memory:", id: "mem")
    var launch = ConnectionConfig.duckDB(path: "/d/l.duckdb", id: "l")
    launch.connectOnLaunch = true
    let pg = ConnectionConfig(id: "pg", name: "p", host: "h", port: 5432, database: "d", username: "u")
    let all = [a, a2, b, mem, launch, pg]
    let path: (String) -> String = { ($0 as NSString).standardizingPath }
    func close(tabs: [String?], connected: Set<String> = ["a", "a2", "b", "mem", "l", "pg"],
               connecting: Set<String> = [], quitting: Bool = false) -> [String] {
        DuckDBCloseRule.recordsToClose(
            connections: all, tabConnectionIds: tabs,
            status: { connecting.contains($0) ? .connecting : connected.contains($0) ? .connected : .disconnected },
            isTerminating: quitting, canonicalPath: path)
    }

    expect(close(tabs: ["a", "b", "mem", "l", "pg"]) == [], "every file in a tab: nothing closes")
    expect(close(tabs: ["a", "mem", "pg", nil]) == ["b"], "a file no tab uses closes")
    expect(close(tabs: ["a2", "b"]).isEmpty, "a tab on ANOTHER record of the same file keeps it open")
    expect(close(tabs: []) == ["a", "a2", "b"], "no tabs: every file closes, each record on it")
    expect(!close(tabs: []).contains("mem"), "in-memory never closes this way (its tables would go)")
    expect(!close(tabs: []).contains("l"), "connect-on-launch files stay open")
    expect(!close(tabs: []).contains("pg"), "PostgreSQL is never closed")
    expect(close(tabs: [], connecting: ["a2"]) == ["b"], "a file still connecting is left alone")
    expect(close(tabs: [], quitting: true).isEmpty, "nothing while Pharos quits")
    expect(close(tabs: [], connected: ["b"]) == ["b"], "only connected records are closed")

    print(failures == 0 ? "ALL PASS" : "\(failures) FAILURE(S)")
    exit(failures == 0 ? 0 : 1)
}
