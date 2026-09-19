import Foundation

/// Re-renders a result cell's TEXT for display.
///
/// # Why this is a parser
///
/// Every value of a real result crosses the FFI as a JSON **string**: the core
/// reads PostgreSQL's text format, so `AnyCodable` lands every cell in its
/// `String` branch (see `Pharos/Models/QueryResult.swift`). There are no
/// `Date`s and no numbers on the Swift side — only text. So "format this
/// timestamp" can only mean: parse the text PostgreSQL sent, and write it out
/// again another way.
///
/// That makes the pass-through rule the whole safety of this feature. **Any
/// shape this file does not fully recognise is returned byte for byte.** A
/// column declared `timestamp` can hold a value this parser has never seen (a
/// `DateStyle` the session changed, an `interval`, a server-side cast), and the
/// only acceptable answer for one of those is the text the server sent.
///
/// # Display only
///
/// Nothing here may touch a value on its way to the pasteboard, to a file, or
/// into a find, filter or sort comparison — the same rule `DisplayEscape` and
/// `ResultCellText` state. Copy, export, find, filter and sort all read
/// `AnyCodable.displayString` straight off the model and never come through
/// here.
///
/// # No `DateFormatter` for PARSING
///
/// `DateFormatter.date(from:)` is locale-sensitive and costs far too much to
/// run per cell on a 10,000-row grid. The parse below walks the UTF-8 bytes and
/// allocates nothing. A cached `DateFormatter` is used only to WRITE the two
/// localised styles, where a locale-correct pattern is the point.
enum ResultValueFormatter {

    // MARK: - Entry point

    /// The display text for one raw cell value.
    ///
    /// Returns `raw` unchanged whenever the style is `asReturned`, the column's
    /// kind is not one this file formats, or the text does not parse.
    static func formatted(_ raw: String,
                          kind: ResultValueKind,
                          dateStyle: ResultDateStyle,
                          numberStyle: ResultNumberStyle) -> String {
        switch kind {
        case .date, .timestamp, .timestampTZ, .time, .timeTZ:
            return temporal(raw, style: dateStyle)
        case .integer, .decimal, .float:
            return number(raw, style: numberStyle)
        case .other:
            return raw
        }
    }

    // MARK: - Temporal

    static func temporal(_ raw: String, style: ResultDateStyle) -> String {
        guard style != .asReturned else { return raw }
        guard let parts = TimestampParts(raw) else { return raw }

        switch style {
        case .asReturned:
            return raw

        case .iso8601T:
            // A textual reshape, so it re-emits the ORIGINAL date and time
            // slices rather than re-printing the parsed integers: the parts
            // this style does not change cannot drift. A value with only a
            // date or only a time has no `T` to insert and comes back
            // unchanged — there is nothing ISO 8601 would do to it here.
            guard let date = parts.dateText, let time = parts.timeText else { return raw }
            var out = date + "T" + time
            if let fraction = parts.fractionText { out += "." + fraction }
            if let offset = parts.offsetSeconds {
                out += offset == 0 ? "Z" : offsetText(offset)
            }
            return out

        case .short, .medium:
            // These need a real `Date`, and two shapes cannot become one
            // without moving the value: hour 24 (PostgreSQL's end-of-day)
            // would roll onto the next day, and a `BC` date is refused by the
            // parser outright. Both come back raw.
            guard parts.hour != 24, let date = parts.date() else { return raw }
            let formatter = FormatterCache.shared.dateFormatter(
                style: style, hasDate: parts.dateText != nil, hasTime: parts.timeText != nil)
            let text = formatter.string(from: date)
            // An empty answer would blank the cell. Nothing is better than the
            // value the server sent.
            return text.isEmpty ? raw : text
        }
    }

    /// `+05:30` / `-08:00` for a non-zero offset. Always the padded `±HH:MM`
    /// form, which is what ISO 8601 asks for.
    private static func offsetText(_ seconds: Int) -> String {
        let sign = seconds < 0 ? "-" : "+"
        let total = abs(seconds) / 60
        return String(format: "%@%02d:%02d", sign, total / 60, total % 60)
    }

    // MARK: - Numeric

