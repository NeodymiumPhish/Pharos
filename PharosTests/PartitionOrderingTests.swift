// Standalone test runner for PartitionOrdering — no Xcode project involvement.
// Compiled with Pharos/Models/Schema.swift + PartitionOrdering.swift by
// scripts/test-partition-ordering.sh.
import Foundation

var failures = 0

func expectEqualNames(_ actual: [TableInfo], _ expected: [String], _ name: String) {
    let got = actual.map { $0.name }
    if got == expected { print("PASS \(name)") } else {
        failures += 1
        print("FAIL \(name)\n  expected: \(expected)\n  actual:   \(got)")
    }
}

private func part(_ name: String, bound: String?, size: Int64? = nil) -> TableInfo {
    TableInfo(name: name, schemaName: "public", tableType: .table,
              rowCountEstimate: nil, totalSizeBytes: size,
              isPartition: true, partitionBound: bound)
}

func runTests() {
    // Range partitions: bound order must beat the "2024_1 vs 2024_10" lexical bug.
    let ranges = [
        part("events_2024_10", bound: "FOR VALUES FROM ('2024-10-01') TO ('2024-11-01')"),
        part("events_2024_2",  bound: "FOR VALUES FROM ('2024-02-01') TO ('2024-03-01')"),
        part("events_2024_1",  bound: "FOR VALUES FROM ('2024-01-01') TO ('2024-02-01')"),
        part("events_default", bound: "DEFAULT"),
    ]
    expectEqualNames(PartitionOrdering.sorted(ranges, by: .bound),
        ["events_2024_1", "events_2024_2", "events_2024_10", "events_default"],
        "bound order sorts chronologically, DEFAULT last")

    // Integer range bounds must compare numerically, not lexically.
    let ints = [
        part("p_1000", bound: "FOR VALUES FROM (1000) TO (2000)"),
        part("p_20",   bound: "FOR VALUES FROM (20) TO (30)"),
        part("p_100",  bound: "FOR VALUES FROM (100) TO (200)"),
    ]
    expectEqualNames(PartitionOrdering.sorted(ints, by: .bound),
        ["p_20", "p_100", "p_1000"],
        "numeric range bounds compared numerically")

    // Name order = plain case-insensitive.
    expectEqualNames(PartitionOrdering.sorted(ranges, by: .name),
        ["events_2024_1", "events_2024_10", "events_2024_2", "events_default"],
        "name order is lexical")

    // Size order = largest first, nil sizes last.
    let sized = [
        part("small", bound: "DEFAULT", size: 10),
        part("big",   bound: "DEFAULT", size: 900),
        part("mid",   bound: "DEFAULT", size: 500),
    ]
    expectEqualNames(PartitionOrdering.sorted(sized, by: .size),
        ["big", "mid", "small"],
        "size order is descending")

    // HASH bounds have no natural order → fall back to name.
    let hash = [
        part("h_2", bound: "FOR VALUES WITH (modulus 4, remainder 2)"),
        part("h_0", bound: "FOR VALUES WITH (modulus 4, remainder 0)"),
    ]
    expectEqualNames(PartitionOrdering.sorted(hash, by: .bound),
        ["h_0", "h_2"],
        "hash bound order falls back to remainder/name")

    // Unbounded ranges: MINVALUE sorts first, MAXVALUE after real values, DEFAULT last.
    let unbounded = [
        part("p_mid",  bound: "FOR VALUES FROM ('2024-01-01') TO ('2024-06-01')"),
        part("p_low",  bound: "FOR VALUES FROM (MINVALUE) TO ('2024-01-01')"),
        part("p_high", bound: "FOR VALUES FROM ('2024-06-01') TO (MAXVALUE)"),
        part("p_def",  bound: "DEFAULT"),
    ]
    expectEqualNames(PartitionOrdering.sorted(unbounded, by: .bound),
        ["p_low", "p_mid", "p_high", "p_def"],
        "MINVALUE first, MAXVALUE after reals, DEFAULT last")

    if failures == 0 { print("\nAll tests passed.") } else { print("\n\(failures) failure(s)."); exit(1) }
}
