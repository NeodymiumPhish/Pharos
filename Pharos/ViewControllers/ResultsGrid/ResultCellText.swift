import Foundation

extension String {
    /// Replaces newlines with a visible ↵ so multi-line data shows as one line in
    /// the results grid. (Moved here from ResultsDataSource so the width measurement
    /// can share it; internal, not private.)
    var flattenedForCell: String {
        guard contains(where: \.isNewline) else { return self }
        return replacingOccurrences(of: "\r\n", with: "↵")
            .replacingOccurrences(of: "\n", with: "↵")
            .replacingOccurrences(of: "\r", with: "↵")
    }
}

/// The exact string a result cell renders for a value — shared by the grid's cell
/// styling (`styleCell`) and the column-width measurement, so what's measured
/// always equals what's drawn.
enum ResultCellText {
    static func rendered(value: AnyCodable, category: PGTypeCategory,
                         boolTrue: String, boolFalse: String, nullString: String) -> String {
        if value.isNull { return nullString }
        let raw = value.displayString
        switch category {
        case .boolean:
            switch raw.lowercased() {
            case "t", "true": return boolTrue
            case "f", "false": return boolFalse
            default: return raw
            }
        case .string, .json, .array:
            return raw.flattenedForCell
        case .numeric, .temporal:
            return raw
        }
    }
}