    static func number(_ raw: String, style: ResultNumberStyle) -> String {
        guard style == .grouped else { return raw }
        // The validator, not `Decimal(string:)`, decides what is a number.
        // `Decimal(string:)` accepts "NaN" and takes a prefix of "12abc"; a
        // `float8` really can hold `NaN`, `Infinity` and `1e+20`, and none of
        // those means anything grouped.
        guard let scale = decimalScale(raw), let value = Decimal(string: raw) else { return raw }
        let formatter = FormatterCache.shared.numberFormatter()
        // The EXACT scale PostgreSQL sent, both bounds. A `numeric(12,4)`
        // money column sends "1234.5000"; rounding that to two places, or
        // dropping the trailing zeros, is the app rewriting the amount.
        formatter.minimumFractionDigits = scale
        formatter.maximumFractionDigits = scale
        guard let text = formatter.string(from: value as NSDecimalNumber), !text.isEmpty else {
            return raw
        }
        return text
    }

    /// The number of digits after the decimal point, or nil when `raw` is not a
    /// plain decimal literal this file is willing to re-render.
    ///
    /// Accepts: an optional leading `-`, at least one digit, and at most one
    /// `.` followed by at least one digit. Nothing else — no exponent, no
    /// leading `+`, no separators, no spaces.
    ///
    /// Rejects anything with more than `maximumSignificantDigits` digits.
    /// `Decimal` holds 38 of them, and a value that overflows it comes back
    /// silently rounded — which for a display formatter means quietly showing
    /// the wrong number.
    private static func decimalScale(_ raw: String) -> Int? {
        let maximumSignificantDigits = 38
        let bytes = Array(raw.utf8)
        var index = 0
        if index < bytes.count, bytes[index] == UInt8(ascii: "-") { index += 1 }

        var integerDigits = 0
        while index < bytes.count, isDigit(bytes[index]) {
            integerDigits += 1
            index += 1
        }
        guard integerDigits > 0 else { return nil }

        var scale = 0
        if index < bytes.count, bytes[index] == UInt8(ascii: ".") {
            index += 1
            while index < bytes.count, isDigit(bytes[index]) {
                scale += 1
                index += 1
            }
            guard scale > 0 else { return nil }
        }
        guard index == bytes.count else { return nil }
        guard integerDigits + scale <= maximumSignificantDigits else { return nil }
        return scale
    }

    // MARK: - Byte helpers

    private static func isDigit(_ byte: UInt8) -> Bool {
        byte >= UInt8(ascii: "0") && byte <= UInt8(ascii: "9")
    }

    /// A trailing ` BC` or ` AD`, in either case. Checked on the bytes rather
    /// than through `uppercased()`, which would allocate a second string for
    /// every temporal cell on screen.
    private static func hasEraSuffix(_ bytes: [UInt8]) -> Bool {
        guard bytes.count >= 3, bytes[bytes.count - 3] == UInt8(ascii: " ") else { return false }
        let first = bytes[bytes.count - 2] | 0x20
        let second = bytes[bytes.count - 1] | 0x20
        return (first == UInt8(ascii: "b") && second == UInt8(ascii: "c"))
            || (first == UInt8(ascii: "a") && second == UInt8(ascii: "d"))
    }

    // MARK: - The parse

    /// One PostgreSQL ISO timestamp, date or time, split into the pieces a
    /// renderer needs. `init?` is the whole parser; a nil result means "this
    /// text is not a shape we re-render", and the caller passes the raw text
    /// through.
    struct TimestampParts {
        /// `2026-01-31`, exactly as written, or nil for a time-only value.
        let dateText: String?
        /// `14:05:09`, exactly as written, or nil for a date-only value.
        let timeText: String?
        /// The digits after the decimal point, without the dot. nil when the
        /// value carried no fractional seconds.
        let fractionText: String?
        /// Seconds east of UTC, or nil when the text carried no zone at all.
        /// A `timestamp` (no zone) and a `timestamptz` at UTC are different
        /// values and must not both render `Z`.
        let offsetSeconds: Int?

        let year: Int
        let month: Int
        let day: Int
        let hour: Int
        let minute: Int
        let second: Int

