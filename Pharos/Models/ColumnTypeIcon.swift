import Foundation

/// Maps a PostgreSQL column data-type string (as returned by
/// `information_schema.columns.data_type`) to a monochrome SF Symbol name for the
/// schema browser's column rows. Foundation-only and returns a plain String, so it
/// is unit-testable standalone. Never returns nil — unmatched types fall back to
/// "textformat" (the generic "Aa" glyph) so a column icon never renders blank.
enum ColumnTypeIcon {

    static func symbolName(forDataType dataType: String) -> String {
        let t = dataType.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()

        // Array first: information_schema reports "ARRAY"; also handle "<type>[]".
        if t == "array" || t.hasSuffix("[]") { return "curlybraces" }

        // Date/time: check the "timestamp" prefix before the generic "time" prefix.
        if t.hasPrefix("timestamp") || t == "date" { return "calendar" }
        if t.hasPrefix("time") || t == "interval" { return "clock" }

        switch t {
        case "boolean", "bool":
            return "switch.2"
        case "json", "jsonb":
            return "curlybraces.square"
        case "inet", "cidr", "macaddr", "macaddr8":
            return "network"
        case "uuid":
            return "number.square"
        case "bytea":
            return "doc"
        case "text", "character varying", "varchar", "character",
             "char", "\"char\"", "name", "bpchar", "citext":
            return "textformat"
        case "smallint", "integer", "int", "int2", "int4", "int8", "bigint",
             "decimal", "numeric", "real", "double precision",
             "float", "float4", "float8", "money":
            return "number"
        default:
            return "textformat"
        }
    }
}
