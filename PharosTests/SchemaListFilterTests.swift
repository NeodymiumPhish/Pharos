// Standalone test runner for SchemaListFilter. Not part of the app target —
// compiled together with the implementation by scripts/test-schema-list-filter.sh.
import Foundation

var failures = 0

func expectEqual(_ actual: [String], _ expected: [String], _ name: String) {
    if actual == expected { print("PASS \(name)") } else {
        failures += 1
        print("FAIL \(name)\n  expected: \(expected)\n  actual:   \(actual)")
    }
}

func runTests() {
    let schemas = ["public", "analytics", "Reporting", "audit_log", "billing"]

    expectEqual(SchemaListFilter.filter(schemas, query: ""), schemas,
        "empty query returns all, order preserved")
    expectEqual(SchemaListFilter.filter(schemas, query: "   "), schemas,
        "whitespace-only query returns all")
    expectEqual(SchemaListFilter.filter(schemas, query: "log"), ["audit_log"],
        "substring match (not just prefix)")
    expectEqual(SchemaListFilter.filter(schemas, query: "REPORT"), ["Reporting"],
        "case-insensitive match")
    expectEqual(SchemaListFilter.filter(schemas, query: "i"), ["public", "analytics", "Reporting", "audit_log", "billing"],
        "multiple matches keep original order")
    expectEqual(SchemaListFilter.filter(schemas, query: "zzz"), [],
        "no match returns empty")
    expectEqual(SchemaListFilter.filter(schemas, query: "  bill  "), ["billing"],
        "query is trimmed before matching")

    if failures == 0 { print("\nAll tests passed.") } else { print("\n\(failures) failure(s).") ; exit(1) }
}
