import Foundation

/// Coerces PostgreSQL text-format values (which cross the FFI as JSON strings,
/// held as text in a `ResultTable`) into typed values for charting.
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

    /// A cell's text, nil for a SQL NULL (which is no number).
    static func double(from s: String?) -> Double? {
        s.flatMap { double(from: $0) }
    }

    static func bool(from s: String) -> Bool? {
        switch s.trimmingCharacters(in: .whitespaces).lowercased() {
        case "t", "true": return true
        case "f", "false": return false
        default: return nil
        }
    }

    static func date(from s: String) -> Date? {
        // PostgreSQL's (and DuckDB's) text form of a date or timestamp is one
        // fixed ISO shape; read it with integer arithmetic. A chart reads one
        // date per row and column, and DateFormatter took ~10 ICU parses per
        // cell: 60,000 rows held the main thread for minutes (measured).
        if let fast = isoTimestamp(s) { return Date(timeIntervalSince1970: fast) }
        return formatterDate(from: s)
    }

    /// `YYYY-MM-DD`, optionally followed by ` HH:MM:SS` or `THH:MM:SS`, an
    /// optional fraction (ignored: the formatter path drops it too) and an
    /// optional zone `Z`, `±HH`, `±HHMM` or `±HH:MM`. Seconds since 1970 in
    /// UTC (a time with no zone is UTC, as the formatters read it), or nil for
    /// any other text, which the formatters then try.
    static func isoTimestamp(_ s: String) -> TimeInterval? {
        var text = s
        return text.withUTF8 { b -> TimeInterval? in
            var i = 0, end = b.count
            while i < end, b[i] == 0x20 { i += 1 }          // spaces, as `.whitespaces` trims
            while end > i, b[end - 1] == 0x20 { end -= 1 }
            func digits(_ n: Int) -> Int? {
                guard i + n <= end else { return nil }
                var v = 0
                for k in i..<(i + n) {
                    let d = Int(b[k]) - 0x30
                    guard d >= 0 && d <= 9 else { return nil }
                    v = v * 10 + d
                }
                i += n
                return v
            }
            func expect(_ c: UInt8) -> Bool {
                guard i < end, b[i] == c else { return false }
                i += 1
                return true
            }
            // From 1583 only: before the Gregorian reform DateFormatter
            // counts Julian dates, and the old answer stands for those.
            guard let y = digits(4), y >= 1583, expect(0x2D), let mo = digits(2), expect(0x2D), let d = digits(2),
                  (1...12).contains(mo), d >= 1, d <= daysIn(month: mo, year: y) else { return nil }
            var seconds = 0
            if i < end {
                guard b[i] == 0x20 || b[i] == 0x54 else { return nil }   // ' ' or 'T'
                i += 1
                guard let h = digits(2), expect(0x3A), let mi = digits(2), expect(0x3A), let sec = digits(2),
                      h <= 23, mi <= 59, sec <= 59 else { return nil }
                seconds = h * 3600 + mi * 60 + sec
                if i < end, b[i] == 0x2E {                                  // '.' fraction
                    i += 1
                    let start = i
                    while i < end, b[i] >= 0x30, b[i] <= 0x39 { i += 1 }
                    guard i > start else { return nil }
                }
                if i < end {
                    if b[i] == 0x5A { i += 1 }                              // 'Z'
                    else if b[i] == 0x2B || b[i] == 0x2D {                  // '+' or '-'
                        let sign = b[i] == 0x2B ? 1 : -1
                        i += 1
                        guard let oh = digits(2), oh <= 15 else { return nil }
                        var om = 0
                        if i < end {
                            _ = expect(0x3A)
                            guard let m = digits(2), m <= 59 else { return nil }
                            om = m
                        }
                        seconds -= sign * (oh * 3600 + om * 60)
                    } else { return nil }
                }
            }
            guard i == end else { return nil }
            return TimeInterval(daysFromCivil(year: y, month: mo, day: d) * 86_400 + seconds)
        }
    }

    private static func daysIn(month: Int, year: Int) -> Int {
        switch month {
        case 2: return (year % 4 == 0 && year % 100 != 0) || year % 400 == 0 ? 29 : 28
        case 4, 6, 9, 11: return 30
        default: return 31
        }
    }

    /// Days from 1970-01-01 to a proleptic Gregorian date (H. Hinnant's
    /// `days_from_civil`).
    private static func daysFromCivil(year: Int, month: Int, day: Int) -> Int {
        let y = month <= 2 ? year - 1 : year
        let era = (y >= 0 ? y : y - 399) / 400
        let yoe = y - era * 400
        let doy = (153 * (month + (month > 2 ? -3 : 9)) + 2) / 5 + day - 1
        let doe = yoe * 365 + yoe / 4 - yoe / 100 + doy
        return era * 146_097 + doe - 719_468
    }

    /// The formatter path, for text that is not the fixed ISO shape.
    static func formatterDate(from s: String) -> Date? {
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
