import Foundation

var failures = 0
func expect(_ c: Bool, _ n: String) { if c { print("PASS \(n)") } else { failures += 1; print("FAIL \(n)") } }

func runTests() {
    func r(_ v: AnyCodable, _ c: PGTypeCategory) -> String {
        ResultCellText.rendered(value: v, category: c, boolTrue: "✓", boolFalse: "✗", nullString: "NULL")
    }
    expect(r(AnyCodable("t"), .boolean) == "✓", "bool t → true glyph")
    expect(r(AnyCodable("true"), .boolean) == "✓", "bool true → true glyph")
    expect(r(AnyCodable("F"), .boolean) == "✗", "bool F → false glyph (case-insensitive)")
    expect(r(AnyCodable("false"), .boolean) == "✗", "bool false → false glyph")
    expect(r(AnyCodable("maybe"), .boolean) == "maybe", "unknown bool → raw")
    expect(r(AnyCodable(nil), .string) == "NULL", "null → null string")
    expect(r(AnyCodable("a\nb"), .string) == "a↵b", "string newline flattened")
    expect(r(AnyCodable("{\n}"), .json) == "{↵}", "json newline flattened")
    expect(r(AnyCodable("42"), .numeric) == "42", "numeric raw")
    expect(r(AnyCodable("2026-01-01"), .temporal) == "2026-01-01", "temporal raw")

    if failures == 0 { print("\nAll tests passed.") } else { print("\n\(failures) failure(s)."); exit(1) }
}
