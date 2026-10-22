// Standalone test for DockMenuRule: which records the Dock icon's menu lists.
// Compiled by scripts/test-dock-menu-rule.sh.
import Foundation

private var failures = 0
private func expect(_ c: Bool, _ n: String, _ detail: @autoclosure () -> String = "") {
    if c { print("PASS \(n)") } else { failures += 1; print("FAIL \(n)" + (detail().isEmpty ? "" : "\n  \(detail())")) }
}

private func ids(_ content: DockMenuRule.Content) -> [String]? {
    if case .connections(let list) = content { return list.map(\.id) }
    return nil
}

func runTests() {
    let pg = ConnectionConfig(id: "pg", name: "Prod", host: "h", port: 5432, database: "d", username: "u")
    let file = ConnectionConfig.duckDB(path: "/tmp/sales.duckdb", id: "file")
    let mem = ConnectionConfig.duckDB(path: ":memory:", id: "mem", saved: true)
    let openedMem = ConnectionConfig.duckDB(path: ":memory:", id: "openedMem")
    var openedPg = ConnectionConfig(id: "openedPg", name: "X", host: "h", port: 5432, database: "d", username: "u")
    openedPg.saved = false
    let pg2 = ConnectionConfig(id: "pg2", name: "Dev", host: "h", port: 5432, database: "d", username: "u")

    expect(ids(DockMenuRule.content(for: [pg, file, mem, pg2])) == ["pg", "mem", "pg2"],
           "servers and in-memory databases are listed in order; a file is not")
    if case .onlyFiles = DockMenuRule.content(for: [file]) { expect(true, "only files: nothing listed") }
    else { expect(false, "only files: nothing listed") }
    if case .none = DockMenuRule.content(for: []) { expect(true, "no records: the No Connections case") }
    else { expect(false, "no records: the No Connections case") }
    expect(ids(DockMenuRule.content(for: [file, mem])) == ["mem"], "an in-memory database is listed beside a file")
    expect(ids(DockMenuRule.content(for: [pg, openedMem, openedPg])) == ["pg"],
           "a record that was opened, not saved, is not listed")
    if case .onlyFiles = DockMenuRule.content(for: [openedMem]) { expect(true, "only not-saved records: nothing listed") }
    else { expect(false, "only not-saved records: nothing listed") }

    if failures == 0 { print("\nAll Dock menu rule tests passed.") } else { print("\n\(failures) failure(s)."); exit(1) }
}
