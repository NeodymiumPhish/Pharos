// Standalone test runner for ValueCoercion.
// Compiled by scripts/test-value-coercion.sh.
import Foundation

var failures = 0
func expect(_ cond: Bool, _ name: String) {
    if cond { print("PASS \(name)") } else { failures += 1; print("FAIL \(name)") }
}

func runTests() {
    // Numbers arrive as strings (PG text format).
    expect(ValueCoercion.double(from: "123") == 123, "int string")
    expect(ValueCoercion.double(from: "1234.56") == 1234.56, "decimal string")
    expect(ValueCoercion.double(from: "-0.5") == -0.5, "negative")
    expect(ValueCoercion.double(from: "9007199254740993") != nil, "big int8 as string parses")
    expect(ValueCoercion.double(from: "not a number") == nil, "non-numeric → nil")
    expect(ValueCoercion.double(from: "") == nil, "empty → nil")

    // From a result cell (text, or nil for a SQL NULL).
    expect(ValueCoercion.double(from: "42") == 42, "cell string")
    expect(ValueCoercion.double(from: "3.14") == 3.14, "cell decimal string")
    let nullCell: String? = nil
    expect(ValueCoercion.double(from: nullCell) == nil, "cell null → nil")

    // Booleans: PG text is t/f.
    expect(ValueCoercion.bool(from: "t") == true, "t → true")
    expect(ValueCoercion.bool(from: "f") == false, "f → false")

    // Dates: PG text formats.
    expect(ValueCoercion.date(from: "2024-01-15") != nil, "date only")
    expect(ValueCoercion.date(from: "2024-01-15 12:30:00+00") != nil, "timestamptz")
    expect(ValueCoercion.date(from: "2024-01-15 12:30:00") != nil, "timestamp no tz")
    // PostgreSQL emits fractional seconds by default (now(), created_at, …).
    expect(ValueCoercion.date(from: "2024-01-15 12:30:00.123456+00") != nil, "timestamptz fractional")
    expect(ValueCoercion.date(from: "2024-01-15 12:30:00.5") != nil, "timestamp fractional short")
    expect(ValueCoercion.date(from: "2024-01-15T12:30:00.123Z") != nil, "iso fractional Z")
    expect(ValueCoercion.date(from: "garbage") == nil, "bad date → nil")

    // The fast ISO reader gives the formatter path's answer for every shape
    // PostgreSQL and DuckDB print, so charts plot the same instants.
    let shapes = [
        "2024-01-15", "1970-01-01", "1969-12-31", "2000-02-29", "1999-03-01", "1583-01-01",
        "2024-01-15 12:30:00", "2024-01-15T12:30:00", "2024-01-15 00:00:00", "2024-12-31 23:59:59",
        "2024-01-15 12:30:00+00", "2024-01-15 12:30:00-08", "2024-01-15 12:30:00+0530",
        "2024-01-15 12:30:00.123456+00", "2024-01-15 12:30:00.5", "2024-01-15T12:30:00.123Z",
        "2024-01-15T12:30:00Z", "  2024-01-15 12:30:00  ", "2024-06-30 23:00:00-0700",
    ]
    for text in shapes {
        let fast = ValueCoercion.isoTimestamp(text)
        let slow = ValueCoercion.formatterDate(from: text)?.timeIntervalSince1970
        expect(fast != nil && fast == slow, "fast ISO = formatter for \(text) (\(String(describing: fast)) vs \(String(describing: slow)))")
    }
    // Shapes the fast reader leaves to the formatters (and their answer stands).
    for text in ["0001-01-01", "1582-10-04", "2024-02-30", "2023-02-29", "2024-13-01", "2024-01-15 24:00:00", "2024-01-15 12:30",
                 "infinity", "2024-01-15 12:30:00 BC", "15/01/2024", "2024-01-15 12:30:00+00 extra"] {
        expect(ValueCoercion.isoTimestamp(text) == nil, "not the fast shape: \(text)")
        expect(ValueCoercion.date(from: text) == ValueCoercion.formatterDate(from: text), "same answer as before: \(text)")
    }
    expect(ValueCoercion.isoTimestamp("2024-01-15 12:30:00+05:30") == ValueCoercion.isoTimestamp("2024-01-15 12:30:00+0530"),
           "+05:30 reads as +0530")

    if ProcessInfo.processInfo.environment["DATE_BENCH"] == "1" {
        let cells = (0..<60_000).map { "2026-0\(1 + $0 % 9)-1\($0 % 10) 12:\(10 + $0 % 50):00.123456+00" }
        var t = DispatchTime.now(); var n = 0
        for c in cells where ValueCoercion.date(from: c) != nil { n += 1 }
        let fastMs = (DispatchTime.now().uptimeNanoseconds - t.uptimeNanoseconds) / 1_000_000
        t = DispatchTime.now()
        for c in cells.prefix(6_000) where ValueCoercion.formatterDate(from: c) != nil { n += 1 }
        let slowMs = (DispatchTime.now().uptimeNanoseconds - t.uptimeNanoseconds) / 1_000_000
        print("BENCH 60,000 timestamps: fast \(fastMs) ms; formatter 6,000 in \(slowMs) ms (\(n))")
    }

    if failures == 0 { print("\nAll tests passed.") } else { print("\n\(failures) failure(s)."); exit(1) }
}
