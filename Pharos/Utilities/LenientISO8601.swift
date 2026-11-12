import Foundation

/// Reads the ISO 8601 times Pharos stores, with or without fractional
/// seconds. The core writes history times with them (`to_rfc3339`:
/// `2026-11-11T19:07:46.133123+00:00`), which `ISO8601DateFormatter` refuses
/// unless told to expect them; Swift's own writes have none.
enum LenientISO8601 {

    private static let fractional: ISO8601DateFormatter = {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return formatter
    }()

    private static let whole = ISO8601DateFormatter()

    static func date(from text: String) -> Date? {
        fractional.date(from: text) ?? whole.date(from: text)
    }
}
