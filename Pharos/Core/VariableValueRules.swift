import Foundation

/// The single source of truth for what a variable's value may hold and the SQL
/// it renders to, for every `VariableType`. Pure logic, Foundation only — used by
/// `VariableSubstitutor` (render and problems) and by the Variable Manager's
/// editors (live checks, date pickers, type switches). Tested standalone by
/// `scripts/test-variable-value-rules.sh`.
///
/// Stored forms (one string per variable, as for every type):
/// - Date: `YYYY-MM-DD`, or `today`.
/// - Timestamp: `YYYY-MM-DD HH:MM:SS` (a `T` separator and fractional seconds are
///   accepted too), or `now`.
/// - Timestamp with time zone: `YYYY-MM-DD HH:MM:SS <IANA zone id>`, or `now`.
/// - Lists: one item per line; blank lines are ignored and each item's leading
///   and trailing spaces are dropped.
///
/// Relative values render as SQL keywords, so the database evaluates them in the
/// session time zone when the query runs.
enum VariableValueRules {

    typealias ValueProblem = VariableSubstitutor.ValueProblem

    /// What a value renders to: SQL text, or the reason it cannot. `reason` is
    /// the text `ValueProblem.invalidValue(reason:)` carries, so it is written to
    /// follow "the value is …".
    enum Rendering: Equatable {
        case sql(String)
        case invalid(reason: String)

        var sql: String? {
            if case .sql(let text) = self { return text }
            return nil
        }

        var reason: String? {
            if case .invalid(let reason) = self { return reason }
            return nil
        }
    }

    // MARK: - Render and validate

    static func render(_ value: String, as type: VariableType) -> Rendering {
        switch type {
        case .literal:
            return .sql(value)
        case .text:
            return .sql(quoted(value))
        case .number:
            // Newlines too, not just spaces: a value pasted from a spreadsheet or
            // a terminal arrives with a trailing line break, and the regex anchors
            // to the hard end of input, so an untrimmed one would be rejected
            // outright rather than silently rendered into the SQL.
            let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
            if isValidNumber(trimmed) { return .sql(trimmed) }
            return .invalid(reason: "not a valid number: \(value.debugDescription)")
        case .bool:
            // Three values, not two: NULL is a Bool value rather than a variable
            // type of its own. Rendered uppercase because it is a SQL keyword, not
            // a boolean literal — `true`/`false` stay lowercase.
            if let choice = boolChoice(for: value) { return .sql(choice.rawValue) }
            return .invalid(reason: "not a valid boolean: \(value.debugDescription)")
        case .date:
            return renderDate(value)
        case .timestamp:
            return renderTimestamp(value)
        case .timestamptz:
            return renderTimestampWithZone(value)
        case .textList:
            let items = listItems(in: value)
            if items.isEmpty { return .invalid(reason: emptyListReason) }
            return .sql("(" + items.map { quoted($0.text) }.joined(separator: ", ") + ")")
        case .numberList:
            let items = listItems(in: value)
            if items.isEmpty { return .invalid(reason: emptyListReason) }
            if let bad = items.first(where: { !isValidNumber($0.text) }) {
                return .invalid(reason: "not a valid number list: line \(bad.line) is \(bad.text.debugDescription)")
            }
            return .sql("(" + items.map(\.text).joined(separator: ", ") + ")")
        }
    }

    /// Why `value` cannot become working SQL as `type`, or `nil` when it can.
    /// A `Literal` is a raw-SQL escape hatch: only an empty one is known to be
    /// broken. A `Text` value always renders (`''` is a legal empty string).
    static func validate(_ value: String, as type: VariableType) -> ValueProblem? {
        switch type {
        case .literal:
            return value.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? .emptyLiteral : nil
        case .text:
            return nil
        default:
            if case .invalid(let reason) = render(value, as: type) { return .invalidValue(reason: reason) }
            return nil
        }
    }

    // MARK: - Number and Bool

    /// SQL numeric literal: optional sign, integer/decimal (no exponent).
    ///
    /// `[0-9]` rather than `\d`: ICU's `\d` matches all of Unicode category Nd, so
    /// `٤٤٣`, `１２３` and `१२३` used to validate, render bare into the SQL, and be
    /// lexed by Postgres as identifiers — the user saw `column "٤٤٣" does not
    /// exist` instead of "not a valid number".
    ///
    /// `\A`/`\z` rather than `^`/`$`: ICU's `$` also matches before a single
    /// trailing line terminator, so `"443\n"` validated and then rendered with the
    /// newline still attached. `\z` is the hard end of input a reader expects here.
    private static let numberRegex = try! NSRegularExpression(
        pattern: #"\A[+-]?([0-9]+(\.[0-9]+)?|\.[0-9]+)\z"#
    )