        init?(_ raw: String) {
            // Two sentinels and an era suffix that no re-render can improve on.
            //
            // `infinity` / `-infinity` are real `timestamp` values, not text;
            // there is no instant to restyle. A ` BC` date cannot be built as
            // a `Date` without choosing an era convention (is `0001-01-01 BC`
            // year 0 or year -1?), and getting that wrong shows the user a
            // different year than their database holds. All three come back
            // byte for byte.
            if raw.count <= 9 {
                let lowered = raw.lowercased()
                if lowered == "infinity" || lowered == "-infinity" { return nil }
            }
            let bytes = Array(raw.utf8)
            if ResultValueFormatter.hasEraSuffix(bytes) { return nil }
            var index = 0

            var year = 2000, month = 1, day = 1
            var dateSlice: String?

            // A date is 4-to-6 digits, `-`, two digits, `-`, two digits.
            // PostgreSQL's highest year is 294276, so six digits is the cap
            // and a longer digit run is not a year at all.
            let leadingDigits = digitRun(bytes, from: index)
            if leadingDigits.count >= 4, leadingDigits.count <= 6,
               index + leadingDigits.count < bytes.count,
               bytes[index + leadingDigits.count] == UInt8(ascii: "-") {
                year = leadingDigits.value
                index += leadingDigits.count + 1
                guard let m = fixedDigits(bytes, at: index, count: 2) else { return nil }
                month = m
                index += 2
                guard index < bytes.count, bytes[index] == UInt8(ascii: "-") else { return nil }
                index += 1
                guard let d = fixedDigits(bytes, at: index, count: 2) else { return nil }
                day = d
                index += 2
                // Range checks, so `2026-13-45` and `2026-02-30` are refused
                // rather than silently rolled forward by `Calendar`.
                guard year >= 1, month >= 1, month <= 12,
                      day >= 1, day <= Self.daysInMonth(month, year: year) else { return nil }
                dateSlice = String(decoding: bytes[0..<index], as: UTF8.self)

                if index == bytes.count {
                    // A bare date.
                    self.init(dateText: dateSlice, timeText: nil, fractionText: nil,
                              offsetSeconds: nil, year: year, month: month, day: day,
                              hour: 0, minute: 0, second: 0)
                    return
                }
                // PostgreSQL writes a space; ISO 8601 writes `T`. Both are
                // accepted so that re-formatting an already-ISO value is
                // idempotent.
                let separator = bytes[index]
                guard separator == UInt8(ascii: " ") || separator == UInt8(ascii: "T")
                        || separator == UInt8(ascii: "t") else { return nil }
                index += 1
            }

            // From here a time is mandatory: either the value began with one
            // (a `time` column) or the date was followed by a separator.
            let timeStart = index
            guard let h = fixedDigits(bytes, at: index, count: 2) else { return nil }
            index += 2
            guard index < bytes.count, bytes[index] == UInt8(ascii: ":") else { return nil }
            index += 1
            guard let mi = fixedDigits(bytes, at: index, count: 2) else { return nil }
            index += 2
            guard index < bytes.count, bytes[index] == UInt8(ascii: ":") else { return nil }
            index += 1
            guard let s = fixedDigits(bytes, at: index, count: 2) else { return nil }
            index += 2
            // 24:00:00 is PostgreSQL's end-of-day and is accepted, but only in
            // that exact form. Seconds stop at 59: PostgreSQL does not emit a
            // leap second, so a 60 here is some other format wearing this one's
            // shape.
            guard h >= 0, h <= 24, mi >= 0, mi <= 59, s >= 0, s <= 59 else { return nil }
            if h == 24 { guard mi == 0, s == 0 else { return nil } }
            let timeSlice = String(decoding: bytes[timeStart..<index], as: UTF8.self)

            // Optional fractional seconds: a dot and one to six digits.
            var fraction: String?
            if index < bytes.count, bytes[index] == UInt8(ascii: ".") {
                let digits = digitRun(bytes, from: index + 1)
                guard digits.count >= 1, digits.count <= 6 else { return nil }
                fraction = String(decoding: bytes[(index + 1)..<(index + 1 + digits.count)],
                                  as: UTF8.self)
                index += 1 + digits.count
            }

            // Optional zone: `Z`, `±HH` or `±HH:MM`. The `±HH:MM:SS` form some
            // very old zones produce is deliberately NOT accepted — ISO 8601
            // has nowhere to put those seconds, so such a value passes through.
            var offset: Int?
            if index < bytes.count {
                let marker = bytes[index]
                if marker == UInt8(ascii: "Z") || marker == UInt8(ascii: "z") {
                    offset = 0
                    index += 1
                } else if marker == UInt8(ascii: "+") || marker == UInt8(ascii: "-") {
                    let sign = marker == UInt8(ascii: "-") ? -1 : 1
                    index += 1
                    guard let oh = fixedDigits(bytes, at: index, count: 2), oh <= 15 else { return nil }
                    index += 2
                    var om = 0
                    if index < bytes.count, bytes[index] == UInt8(ascii: ":") {
                        guard let value = fixedDigits(bytes, at: index + 1, count: 2), value <= 59
                        else { return nil }
                        om = value
                        index += 3
                    }
                    offset = sign * (oh * 3600 + om * 60)
                } else {
                    return nil
                }
            }

            // Nothing may trail. A value that parsed as far as here and then
            // carries more text is a shape this file does not know.
            guard index == bytes.count else { return nil }

            self.init(dateText: dateSlice, timeText: timeSlice, fractionText: fraction,
                      offsetSeconds: offset, year: year, month: month, day: day,
                      hour: h, minute: mi, second: s)
        }

