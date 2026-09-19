import Foundation

var failures = 0
func expect(_ c: Bool, _ n: String) { if c { print("PASS \(n)") } else { failures += 1; print("FAIL \(n)") } }

/// `ResultValueFormatter` is a PARSER, so it is tested like one: what shape is
/// accepted, what shape is refused, and — the rule the whole feature rests on —
/// that a refused shape comes back byte for byte.
func runTests() {

    // The locale decides the separators, so nothing below may assume "," and
    // ".". These are read from Foundation the same way the formatter does.
    let probe = NumberFormatter()
    probe.numberStyle = .decimal
    let group = probe.groupingSeparator ?? ","
    let point = probe.decimalSeparator ?? "."

    /// Digits in order, so a grouped number can be checked against its input
    /// without knowing which separator this machine's locale uses.
    func digits(_ text: String) -> String { text.filter(\.isNumber) }

    let everyDateStyle: [ResultDateStyle] = [.asReturned, .iso8601T, .short, .medium]

    func date(_ raw: String, _ style: ResultDateStyle) -> String {
        ResultValueFormatter.temporal(raw, style: style)
    }
    func grouped(_ raw: String) -> String {
        ResultValueFormatter.number(raw, style: .grouped)
    }

    // MARK: - Every accepted shape parses

    // The parse is the gate: if `TimestampParts` refuses a shape, every style
    // passes the raw text through and the setting does nothing for that column.
    let accepted: [(String, String)] = [
        ("2026-01-31", "a bare date"),
        ("2026-01-31 14:05:09", "a timestamp"),
        ("2026-01-31T14:05:09", "a timestamp already written with T"),
        ("2026-01-31 14:05:09.1", "1 fractional digit"),
        ("2026-01-31 14:05:09.12", "2 fractional digits"),
        ("2026-01-31 14:05:09.123", "3 fractional digits"),
        ("2026-01-31 14:05:09.1234", "4 fractional digits"),
        ("2026-01-31 14:05:09.12345", "5 fractional digits"),
        ("2026-01-31 14:05:09.123456", "6 fractional digits"),
        ("2026-01-31 14:05:09+05:30", "a +HH:MM offset"),
        ("2026-01-31 14:05:09-08", "a -HH offset"),
        ("2026-01-31 14:05:09Z", "a Z offset"),
        ("2026-01-31 14:05:09.123456+05:30", "a fraction AND an offset"),
        ("14:05:09", "a bare time"),
        ("14:05:09+05:30", "a time with an offset"),
        ("24:00:00", "PostgreSQL's end-of-day time"),
        ("2026-01-31 24:00:00", "an end-of-day timestamp"),
        ("2024-02-29", "a real leap day"),
        ("2000-02-29", "the 400-year leap day"),
    ]
    for (text, name) in accepted {
        expect(ResultValueFormatter.TimestampParts(text) != nil, "parses: \(name)")
    }

    // MARK: - The parts come out right

    if let p = ResultValueFormatter.TimestampParts("2026-01-31 14:05:09.123456+05:30") {
        expect(p.year == 2026 && p.month == 1 && p.day == 31, "parts: date")
        expect(p.hour == 14 && p.minute == 5 && p.second == 9, "parts: time")
        expect(p.fractionText == "123456", "parts: fraction kept as written")
        expect(p.offsetSeconds == 5 * 3600 + 30 * 60, "parts: +05:30 is 19800 seconds")
    } else {
        expect(false, "parts: the full shape parses at all")
    }
    expect(ResultValueFormatter.TimestampParts("2026-01-31 14:05:09")?.offsetSeconds == nil,
           "parts: no zone is nil, not zero — a timestamp is not a timestamptz at UTC")
    expect(ResultValueFormatter.TimestampParts("2026-01-31 14:05:09Z")?.offsetSeconds == 0,
           "parts: Z is a zero offset, not an absent one")
    expect(ResultValueFormatter.TimestampParts("2026-01-31 14:05:09-08")?.offsetSeconds == -8 * 3600,
           "parts: -08 is negative")

    // MARK: - Every rejected shape passes through BYTE-IDENTICAL
    //
    // This is the rule the feature rests on. A column declared `timestamp` can
    // hold text this parser has never seen, and the only honest answer for one
    // of those is what the server sent.
    let rejected: [(String, String)] = [
        ("", "an empty string"),
        ("-", "a lone minus"),
        ("not a date", "prose"),
        ("2026-13-45", "month 13, day 45"),
        ("2026-02-30", "the 30th of February"),
        ("2025-02-29", "the 29th of a non-leap February"),
        ("1900-02-29", "the 29th of a century non-leap February"),
        ("2026-01-", "a half-typed date"),
        ("12345678901234567890123456789012345678901234567890", "a very long run of digits"),
        ("2026-01-31 14:05:09.1234567", "7 fractional digits — one too many"),
        ("2026-01-31 14:05", "a timestamp with no seconds"),
        ("2026-01-31 14:05:60", "second 60"),
        ("2026-01-31 25:00:00", "hour 25"),
        ("2026-01-31 24:00:01", "24:00:01 — only 24:00:00 exists"),
        ("2026-01-31 14:05:09 trailing", "trailing text"),
        ("2026-01-31 14:05:09+05:30:00", "an offset with seconds"),
        ("1 day 03:00:00", "an interval"),
        ("2026-01-31 14:05:09 Europe/London", "a named zone"),
        ("0000-01-01", "year zero"),
    ]
    for (text, name) in rejected {
        expect(ResultValueFormatter.TimestampParts(text) == nil, "refuses: \(name)")
        for style in everyDateStyle {
            expect(date(text, style) == text,
                   "passes through unchanged (\(style.rawValue)): \(name)")
        }
    }

    // MARK: - infinity, BC, and the end of the day

    for text in ["infinity", "-infinity", "Infinity", "-INFINITY"] {
        expect(ResultValueFormatter.TimestampParts(text) == nil, "refuses the sentinel \(text)")
        for style in everyDateStyle {
            expect(date(text, style) == text, "sentinel \(text) unchanged (\(style.rawValue))")
        }
    }
    for text in ["1000-01-01 BC", "1000-01-01 bc", "4713-01-01 BC", "2026-01-31 14:05:09 BC"] {
        expect(ResultValueFormatter.TimestampParts(text) == nil, "refuses the BC date \(text)")
        for style in everyDateStyle {
            expect(date(text, style) == text, "BC date \(text) unchanged (\(style.rawValue))")
        }
    }
    // 24:00:00 parses, but no style may move it onto the next day.
    expect(date("24:00:00", .iso8601T) == "24:00:00",
           "24:00:00 alone has no date to join, so ISO leaves it")
    expect(date("24:00:00", .short) == "24:00:00", "24:00:00 is never rolled to 00:00 (short)")
    expect(date("24:00:00", .medium) == "24:00:00", "24:00:00 is never rolled to 00:00 (medium)")
    expect(date("2026-01-31 24:00:00", .iso8601T) == "2026-01-31T24:00:00",
           "an end-of-day timestamp keeps hour 24 through ISO")
    expect(date("2026-01-31 24:00:00", .short) == "2026-01-31 24:00:00",
           "an end-of-day timestamp is raw in short — the day must not advance")
    expect(date("2026-01-31 24:00:00", .medium) == "2026-01-31 24:00:00",
           "an end-of-day timestamp is raw in medium — the day must not advance")

    // MARK: - asReturned is byte-identical for EVERY input
    //
    // The default, so this is what protects every existing user.
    let everyInput = accepted.map(\.0) + rejected.map(\.0)
        + ["infinity", "-infinity", "1000-01-01 BC", "24:00:00"]
    var asReturnedHeld = true
    for text in everyInput where date(text, .asReturned) != text { asReturnedHeld = false }
    expect(asReturnedHeld, "asReturned returns every one of \(everyInput.count) inputs byte for byte")

    var asReturnedNumbersHeld = true
    let everyNumber = ["0", "42", "-7", "1234567", "1234.5000", "0.1", "-1234567.89",
                       "123456789012345678901234567890", "NaN", "Infinity", "-Infinity",
                       "1e+20", "1.5e-08", "abc", "", "12.", ".5", "+5", "1,234", "$5.00"]
    for text in everyNumber where ResultValueFormatter.number(text, style: .asReturned) != text {
        asReturnedNumbersHeld = false
    }
    expect(asReturnedNumbersHeld, "asReturned returns every numeric input byte for byte")

    // MARK: - ISO 8601

    expect(date("2026-01-31 14:05:09", .iso8601T) == "2026-01-31T14:05:09", "ISO: a T is inserted")
    expect(date("2026-01-31 14:05:09Z", .iso8601T) == "2026-01-31T14:05:09Z", "ISO: Z is kept")
    expect(date("2026-01-31 14:05:09+00", .iso8601T) == "2026-01-31T14:05:09Z",
           "ISO: a zero offset becomes Z")
    expect(date("2026-01-31 14:05:09+00:00", .iso8601T) == "2026-01-31T14:05:09Z",
           "ISO: +00:00 becomes Z too")
    expect(date("2026-01-31 14:05:09+05:30", .iso8601T) == "2026-01-31T14:05:09+05:30",
           "ISO: a half-hour offset survives")
    expect(date("2026-01-31 14:05:09-08", .iso8601T) == "2026-01-31T14:05:09-08:00",
           "ISO: a bare -08 is padded to -08:00")
    expect(date("2026-01-31 14:05:09.123456", .iso8601T) == "2026-01-31T14:05:09.123456",
           "ISO: the fraction is kept exactly as written")
    expect(date("2026-01-31 14:05:09.100", .iso8601T) == "2026-01-31T14:05:09.100",
           "ISO: trailing zeros in the fraction are not trimmed")
    expect(date("2026-01-31", .iso8601T) == "2026-01-31",
           "ISO: a bare date has no T to insert, so it is unchanged")
    expect(date("14:05:09", .iso8601T) == "14:05:09",
           "ISO: a bare time has no T to insert, so it is unchanged")

    // MARK: - The localised styles
    //
    // The exact text is the reader's locale's business, so these pin the
    // properties that must hold whatever that locale is.
    let shortStamp = date("2026-01-31 14:05:09", .short)
    expect(shortStamp != "2026-01-31 14:05:09", "short: a timestamp is restyled")
    expect(!shortStamp.isEmpty, "short: never blanks the cell")
    let shortDate = date("2026-01-31", .short)
    expect(!shortDate.isEmpty, "short: a bare date never blanks the cell")
    // NOT "it differs from the raw text": a region may legitimately set its
    // short date format to ISO, and then it does not. What must hold in every
    // region is that a date-only value never grows an invented midnight.
    expect(shortDate != shortStamp, "short: a bare date draws no time")
    expect(!shortDate.contains("00:00"), "short: a bare date draws no invented midnight")
    let mediumStamp = date("2026-01-31 14:05:09", .medium)
    expect(mediumStamp != shortStamp, "medium differs from short")
    // The wall clock the server sent, never moved into the reader's own zone:
    // both of these are 14:05 where they were written, and the formatter is
    // pinned to UTC to match. 14 or 2 must appear whatever the hour format.
    expect(mediumStamp.contains("14") || mediumStamp.contains("2:05"),
           "medium keeps the wall clock the server sent")

    // MARK: - Numbers

    expect(grouped("1234567").contains(group), "grouped: a separator is added")
    expect(digits(grouped("1234567")) == "1234567", "grouped: every digit survives, in order")
    expect(grouped("999") == "999", "grouped: three digits need no separator")
    expect(grouped("0") == "0", "grouped: zero is zero")

    // The scale PostgreSQL sent, kept exactly. Rounding a money column is the
    // app rewriting the amount.
    let money = grouped("1234.5000")
    expect(money.contains(group), "grouped: the money value is grouped")
    expect(digits(money) == "12345000", "grouped: 1234.5000 keeps all four decimal places")
    if let tail = money.range(of: point) {
        expect(money[tail.upperBound...].count == 4, "grouped: exactly four digits after the point")
    } else {
        expect(false, "grouped: the money value still has a decimal point")
    }
    expect(digits(grouped("1234.50")) == "123450", "grouped: a scale of 2 stays a scale of 2")
    expect(digits(grouped("1234.0")) == "12340", "grouped: a single trailing zero is kept")

    let negative = grouped("-1234567.89")
    expect(negative.hasPrefix("-") || negative.hasPrefix("\u{2212}"), "grouped: a negative stays negative")
    expect(digits(negative) == "123456789", "grouped: a negative keeps every digit")

    // Too large for Double — this is why `Decimal` is used rather than
    // `Double(string:)`, which would come back 1.2345678901234568e+29.
    let huge = "123456789012345678901234567890"
    expect(Double(huge).map { String(format: "%.0f", $0) } != huge, "the huge value really does break Double")
    expect(digits(grouped(huge)) == huge, "grouped: a 30-digit value keeps every digit exactly")
    expect(grouped(huge).contains(group), "grouped: the 30-digit value is grouped")
    // Past what `Decimal` can hold, so nothing is rewritten.
    let beyondDecimal = String(repeating: "9", count: 40)
    expect(grouped(beyondDecimal) == beyondDecimal,
           "grouped: 40 digits is past Decimal's 38, so it passes through rather than round")

    // Non-numbers pass through. `float8` really can hold all three of these.
    for text in ["abc", "", "NaN", "Infinity", "-Infinity", "1e+20", "1.5e-08",
                 "12.", ".5", "+5", "1,234", "$5.00", "-", "12 34", "1.2.3"] {
        expect(grouped(text) == text, "grouped: passes through \(text.isEmpty ? "an empty string" : text)")
    }

    // MARK: - Round-trip sanity
    //
    // Formatting a value twice must give the same answer as once: the grid
    // re-renders a cell on every realize and every scroll tick, and a
    // formatter that kept eating its own output would drift on screen.
    var roundTripHeld = true
    for text in everyInput {
        for style in everyDateStyle where date(date(text, style), style) != date(text, style) {
            roundTripHeld = false
            print("  round-trip drift: \(text) at \(style.rawValue)")
        }
    }
    expect(roundTripHeld, "temporal: formatting twice equals formatting once")

    var numberRoundTripHeld = true
    for text in everyNumber where grouped(grouped(text)) != grouped(text) {
        numberRoundTripHeld = false
        print("  round-trip drift: \(text)")
    }
    expect(numberRoundTripHeld, "numeric: formatting twice equals formatting once")

    // MARK: - The entry point routes by column kind

    expect(ResultValueFormatter.formatted("2026-01-31 14:05:09", kind: .timestamp,
                                          dateStyle: .iso8601T, numberStyle: .asReturned)
           == "2026-01-31T14:05:09", "entry: a timestamp column is formatted")
    expect(ResultValueFormatter.formatted("2026-01-31 14:05:09", kind: .other,
                                          dateStyle: .iso8601T, numberStyle: .asReturned)
           == "2026-01-31 14:05:09",
           "entry: the SAME text in a text column is never touched")
    expect(ResultValueFormatter.formatted("1234567", kind: .integer,
                                          dateStyle: .asReturned, numberStyle: .grouped)
           .contains(group), "entry: an integer column is grouped")
    expect(ResultValueFormatter.formatted("1234567", kind: .other,
                                          dateStyle: .asReturned, numberStyle: .grouped)
           == "1234567", "entry: the same digits in a text column are never grouped")
    expect(ResultValueFormatter.formatted("1234567", kind: .integer,
                                          dateStyle: .asReturned, numberStyle: .asReturned)
           == "1234567", "entry: the default leaves an integer alone")

    // MARK: - The column kinds

    let kinds: [(String, ResultValueKind)] = [
        ("date", .date),
        ("timestamp", .timestamp),
        ("timestamp without time zone", .timestamp),
        ("timestamptz", .timestampTZ),
        ("timestamp with time zone", .timestampTZ),
        ("time", .time),
        ("time without time zone", .time),
        ("timetz", .timeTZ),
        ("time with time zone", .timeTZ),
        ("numeric", .decimal),
        ("decimal", .decimal),
        ("int2", .integer),
        ("int4", .integer),
        ("int8", .integer),
        ("smallint", .integer),
        ("integer", .integer),
        ("bigint", .integer),
        ("float4", .float),
        ("float8", .float),
        ("real", .float),
        ("double precision", .float),
        ("  TIMESTAMPTZ ", .timestampTZ),
        // Never formatted.
        ("interval", .other),
        ("money", .other),
        ("text", .other),
        ("timestamp[]", .other),
        ("_timestamp", .other),
        ("jsonb", .other),
    ]
    for (type, expected) in kinds {
        expect(ResultValueKind(dataType: type) == expected, "kind: \(type) → \(expected)")
    }

    if failures == 0 {
        print("\nAll ResultValueFormatter tests passed.")
    } else {
        print("\n\(failures) failure(s).")
        exit(1)
    }
}
