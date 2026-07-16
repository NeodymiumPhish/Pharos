// Standalone test runner for TableDDL / DDLDetailLevel — no Xcode project involvement.
// Compiled with Pharos/Models/TableDDL.swift by scripts/test-table-ddl.sh.
import Foundation

var failures = 0

func expectEqual(_ actual: String, _ expected: String, _ name: String) {
    if actual == expected { print("PASS \(name)") } else {
        failures += 1
        print("FAIL \(name)\n  expected: \(expected)\n  actual:   \(actual)")
    }
}

func expectTrue(_ cond: Bool, _ name: String) {
    if cond { print("PASS \(name)") } else { failures += 1; print("FAIL \(name)") }
}

func runTests() {
    // Decoding from Rust camelCase JSON.
    let json = """
    {"columnsOnly":"CT cols","withConstraints":"CT cons","full":"CT full"}
    """.data(using: .utf8)!
    let decoded = try! JSONDecoder().decode(TableDDL.self, from: json)
    expectEqual(decoded.columnsOnly, "CT cols", "decode columnsOnly")
    expectEqual(decoded.withConstraints, "CT cons", "decode withConstraints")
    expectEqual(decoded.full, "CT full", "decode full")

    // Level → variant mapping.
    expectEqual(DDLDetailLevel.columns.ddl(from: decoded), "CT cols", "columns → columnsOnly")
    expectEqual(DDLDetailLevel.constraints.ddl(from: decoded), "CT cons", "constraints → withConstraints")
    expectEqual(DDLDetailLevel.full.ddl(from: decoded), "CT full", "full → full")

    // Titles and ordering.
    expectEqual(DDLDetailLevel.columns.title, "Columns", "columns title")
    expectEqual(DDLDetailLevel.constraints.title, "+ Constraints", "constraints title")
    expectEqual(DDLDetailLevel.full.title, "Full (+ Indexes)", "full title")
    expectTrue(DDLDetailLevel.allCases == [.columns, .constraints, .full], "allCases order")

    if failures == 0 { print("\nAll tests passed.") } else { print("\n\(failures) failure(s)."); exit(1) }
}