    /// True if `text`, exactly as given (no trimming), is a SQL numeric literal.
    static func isValidNumber(_ text: String) -> Bool {
        numberRegex.firstMatch(in: text, range: NSRange(location: 0, length: (text as NSString).length)) != nil
    }

    private static let trueSet: Set<String> = ["true", "t", "1", "yes", "y"]
    private static let falseSet: Set<String> = ["false", "f", "0", "no", "n"]
    /// `Bool`'s third value. Only the one spelling — unlike true/false, nothing
    /// hand-types this: the detail level offers it as a choice.
    private static let nullSet: Set<String> = ["null"]

    /// Which of `Bool`'s three values `value` means, or `nil` for none of them.
    /// Trims spaces only: a Bool carrying a newline is rejected, not coerced.
    static func boolChoice(for value: String) -> VariableSubstitutor.BoolChoice? {
        let key = value.trimmingCharacters(in: .whitespaces).lowercased()
        if trueSet.contains(key) { return .isTrue }
        if falseSet.contains(key) { return .isFalse }
        if nullSet.contains(key) { return .isNull }
        return nil
    }

    // MARK: - Relative values

    static let todayKeyword = "today"
    static let nowKeyword = "now"

    /// The keyword a type stores for its relative value: `today` for Date, `now`
    /// for both Timestamps, `nil` for every other type.
    static func relativeKeyword(for type: VariableType) -> String? {
        switch type {
        case .date: return todayKeyword
        case .timestamp, .timestamptz: return nowKeyword
        default: return nil
        }
    }

    /// True if `value` is `type`'s relative keyword (trimmed, any case).
    static func isRelative(_ value: String, as type: VariableType) -> Bool {
        guard let keyword = relativeKeyword(for: type) else { return false }
        return value.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() == keyword
    }

    // MARK: - Date and timestamp

    /// A fixed date or date-time as the user means it, with the zone it is
    /// expressed in. For Date and Timestamp the zone is always UTC: they have no
    /// zone, so a picker bound with `timeZone = UTC` shows exactly the stored
    /// fields and never meets a daylight-saving gap.
    struct DateTimeValue: Equatable {
        var date: Date
        var timeZone: TimeZone
        /// The zone id as stored (`"UTC"` for Date and Timestamp). Foundation
        /// normalises some ids (`TimeZone(identifier: "UTC")` reports `"GMT"`), so
        /// pass this back to `format` to keep the stored spelling.
        var zoneIdentifier: String
    }

    /// The fixed value a Date, Timestamp or Timestamp-with-zone variable holds,
    /// for binding to a date picker. `nil` for a relative or invalid value, and
    /// for every other type.
    static func dateTime(from value: String, as type: VariableType) -> DateTimeValue? {
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        switch type {
        case .date:
            guard case .valid(let local) = parseDate(trimmed) else { return nil }
            return DateTimeValue(date: Date(timeIntervalSince1970: TimeInterval(local.civilSeconds)),
                                 timeZone: utc, zoneIdentifier: "UTC")
        case .timestamp:
            guard case .valid(let local) = parseTimestamp(trimmed) else { return nil }
            return DateTimeValue(date: Date(timeIntervalSince1970: local.civilInterval),
                                 timeZone: utc, zoneIdentifier: "UTC")
        case .timestamptz:
            guard case .valid(let local, let zone, let id) = parseTimestampWithZone(trimmed),
                  let offset = resolveOffset(local.civilSeconds, in: zone) else { return nil }
            return DateTimeValue(
                date: Date(timeIntervalSince1970: local.civilInterval - TimeInterval(offset)),
                timeZone: zone, zoneIdentifier: id)
        default:
            return nil
        }
    }

