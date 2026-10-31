// Standalone test for DuckDBAttachRules — the Attach Database sheet's
// choices, default names and file check, and the navigator's subtitle.
import Foundation

var failures = 0
func expect(_ c: Bool, _ n: String) { if c { print("PASS \(n)") } else { failures += 1; print("FAIL \(n)") } }

func runTests() {
    let pg = ConnectionConfig(id: "p", name: "Live Analysis", host: "h", port: 5432, database: "d", username: "u")
    let dir = FileManager.default.temporaryDirectory.appendingPathComponent("attach-rules-\(UUID().uuidString)")
    try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: dir) }
    let salesPath = dir.appendingPathComponent("sales.duckdb").path
    var sales = ConnectionConfig.duckDB(path: salesPath)
    sales.id = "s"
    var salesAgain = ConnectionConfig.duckDB(path: salesPath)
    salesAgain.id = "s2"
    var other = ConnectionConfig.duckDB(path: dir.appendingPathComponent("other.duckdb").path)
    other.id = "o"
    var memory = ConnectionConfig.duckDB(path: ConnectionConfig.duckDBInMemoryPath)
    memory.id = "m"

    expect(DuckDBAttachRules.postgresCandidates([sales, pg]).map(\.id) == ["p"], "only PostgreSQL records under PostgreSQL")
    expect(DuckDBAttachRules.fileCandidates([sales, pg, memory, salesAgain, other], excludingFileOf: memory).map(\.id) == ["s", "o"],
           "file records once per file, no in-memory records")
    expect(DuckDBAttachRules.fileCandidates([sales, other], excludingFileOf: sales).map(\.id) == ["o"],
           "never the database's own file")

    // The same table as pharos-core's default_aliases_are_valid_identifiers.
    for (name, want) in [("Live Analysis", "live_analysis"), ("Ghostnet/ZISK", "ghostnet_zisk"),
                         ("2024 db", "pg_2024_db"), ("  ", "pg"), ("main", "pg_main"), ("WHOIS - CH", "whois_ch")] {
        let got = DuckDBAttachRules.defaultAlias(for: name)
        expect(got == want, "default alias of \"\(name)\" is \(want) (got \(got))")
        expect(DuckDBAttachRules.isValidAlias(got), "\(got) is valid")
    }
    // And file_aliases_and_free_names.
    expect(DuckDBAttachRules.defaultAlias(forFile: "/a/sales-2024.duckdb") == "sales_2024", "file alias from its name")
    expect(DuckDBAttachRules.defaultAlias(forFile: "/a/2024.sqlite") == "db_2024", "a file alias that starts with a digit")
    expect(DuckDBAttachRules.defaultAlias(forFile: "/a/main.db") == "db_main", "a reserved file alias")
    expect(DuckDBAttachRules.isValidAlias(""), "empty means the default")
    for bad in ["Bad Name", "x;drop", "memory", "1abc", "é"] {
        expect(!DuckDBAttachRules.isValidAlias(bad), "\"\(bad)\" is refused")
    }

    var ro = pg
    ro.readOnly = true
    expect(DuckDBAttachRules.forcesReadOnly(ro) && !DuckDBAttachRules.forcesReadOnly(pg), "a read-only record forces read-only")

    expect(DuckDBAttachRules.attachedDatabase(ofSchema: "local_pg.public") == "local_pg", "an attached schema names its database")
    expect(DuckDBAttachRules.attachedDatabase(ofSchema: "main") == nil, "the file's own schema is not attached")

    // File check: the header decides.
    var duckHeader = Data(repeating: 0, count: 8) + Data("DUCK".utf8) + Data(repeating: 0, count: 100)
    expect(DuckDBAttachRules.databaseKind(header: duckHeader) == "duckdb", "a DuckDB header")
    expect(DuckDBAttachRules.databaseKind(header: Data("SQLite format 3\0more".utf8)) == "sqlite", "a SQLite header")
    expect(DuckDBAttachRules.databaseKind(header: Data("hello, this is text".utf8)) == nil, "text is no database")
    expect(DuckDBAttachRules.databaseKind(header: Data()) == nil, "an empty file is no database")
    let duckFile = dir.appendingPathComponent("x.db")
    try? duckHeader.write(to: duckFile)
    let textFile = dir.appendingPathComponent("notes.db")
    try? Data("hello, this is text".utf8).write(to: textFile)
    let wrongExt = dir.appendingPathComponent("x.csv")
    try? duckHeader.write(to: wrongExt)
    expect(DuckDBAttachRules.isDatabaseFile(duckFile), "a .db with a DuckDB header is a database file")
    expect(!DuckDBAttachRules.isDatabaseFile(textFile), "a .db of text is not")
    expect(!DuckDBAttachRules.isDatabaseFile(wrongExt), "a .csv is not, whatever its header")
    duckHeader.removeAll()

    // The sheet's disabled reasons.
    let attachedPg = DuckDBAttachment(alias: "live", kind: "postgres", path: nil, pgId: "p", pgName: "Live Analysis",
                                      readOnly: true, attached: true, remembered: true)
    let waitingPg = DuckDBAttachment(alias: "wh", kind: "postgres", path: nil, pgId: "w", pgName: "Warehouse",
                                     readOnly: true, attached: false, remembered: true)
    let attachedFile = DuckDBAttachment(alias: "sales", kind: "duckdb", path: salesPath, pgId: nil, pgName: nil,
                                        readOnly: false, attached: true, remembered: true)
    let list = [attachedPg, waitingPg, attachedFile]
    expect(DuckDBAttachRules.unavailableReason(postgres: "p", in: list) == "Attached as live", "an attached connection")
    expect(DuckDBAttachRules.unavailableReason(postgres: "w", in: list) == nil, "a remembered, waiting connection can be chosen")
    expect(DuckDBAttachRules.unavailableReason(file: salesPath, in: list, openWritable: false) == "Attached as sales", "an attached file")
    expect(DuckDBAttachRules.unavailableReason(file: other.database, in: list, openWritable: true) == "Open in another tab",
           "a file another tab writes")
    expect(DuckDBAttachRules.unavailableReason(file: other.database, in: list, openWritable: false) == nil, "a free file")

    // The navigator subtitle.
    expect(DuckDBAttachRules.subtitle(for: attachedPg) == "PostgreSQL · Live Analysis · Read-only", "a PostgreSQL subtitle")
    expect(DuckDBAttachRules.subtitle(for: attachedFile) == "sales.duckdb", "a writable file subtitle")
    let remote = DuckDBAttachment(alias: "t", kind: "duckdb", path: "https://h.example/db/t7091.duckdb", pgId: nil, pgName: nil,
                                  readOnly: true, attached: true, remembered: false)
    expect(DuckDBAttachRules.subtitle(for: remote) == "t7091.duckdb · Read-only", "a link's file subtitle")
    let typed = DuckDBAttachment(alias: "m", kind: "duckdb", path: nil, pgId: nil, pgName: nil,
                                 readOnly: false, attached: true, remembered: false)
    expect(DuckDBAttachRules.subtitle(for: typed) == "DuckDB", "an in-memory attach")

    print(failures == 0 ? "ALL PASS" : "\(failures) FAILURE(S)")
    exit(failures == 0 ? 0 : 1)
}
