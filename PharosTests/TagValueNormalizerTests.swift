// Standalone runner for TagValueNormalizer. Foundation + CIDRRange.
import Foundation

var failures = 0

func expectEqual<T: Equatable>(_ actual: T, _ expected: T, _ name: String) {
    if actual == expected { print("PASS \(name)") } else {
        failures += 1
        print("FAIL \(name)\n  expected: \(expected)\n  actual:   \(actual)")
    }
}

private func norm(_ text: String, _ dataType: String) -> String {
    TagValueNormalizer.normalize(text,
        family: TagValueNormalizer.family(forDataType: dataType))
}

func runTests() {
    // 1. The family table, both spellings PostgreSQL uses. sqlx reports the
    //    short upper-case name ("INT4"); information_schema reports "integer".
    expectEqual(TagValueNormalizer.family(forDataType: "INET"), "address", "inet -> address")
    expectEqual(TagValueNormalizer.family(forDataType: "cidr"), "address", "cidr -> address")
    expectEqual(TagValueNormalizer.family(forDataType: "VARCHAR"), "text", "varchar -> text")
    expectEqual(TagValueNormalizer.family(forDataType: "character varying"), "text",
                "spelled-out varchar -> text")
    expectEqual(TagValueNormalizer.family(forDataType: "INT4"), "numeric", "int4 -> numeric")
    expectEqual(TagValueNormalizer.family(forDataType: "bigint"), "numeric", "bigint -> numeric")
    expectEqual(TagValueNormalizer.family(forDataType: "TIMESTAMPTZ"), "temporal",
                "timestamptz -> temporal")
    expectEqual(TagValueNormalizer.family(forDataType: "UUID"), "uuid", "uuid -> uuid")
    // Anything else keeps its own type name, so a jsonb value never compares
    // equal to a bytea value that happens to render the same.
    expectEqual(TagValueNormalizer.family(forDataType: "JSONB"), "type:jsonb", "jsonb -> its own")
    expectEqual(TagValueNormalizer.family(forDataType: "  MacAddr "), "type:macaddr",
                "an unknown type is trimmed and lower-cased")

    // 2. Address: prefix and spelling collapse; junk falls back to trimmed text.
    expectEqual(norm("10.2.3.4/32", "inet"), "10.2.3.4", "address drops /32")
    expectEqual(norm(" 2001:0DB8::0001 ", "inet"), "2001:db8::1", "address collapses v6")
    expectEqual(norm("not an address", "inet"), "not an address", "unparseable address is text")

    // 3. Text: case and surrounding space are representation, not identity.
    expectEqual(norm(" D41D8CD98F00 ", "text"), "d41d8cd98f00", "text folds case and trims")
    expectEqual(norm("CN=Evil Corp", "varchar"), "cn=evil corp", "text folds a subject")

    // 4. Numeric: one canonical decimal per number.
    expectEqual(norm("443", "int4"), "443", "integer is itself")
    expectEqual(norm("443.0", "numeric"), "443", "trailing zero is not a difference")
    expectEqual(norm("0443", "int8"), "443", "leading zero is not a difference")
    expectEqual(norm("-0.500", "numeric"), "-0.5", "trailing zeros after the point go")
    expectEqual(norm("1e3", "float8"), "1000", "exponent notation resolves")
    // Decimal covers ~38 significant digits; beyond that it refuses, and the
    // exact text is the honest fallback.
    expectEqual(norm("1e308", "float8"), "1e308", "out-of-range float falls back to text")
    expectEqual(norm("NaN", "float8"), "NaN", "NaN falls back to text")
    // Decimal(string:) scans a PREFIX and returns what it read, so a validator
    // is needed in front of it. Each of these decayed to a finite Decimal — and
    // "0" — before `isNumericText` was added, which made every one of them
    // match every literal zero in its column.
    expectEqual(norm("-Infinity", "float8"), "-Infinity", "negative infinity keeps its text")
    expectEqual(norm("-NaN", "float8"), "-NaN", "negative NaN keeps its text")
    expectEqual(norm("Infinity", "float8"), "Infinity", "infinity keeps its text")
    expectEqual(norm("1,000", "numeric"), "1,000", "a thousands separator is not dropped")
    expectEqual(norm("5-", "numeric"), "5-", "trailing junk is not dropped")
    expectEqual(norm("0x10", "numeric"), "0x10", "hex is not a number here")
    expectEqual(norm("", "numeric"), "", "an empty numeric cell stays empty")
    expectEqual(norm(".5", "numeric"), "0.5", "a leading point is still a number")
    expectEqual(norm("-0.5e-3", "numeric"), "-0.0005", "sign and exponent both parse")
    // Magnitude, not grammar. Decimal rounds a plain digit string past 38
    // significant digits instead of refusing it, so these two 39-digit values
    // produced ONE string — a false match between two different numbers.
    let wide1 = String(repeating: "7", count: 38) + "1"
    let wide2 = String(repeating: "7", count: 38) + "9"
    expectEqual(norm(wide1, "numeric") == norm(wide2, "numeric"), false,
                "39-digit values differing past Decimal's precision stay distinct")
    expectEqual(norm(wide1, "numeric"), wide1, "an over-precision value keeps its exact text")
    // 38 digits still canonicalise — the bound must not cost a real match.
    expectEqual(norm("0" + String(repeating: "7", count: 38), "numeric"),
                String(repeating: "7", count: 38), "38 significant digits still canonicalise")
    // Trailing zeros are magnitude, not precision: one significant digit, held
    // exactly by Decimal as a mantissa and an exponent. The bound must not
    // reject this — a wide round number is ordinary data, and rejecting it
    // would cost a real match for nothing. Decimal prints the whole-number case
    // in plain digits, not scientific notation.
    expectEqual(norm("1" + String(repeating: "0", count: 40), "numeric"),
                "1" + String(repeating: "0", count: 40),
                "a wide trailing-zero value canonicalises to itself")
    // The same magnitude with a leading zero and a redundant point. Only the
    // canonicalising path can produce the bare form, so this separates "the
    // bound let it through" from "the fallback returned the input unchanged".
    expectEqual(norm("01" + String(repeating: "0", count: 40) + ".00", "numeric"),
                "1" + String(repeating: "0", count: 40),
                "a wide value still canonicalises rather than falling back")

    // 5. Temporal: one ISO form, in UTC, with the fraction PRESERVED. A
    //    formatter that truncates to milliseconds would make two timestamps a
    //    microsecond apart into one value — a false match, the one direction
    //    that matters.
    expectEqual(norm("2026-08-13 12:34:56+01", "timestamptz"), "2026-08-13T11:34:56Z",
                "offset is applied")
    expectEqual(norm("2026-08-13 12:34:56.789123+00", "timestamptz"),
                "2026-08-13T12:34:56.789123Z", "microseconds survive")
    expectEqual(norm("2026-08-13 12:34:56.789000", "timestamp"), "2026-08-13T12:34:56.789Z",
                "trailing zeros in the fraction go")
    expectEqual(norm("2026-08-13 12:34:56", "timestamp"), "2026-08-13T12:34:56Z",
                "no fraction, no point")
    expectEqual(norm("2026-08-13", "date"), "2026-08-13T00:00:00Z",
                "a date is midnight UTC, so it meets a timestamp")
    expectEqual(norm("12:34:56", "time"), "12:34:56",
                "a bare time does not parse and stays exact text")
    expectEqual(norm("yesterday", "timestamp"), "yesterday", "junk stays exact text")

    // 6. UUID: one spelling.
    expectEqual(norm("{D41D8CD9-8F00-4B2E-8000-000000000001}", "uuid"),
                "d41d8cd98f004b2e8000000000000001", "uuid strips braces and hyphens")

    // 7. An unknown type compares EXACTLY — no trim, no folding. A jsonb blob's
    //    whitespace is part of it.
    expectEqual(norm(" {\"a\": 1} ", "jsonb"), " {\"a\": 1} ", "unknown type is exact text")

    // 8. A NULL is the absence of a value, so it produces no key at all.
    expectEqual(TagValueNormalizer.key(text: nil, family: "text") == nil, true,
                "NULL yields no key")
    expectEqual(TagValueNormalizer.key(text: "A", family: "text"),
                TagValueKey(family: "text", value: "a"), "key carries family and normalized text")

    // MARK: comparable forms

    func normNum(_ t: String) -> String { TagValueNormalizer.normalize(t, family: "numeric") }
    func normTime(_ t: String) -> String { TagValueNormalizer.normalize(t, family: "temporal") }

    // A parseable number yields a Decimal, and the ORDER is numeric, not byte
    // order: a byte compare puts "9" above "10".
    let nine = TagValueNormalizer.decimal(from: normNum("9"))
    let ten = TagValueNormalizer.decimal(from: normNum("10"))
    expectEqual(nine != nil && ten != nil, true, "9 and 10 both parse to a Decimal")
    expectEqual(nine! < ten!, true, "9 orders below 10, which byte order gets wrong")

    // Negatives order correctly too, which byte order also gets wrong.
    let minusFive = TagValueNormalizer.decimal(from: normNum("-5"))
    let zero = TagValueNormalizer.decimal(from: normNum("0"))
    expectEqual(minusFive != nil && zero != nil, true, "-5 and 0 both parse to a Decimal")
    expectEqual(minusFive! < nine!, true, "-5 orders below 9")
    expectEqual(minusFive! < zero!, true, "-5 orders below 0")

    // A value that FELL BACK to raw text has no Decimal. A comparator against
    // it must fail to match rather than compare bytes.
    expectEqual(TagValueNormalizer.decimal(from: normNum("-Infinity")) == nil, true,
                "-Infinity has no Decimal")
    expectEqual(TagValueNormalizer.decimal(from: normNum("5-")) == nil, true,
                "a trailing sign has no Decimal")
    expectEqual(TagValueNormalizer.decimal(from: normNum("1,000")) == nil, true,
                "grouped digits have no Decimal")
    expectEqual(TagValueNormalizer.decimal(from: normNum(String(repeating: "9", count: 39))) == nil,
                true, "39 significant digits have no Decimal")
    expectEqual(TagValueNormalizer.decimal(from: normNum("not a number")) == nil, true,
                "plain text has no Decimal")

    // Temporal: padding makes byte order agree with time order. Without it
    // ".9Z" sorts ABOVE ".91Z", because 'Z' outranks '1'.
    let shortFraction = TagValueNormalizer.comparableTimestamp(normTime("2026-08-13 12:34:56.9"))
    let longFraction = TagValueNormalizer.comparableTimestamp(normTime("2026-08-13 12:34:56.91"))
    expectEqual(shortFraction != nil && longFraction != nil, true,
                "both fractional timestamps have a comparable form")
    expectEqual(shortFraction! < longFraction!, true,
                ".9 orders below .91, which byte order gets wrong")

    // Equal instants written differently compare EQUAL.
    expectEqual(TagValueNormalizer.comparableTimestamp(normTime("2026-08-13 12:34:56.500"))
                    == TagValueNormalizer.comparableTimestamp(normTime("2026-08-13 12:34:56.5")),
                true, ".500 and .5 are one instant")

    // Ordering across the whole form, and across a date/timestamp boundary.
    let dayOne = TagValueNormalizer.comparableTimestamp(normTime("2026-08-13"))
    let dayTwo = TagValueNormalizer.comparableTimestamp(normTime("2026-08-14"))
    expectEqual(dayOne != nil && dayTwo != nil, true, "both dates have a comparable form")
    expectEqual(dayOne! < dayTwo!, true, "dates order")
    expectEqual(dayOne! < TagValueNormalizer.comparableTimestamp(normTime("2026-08-13 00:00:01"))!,
                true, "a date sits at midnight, below a time later that day")

    // A temporal value that fell back to raw text has no comparable form. The
    // gate is the normalizer's OWN idempotence, so it cannot disagree with it.
    expectEqual(TagValueNormalizer.comparableTimestamp(normTime("12:34:56")) == nil, true,
                "a bare time has no comparable form")
    expectEqual(TagValueNormalizer.comparableTimestamp(normTime("3 days")) == nil, true,
                "an interval has no comparable form")
    expectEqual(TagValueNormalizer.comparableTimestamp("XYZ") == nil, true,
                "raw text ending in Z has no comparable form")

    print(failures == 0 ? "\nAll normalizer checks passed" : "\n\(failures) FAILED")
    if failures > 0 { exit(1) }
}