        private init(dateText: String?, timeText: String?, fractionText: String?,
                     offsetSeconds: Int?, year: Int, month: Int, day: Int,
                     hour: Int, minute: Int, second: Int) {
            self.dateText = dateText
            self.timeText = timeText
            self.fractionText = fractionText
            self.offsetSeconds = offsetSeconds
            self.year = year
            self.month = month
            self.day = day
            self.hour = hour
            self.minute = minute
            self.second = second
        }

        /// The instant to hand a `DateFormatter` pinned to UTC.
        ///
        /// The components are taken AS IF they were UTC and the zone offset is
        /// deliberately NOT applied, so the localised styles print the same
        /// wall clock the server sent rather than moving the value into the
        /// reader's own time zone. `.short` and `.medium` show no zone, so the
        /// offset has nowhere to go; a reader who needs it uses ISO 8601 or
        /// As returned. A date-only value takes midnight, and a time-only one
        /// takes an arbitrary day that the formatter is told not to print.
        func date() -> Date? {
            guard hour < 24 else { return nil }
            let days = Self.daysFromCivil(year: year, month: month, day: day)
            let seconds = Double(days) * 86400 + Double(hour * 3600 + minute * 60 + second)
            return Date(timeIntervalSince1970: seconds)
        }

        /// Days from 1970-01-01, by Howard Hinnant's civil-date algorithm. No
        /// `Calendar`: this runs per cell, and `Calendar` would also happily
        /// roll an out-of-range day forward instead of refusing it.
        static func daysFromCivil(year: Int, month: Int, day: Int) -> Int {
            let y = year - (month <= 2 ? 1 : 0)
            let era = (y >= 0 ? y : y - 399) / 400
            let yoe = y - era * 400
            let doy = (153 * (month + (month > 2 ? -3 : 9)) + 2) / 5 + day - 1
            let doe = yoe * 365 + yoe / 4 - yoe / 100 + doy
            return era * 146097 + doe - 719468
        }

        static func daysInMonth(_ month: Int, year: Int) -> Int {
            switch month {
            case 1, 3, 5, 7, 8, 10, 12: return 31
            case 4, 6, 9, 11: return 30
            case 2: return isLeapYear(year) ? 29 : 28
            default: return 0
            }
        }

        static func isLeapYear(_ year: Int) -> Bool {
            (year % 4 == 0 && year % 100 != 0) || year % 400 == 0
        }
    }

    /// A run of ASCII digits starting at `start`, as a value and a length.
    /// Stops accumulating at seven digits, which is past every year and every
    /// fraction this file accepts, so a hundred-digit string can never
    /// overflow `Int` on the way to being rejected.
    private static func digitRun(_ bytes: [UInt8], from start: Int) -> (value: Int, count: Int) {
        var index = start
        var value = 0
        while index < bytes.count, isDigit(bytes[index]) {
            if index - start < 7 { value = value * 10 + Int(bytes[index] - UInt8(ascii: "0")) }
            index += 1
        }
        return (value, index - start)
    }

