import AppKit

// MARK: - PG Type Classification

enum PGTypeCategory {
    case numeric
    case boolean
    case temporal
    case array
    case json
    case string

    init(dataType: String) {
        let dt = dataType.lowercased().trimmingCharacters(in: .whitespaces)
        if dt.hasSuffix("[]") || dt.hasPrefix("_") {
            self = .array
            return
        }
        switch dt {
        case "boolean", "bool":
            self = .boolean
        case "smallint", "int2", "integer", "int", "int4", "bigint", "int8",
             "real", "float4", "double precision", "float8",
             "numeric", "decimal", "money",
             "serial", "bigserial", "smallserial", "oid":
            self = .numeric
        case "json", "jsonb":
            self = .json
        case "date", "time", "timetz", "timestamp", "timestamptz",
             "timestamp without time zone", "timestamp with time zone",
             "time without time zone", "time with time zone", "interval":
            self = .temporal
        default:
            if dt.contains("int") || dt.contains("float") || dt.contains("numeric") || dt.contains("decimal") {
                self = .numeric
            } else {
                self = .string
            }
        }
    }
}

// MARK: - NSFont Italic Extension

extension NSFont {
    func withTraits(_ traits: NSFontDescriptor.SymbolicTraits) -> NSFont {
        let descriptor = fontDescriptor.withSymbolicTraits(traits)
        return NSFont(descriptor: descriptor, size: pointSize) ?? self
    }
}
