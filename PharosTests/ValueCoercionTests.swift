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

    // From AnyCodable (value is a String, or already a number via the memberwise init).
    expect(ValueCoercion.double(from: AnyCodable("42")) == 42, "AnyCodable string")
    expect(ValueCoercion.double(from: AnyCodable(3.14)) == 3.14, "AnyCodable double")
    expect(ValueCoercion.double(from: AnyCodable(nil)) == nil, "AnyCodable null → nil")

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

    if failures == 0 { print("\nAll tests passed.") } else { print("\n\(failures) failure(s)."); exit(1) }
}