    /// Exactly `count` digits at `at`, or nil. The next byte must not be a
    /// digit either, so `2026-011-01` is refused rather than read as month 01.
    private static func fixedDigits(_ bytes: [UInt8], at start: Int, count: Int) -> Int? {
        guard start + count <= bytes.count else { return nil }
        var value = 0
        for index in start..<(start + count) {
            guard isDigit(bytes[index]) else { return nil }
            value = value * 10 + Int(bytes[index] - UInt8(ascii: "0"))
        }
        if start + count < bytes.count, isDigit(bytes[start + count]) { return nil }
        return value
    }

    // MARK: - Formatter cache

    /// The `DateFormatter`s and the one `NumberFormatter`, built once.
    ///
    /// Both types cost milliseconds to create and the render path runs per
    /// visible cell, per realize, per scroll tick — and twice more for the
    /// column-width measurement. The lock is there because the cache is
    /// process-wide; the grid calls in from the main thread only.
    private final class FormatterCache: @unchecked Sendable {
        static let shared = FormatterCache()

        private let lock = NSLock()
        private var dateFormatters: [Int: DateFormatter] = [:]
        private var number: NumberFormatter?

        func dateFormatter(style: ResultDateStyle, hasDate: Bool, hasTime: Bool) -> DateFormatter {
            let key = (style == .medium ? 4 : 0) | (hasDate ? 2 : 0) | (hasTime ? 1 : 0)
            lock.lock()
            defer { lock.unlock() }
            if let existing = dateFormatters[key] { return existing }
            let formatter = DateFormatter()
            let resolved: DateFormatter.Style = style == .medium ? .medium : .short
            formatter.dateStyle = hasDate ? resolved : .none
            formatter.timeStyle = hasTime ? resolved : .none
            // UTC, to match `TimestampParts.date()` taking the components as
            // written: the pair keeps the server's wall clock exactly.
            formatter.timeZone = TimeZone(secondsFromGMT: 0)
            dateFormatters[key] = formatter
            return formatter
        }

        /// Returned MUTABLE on purpose: the caller sets the fraction digits per
        /// value, because the scale belongs to the value and not to the
        /// setting. Single-threaded use by the grid's render path.
        func numberFormatter() -> NumberFormatter {
            lock.lock()
            defer { lock.unlock() }
            if let existing = number { return existing }
            let formatter = NumberFormatter()
            formatter.numberStyle = .decimal
            formatter.usesGroupingSeparator = true
            number = formatter
            return formatter
        }
    }
}

// MARK: - Column kind

/// The finer type `ResultValueFormatter` needs, derived from the column's
/// declared `ColumnDef.dataType`.
///
/// Separate from `PGTypeCategory` because that enum answers a different
/// question — what colour is this cell, which operators does this column
/// offer — and six cases is exactly right for it. Formatting needs to tell a
/// `date` from a `timestamptz` and an `interval` from either, and widening
/// `PGTypeCategory` with associated values would break every `== .numeric`
/// comparison in the grid for no gain. `PGTypeCategory.valueKind(dataType:)`
/// is the bridge.
///
/// `.other` is the safe case, and everything not named below takes it:
/// `interval`, `money`, an array, a domain, an enum, a text column that
/// happens to hold something date-shaped. None of those is ever reformatted.
enum ResultValueKind: Equatable {
    case date
    case timestamp
    case timestampTZ
    case time
    case timeTZ
    case integer
    case decimal
    case float
    case other

    init(dataType: String) {
        let type = dataType.lowercased().trimmingCharacters(in: .whitespaces)
        // An array of timestamps is `{"2026-01-01 00:00:00",...}` — a composite
        // literal, not a timestamp, so it is never reformatted.
        if type.hasSuffix("[]") || type.hasPrefix("_") {
            self = .other
            return
        }
        switch type {
        case "date":
            self = .date
        case "timestamp", "timestamp without time zone":
            self = .timestamp
        case "timestamptz", "timestamp with time zone":
            self = .timestampTZ
        case "time", "time without time zone":
            self = .time
        case "timetz", "time with time zone":
            self = .timeTZ
        case "smallint", "int2", "integer", "int", "int4", "bigint", "int8",
             "serial", "bigserial", "smallserial", "oid":
            self = .integer
        case "numeric", "decimal":
            self = .decimal
        case "real", "float4", "double precision", "float8":
            self = .float
        default:
            // `money` lands here deliberately: PostgreSQL has already grouped
            // it and added a currency symbol under the server's `lc_monetary`,
            // so it is formatted text, not a bare number.
            self = .other
        }
    }
}
