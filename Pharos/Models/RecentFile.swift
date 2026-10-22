import Foundation

/// One entry of the sidebar's Files navigator: a DuckDB database or a data
/// file the user opened, and when they last did. Mirrors the core's
/// `RecentFile` (camelCase keys; `JSONDecoder.pharos` applies no strategy).
struct RecentFile: Codable, Equatable {
    /// "duckdb" or "data". Opaque to the core.
    enum Kind: String {
        case duckdb, data
    }

    var path: String
    var kind: String
    /// ISO 8601 UTC ("2026-10-22T16:02:00Z").
    var lastOpenedAt: String

    var url: URL { URL(fileURLWithPath: path) }
    var lastOpened: Date? { Self.formatter.date(from: lastOpenedAt) }

    static let formatter = ISO8601DateFormatter()

    static func stamp(_ date: Date) -> String { formatter.string(from: date) }
}
