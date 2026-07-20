// Standalone test for DrillSqlTranslator. Compiled with QueryResult.swift +
// ChartTypes.swift + DrillKey.swift + DrillSqlTranslator.swift.
import Foundation

var failures = 0
func expect(_ c: Bool, _ n: String) { if c { print("PASS \(n)") } else { failures += 1; print("FAIL \(n)") } }

func runTests() {
    let columns: [ColumnDef] = [
        ColumnDef(name: "status", dataType: "text"),
        ColumnDef(name: "age", dataType: "int4"),
        ColumnDef(name: "created_at", dataType: "timestamptz"),
    ]

    let statusRef = ColumnRef(index: 0, name: "status")
    let ageRef = ColumnRef(index: 1, name: "age")
    let createdRef = ColumnRef(index: 2, name: "created_at")

    // anyOf
    let anyOfKey = DrillKey.anyOf(statusRef, ["a", "b"])
    expect(
        DrillSqlTranslator.predicate(for: anyOfKey, columns: columns) == "\"status\" IN ('a', 'b')",
        "anyOf basic"
    )

    // anyOf escaping single quotes
    let escKey = DrillKey.anyOf(statusRef, ["O'Brien"])
    expect(
        DrillSqlTranslator.predicate(for: escKey, columns: columns) == "\"status\" IN ('O''Brien')",
        "anyOf escapes single quotes"
    )

    // blank
    let blankKey = DrillKey.blank(statusRef)
    expect(
        DrillSqlTranslator.predicate(for: blankKey, columns: columns) == "\"status\" IS NULL",
        "blank is IS NULL"
    )

    // numeric range: half-open, locale-independent integers
    let rangeKey = DrillKey.range(ageRef, 10, 20, .numeric)
    expect(
        DrillSqlTranslator.predicate(for: rangeKey, columns: columns) == "\"age\" >= 10 AND \"age\" < 20",
        "numeric range half-open integers"
    )

    // temporal range: UTC ISO-ish bounds, half-open
    var cal = Calendar(identifier: .gregorian)
    cal.timeZone = TimeZone(identifier: "UTC")!
    let lo = DateComponents(calendar: cal, year: 2024, month: 1, day: 1).date!.timeIntervalSince1970
    let hi = DateComponents(calendar: cal, year: 2024, month: 1, day: 2).date!.timeIntervalSince1970
    let temporalKey = DrillKey.range(createdRef, lo, hi, .temporal)
    expect(
        DrillSqlTranslator.predicate(for: temporalKey, columns: columns)
            == "\"created_at\" >= '2024-01-01 00:00:00' AND \"created_at\" < '2024-01-02 00:00:00'",
        "temporal range UTC half-open bounds"
    )

    // compound: children joined with AND, each wrapped in parens
    let compoundKey = DrillKey.compound([anyOfKey, rangeKey])
    expect(
        DrillSqlTranslator.predicate(for: compoundKey, columns: columns)
            == "(\"status\" IN ('a', 'b')) AND (\"age\" >= 10 AND \"age\" < 20)",
        "compound wraps children and joins with AND"
    )

    if failures == 0 { print("\nAll tests passed.") } else { print("\n\(failures) failure(s)."); exit(1) }
}
