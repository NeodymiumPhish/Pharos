// Standalone test runner for VariableValueRules and ListPasteParser. Not part of
// the app target — compiled together with the implementation by
// scripts/test-variable-value-rules.sh.
import Foundation

private var failures = 0

private func expectEqual(_ actual: String?, _ expected: String?, _ name: String) {
    if actual == expected { print("PASS \(name)") } else {
        failures += 1
        print("FAIL \(name)\n  expected: \(String(describing: expected?.debugDescription))\n"
            + "  actual:   \(String(describing: actual?.debugDescription))")
    }
}

private func expectItems(_ actual: [String], _ expected: [String], _ name: String) {
    if actual == expected { print("PASS \(name)") } else {
        failures += 1
        print("FAIL \(name)\n  expected: \(expected)\n  actual:   \(actual)")
    }
}

private func expectTrue(_ actual: Bool, _ name: String) {
    if actual { print("PASS \(name)") } else { failures += 1; print("FAIL \(name) — expected true") }
}

private typealias Rules = VariableValueRules

/// The SQL `value` renders to as `type`, or nil when it is invalid.
private func sql(_ value: String, _ type: VariableType) -> String? {
    Rules.render(value, as: type).sql
}

private func reason(_ value: String, _ type: VariableType) -> String? {
    Rules.render(value, as: type).reason
}

private func zone(_ id: String) -> TimeZone { TimeZone(identifier: id)! }

/// A fixed moment: 2026-10-28 14:30:05 UTC.
private let fixedNow = Date(timeIntervalSince1970: 1_793_197_805)

