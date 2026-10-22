// Standalone test for ConnectionMenuText and PathAbbreviation — compiled by
// scripts/test-connection-menu-text.sh.
import Foundation

private var failures = 0
private func expect<T: Equatable>(_ actual: T, _ expected: T, _ name: String) {
    if actual == expected { print("PASS \(name)") } else {
        failures += 1
        print("FAIL \(name)\n  expected: \(expected)\n  actual:   \(actual)")
    }
}

func runTests() {
    var pg = ConnectionConfig(id: "p", name: "Live Analysis", host: "db.internal", port: 5432,
                              database: "analytics", username: "nfinn")
    expect(ConnectionMenuText.place(of: pg), "analytics on db.internal:5432", "a server: database on host:port")
    expect(ConnectionMenuText.place(of: pg).contains("nfinn"), false, "no user name")
    expect(ConnectionMenuText.badge(of: pg), nil, "a plain server has no badge")
    expect(ConnectionMenuText.toolTip(of: pg), "Live Analysis\nanalytics on db.internal:5432", "tooltip: name and place")

    pg.sshTunnel = SshTunnelConfig(host: "bastion.example.com", user: "nfinn")
    expect(ConnectionMenuText.badge(of: pg), "SSH", "a tunnel: SSH")
    expect(ConnectionMenuText.toolTip(of: pg),
           "Live Analysis\nanalytics on db.internal:5432\nThrough an SSH tunnel via bastion.example.com",
           "the tooltip names the tunnel host, not the user")
    pg.readOnly = true
    expect(ConnectionMenuText.badge(of: pg), "SSH · Read-only", "a tunnel and Read-only")
    pg.sshTunnel = nil
    expect(ConnectionMenuText.badge(of: pg), "Read-only", "Read-only alone")

    let file = ConnectionConfig.duckDB(path: NSHomeDirectory() + "/Data/sales.duckdb", id: "f")
    expect(ConnectionMenuText.place(of: file), "~/Data/sales.duckdb", "a file: its path, ~ for home")
    expect(ConnectionMenuText.badge(of: file, readOnlyNow: true), "Read-only", "another app holds the file: Read-only")
    expect(ConnectionMenuText.toolTip(of: file), "sales\n" + NSHomeDirectory() + "/Data/sales.duckdb", "tooltip: the full path")
    let mem = ConnectionConfig.duckDB(path: ":memory:", id: "m")
    expect(ConnectionMenuText.place(of: mem), "In memory", "in-memory")
    expect(ConnectionMenuText.kind(of: mem), .memory, "in-memory kind")
    expect(ConnectionMenuText.kind(of: file), .file, "file kind")

    let hostile = ConnectionConfig(id: "h", name: "x", host: "evil\u{202E}moc", port: 1, database: "d", username: "")
    expect(ConnectionMenuText.place(of: hostile), "d on evil<U+202E>moc:1", "each field is escaped")

    let long = "~/Projects/aSideProjects/Pharos/fixtures/2026/q3-sales-final.duckdb"
    expect(PathAbbreviation.middle(long), "~/Projects/…/q3-sales-final.duckdb", "a long path keeps its start and its file")
    expect(PathAbbreviation.middle("~/Downloads/rule605-20240311.duckdb"), "~/Downloads/rule605-20240311.duckdb",
           "a short path is left alone")
    let longName = "~/a/b/c/" + String(repeating: "n", count: 60) + ".duckdb"
    expect(PathAbbreviation.middle(longName), "…/" + String(repeating: "n", count: 60) + ".duckdb",
           "a file name too long for the start: …/name")

    if failures == 0 { print("\nAll connection menu text tests passed.") } else { print("\n\(failures) failure(s)."); exit(1) }
}
