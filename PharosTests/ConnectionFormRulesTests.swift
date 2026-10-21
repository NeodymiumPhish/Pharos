// Standalone test for ConnectionFormRules — what the Connections Manager shows
// and accepts per engine.
import Foundation

var failures = 0
func expect(_ c: Bool, _ n: String) { if c { print("PASS \(n)") } else { failures += 1; print("FAIL \(n)") } }

func runTests() {
    let pg = ConnectionFormRules.visibility(for: .postgres)
    expect(pg.server && pg.authentication && pg.sshTunnel && pg.databaseName && pg.timeZone && !pg.databaseFile,
           "PostgreSQL shows the server sections and no file")
    let dk = ConnectionFormRules.visibility(for: .duckdb)
    expect(!dk.server && !dk.authentication && !dk.sshTunnel && !dk.databaseName && !dk.timeZone && dk.databaseFile,
           "DuckDB shows only the file")

    var server = ConnectionConfig(id: "a", name: "p", host: "h", port: 5432, database: "d", username: "u")
    expect(ConnectionFormRules.isValid(server), "a complete server record is valid")
    server.username = " "
    expect(!ConnectionFormRules.isValid(server), "a server record needs a user")

    var duck = ConnectionConfig.duckDB(path: "/tmp/x.duckdb", id: "b")
    expect(ConnectionFormRules.isValid(duck), "a DuckDB record with a file is valid without host or user")
    duck.database = ""
    expect(!ConnectionFormRules.isValid(duck), "a DuckDB record needs a file or in-memory")
    duck.database = ConnectionFormRules.duckDBPath(inMemory: true, typed: "ignored")
    expect(duck.database == ":memory:" && ConnectionFormRules.isValid(duck), "in-memory is a valid choice")
    expect(ConnectionFormRules.duckDBPath(inMemory: false, typed: "  /a b.duckdb ") == "/a b.duckdb", "a typed path is trimmed")
    duck.name = ""
    expect(!ConnectionFormRules.isValid(duck), "a DuckDB record needs a name")

    var switched = ConnectionConfig(id: "c", name: "n", host: "h", port: 5432, database: "/f.duckdb", username: "u",
                                    password: "secret", requiresAuthentication: true,
                                    sshTunnel: SshTunnelConfig(host: "bastion"), sessionTimeZone: "UTC")
    switched.engine = .duckdb
    let n = ConnectionFormRules.normalized(switched)
    expect(n.host.isEmpty && n.port == 0 && n.username.isEmpty && n.password.isEmpty, "server fields are cleared for DuckDB")
    expect(n.sshTunnel == nil && !n.requiresAuthentication && n.sessionTimeZone == nil, "tunnel, gate and zone are cleared")
    expect(n.database == "/f.duckdb" && n.name == "n", "the file and the name stay")
    expect(ConnectionFormRules.normalized(server) == server, "a PostgreSQL record is untouched")
    expect(ConnectionFormRules.readOnlyHelp(for: .duckdb) != ConnectionFormRules.readOnlyHelp(for: .postgres), "the read-only help names the engine's behaviour")

    // Test Connection's schema fetch (the cause of the duplicate record).
    let missing = ConnectionConfig.duckDB(path: "/no/such/new.duckdb")
    expect(!ConnectionFormRules.shouldFetchSchemas(missing, fileExists: { _ in false }), "a DuckDB file that does not exist yet: no schema fetch")
    expect(ConnectionFormRules.shouldFetchSchemas(missing, fileExists: { _ in true }), "an existing DuckDB file: fetch")
    var seen = ""
    _ = ConnectionFormRules.shouldFetchSchemas(ConnectionConfig.duckDB(path: "~/x.duckdb"), fileExists: { seen = $0; return true })
    expect(seen.hasPrefix("/") && seen.hasSuffix("/x.duckdb"), "the tilde is expanded before the check")
    expect(ConnectionFormRules.shouldFetchSchemas(ConnectionConfig.duckDB(path: ConnectionConfig.duckDBInMemoryPath), fileExists: { _ in false }), "in-memory: fetch")
    expect(ConnectionFormRules.shouldFetchSchemas(server, fileExists: { _ in false }), "PostgreSQL: always fetch")
    expect(ConnectionFormRules.schemaFetchIdPrefix == "__test_schema_fetch_", "the prefix pharos-core hides and purges")

    print(failures == 0 ? "ALL PASS" : "\(failures) FAILURE(S)")
    exit(failures == 0 ? 0 : 1)
}
