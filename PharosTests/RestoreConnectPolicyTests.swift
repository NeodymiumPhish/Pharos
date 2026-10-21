// Standalone test for RestoreConnectPolicy — which DuckDB files relaunch
// restore opens again.
import Foundation

var failures = 0
func expect(_ c: Bool, _ n: String) { if c { print("PASS \(n)") } else { failures += 1; print("FAIL \(n)") } }

func runTests() {
    let a = ConnectionConfig.duckDB(path: "/d/a.duckdb", id: "a")
    let b = ConnectionConfig.duckDB(path: "/d/b.duckdb", id: "b")
    let mem = ConnectionConfig.duckDB(path: ":memory:", id: "mem")
    let pg = ConnectionConfig(id: "pg", name: "p", host: "h", port: 5432, database: "d", username: "u")
    let all = [a, b, mem, pg]
    func open(_ tabs: [String?], connected: Set<String> = [], connecting: Set<String> = []) -> [String] {
        RestoreConnectPolicy.recordsToOpen(tabConnectionIds: tabs, connections: all) {
            connecting.contains($0) ? .connecting : connected.contains($0) ? .connected : .disconnected
        }
    }
    expect(open(["b", "a", "b", nil]) == ["b", "a"], "each file once, in tab order")
    expect(open(["pg", "mem"]).isEmpty, "server and in-memory connections stay closed")
    expect(open(["a", "b"], connected: ["a"], connecting: ["b"]).isEmpty, "already open or opening: left alone")
    expect(open(["gone"]).isEmpty, "a tab whose record was deleted")
    print(failures == 0 ? "ALL PASS" : "\(failures) FAILURE(S)")
    exit(failures == 0 ? 0 : 1)
}
