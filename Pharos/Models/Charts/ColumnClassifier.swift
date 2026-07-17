import Foundation

/// Classifies a PostgreSQL column type string into a ColumnKind for charting.
enum ColumnClassifier {
    static func kind(forDataType dataType: String) -> ColumnKind {
        let t = dataType.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()

        // Temporal
        if t.hasPrefix("date") || t.hasPrefix("timestamp") || t.hasPrefix("time") {
            return .temporal
        }
        // Numeric
        let numericPrefixes = ["int", "smallint", "bigint", "serial", "smallserial", "bigserial",
                               "float", "double", "real", "numeric", "decimal", "money"]
        if numericPrefixes.contains(where: { t.hasPrefix($0) }) {
            return .numeric
        }
        // Everything else (text, varchar, bool, uuid, enums, arrays, json…)
        return .categorical
    }

    /// Refine a kind by sniffing sample string values when the type is ambiguous.
    /// Values arrive as PG text strings; a column that parses fully as numbers is numeric.
    static func refine(kind: ColumnKind, sampleValues: [String]) -> ColumnKind {
        guard kind == .categorical, !sampleValues.isEmpty else { return kind }
        let allNumeric = sampleValues.allSatisfy { ValueCoercion.double(from: $0) != nil }
        return allNumeric ? .numeric : kind
    }
}
