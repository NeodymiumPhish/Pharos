import Foundation

/// What the Connections Manager form shows and accepts for each engine.
///
/// Pure and Foundation-only (it needs `Models/Connection.swift`), so
/// `scripts/test-connection-form-rules.sh` pins it without AppKit.
enum ConnectionFormRules {

    /// Which parts of the form are on screen.
    struct Visibility: Equatable {
        /// Server: host and port.
        let server: Bool
        /// Authentication: user, password, SSL, remember, Touch ID.
        let authentication: Bool
        let sshTunnel: Bool
        /// The Database row (a server's database NAME).
        let databaseName: Bool
        /// Database File: path, Choose…, New…, In-memory.
        let databaseFile: Bool
        /// Session ▸ Time Zone.
        let timeZone: Bool
    }

    static func visibility(for engine: DatabaseEngine) -> Visibility {
        let server = engine.capabilities.serverConnection
        return Visibility(server: server, authentication: server, sshTunnel: server,
                          databaseName: server, databaseFile: !server, timeZone: server)
    }

    /// Whether Save can be pressed. A server needs a name, host, database and
    /// user; a DuckDB record needs a name and a file (or in-memory).
    static func isValid(_ d: ConnectionConfig) -> Bool {
        let filled = { (s: String) in !s.trimmingCharacters(in: .whitespaces).isEmpty }
        guard filled(d.name) else { return false }
        switch d.engine {
        case .postgres:
            return filled(d.host) && filled(d.database) && filled(d.username)
        case .duckdb:
            return filled(d.database)
        }
    }

    /// The record as the form saves it for its engine. A DuckDB record keeps
    /// no server fields: they are cleared, so nothing stale is stored, and a
    /// tunnel or Touch ID gate the form no longer shows cannot stay in force.
    static func normalized(_ d: ConnectionConfig) -> ConnectionConfig {
        guard d.engine == .duckdb else { return d }
        var out = d
        out.host = ""
        out.port = 0
        out.username = ""
        out.password = ""
        out.sslMode = .prefer
        out.sslRootCertPath = nil
        out.sshTunnel = nil
        out.requiresAuthentication = false
        out.sessionTimeZone = nil
        return out
    }

    /// The id prefix of the temporary record Test Connection saves to read
    /// the schema list. pharos-core hides and purges records with it
    /// (`commands::connection::SCHEMA_FETCH_ID_PREFIX`); the two must match.
    static let schemaFetchIdPrefix = "__test_schema_fetch_"

    /// Whether a passing Test Connection goes on to read the draft's schema
    /// list. A DuckDB file that does not exist yet has no schemas, and the
    /// read-only open the fetch uses would fail on it.
    static func shouldFetchSchemas(_ d: ConnectionConfig, fileExists: (String) -> Bool) -> Bool {
        guard d.engine == .duckdb, !d.isInMemoryDuckDB else { return true }
        return fileExists((d.database as NSString).expandingTildeInPath)
    }

    /// The Default Schema pop-up before any list was read: PostgreSQL asks
    /// for a test; DuckDB shows "main", which a record with no schema set
    /// already uses (HIG, Pop-up buttons: a useful default selection).
    static func schemaPlaceholder(for engine: DatabaseEngine) -> (sentinel: String?, values: [String]) {
        switch engine {
        case .postgres: return (String(localized: "Test connection first"), [])
        case .duckdb: return (nil, [DatabaseEngine.duckdb.defaultSchema])
        }
    }

    /// What Test Connection says about a DuckDB file that opened:
    /// "DuckDB file · 12.4 MB · modified today". The size is the database
    /// file alone; a `.wal` beside it is not counted.
    static func duckDBFileSummary(size: Int64, modified: Date, now: Date = Date()) -> String {
        let bytes = ByteCountFormatter.string(fromByteCount: size, countStyle: .file)
        let calendar = Calendar.current
        let when: String
        if calendar.isDate(modified, inSameDayAs: now) {
            when = String(localized: "modified today")
        } else if let yesterday = calendar.date(byAdding: .day, value: -1, to: now),
                  calendar.isDate(modified, inSameDayAs: yesterday) {
            when = String(localized: "modified yesterday")
        } else {
            when = String(localized: "modified \(modified.formatted(date: .abbreviated, time: .omitted))")
        }
        return String(localized: "DuckDB file · \(bytes) · \(when)")
    }

    /// The path a DuckDB record stores: `:memory:` for in-memory, else the
    /// path as typed, trimmed of outer spaces.
    static func duckDBPath(inMemory: Bool, typed: String) -> String {
        inMemory ? ConnectionConfig.duckDBInMemoryPath : typed.trimmingCharacters(in: .whitespaces)
    }

    /// The Read-only switch's tooltip, which says what the ENGINE does.
    static func readOnlyHelp(for engine: DatabaseEngine) -> String {
        switch engine {
        case .postgres:
            return String(localized: "Opens every session with default_transaction_read_only on, so the SERVER refuses writes. It takes effect the next time this connection opens.")
        case .duckdb:
            return String(localized: "Opens the file read-only, so DuckDB refuses writes. Other apps that also open it read-only can read it at the same time. It takes effect the next time this connection opens.")
        }
    }
}