    /// The stored string for `date` seen in `timeZone`: `YYYY-MM-DD` for Date,
    /// `YYYY-MM-DD HH:MM:SS` for Timestamp, and that plus ` <zone id>` for
    /// Timestamp with time zone, where the zone is written as `zoneIdentifier`
    /// (default `timeZone.identifier`). Fractional seconds are dropped. Any other
    /// type gets the Timestamp form.
    static func format(
        _ date: Date,
        timeZone: TimeZone,
        zoneIdentifier: String? = nil,
        as type: VariableType
    ) -> String {
        let local = LocalDateTime(date: date, in: timeZone)
        switch type {
        case .date: return local.dateText
        case .timestamptz: return local.dateText + " " + local.timeText + " " + (zoneIdentifier ?? timeZone.identifier)
        default: return local.dateText + " " + local.timeText
        }
    }

    // MARK: - Lists

    /// One non-blank line of a List value. `line` is 1-based and counts blank
    /// lines, so it names the line the user sees in the editor.
    struct ListItem: Equatable {
        let line: Int
        let text: String
    }

    /// The items of a List value: one per line (LF, CRLF, CR and the other line
    /// breaks), spaces and tabs trimmed, blank lines skipped.
    static func listItems(in value: String) -> [ListItem] {
        let lines = value.replacingOccurrences(of: "\r\n", with: "\n").components(separatedBy: .newlines)
        var items: [ListItem] = []
        for (index, line) in lines.enumerated() {
            let text = line.trimmingCharacters(in: .whitespaces)
            if !text.isEmpty { items.append(ListItem(line: index + 1, text: text)) }
        }
        return items
    }

    /// The items of a List value that are not valid numbers, for a caption such
    /// as "1 not a number (line 4)".
    static func invalidNumberItems(in value: String) -> [ListItem] {
        listItems(in: value).filter { !isValidNumber($0.text) }
    }

    // MARK: - Type switch

    /// The value to keep when a variable's type changes from `from` to `to`.
    ///
    /// - To Literal, Text or Bool: the value unchanged (a List is already one
    ///   item per line).
    /// - To Number: the value trimmed (an invalid one stays, and is flagged).
    /// - To a List: from another List unchanged, else split by `ListPasteParser`.
    /// - To Date / Timestamp / Timestamp with zone: a relative keyword (`today`
    ///   or `now`, either one) maps to the target's keyword. Otherwise the value
    ///   is parsed (the stored forms, `yyyy/MM/dd`, ISO 8601 with `T`, `Z` or a
    ///   numeric offset); an instant is seen in `timeZone`. A value that does not
    ///   parse becomes `now` as a FIXED value in `timeZone`. Date → Timestamp adds
    ///   `00:00:00`; Timestamp → Date drops the time; a zone is added (`timeZone`)
    ///   or dropped.
    static func convert(
        _ value: String,
        from: VariableType,
        to: VariableType,
        now: Date = Date(),
        timeZone: TimeZone = .current
    ) -> String {
        if from == to { return value }
        switch to {
        case .literal, .text, .bool:
            return value
        case .number:
            return value.trimmingCharacters(in: .whitespacesAndNewlines)
        case .textList, .numberList:
            if from.isList { return value }
            return ListPasteParser.joined(ListPasteParser.items(from: value))
        case .date, .timestamp, .timestamptz:
            return convertToDateTime(value, to: to, now: now, timeZone: timeZone)
        }
    }

    // MARK: - Private: rendering helpers

    private static let utc = TimeZone(identifier: "UTC")!
    private static let emptyListReason = "an empty list"

    private static func quoted(_ text: String) -> String {
        "'" + text.replacingOccurrences(of: "'", with: "''") + "'"
    }

    private static func renderDate(_ value: String) -> Rendering {
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed.lowercased() == todayKeyword { return .sql("CURRENT_DATE") }
        switch parseDate(trimmed) {
        case .valid(let local): return .sql("DATE '\(local.dateText)'")
        case .notACalendarValue: return .invalid(reason: "not a real calendar date: \(value.debugDescription)")
        case .malformed:
            return .invalid(reason: "not a valid date: \(value.debugDescription) (use YYYY-MM-DD or today)")
        }
    }

    private static func renderTimestamp(_ value: String) -> Rendering {
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed.lowercased() == nowKeyword { return .sql("LOCALTIMESTAMP") }
        switch parseTimestamp(trimmed) {
        case .valid(let local): return .sql("TIMESTAMP '\(local.dateText) \(local.timeText)'")
        case .notACalendarValue:
            return .invalid(reason: "not a real date and time: \(value.debugDescription)")
        case .malformed:
            return .invalid(reason:
                "not a valid timestamp: \(value.debugDescription) (use YYYY-MM-DD HH:MM:SS or now)")
        }
    }