func runTests() {
    // MARK: VariableType helpers

    expectTrue(VariableType.timestamptz.family == .timestamp && VariableType.timestamp.family == .timestamp,
               "both timestamps share the Timestamp family")
    expectTrue(VariableType.timestamptz.withTimeZone && !VariableType.timestamp.withTimeZone,
               "only timestamptz is with time zone")
    expectTrue(VariableType.textList.listElement == .text && VariableType.numberList.listElement == .number,
               "list element types")
    expectTrue(VariableType.date.listElement == nil && !VariableType.text.isList, "non-lists have no element")
    for type in VariableType.allCases {
        let rebuilt = VariableType.make(family: type.family, withTimeZone: type.withTimeZone,
                                        listElement: type.listElement ?? .text)
        expectTrue(rebuilt == type, "make(family:) round-trips \(type.rawValue)")
    }
    expectTrue(Set(VariableType.allCases.map(\.displayName)).count == VariableType.allCases.count,
               "every type has a distinct display name")
    expectEqual(VariableTypeFamily.allCases.map(\.displayName).joined(separator: ","),
                "Literal,Text,Number,Bool,Date,Timestamp,List", "family pop-up order and names")
    expectTrue(VariableType(rawValue: "list_text") == .textList && VariableType(rawValue: "list_number") == .numberList,
               "list raw values")
    let unknownJSON = #"[{"name":"n","value":"x","type":"interval"}]"#
    let decoded = try? JSONDecoder().decode([QueryVariable].self, from: Data(unknownJSON.utf8))
    expectTrue(decoded?.first?.type == .literal && decoded?.first?.value == "x",
               "an unknown type still decodes as Literal with its value")
    let newJSON = #"[{"name":"n","value":"2026-10-28","type":"date"},{"name":"l","value":"a","type":"list_number"}]"#
    let decodedNew = try? JSONDecoder().decode([QueryVariable].self, from: Data(newJSON.utf8))
    expectTrue(decodedNew?.map(\.type) == [.date, .numberList], "new raw types decode")
    if let data = try? JSONEncoder().encode([QueryVariable(name: "l", value: "1", type: .numberList)]),
       let text = String(data: data, encoding: .utf8) {
        expectTrue(text.contains(#""type":"list_number""#), "numberList encodes as list_number")
    } else {
        expectTrue(false, "numberList encodes")
    }

    // MARK: Existing types keep their messages

    expectEqual(sql(" 42 \n", .number), "42", "number trims and renders")
    expectEqual(reason("4x", .number), "not a valid number: \"4x\"", "number message unchanged")
    expectEqual(reason("maybe", .bool), "not a valid boolean: \"maybe\"", "bool message unchanged")
    expectEqual(sql("Yes", .bool), "true", "bool yes")
    expectEqual(sql("it's", .text), "'it''s'", "text quotes")
    expectEqual(sql("", .literal), "", "literal verbatim")
    expectTrue(Rules.validate("  ", as: .literal) == .emptyLiteral, "blank literal is emptyLiteral")
    expectTrue(Rules.validate("", as: .text) == nil, "empty text is fine")
    expectTrue(Rules.isValidNumber("-.5") && !Rules.isValidNumber(" 1") && !Rules.isValidNumber("1e3"),
               "isValidNumber is exact")

    // MARK: Date

    expectEqual(sql("2026-10-28", .date), "DATE '2026-10-28'", "date renders")
    expectEqual(sql("  2024-02-29\n", .date), "DATE '2024-02-29'", "leap day, trimmed")
    expectEqual(sql("today", .date), "CURRENT_DATE", "today")
    expectEqual(sql("  ToDaY \n", .date), "CURRENT_DATE", "today with case and whitespace")
    expectEqual(sql("now", .date), nil, "now is not a date keyword")
    expectEqual(reason("2026-02-30", .date), "not a real calendar date: \"2026-02-30\"", "Feb 30 is not real")
    expectEqual(sql("2025-02-29", .date), nil, "Feb 29 in a common year")
    expectEqual(sql("1900-02-29", .date), nil, "1900 is not a leap year")
    expectEqual(sql("2000-02-29", .date), "DATE '2000-02-29'", "2000 is a leap year")
    expectEqual(sql("2026-13-01", .date), nil, "month 13")
    expectEqual(sql("2026-04-31", .date), nil, "April 31")
    expectEqual(sql("0000-01-01", .date), nil, "year 0")
    expectEqual(reason("2026/10/28", .date),
                "not a valid date: \"2026/10/28\" (use YYYY-MM-DD or today)", "slashes are malformed")
    expectEqual(sql("2026-1-28", .date), nil, "one-digit month")
    expectEqual(sql("2026-10-28 00:00:00", .date), nil, "a timestamp is not a date")
    expectEqual(sql("", .date), nil, "empty date")
    expectEqual(sql("\u{0662}026-10-28", .date), nil, "non-ASCII digits")

    // MARK: Timestamp

    expectEqual(sql("2026-10-28 14:30:00", .timestamp), "TIMESTAMP '2026-10-28 14:30:00'", "timestamp renders")
    expectEqual(sql("2026-10-28T14:30:00", .timestamp), "TIMESTAMP '2026-10-28 14:30:00'", "T is normalised")
    expectEqual(sql("2026-10-28T14:30:00.250", .timestamp), "TIMESTAMP '2026-10-28 14:30:00.250'",
                "fractional seconds are kept")
    expectEqual(sql(" NOW ", .timestamp), "LOCALTIMESTAMP", "now")
    expectEqual(sql("today", .timestamp), nil, "today is not a timestamp keyword")
    expectEqual(reason("2026-10-28 24:00:00", .timestamp), "not a real date and time: \"2026-10-28 24:00:00\"",
                "hour 24")
    expectEqual(sql("2026-10-28 23:60:00", .timestamp), nil, "minute 60")
    expectEqual(sql("2026-02-30 10:00:00", .timestamp), nil, "impossible date in a timestamp")
    expectEqual(sql("2026-10-28 14:30", .timestamp), nil, "seconds are required")
    expectEqual(reason("yesterday", .timestamp),
                "not a valid timestamp: \"yesterday\" (use YYYY-MM-DD HH:MM:SS or now)", "timestamp message")
    expectEqual(sql("2026-10-28 14:30:00 UTC", .timestamp), nil, "a zone is not part of a timestamp")

    // MARK: Timestamp with time zone

    expectEqual(sql("2026-07-15 14:30:00 America/New_York", .timestamptz),
                "TIMESTAMPTZ '2026-07-15 14:30:00-04:00'", "New York in July is -04:00")
    expectEqual(sql("2026-01-15 14:30:00 America/New_York", .timestamptz),
                "TIMESTAMPTZ '2026-01-15 14:30:00-05:00'", "New York in January is -05:00")
    expectEqual(sql("2026-10-28 14:30:00 Asia/Kolkata", .timestamptz),
                "TIMESTAMPTZ '2026-10-28 14:30:00+05:30'", "Kolkata is +05:30")
    expectEqual(sql("2026-10-28 14:30:00 Asia/Kathmandu", .timestamptz),
                "TIMESTAMPTZ '2026-10-28 14:30:00+05:45'", "Kathmandu is +05:45")
    expectEqual(sql("2026-10-28 14:30:00 UTC", .timestamptz),
                "TIMESTAMPTZ '2026-10-28 14:30:00+00:00'", "UTC is +00:00")
    expectEqual(sql("2026-10-28T14:30:00.5   Europe/Berlin", .timestamptz),
                "TIMESTAMPTZ '2026-10-28 14:30:00.5+01:00'", "T, fraction and extra spaces; Berlin after DST")
    expectEqual(sql("2026-07-01 12:00:00 Australia/Sydney", .timestamptz),
                "TIMESTAMPTZ '2026-07-01 12:00:00+10:00'", "southern winter")
    expectEqual(sql("2026-12-01 12:00:00 Australia/Sydney", .timestamptz),
                "TIMESTAMPTZ '2026-12-01 12:00:00+11:00'", "southern summer")
    // 2026-03-08 02:30 does not exist in New York (clocks go 02:00 → 03:00).
    expectEqual(reason("2026-03-08 02:30:00 America/New_York", .timestamptz),
                "a time that does not exist in America/New_York (the clocks skip it): "
                + "\"2026-03-08 02:30:00 America/New_York\"", "a spring-forward gap is a problem")
    // 2026-11-01 01:30 happens twice in New York; the earlier (EDT) wins.
    expectEqual(sql("2026-11-01 01:30:00 America/New_York", .timestamptz),
                "TIMESTAMPTZ '2026-11-01 01:30:00-04:00'", "a fall-back overlap takes the earlier moment")
    // 2026-10-25 02:30 happens twice in Berlin; the earlier (CEST) wins too.
    expectEqual(sql("2026-10-25 02:30:00 Europe/Berlin", .timestamptz),
                "TIMESTAMPTZ '2026-10-25 02:30:00+02:00'", "the overlap rule holds east of UTC")
    expectEqual(sql("now", .timestamptz), "CURRENT_TIMESTAMP", "now")
    expectEqual(reason("2026-10-28 14:30:00", .timestamptz),
                "missing a time zone: \"2026-10-28 14:30:00\" (add one such as UTC or America/New_York)",
                "a missing zone is a problem")
    expectEqual(reason("2026-10-28 14:30:00 Mars/Olympus", .timestamptz),
                "using an unknown time zone: \"Mars/Olympus\"", "an unknown zone is a problem")
    expectEqual(sql("2026-02-30 14:30:00 UTC", .timestamptz), nil, "impossible date with a zone")
    expectEqual(sql("2026-10-28 14:30:00+02:00", .timestamptz), nil, "a numeric offset is not a stored zone")

    // MARK: Lists

    expectEqual(sql("a\nb'c", .textList), "('a', 'b''c')", "text list quotes and escapes")
    expectEqual(sql("  a  \r\n\r\n b \r\n", .textList), "('a', 'b')", "text list trims and skips blank lines")
    expectEqual(sql("x\ry", .textList), "('x', 'y')", "a bare CR splits")
    expectEqual(sql("a\na", .textList), "('a', 'a')", "duplicates stay")
    expectEqual(sql("1\n2.5\n-3", .numberList), "(1, 2.5, -3)", "number list")
    expectEqual(sql(" 7 \n\n", .numberList), "(7)", "one number")
    expectEqual(reason("", .textList), "an empty list", "empty text list")
    expectEqual(reason(" \n \t\n", .numberList), "an empty list", "whitespace-only number list")
    expectEqual(reason("1\n2\n\nx4\n5y", .numberList), "not a valid number list: line 4 is \"x4\"",
                "the first bad line is named, counting blank lines")
    expectTrue(Rules.invalidNumberItems(in: "1\n2\n\nx4\n5y")
                .map { "\($0.line):\($0.text)" } == ["4:x4", "5:5y"], "invalidNumberItems lists every bad line")
    expectTrue(Rules.listItems(in: "a\n\n b").map(\.line) == [1, 3], "listItems line numbers")

    // MARK: Relative and picker helpers

    expectTrue(Rules.isRelative(" TODAY ", as: .date), "today is relative for a date")
    expectTrue(!Rules.isRelative("now", as: .date), "now is not relative for a date")
    expectTrue(Rules.isRelative("Now", as: .timestamptz), "now is relative for a timestamptz")
    expectTrue(!Rules.isRelative("today", as: .text), "text has no relative value")
    expectEqual(Rules.relativeKeyword(for: .timestamp), "now", "timestamp keyword")

    if let value = Rules.dateTime(from: "2026-10-28", as: .date) {
        expectTrue(value.zoneIdentifier == "UTC" && value.timeZone.secondsFromGMT() == 0, "a date binds in UTC")
        expectEqual(Rules.format(value.date, timeZone: value.timeZone, as: .date), "2026-10-28", "date round trip")
        expectTrue(value.date.timeIntervalSince1970 == 1_793_145_600, "a date is midnight UTC")
    } else { expectTrue(false, "date parses") }
    if let value = Rules.dateTime(from: "2026-10-28T14:30:05", as: .timestamp) {
        expectEqual(Rules.format(value.date, timeZone: value.timeZone, as: .timestamp), "2026-10-28 14:30:05",
                    "timestamp round trip normalises T")
    } else { expectTrue(false, "timestamp parses") }
    if let value = Rules.dateTime(from: "2026-10-28 20:00:05 Asia/Kolkata", as: .timestamptz) {
        expectTrue(value.zoneIdentifier == "Asia/Kolkata", "a timestamptz binds in its zone")
        expectTrue(value.date == fixedNow, "the instant is right (20:00:05 IST = 14:30:05 UTC)")
        expectEqual(Rules.format(value.date, timeZone: value.timeZone, as: .timestamptz),
                    "2026-10-28 20:00:05 Asia/Kolkata", "timestamptz round trip")
    } else { expectTrue(false, "timestamptz parses") }
    if let value = Rules.dateTime(from: "2026-10-28 14:30:05 UTC", as: .timestamptz) {
        expectTrue(value.date == fixedNow, "UTC instant")
        expectEqual(Rules.format(value.date, timeZone: value.timeZone, zoneIdentifier: value.zoneIdentifier,
                                 as: .timestamptz),
                    "2026-10-28 14:30:05 UTC", "the stored zone spelling survives a round trip")
    } else { expectTrue(false, "UTC timestamptz parses") }
    expectTrue(Rules.dateTime(from: "today", as: .date) == nil, "a relative value has no fixed date")
    expectTrue(Rules.dateTime(from: "2026-02-30", as: .date) == nil, "an invalid value has no fixed date")
    expectTrue(Rules.dateTime(from: "2026-10-28", as: .text) == nil, "text has no fixed date")
    expectEqual(Rules.format(fixedNow, timeZone: zone("America/New_York"), as: .timestamptz),
                "2026-10-28 10:30:05 America/New_York", "format shows the zone's wall clock")
    expectEqual(Rules.format(Date(timeIntervalSince1970: -1), timeZone: zone("UTC"), as: .timestamp),
                "1969-12-31 23:59:59", "format before 1970")
    expectEqual(Rules.format(Date(timeIntervalSince1970: 951_782_400), timeZone: zone("UTC"), as: .date),
                "2000-02-29", "format a leap day")

    // MARK: ListPasteParser

    expectItems(ListPasteParser.items(from: "alpha\r\nbeta\r\n\r\ngamma\r\n"), ["alpha", "beta", "gamma"],
                "spreadsheet column with CRLF")
    expectItems(ListPasteParser.items(from: "a\rb\rc"), ["a", "b", "c"], "classic Mac CR")
    expectItems(ListPasteParser.items(from: "a, b ,c"), ["a", "b", "c"], "CSV row")
    expectItems(ListPasteParser.items(from: "a\tb, c\td"), ["a", "b, c", "d"], "a tab row wins over commas")
    expectItems(ListPasteParser.items(from: "a;b; c"), ["a", "b", "c"], "semicolons")
    expectItems(ListPasteParser.items(from: "a, b; c"), ["a", "b; c"], "commas win over semicolons")
    expectItems(ListPasteParser.items(from: "('a','b')"), ["a", "b"], "SQL tuple")
    expectItems(ListPasteParser.items(from: "[1, 2, 3]"), ["1", "2", "3"], "JSON array")
    expectItems(ListPasteParser.items(from: "{x;y}"), ["x", "y"], "braces")
    expectItems(ListPasteParser.items(from: "(a), (b)"), ["(a)", "(b)"], "brackets that do not enclose the whole")
    expectItems(ListPasteParser.items(from: "('it''s', 'b')"), ["it's", "b"], "SQL doubled quote")
    expectItems(ListPasteParser.items(from: "\"say \"\"hi\"\"\",x"), ["say \"hi\"", "x"], "CSV doubled quote")
    expectItems(ListPasteParser.items(from: "'a,b', 'c'"), ["a,b", "c"], "commas inside quotes do not split")
    expectItems(ListPasteParser.items(from: "'a,b'; 'c'"), ["a,b", "c"], "quoted commas leave semicolons to split")
    expectItems(ListPasteParser.items(from: "O'Brien, Smith"), ["O'Brien", "Smith"], "an apostrophe is not a quote")
    expectItems(ListPasteParser.items(from: "(O'Brien, Smith)"), ["O'Brien", "Smith"],
                "an apostrophe does not stop bracket stripping")
    expectItems(ListPasteParser.items(from: "'a' , \"b\" , 'c\""), ["a", "b", "'c\""], "only matching quotes strip")
    expectItems(ListPasteParser.items(from: "a,,b, ,''"), ["a", "b"], "blank items drop")
    expectItems(ListPasteParser.items(from: "x,x,y"), ["x", "x", "y"], "duplicates stay")
    expectItems(ListPasteParser.items(from: "(\n  'a',\n  'b',\n  'c'\n)"), ["a", "b", "c"],
                "a SQL list one item per line drops the trailing commas")
    expectItems(ListPasteParser.items(from: "a,b\nc,d"), ["a,b", "c,d"], "with many lines, each line is one item")
    expectItems(ListPasteParser.items(from: "  single  "), ["single"], "one item")
    expectItems(ListPasteParser.items(from: " \n\t\n "), [], "nothing")
    expectItems(ListPasteParser.items(from: "()"), [], "empty brackets")
    expectEqual(ListPasteParser.joined(["a", "b"]), "a\nb", "joined")

    // MARK: Type conversion

    let ny = zone("America/New_York")
    func convert(_ value: String, _ from: VariableType, _ to: VariableType) -> String {
        Rules.convert(value, from: from, to: to, now: fixedNow, timeZone: ny)
    }
    expectEqual(convert(" 4x \n", .text, .number), "4x", "to number keeps trimmed text")
    expectEqual(convert("abc", .number, .text), "abc", "to text keeps the value")
    expectEqual(convert("a\nb", .textList, .text), "a\nb", "list to text keeps the lines")
    expectEqual(convert("2026-10-28", .date, .timestamp), "2026-10-28 00:00:00", "date to timestamp adds midnight")
    expectEqual(convert("2026-10-28 14:30:00", .timestamp, .date), "2026-10-28", "timestamp to date drops time")
    expectEqual(convert("2026-10-28 14:30:00", .timestamp, .timestamptz), "2026-10-28 14:30:00 America/New_York",
                "timestamp to timestamptz adds the zone")
    expectEqual(convert("2026-10-28 14:30:00 Asia/Kolkata", .timestamptz, .timestamp), "2026-10-28 14:30:00",
                "timestamptz to timestamp drops the zone")
    expectEqual(convert("2026-10-28 14:30:00 Asia/Kolkata", .timestamptz, .date), "2026-10-28",
                "timestamptz to date")
    expectEqual(convert("2026-10-28", .date, .timestamptz), "2026-10-28 00:00:00 America/New_York",
                "date to timestamptz")
    expectEqual(convert("today", .date, .timestamp), "now", "today maps to now")
    expectEqual(convert(" NOW ", .timestamptz, .date), "today", "now maps to today")
    expectEqual(convert("now", .timestamp, .timestamptz), "now", "now stays now")
    expectEqual(convert("Today", .text, .date), "today", "a text keyword becomes relative")
    expectEqual(convert("2026/3/7", .text, .date), "2026-03-07", "slashes and one-digit fields")
    expectEqual(convert("2026-10-28T14:30:00", .text, .timestamp), "2026-10-28 14:30:00", "ISO with T")
    expectEqual(convert("2026-10-28T02:00:00Z", .text, .date), "2026-10-27",
                "an instant with Z is seen in the given zone")
    expectEqual(convert("2026-10-28T14:30:00Z", .text, .timestamptz), "2026-10-28 10:30:00 America/New_York",
                "Z to timestamptz")
    expectEqual(convert("2026-10-28T14:30:00+05:30", .text, .timestamp), "2026-10-28 05:00:00",
                "a numeric offset is converted")
    expectEqual(convert("2026-10-28 09:15", .text, .timestamp), "2026-10-28 09:15:00", "seconds are optional")
    expectEqual(convert("not a date", .text, .date), "2026-10-28", "unparseable becomes today, fixed")
    expectEqual(convert("not a date", .text, .timestamp), "2026-10-28 10:30:05", "unparseable becomes now, fixed")
    expectEqual(convert("2026-02-30", .text, .date), "2026-10-28", "an impossible date falls back to today")
    expectEqual(convert("not a date", .text, .timestamptz), "2026-10-28 10:30:05 America/New_York",
                "unparseable becomes now with the default zone")
    expectEqual(convert("a, b, c", .text, .textList), "a\nb\nc", "to list splits")
    expectEqual(convert("('1','2')", .literal, .numberList), "1\n2", "to number list splits and unquotes")
    expectEqual(convert("'a'\nb", .textList, .numberList), "'a'\nb", "list to list keeps the lines")
    expectEqual(convert("x", .text, .text), "x", "same type is unchanged")
    expectEqual(convert("yes", .text, .bool), "yes", "to bool keeps the value")

    print(failures == 0 ? "\nALL PASSED" : "\n\(failures) FAILURE(S)")
    exit(failures == 0 ? 0 : 1)
}
