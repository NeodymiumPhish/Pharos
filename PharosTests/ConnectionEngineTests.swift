// Standalone test for `ConnectionConfig.engine` and the DuckDB helpers beside
// it: the decode of the FFI document (with and without the key, with no
// server fields), the round trip, the equality the form's dirty state uses,
// the capabilities each engine declares, and the DuckDB open-error markers.
import Foundation

var failures = 0
func expect(_ c: Bool, _ n: String) { if c { print("PASS \(n)") } else { failures += 1; print("FAIL \(n)") } }

private func decode(_ json: String, _ name: String) -> ConnectionConfig? {
    do {
        return try JSONDecoder().decode(ConnectionConfig.self, from: Data(json.utf8))
    } catch {
        failures += 1
        print("FAIL \(name) — decode threw: \(error)")
        return nil
    }
}

func runTests() {
    // 1. A record from before DuckDB support has no engine key: PostgreSQL.
    if let c = decode(#"{"id":"a","name":"p","host":"h","port":5432,"database":"d","username":"u"}"#, "no engine key") {
        expect(c.engine == .postgres, "an absent engine key is PostgreSQL")
        expect(!c.isDuckDB, "and is not DuckDB")
        expect(c.effectiveDefaultSchema == "public", "PostgreSQL's default schema is public")
        expect(c.locationDescription == "h:5432/d", "a server record shows host:port/database")
    }

    // 2. The core's DuckDB document, read from a LITERAL so a mis-cased key fails.
    if let c = decode(#"{"id":"b","name":"sales","engine":"duckdb","host":"","port":0,"database":"/Users/x/Data/sales.duckdb","username":""}"#, "duckdb") {
        expect(c.engine == .duckdb, "\"engine\":\"duckdb\" decodes to .duckdb")
        expect(c.effectiveDefaultSchema == "main", "DuckDB's default schema is main")
        expect(ConnectionConfig.abbreviatingHome(c.database, home: "/Users/x") == "~/Data/sales.duckdb", "the home folder is abbreviated")
        expect(!c.isInMemoryDuckDB, "a file is not in-memory")
    }

    // 3. A producer that leaves the server fields out entirely still decodes.
    if let c = decode(#"{"id":"c","name":"m","engine":"duckdb","database":":memory:"}"#, "no server fields") {
        expect(c.host.isEmpty && c.port == 0 && c.username.isEmpty, "absent host, port and user default to empty")
        expect(c.isInMemoryDuckDB, ":memory: is in-memory")
        expect(c.locationDescription == String(localized: "In-memory"), "an in-memory record says so")
    }

    // 4. An unknown engine is a loud failure, never a silent fallback.
    let unknown = try? JSONDecoder().decode(ConnectionConfig.self, from: Data(#"{"id":"d","name":"x","engine":"oracle","database":"d"}"#.utf8))
    expect(unknown == nil, "an unknown engine does not decode")

    // 5. Round trip writes the key, and equality sees it.
    var duck = ConnectionConfig.duckDB(path: "/tmp/a/b.duckdb", id: "e")
    expect(duck.name == "b", "a new record is named after the file stem")
    let data = (try? JSONEncoder().encode(duck)) ?? Data()
    let text = String(data: data, encoding: .utf8) ?? ""
    expect(text.contains("\"engine\":\"duckdb\""), "encoding writes the engine")
    let back = try? JSONDecoder().decode(ConnectionConfig.self, from: data)
    expect(back == duck, "the round trip is equal")
    var other = duck
    other.engine = .postgres
    expect(other != duck, "equality compares the engine (the form's dirty state)")
    duck.database = ":memory:"
    expect(ConnectionConfig.duckDB(path: ":memory:").name == String(localized: "In-memory DuckDB"), "an in-memory record has a name")

    // 6. Capabilities.
    let pg = DatabaseEngine.postgres.capabilities, dk = DatabaseEngine.duckdb.capabilities
    expect(pg.serverConnection && !dk.serverConnection, "only PostgreSQL has a server")
    expect(!pg.parquetExport && dk.parquetExport, "Parquet export is DuckDB-only")
    expect(!dk.partitions && !dk.automaticAnalyze, "DuckDB has no partitions and no automatic ANALYZE")
    expect(DatabaseEngine.duckdb.dialectName == "DuckDB" && DatabaseEngine.postgres.dialectName == "PostgreSQL", "dialect names")

    // 7. DuckDB open errors.
    let locked = "[PHAROS_DUCKDB_LOCKED] IO Error: Could not set lock on file \"/x.duckdb\": Conflicting lock is held in /usr/local/bin/duckdb (PID 4242) by user x."
    expect(DuckDBOpenError.isLocked(locked) && !DuckDBOpenError.isTooNew(locked), "the lock marker is read")
    expect(DuckDBOpenError.holderPID(locked) == 4242, "the holder's PID is read")
    expect(!DuckDBOpenError.humanised(locked).contains("[PHAROS"), "the marker is not shown")
    expect(DuckDBOpenError.humanised("plain") == "plain", "other messages pass through")
    expect(DuckDBOpenError.isTooNew("[PHAROS_DUCKDB_TOO_NEW] Serialization Error"), "the too-new marker is read")
    let missing = "[PHAROS_DUCKDB_MISSING] There is no file at /x/sales.duckdb."
    expect(DuckDBOpenError.isMissing(missing) && !DuckDBOpenError.isLocked(missing), "the missing-file marker is read")
    expect(DuckDBOpenError.humanised(missing) == "There is no file at /x/sales.duckdb.", "the missing-file marker is not shown")
    expect(DuckDBOpenError.holderPID("no pid here") == nil, "no PID, no number")

    print(failures == 0 ? "ALL PASS" : "\(failures) FAILURE(S)")
    exit(failures == 0 ? 0 : 1)
}
