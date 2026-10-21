import Foundation

/// What the Attach PostgreSQL Connection sheet offers and accepts.
///
/// Pure and Foundation-only (it needs `Models/Connection.swift`), so
/// `scripts/test-duckdb-attach-rules.sh` pins it without AppKit.
enum DuckDBAttachRules {

    /// The connections the sheet offers: every PostgreSQL record, in the
    /// user's order.
    static func candidates(_ connections: [ConnectionConfig]) -> [ConnectionConfig] {
        connections.filter { $0.engine == .postgres }
    }

    /// A read-only record attaches read-only whatever the checkbox says, as
    /// its own sessions are read-only.
    static func forcesReadOnly(_ config: ConnectionConfig) -> Bool {
        config.readOnly
    }

    /// The alias pharos-core uses when the field is empty — a mirror of
    /// `duck_attach::default_alias`, shown as the field's placeholder.
    static func defaultAlias(for name: String) -> String {
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
            out = "pg_" + out
            while out.hasSuffix("_") { out.removeLast() }
        }
        if reserved.contains(out) { out = "pg_" + out }
        return String(out.prefix(63))
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

    private static let reserved: Set<String> = ["memory", "system", "temp", "main"]
}