    private static func renderTimestampWithZone(_ value: String) -> Rendering {
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed.lowercased() == nowKeyword { return .sql("CURRENT_TIMESTAMP") }
        switch parseTimestampWithZone(trimmed) {
        case .valid(let local, let zone, _):
            guard let offset = resolveOffset(local.civilSeconds, in: zone) else {
                return .invalid(reason:
                    "a time that does not exist in \(zone.identifier) (the clocks skip it): \(value.debugDescription)")
            }
            return .sql("TIMESTAMPTZ '\(local.dateText) \(local.timeText)\(offsetText(offset))'")
        case .missingZone:
            return .invalid(reason:
                "missing a time zone: \(value.debugDescription) (add one such as UTC or America/New_York)")
        case .unknownZone(let id):
            return .invalid(reason: "using an unknown time zone: \(id.debugDescription)")
        case .notACalendarValue:
            return .invalid(reason: "not a real date and time: \(value.debugDescription)")
        case .malformed:
            return .invalid(reason: "not a valid timestamp with time zone: \(value.debugDescription) "
                + "(use YYYY-MM-DD HH:MM:SS Zone/Name or now)")
        }
    }

    /// `±HH:MM`, or `±HH:MM:SS` for the rare historical offset with seconds.
    private static func offsetText(_ seconds: Int) -> String {
        let sign = seconds < 0 ? "-" : "+"
        let magnitude = abs(seconds)
        var text = sign + String(format: "%02d:%02d", magnitude / 3600, (magnitude % 3600) / 60)
        if magnitude % 60 != 0 { text += String(format: ":%02d", magnitude % 60) }
        return text
    }

    /// The UTC offset `zone` has at the wall-clock time `civilSeconds` (seconds
    /// since 1970 as if the wall clock were UTC). `nil` when that wall-clock time
    /// does not exist (a spring-forward gap). When it exists twice (a fall-back
    /// overlap), the EARLIER moment wins — the larger offset.
    private static func resolveOffset(_ civilSeconds: Int64, in zone: TimeZone) -> Int? {
        func offset(at instant: Int64) -> Int {
            zone.secondsFromGMT(for: Date(timeIntervalSince1970: TimeInterval(instant)))
        }
        // Every offset the zone has within 36 hours of the wall-clock time; a
        // valid one is an offset `o` the zone really has at `civil - o`.
        let window: Int64 = 36 * 3600
        let candidates = Set([offset(at: civilSeconds - window), offset(at: civilSeconds), offset(at: civilSeconds + window)])
        let valid = candidates.filter { offset(at: civilSeconds - Int64($0)) == $0 }
        return valid.max()
    }

    // MARK: - Private: parsing

    /// A wall-clock date and time with no zone. `fraction` is "" or the typed
    /// fractional seconds with their dot (".5"), kept verbatim in rendering.
    private struct LocalDateTime {
        var year: Int, month: Int, day: Int
        var hour = 0, minute = 0, second = 0
        var fraction = ""

        var dateText: String { String(format: "%04d-%02d-%02d", year, month, day) }
        var timeText: String { String(format: "%02d:%02d:%02d", hour, minute, second) + fraction }

        /// True for a real proleptic-Gregorian date (year 1 or later — PostgreSQL
        /// has no year 0) and a time of 00:00:00 … 23:59:59.
        var isReal: Bool {
            guard year >= 1, (1...12).contains(month), day >= 1,
                  day <= LocalDateTime.daysInMonth(year: year, month: month) else { return false }
            return (0...23).contains(hour) && (0...59).contains(minute) && (0...59).contains(second)
        }

        /// Seconds since 1970-01-01 00:00:00 as if this wall-clock time were UTC.
        var civilSeconds: Int64 {
            Int64(LocalDateTime.days(year: year, month: month, day: day)) * 86_400
                + Int64(hour * 3600 + minute * 60 + second)
        }

        var civilInterval: TimeInterval {
            TimeInterval(civilSeconds) + (Double("0" + fraction) ?? 0)
        }

        init(year: Int, month: Int, day: Int, hour: Int = 0, minute: Int = 0, second: Int = 0, fraction: String = "") {
            self.year = year; self.month = month; self.day = day
            self.hour = hour; self.minute = minute; self.second = second
            self.fraction = fraction
        }

