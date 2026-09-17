import Foundation

/// What a result column looks like, from its type and a sample of its values.
///
/// The recommender and the model prompt both work from this and never from
/// the rows: every field is a count, a share, a flag or a span. No cell value
/// survives into a profile, which is what lets the prompt be built without a
/// `RowDataConsent` sheet.
struct ColumnProfile: Equatable {
    let index: Int
    let name: String
    let dataType: String
    /// The kind PostgreSQL's type says.
    let declaredKind: ColumnKind
    /// The kind after sniffing the sample: a text column whose every non-null
    /// value parses as a number is numeric, as a date is temporal.
    let kind: ColumnKind
    /// Rows looked at (the sample, not the whole result).
    let sampledRows: Int
    let nonNullCount: Int
    let distinctCount: Int
    /// A PostgreSQL boolean.
    let isBoolean: Bool
    /// Numeric only: no sampled value is below zero. False for other kinds.
    let allNonNegative: Bool
    /// Numeric only: every sampled value is a whole number. False otherwise.
    let allIntegers: Bool
    /// Temporal only: seconds between the earliest and latest sampled value.
    let spanSeconds: Double?

    var nullShare: Double { sampledRows == 0 ? 0 : Double(sampledRows - nonNullCount) / Double(sampledRows) }

    /// Every non-null sampled value is different: a key, not a category.
    var isUnique: Bool { nonNullCount > 1 && distinctCount == nonNullCount }

    /// The column names a row, not a quantity — `id`, `order_id`, a uuid.
    /// Such a column is never a measure and is a poor dimension.
    var looksLikeIdentifier: Bool {
        if dataType.lowercased().hasPrefix("uuid") { return true }
        let lower = name.lowercased()
        if ["id", "uuid", "guid", "oid", "pk", "key", "rowid"].contains(lower) { return true }
        for suffix in ["_id", "_uuid", "_guid", "_key", "_pk", "_no", "_number", "_code"] where lower.hasSuffix(suffix) { return true }
        for suffix in ["Id", "ID", "Uuid", "UUID", "Key"] where name.hasSuffix(suffix) && name.count > suffix.count { return true }
        return false
    }

    /// A quantity worth summing or averaging: numeric, not a key, not a flag.
    var isMeasure: Bool { kind == .numeric && !looksLikeIdentifier && !isBoolean }

    /// Something to group by: any non-numeric column, a flag, or a numeric
    /// column with few distinct values (a year, a rating, a size).
    var isDimension: Bool {
        if isBoolean || kind != .numeric { return true }
        return !looksLikeIdentifier && distinctCount <= ColumnProfiler.discreteNumericThreshold
    }
}

enum ColumnProfiler {

    /// Rows a profile reads. Enough to see cardinality and shape; small enough
    /// to run on every rail change without a pause.
    static let sampleLimit = 2000

    /// A numeric column with this many distinct values or fewer reads as a
    /// dimension (matches the aggregator's low-cardinality escape).
    static let discreteNumericThreshold = 12

    static func profile(_ result: QueryResult, sampleLimit: Int = sampleLimit) -> [ColumnProfile] {
        let rows = result.rows.prefix(sampleLimit)
        return result.columns.enumerated().map { index, column in
            profile(column: column, index: index, rows: rows)
        }
    }

    private static func profile(column: ColumnDef, index: Int, rows: ArraySlice<[AnyCodable]>) -> ColumnProfile {
        let declared = ColumnClassifier.kind(forDataType: column.dataType)
        let isBoolean = column.dataType.lowercased().hasPrefix("bool")

        var values: [String] = []
        var distinct = Set<String>()
        for row in rows where index < row.count {
            let cell = row[index]
            if cell.isNull { continue }
            let text = cell.displayString
            if text.isEmpty { continue }
            values.append(text)
            distinct.insert(text)
        }

        // The same sniff the aggregator runs, over the whole sample.
        let kind = isBoolean ? declared : ColumnClassifier.refine(kind: declared, sampleValues: values)

        var allNonNegative = false, allIntegers = false
        var span: Double? = nil
        switch kind {
        case .numeric:
            let numbers = values.compactMap { ValueCoercion.double(from: $0) }
            allNonNegative = !numbers.isEmpty && numbers.allSatisfy { $0 >= 0 }
            allIntegers = !numbers.isEmpty && numbers.allSatisfy { $0 == $0.rounded() }
        case .temporal:
            // PostgreSQL text dates of one column share a format, so the
            // lexical extremes are the temporal extremes: two parses, not n.
            if let lo = values.min(), let hi = values.max(),
               let d0 = ValueCoercion.date(from: lo), let d1 = ValueCoercion.date(from: hi) {
                span = d1.timeIntervalSince(d0)
            }
        case .categorical:
            break
        }

        return ColumnProfile(index: index, name: column.name, dataType: column.dataType,
                             declaredKind: declared, kind: kind,
                             sampledRows: rows.count, nonNullCount: values.count,
                             distinctCount: distinct.count, isBoolean: isBoolean,
                             allNonNegative: allNonNegative, allIntegers: allIntegers,
                             spanSeconds: span)
    }
}
