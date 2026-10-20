import Foundation

/// A column's type name in the PostgreSQL spelling the type-name sites match.
///
/// Results carry each engine's own type text: sqlx's `INT4`, `FLOAT8`,
/// `TIMESTAMPTZ` for PostgreSQL, DuckDB's `INTEGER`, `DOUBLE`,
/// `DECIMAL(18,3)`, `TIMESTAMP WITH TIME ZONE`, `STRUCT(a INTEGER)`. The sites
/// that classify a column (`PGTypeCategory`, `ResultValueKind`,
/// `ColumnTypeIcon`, `ColumnClassifier`, `TagValueNormalizer`) were written
/// against PostgreSQL's names; each passes the name through here first, so a
/// DuckDB `DOUBLE` formats, sorts, charts and tags as the number it is.
///
/// Every PostgreSQL name passes through unchanged (lowercased and trimmed, as
/// the sites already did): only spellings PostgreSQL never reports are mapped.
/// The column header still shows the engine's own name.
enum SQLTypeName {

    static func postgresEquivalent(_ raw: String) -> String {
        let t = raw.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        // A list `INTEGER[]` or a fixed-size array `INTEGER[3]`: map the element.
        if t.hasSuffix("]"), let open = t.lastIndex(of: "[") {
            let size = t[t.index(after: open)..<t.index(before: t.endIndex)]
            if size.allSatisfy(\.isNumber) {
                return postgresEquivalent(String(t[..<open])) + "[]"
            }
        }
        let base = t.split(separator: "(", maxSplits: 1).first.map {
            $0.trimmingCharacters(in: .whitespaces)
        } ?? t
        switch base {
        case "tinyint", "utinyint": return "int2"
        case "usmallint": return "int4"
        case "uinteger": return "int8"
        case "ubigint", "hugeint", "uhugeint", "bignum", "varint": return "numeric"
        // `DECIMAL(18,3)`: the parameters are the value's, not the kind's.
        case "decimal": return "numeric"
        case "double": return "float8"
        case "float": return "float4"
        case "timestamp_s", "timestamp_ms", "timestamp_ns": return "timestamp"
        case "time_ns": return "time"
        case "blob": return "bytea"
        // Nested values are text to every site; the bare keyword keeps
        // `STRUCT(a INTEGER)` from matching "int" anywhere downstream.
        case "struct", "map", "union", "enum", "variant": return base
        default: return t
        }
    }
}
