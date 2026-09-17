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
    /// Values arrive as PG text strings; a column that parses fully as numbers is
    /// numeric, and one that parses fully as dates is temporal.
    static func refine(kind: ColumnKind, sampleValues: [String]) -> ColumnKind {
        guard kind == .categorical, !sampleValues.isEmpty else { return kind }
        if sampleValues.allSatisfy({ ValueCoercion.double(from: $0) != nil }) { return .numeric }
        if sampleValues.allSatisfy({ ValueCoercion.date(from: $0) != nil }) { return .temporal }
        return kind
    }

    /// Values a `kind(of:in:)` sniff reads. Enough to tell a text column of
    /// numbers from prose; small enough to run inside every aggregation.
    static let sniffLimit = 200

    /// The kind a column is charted as: its declared kind, refined from its
    /// first non-null values when the type is text. Booleans stay categorical.
    /// The aggregator, the bin resolver and the profiler all ask this, so a
    /// text column of dates gets a time axis everywhere or nowhere.
    static func kind(of index: Int, in result: QueryResult) -> ColumnKind {
        guard index < result.columns.count else { return .categorical }
        let declared = kind(forDataType: result.columns[index].dataType)
        guard declared == .categorical, !result.columns[index].dataType.lowercased().hasPrefix("bool") else { return declared }
        var samples: [String] = []
        for row in result.rows where index < row.count {
            let cell = row[index]
            guard !cell.isNull else { continue }
            let text = cell.displayString
            guard !text.isEmpty else { continue }
            samples.append(text)
            if samples.count >= sniffLimit { break }
        }
        return refine(kind: declared, sampleValues: samples)
    }
}
