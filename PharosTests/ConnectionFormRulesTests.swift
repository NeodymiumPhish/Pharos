// Standalone test for ConnectionFormRules — what the Connections Manager shows
// and accepts per engine.
import Foundation

var failures = 0
func expect(_ c: Bool, _ n: String) { if c { print("PASS \(n)") } else { failures += 1; print("FAIL \(n)") } }

func runTests() {
    // C3: the schema pop-up's placeholder and the DuckDB test summary.
    expect(ConnectionFormRules.schemaPlaceholder(for: .duckdb).values == ["main"]
           && ConnectionFormRules.schemaPlaceholder(for: .duckdb).sentinel == nil, "DuckDB shows main before a test")
    expect(ConnectionFormRules.schemaPlaceholder(for: .postgres).sentinel == "Test connection first", "PostgreSQL asks for a test")
    let now = Date()
    let summary = ConnectionFormRules.duckDBFileSummary(size: 12_400_000, modified: now, now: now)
    expect(summary.hasPrefix("DuckDB file · ") && summary.hasSuffix(" · modified today") && summary.contains("MB"),
           "an existing file: size and modified today (\(summary))")
    expect(ConnectionFormRules.duckDBFileSummary(size: 1, modified: now, storage: "storage version 64, written by DuckDB v1.5.6", now: now)
            .hasSuffix(" · modified today · storage version 64, written by DuckDB v1.5.6"), "the storage version follows")
    let yesterday = Calendar.current.date(byAdding: .day, value: -1, to: now)!
    expect(ConnectionFormRules.duckDBFileSummary(size: 1, modified: yesterday, now: now).hasSuffix("modified yesterday"),
           "modified yesterday")
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

    // MARK: missingFields — the "Required" captions

    let complete = ConnectionConfig(id: "m", name: "prod", host: "db", port: 5432, database: "app", username: "me")
    expect(ConnectionFormRules.missingFields(complete).isEmpty, "a complete server record misses nothing")
    let blankServer = ConnectionConfig(id: "m2", name: "", host: "", port: 5432, database: "", username: "")
    expect(ConnectionFormRules.missingFields(blankServer) == [.name, .host, .username, .database],
           "a blank server record misses name, host, username and database, in form order")
    var spaces = complete
    spaces.host = " \t "
    expect(ConnectionFormRules.missingFields(spaces) == [.host], "a host of spaces and tabs is missing")
    var noUser = complete
    noUser.username = ""
    expect(ConnectionFormRules.missingFields(noUser) == [.username], "only the blank field is named (username)")
    var noDatabase = complete
    noDatabase.database = ""
    expect(ConnectionFormRules.missingFields(noDatabase) == [.database], "only the blank field is named (database)")
    // The password, port, SSL and tunnel are never required.
    var noPassword = complete
    noPassword.password = ""
    expect(ConnectionFormRules.missingFields(noPassword).isEmpty, "a blank password is not missing")

    var duckBlank = ConnectionConfig.duckDB(path: "", id: "d")
    duckBlank.name = ""
    expect(ConnectionFormRules.missingFields(duckBlank) == [.name, .databaseFile],
           "a blank DuckDB record misses its name and its FILE, not a host or a user")
    var duckMemory = ConnectionConfig.duckDB(path: ConnectionConfig.duckDBInMemoryPath, id: "d2")
    duckMemory.name = "scratch"
    expect(ConnectionFormRules.missingFields(duckMemory).isEmpty, "in-memory DuckDB misses nothing")
    var duckFile = ConnectionConfig.duckDB(path: "/tmp/a.duckdb", id: "d3")
    duckFile.name = "a"
    duckFile.host = ""
    duckFile.username = ""
    expect(ConnectionFormRules.missingFields(duckFile).isEmpty, "a DuckDB record never needs host or user")

    // An SSH tunnel that is on needs its SSH host; the SSH user may stay
    // blank (~/.ssh/config supplies it). A tunnel that is off needs nothing.
    var tunnelNoHost = complete
    tunnelNoHost.sshTunnel = SshTunnelConfig(host: " \t ")
    expect(ConnectionFormRules.missingFields(tunnelNoHost) == [.sshHost], "a tunnel with a blank SSH host misses it")
    expect(!ConnectionFormRules.isValid(tunnelNoHost), "and Save cannot be pressed")
    var tunnelNoUser = complete
    tunnelNoUser.sshTunnel = SshTunnelConfig(host: "bastion", user: nil)
    expect(ConnectionFormRules.missingFields(tunnelNoUser).isEmpty, "a tunnel with a host and no SSH user misses nothing")
    var blankWithTunnel = blankServer
    blankWithTunnel.sshTunnel = SshTunnelConfig(host: "")
    expect(ConnectionFormRules.missingFields(blankWithTunnel) == [.name, .host, .username, .sshHost, .database],
           "the SSH host comes in form order, after the user and before the database")
    var duckWithStaleTunnel = duckMemory
    duckWithStaleTunnel.sshTunnel = SshTunnelConfig(host: "")
    expect(ConnectionFormRules.missingFields(duckWithStaleTunnel).isEmpty, "a DuckDB record never needs an SSH host")

    // The server's Port: the SSH Port's rule and words.
    expect(ConnectionFormRules.portProblem(engine: .postgres, portText: "99999") == "Enter a port from 1 to 65535.",
           "Port 99999 has a problem, in the SSH Port's words")
    for bad in ["", "0", "65536", "-1", "54x", " "] {
        expect(ConnectionFormRules.portProblem(engine: .postgres, portText: bad) != nil, "Port \"\(bad)\" has a problem")
    }
    for good in ["1", "5432", " 6543 ", "65535"] {
        expect(ConnectionFormRules.portProblem(engine: .postgres, portText: good) == nil, "Port \"\(good)\" is a port")
    }
    expect(ConnectionFormRules.portProblem(engine: .duckdb, portText: "99999") == nil,
           "a DuckDB record shows no Port, so a stale one cannot block Save")

    // isValid is exactly "nothing missing", for every record above.
    for record in [complete, blankServer, spaces, noUser, noDatabase, noPassword, duckBlank, duckMemory, duckFile,
                   tunnelNoHost, tunnelNoUser, blankWithTunnel, duckWithStaleTunnel] {
        expect(ConnectionFormRules.isValid(record) == ConnectionFormRules.missingFields(record).isEmpty,
               "Save and the captions agree (\(record.id))")
    }

    print(failures == 0 ? "ALL PASS" : "\(failures) FAILURE(S)")
    exit(failures == 0 ? 0 : 1)
}
