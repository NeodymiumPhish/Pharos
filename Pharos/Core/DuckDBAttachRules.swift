import Foundation

/// A database attached to (or remembered by) a DuckDB database
/// (`pharos-core` `duck_attach::AttachmentInfo`, camelCase).
struct DuckDBAttachment: Decodable, Equatable {
    /// The DuckDB database name: its schemas show as `alias.schema`.
    let alias: String
    /// DuckDB's database type: "postgres", "duckdb", "sqlite"…
    let kind: String
    /// The file (or URL) of a file database.
    let path: String?
    let pgId: String?
    let pgName: String?
    let readOnly: Bool
    /// Attached now. False for a remembered attach that waits for its
    /// PostgreSQL connection, or that could not be restored.
    let attached: Bool
    /// Pharos attaches it again each time this DuckDB database opens.
    let remembered: Bool
}

/// What Query ▸ Attach Database… offers and accepts, and how the navigator
/// names an attached database.
///
/// Pure and Foundation-only (it needs `Models/Connection.swift` and
/// `Core/DuckDBFiles.swift`), so `scripts/test-duckdb-attach-rules.sh` pins it
/// without AppKit.
enum DuckDBAttachRules {

    /// The PostgreSQL connections the sheet offers: every PostgreSQL record,
    /// in the user's order.
    static func postgresCandidates(_ connections: [ConnectionConfig]) -> [ConnectionConfig] {
        connections.filter { $0.engine == .postgres }
    }

    /// The DuckDB files the sheet offers: every DuckDB record on a file, in
    /// the user's order, once per file, without the database's own file.
    static func fileCandidates(_ connections: [ConnectionConfig], excludingFileOf duck: ConnectionConfig?) -> [ConnectionConfig] {
        let own = duck.flatMap { $0.isInMemoryDuckDB ? nil : DuckDBFiles.canonicalPath($0.database) }
        var seen: Set<String> = []
        return connections.filter { c in
            guard c.isDuckDB, !c.isInMemoryDuckDB else { return false }
            let path = DuckDBFiles.canonicalPath(c.database)
            guard path != own else { return false }
            return seen.insert(path).inserted
        }
    }

    /// A read-only record attaches read-only whatever the checkbox says, as
    /// its own sessions are read-only.
    static func forcesReadOnly(_ config: ConnectionConfig) -> Bool {
        config.readOnly
    }

    /// The alias pharos-core uses when the field is empty — a mirror of
    /// `duck_attach::default_alias`, shown as the field's placeholder.
    /// `prefix` is "pg" for a connection, "db" for a file.
    static func defaultAlias(for name: String, prefix: String = "pg") -> String {
        var out = ""
        for ch in name.trimmingCharacters(in: .whitespaces).lowercased() {
            if ch.isASCII, ch.isLetter || ch.isNumber {
                out.append(ch)
            } else if !out.hasSuffix("_") {
                out.append("_")
            }
        }
        out = out.trimmingCharacters(in: CharacterSet(charactersIn: "_"))
        if out.isEmpty || out.first!.isNumber {
            out = prefix + "_" + out
            while out.hasSuffix("_") { out.removeLast() }
        }
        if reserved.contains(out) { out = prefix + "_" + out }
        return String(out.prefix(63))
    }

    /// The default alias of a database file: its name without the extension.
    static func defaultAlias(forFile path: String) -> String {
        defaultAlias(for: ((path as NSString).lastPathComponent as NSString).deletingPathExtension, prefix: "db")
    }

    /// Whether a typed alias is acceptable (empty = use the default).
    static func isValidAlias(_ alias: String) -> Bool {
        if alias.isEmpty { return true }
        guard alias.count <= 63, let first = alias.first, first == "_" || ("a"..."z").contains(first) else { return false }
        guard !reserved.contains(alias) else { return false }
        return alias.allSatisfy { $0 == "_" || ("a"..."z").contains($0) || ("0"..."9").contains($0) }
    }

    /// The attached database a DuckDB navigator schema belongs to:
    /// `"local_pg.public"` → `"local_pg"`; nil for the file's own schemas.
    static func attachedDatabase(ofSchema schema: String) -> String? {
        guard let dot = schema.firstIndex(of: ".") else { return nil }
        let db = String(schema[..<dot])
        return db.isEmpty ? nil : db
    }

    // MARK: Database files

    /// The extensions the Choose File… panel and a navigator drop accept.
    /// `.db` is also used by files that are not databases: the header decides.
    static let fileExtensions: Set<String> = ["duckdb", "ddb", "db", "sqlite", "sqlite3"]

    /// The type of a database file from its first 16 bytes ("duckdb" or
    /// "sqlite"), or nil — a mirror of `duck_attach::database_kind`.
    static func databaseKind(header: Data) -> String? {
        let bytes = [UInt8](header.prefix(16))
        if bytes.count == 16, bytes == Array("SQLite format 3\0".utf8) { return "sqlite" }
        if bytes.count >= 12, bytes[8..<12].elementsEqual("DUCK".utf8) { return "duckdb" }
        return nil
    }

    /// Whether `url` is a DuckDB or SQLite database file Pharos can attach:
    /// its extension, then its header.
    static func isDatabaseFile(_ url: URL) -> Bool {
        guard url.isFileURL, fileExtensions.contains(url.pathExtension.lowercased()),
              let handle = try? FileHandle(forReadingFrom: url) else { return false }
        defer { try? handle.close() }
        return databaseKind(header: (try? handle.read(upToCount: 16)) ?? Data()) != nil
    }

    // MARK: The sheet's choices

    /// Why a PostgreSQL connection cannot be chosen now, or nil.
    static func unavailableReason(postgres id: String, in attachments: [DuckDBAttachment]) -> String? {
        attachments.first { $0.attached && $0.pgId == id }.map { String(localized: "Attached as \($0.alias)") }
    }

    /// Why a file cannot be chosen now, or nil: attached already, or open
    /// in another tab with write access (rule G1; the core has the last word).
    static func unavailableReason(file path: String, in attachments: [DuckDBAttachment],
                                  openWritable: Bool) -> String? {
        let target = DuckDBFiles.canonicalPath(path)
        if let a = attachments.first(where: { $0.attached && $0.path.map(DuckDBFiles.canonicalPath) == target }) {
            return String(localized: "Attached as \(a.alias)")
        }
        return openWritable ? String(localized: "Open in another tab") : nil
    }

    // MARK: The navigator

    /// The subtitle of an attached schema row: where the database comes from
    /// and whether it is read-only ("PostgreSQL · Live Analysis · Read-only",
    /// "sales.duckdb · Read-only").
    static func subtitle(for attachment: DuckDBAttachment) -> String {
        var parts: [String] = []
        switch attachment.kind {
        case "postgres":
            parts.append("PostgreSQL")
            if let name = attachment.pgName, !name.isEmpty { parts.append(name) }
        default:
            if let path = attachment.path, !path.isEmpty {
                // A file path or an http(s) URL: its last component either way.
                parts.append((path as NSString).lastPathComponent)
            } else {
                parts.append(attachment.kind == "sqlite" ? "SQLite" : "DuckDB")
            }
        }
        if attachment.readOnly { parts.append(String(localized: "Read-only")) }
        return parts.joined(separator: " · ")
    }

    private static let reserved: Set<String> = ["memory", "system", "temp", "main"]
}