        /// The wall-clock time of `date` in `zone`, whole seconds.
        init(date: Date, in zone: TimeZone) {
            let instant = Int64(floor(date.timeIntervalSince1970))
            let local = instant + Int64(zone.secondsFromGMT(for: date))
            let days = local >= 0 ? local / 86_400 : (local - 86_399) / 86_400
            let secondsOfDay = Int(local - days * 86_400)
            let civil = LocalDateTime.civil(days: Int(days))
            self.init(year: civil.year, month: civil.month, day: civil.day,
                      hour: secondsOfDay / 3600, minute: (secondsOfDay % 3600) / 60, second: secondsOfDay % 60)
        }

        static func daysInMonth(year: Int, month: Int) -> Int {
            switch month {
            case 2: return (year % 4 == 0 && year % 100 != 0) || year % 400 == 0 ? 29 : 28
            case 4, 6, 9, 11: return 30
            default: return 31
            }
        }

        /// Days since 1970-01-01 (proleptic Gregorian; H. Hinnant's algorithm).
        static func days(year: Int, month: Int, day: Int) -> Int {
            let y = month <= 2 ? year - 1 : year
            let era = (y >= 0 ? y : y - 399) / 400
            let yearOfEra = y - era * 400
            let dayOfYear = (153 * (month > 2 ? month - 3 : month + 9) + 2) / 5 + day - 1
            let dayOfEra = yearOfEra * 365 + yearOfEra / 4 - yearOfEra / 100 + dayOfYear
            return era * 146_097 + dayOfEra - 719_468
        }

        static func civil(days: Int) -> (year: Int, month: Int, day: Int) {
            let z = days + 719_468
            let era = (z >= 0 ? z : z - 146_096) / 146_097
            let dayOfEra = z - era * 146_097
            let yearOfEra = (dayOfEra - dayOfEra / 1460 + dayOfEra / 36_524 - dayOfEra / 146_096) / 365
            let dayOfYear = dayOfEra - (365 * yearOfEra + yearOfEra / 4 - yearOfEra / 100)
            let mp = (5 * dayOfYear + 2) / 153
            let day = dayOfYear - (153 * mp + 2) / 5 + 1
            let month = mp < 10 ? mp + 3 : mp - 9
            return (yearOfEra + era * 400 + (month <= 2 ? 1 : 0), month, day)
        }
    }

    private enum LocalParse {
        case valid(LocalDateTime)
        case notACalendarValue
        case malformed
    }

    private enum ZonedParse {
        /// The zone, and its id as typed.
        case valid(LocalDateTime, TimeZone, String)
        case missingZone
        case unknownZone(String)
        case notACalendarValue
        case malformed
    }

