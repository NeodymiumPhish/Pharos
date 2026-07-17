import Foundation

/// Coerces PostgreSQL text-format values (which cross the FFI as JSON strings,
/// decoded into AnyCodable as String) into typed values for charting.
enum ValueCoercion {
    private static let dateFormatters: [DateFormatter] = {
        let patterns = [
            "yyyy-MM-dd HH:mm:ssZ",
            "yyyy-MM-dd HH:mm:ss",
            "yyyy-MM-dd'T'HH:mm:ssZ",
            "yyyy-MM-dd'T'HH:mm:ss",
            "yyyy-MM-dd",
        ]
        return patterns.map { p in
            let f = DateFormatter()
            f.locale = Locale(identifier: "en_US_POSIX")
            f.timeZone = TimeZone(identifier: "UTC")
            f.dateFormat = p
            return f
        }
    }()

    static func double(from s: String) -> Double? {
        let trimmed = s.trimmingCharacters(in: .whitespaces)
        if trimmed.isEmpty { return nil }
        return Double(trimmed)
    }

    static func double(from v: AnyCodable) -> Double? {
        switch v.value {
        case nil: return nil
        case let d as Double: return d
        case let i as Int64: return Double(i)
        case let s as String: return double(from: s)
        default: return nil
        }
    }

    static func bool(from s: String) -> Bool? {
        switch s.trimmingCharacters(in: .whitespaces).lowercased() {
        case "t", "true": return true
        case "f", "false": return false
        default: return nil
        }
    }

    static func date(from s: String) -> Date? {
        var trimmed = s.trimmingCharacters(in: .whitespaces)
        if trimmed.isEmpty { return nil }
        // Strip fractional seconds — PostgreSQL emits them by default for
        // timestamp/timestamptz (e.g. ":00.123456"). Sub-second precision is
        // irrelevant for binning/gantt, and stripping handles any digit count
        // (DateFormatter's fixed .SSSSSS would be brittle across 1–6 digits).
        if let r = trimmed.range(of: #"(?<=:\d{2})\.\d+"#, options: .regularExpression) {
            trimmed.removeSubrange(r)
        }
        for f in dateFormatters {
            if let d = f.date(from: trimmed) { return d }
        }
        // PG uses "+00" (2-digit) offsets; normalize to "+0000" and retry.
        if trimmed.range(of: #"[+-]\d{2}$"#, options: .regularExpression) != nil {
            let normalized = trimmed + "00"
            for f in dateFormatters {
                if let d = f.date(from: normalized) { return d }
            }
        }
        return nil
    }
}
