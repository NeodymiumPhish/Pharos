// Standalone test runner for PartitionDisplay.
import Foundation

var failures = 0

func expectEqualStr(_ actual: String?, _ expected: String?, _ name: String) {
    if actual == expected { print("PASS \(name)") } else {
        failures += 1
        print("FAIL \(name)\n  expected: \(expected ?? "nil")\n  actual:   \(actual ?? "nil")")
    }
}

func runTests() {
    // keyColumns extracts the parenthesized column list from pg_get_partkeydef.
    expectEqualStr(PartitionDisplay.keyColumns(fromPartKeyDef: "RANGE (created_at)"), "created_at",
        "range key columns")
    expectEqualStr(PartitionDisplay.keyColumns(fromPartKeyDef: "LIST (region, tier)"), "region, tier",
        "multi-column key")
    expectEqualStr(PartitionDisplay.keyColumns(fromPartKeyDef: nil), nil, "nil key def")

    // boundSummary compacts the common forms.
    expectEqualStr(PartitionDisplay.boundSummary("FOR VALUES FROM ('2024-01-01') TO ('2024-02-01')"),
        "[2024-01-01, 2024-02-01)", "range → bracket notation")
    expectEqualStr(PartitionDisplay.boundSummary("FOR VALUES IN ('US', 'CA')"),
        "IN (US, CA)", "list → IN summary")
    expectEqualStr(PartitionDisplay.boundSummary("FOR VALUES WITH (modulus 4, remainder 0)"),
        "mod 4, rem 0", "hash → mod/rem summary")
    expectEqualStr(PartitionDisplay.boundSummary("DEFAULT"), "DEFAULT", "default passthrough")
    expectEqualStr(PartitionDisplay.boundSummary(nil), nil, "nil bound")

    if failures == 0 { print("\nAll tests passed.") } else { print("\n\(failures) failure(s)."); exit(1) }
}
