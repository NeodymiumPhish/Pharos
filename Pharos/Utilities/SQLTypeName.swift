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
        // ClickHouse wraps a type to say how it is stored, not what it is:
        // `Nullable(DateTime64(0))`, `LowCardinality(Nullable(String))`.
        for wrapper in ["nullable(", "lowcardinality("] where t.hasPrefix(wrapper) && t.hasSuffix(")") {
            return postgresEquivalent(String(t.dropFirst(wrapper.count).dropLast()))
        }
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
        // ClickHouse, through its PostgreSQL port (`commands::clickhouse` in
        // the core puts its own type names on a result). A `DateTime('UTC')`
        // is printed with no offset, so it is a `timestamp`, not a
        // `timestamptz`, whatever its zone. ClickHouse's `Int8` lowercases to
        // PostgreSQL's 8-byte `int8`; both are integers, so it passes through.
        case "datetime", "datetime64": return "timestamp"
        case "date32": return "date"
        case "time64": return "time"
        case "string", "fixedstring": return "text"
        case "uint8", "int16": return "int2"
        case "uint16", "int32": return "int4"
        case "uint32", "int64": return "int8"
        case "uint64", "int128", "uint128", "int256", "uint256",
             "decimal32", "decimal64", "decimal128", "decimal256": return "numeric"
        case "float32", "bfloat16": return "float4"
        case "float64": return "float8"
        case "enum8", "enum16": return "enum"
        case "json", "object": return "json"
        // Composite values are text; the bare keyword keeps
        // `Array(UInt32)` or `Tuple(a Int64)` from matching "int" downstream.
        case "array", "tuple", "nested", "dynamic",
             "aggregatefunction", "simpleaggregatefunction": return base
        // `IntervalDay`, `IntervalSecond` …: a count of one unit, which no
        // site can read as PostgreSQL's `interval` (`interval day to second`
        // has spaces, so it is not caught here).
        case _ where base.hasPrefix("interval") && base != "interval" && !base.contains(" "): return "text"
        default: return t
        }
    }
}