    private static let dateRegex = try! NSRegularExpression(
        pattern: #"\A([0-9]{4})-([0-9]{2})-([0-9]{2})\z"#)
    private static let timestampRegex = try! NSRegularExpression(
        pattern: #"\A([0-9]{4})-([0-9]{2})-([0-9]{2})[ T]([0-9]{2}):([0-9]{2}):([0-9]{2})(\.[0-9]+)?\z"#)
    private static let timestampWithZoneRegex = try! NSRegularExpression(
        pattern: #"\A([0-9]{4})-([0-9]{2})-([0-9]{2})[ T]([0-9]{2}):([0-9]{2}):([0-9]{2})(\.[0-9]+)?(?:[ \t]+([^\s]+))?\z"#)
    /// The forms a type switch accepts: `-` or `/` date separators, one- or
    /// two-digit month/day, optional time (seconds optional), then an optional
    /// `Z`, numeric offset, or space + zone id.
    private static let lenientRegex = try! NSRegularExpression(
        pattern: #"\A([0-9]{4})[-/]([0-9]{1,2})[-/]([0-9]{1,2})"#
            + #"(?:[ T]([0-9]{1,2}):([0-9]{2})(?::([0-9]{2})(\.[0-9]+)?)?)?"#
            + #"(?:[ ]?(Z|[+-][0-9]{2}(?::?[0-9]{2})?)|[ \t]+([^\s]+))?\z"#)

    /// Capture groups of a whole-string match; `nil` for an absent group.
    private static func groups(_ regex: NSRegularExpression, _ text: String) -> [String?]? {
        let ns = text as NSString
        guard let match = regex.firstMatch(in: text, range: NSRange(location: 0, length: ns.length)) else { return nil }
        return (0..<match.numberOfRanges).map { index in
            let range = match.range(at: index)
            return range.location == NSNotFound ? nil : ns.substring(with: range)
        }
    }

    private static func local(from g: [String?], timeGroupsStartAt start: Int?) -> LocalDateTime {
        func int(_ index: Int) -> Int { g[index].flatMap { Int($0) } ?? 0 }
        var local = LocalDateTime(year: int(1), month: int(2), day: int(3))
        if let start {
            local.hour = int(start); local.minute = int(start + 1); local.second = int(start + 2)
            local.fraction = g[start + 3] ?? ""
        }
        return local
    }

    private static func parseDate(_ text: String) -> LocalParse {
        guard let g = groups(dateRegex, text) else { return .malformed }
        let local = local(from: g, timeGroupsStartAt: nil)
        return local.isReal ? .valid(local) : .notACalendarValue
    }

    private static func parseTimestamp(_ text: String) -> LocalParse {
        guard let g = groups(timestampRegex, text) else { return .malformed }
        let local = local(from: g, timeGroupsStartAt: 4)
        return local.isReal ? .valid(local) : .notACalendarValue
    }

    private static func parseTimestampWithZone(_ text: String) -> ZonedParse {
        guard let g = groups(timestampWithZoneRegex, text) else { return .malformed }
        let local = local(from: g, timeGroupsStartAt: 4)
        guard local.isReal else { return .notACalendarValue }
        guard let id = g[8] else { return .missingZone }
        guard let zone = TimeZone(identifier: id) else { return .unknownZone(id) }
        return .valid(local, zone, id)
    }

    private enum LenientParse {
        /// A wall-clock value, with the zone named after it if any.
        case local(LocalDateTime, TimeZone?)
        /// A moment fixed by `Z` or a numeric offset.
        case instant(Date)
    }

    private static func lenientParse(_ text: String) -> LenientParse? {
        guard let g = groups(lenientRegex, text) else { return nil }
        let local = local(from: g, timeGroupsStartAt: 4)
        guard local.isReal else { return nil }
        if let offset = g[8] {
            var seconds = 0
            if offset != "Z" {
                let digits = offset.dropFirst().replacingOccurrences(of: ":", with: "")
                let hours = Int(digits.prefix(2)) ?? 0
                let minutes = digits.count > 2 ? Int(digits.suffix(2)) ?? 0 : 0
                seconds = (hours * 3600 + minutes * 60) * (offset.hasPrefix("-") ? -1 : 1)
            }
            return .instant(Date(timeIntervalSince1970: local.civilInterval - TimeInterval(seconds)))
        }
        if let id = g[9] {
            guard let zone = TimeZone(identifier: id) else { return nil }
            return .local(local, zone)
        }
        return .local(local, nil)
    }

    private static func convertToDateTime(_ value: String, to: VariableType, now: Date, timeZone: TimeZone) -> String {
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        let lowered = trimmed.lowercased()
        if lowered == todayKeyword || lowered == nowKeyword, let keyword = relativeKeyword(for: to) {
            return keyword
        }
        let local: LocalDateTime
        var zone = timeZone
        switch lenientParse(trimmed) {
        case .local(let parsed, let named)?:
            local = parsed
            if let named { zone = named }
        case .instant(let date)?:
            local = LocalDateTime(date: date, in: timeZone)
        case nil:
            local = LocalDateTime(date: now, in: timeZone)
        }
        switch to {
        case .date: return local.dateText
        case .timestamptz: return local.dateText + " " + local.timeText + " " + zone.identifier
        default: return local.dateText + " " + local.timeText
        }
    }
}

/// Turns pasted text into List items. Used by the List editor's paste and by a
/// type switch to a List.
///
/// Rules, in order:
/// 1. Trim the text. Strip ONE pair of `( )`, `[ ]` or `{ }` that encloses the
///    whole text, so `('a','b')` and `[1, 2, 3]` work.
/// 2. Split on line breaks (LF, CRLF, CR). Blank lines are dropped. With more
///    than one line, each line is one item; when every line but the last ends
///    in the same `,` or `;` (a SQL list pasted one item per line), that one
///    trailing separator is removed from each line.
/// 3. With ONE line, split on tabs; with no tab, on commas; with neither, on
///    semicolons. Only separators OUTSIDE quotes count: `'a,b', 'c'` is two
///    items, `a,b` and `c`.
/// 4. Trim each item and strip one matching pair of `'…'` or `"…"`. Inside, a
///    doubled quote (`''` in SQL style, `""` in CSV style) becomes one. A quote
///    counts as opening only at the start of an item, so `O'Brien` stays as is.
/// 5. Drop blank items. Duplicates stay.
enum ListPasteParser {

    static func items(from text: String) -> [String] {
        let body = stripEnclosingBrackets(text.trimmingCharacters(in: .whitespacesAndNewlines))
        let lines = body.replacingOccurrences(of: "\r\n", with: "\n")
            .replacingOccurrences(of: "\r", with: "\n")
            .components(separatedBy: "\n")
            .filter { !$0.trimmingCharacters(in: .whitespaces).isEmpty }

        var raw: [String]
        if lines.count > 1 {
            raw = stripTrailingSeparator(lines)
        } else if let line = lines.first {
            raw = [line]
            for separator: Character in ["\t", ",", ";"] {
                let parts = split(line, on: separator)
                if parts.count > 1 { raw = parts; break }
            }
        } else {
            raw = []
        }
        return raw.map(unquoted).filter { !$0.isEmpty }
    }

    /// The stored List form: one item per line.
    static func joined(_ items: [String]) -> String {
        items.joined(separator: "\n")
    }

    private static let closer: [Character: Character] = ["(": ")", "[": "]", "{": "}"]

    /// `text` without one bracket pair that encloses it whole (the opener's
    /// matching closer is the last character), trimmed again. Brackets inside
    /// quotes do not count; if the quotes do not balance (an apostrophe such as
    /// `O'Brien`), the brackets are matched without them.
    private static func stripEnclosingBrackets(_ text: String) -> String {
        guard let first = text.first, let close = closer[first], text.count >= 2, text.last == close else {
            return text
        }
        let characters = Array(text)
        let match = matchingCloseIndex(characters, respectingQuotes: true)
            ?? matchingCloseIndex(characters, respectingQuotes: false)
        guard match == characters.count - 1 else { return text }
        return String(characters[1..<(characters.count - 1)]).trimmingCharacters(in: .whitespacesAndNewlines)
    }

    /// The index of the bracket that closes `characters[0]`, or `nil` when it is
    /// never closed (or a quote is left open).
    private static func matchingCloseIndex(_ characters: [Character], respectingQuotes: Bool) -> Int? {
        let open = characters[0]
        guard let close = closer[open] else { return nil }
        var depth = 0
        var quote: Character?
        for (index, character) in characters.enumerated() {
            if let inside = quote {
                if character == inside { quote = nil }
                continue
            }
            if respectingQuotes, character == "'" || character == "\"" { quote = character; continue }
            if character == open { depth += 1 }
            if character == close {
                depth -= 1
                if depth == 0 { return index }
            }
        }
        return nil
    }

    private static func stripTrailingSeparator(_ lines: [String]) -> [String] {
        let trimmed = lines.map { $0.trimmingCharacters(in: .whitespaces) }
        for separator in [",", ";"] where trimmed.dropLast().allSatisfy({ $0.hasSuffix(separator) }) {
            return trimmed.map { $0.hasSuffix(separator) ? String($0.dropLast()) : $0 }
        }
        return lines
    }

    /// `line` split on `separator` where it is not inside a quoted item.
    private static func split(_ line: String, on separator: Character) -> [String] {
        var parts: [String] = []
        var current = ""
        var quote: Character?
        let characters = Array(line)
        var index = 0
        while index < characters.count {
            let character = characters[index]
            if let open = quote {
                current.append(character)
                if character == open {
                    if index + 1 < characters.count, characters[index + 1] == open {
                        current.append(open)
                        index += 1
                    } else {
                        quote = nil
                    }
                }
            } else if character == separator {
                parts.append(current)
                current = ""
            } else {
                if (character == "'" || character == "\"")
                    && current.trimmingCharacters(in: .whitespaces).isEmpty {
                    quote = character
                }
                current.append(character)
            }
            index += 1
        }
        parts.append(current)
        return parts
    }

    private static func unquoted(_ item: String) -> String {
        let trimmed = item.trimmingCharacters(in: .whitespacesAndNewlines)
        guard trimmed.count >= 2, let first = trimmed.first, first == "'" || first == "\"",
              trimmed.last == first else { return trimmed }
        let quote = String(first)
        return String(trimmed.dropFirst().dropLast()).replacingOccurrences(of: quote + quote, with: quote)
    }
}
