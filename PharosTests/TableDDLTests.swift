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
    // Decoding from Rust camelCase JSON. The shape is on the wire too, and
    // `shape` is not optional: pharos-core always composes one, and a
    // synthesized Decodable throws on a missing key.
    let json = """
    {"columnsOnly":"CT cols","withConstraints":"CT cons","full":"CT full",\
    "shape":{"partitionBy":null,"inheritsFrom":[],"hasChildTables":false}}
    """.data(using: .utf8)!
    let decoded = try! JSONDecoder().decode(TableDDL.self, from: json)
    expectEqual(decoded.columnsOnly, "CT cols", "decode columnsOnly")
    expectEqual(decoded.withConstraints, "CT cons", "decode withConstraints")
    expectEqual(decoded.full, "CT full", "decode full")

    // The shape a plain table reports: nothing to say about the clone.
    expectTrue(decoded.shape.partitionBy == nil, "plain table has no partition key")
    expectTrue(!decoded.shape.isPartitionedParent, "plain table is not a partitioned parent")
    expectTrue(decoded.shape.inheritsFrom.isEmpty, "plain table has no parents")
    expectTrue(!decoded.shape.hasChildTables, "plain table has no children")

    // A parent's shape, spelled exactly as pharos-core's serde emits it.
    // JSONDecoder.pharos sets no key strategy, so these names are the contract.
    let parentJSON = """
    {"columnsOnly":"c","withConstraints":"c","full":"c","shape":{\
    "partitionBy":"RANGE (seen)",\
    "inheritsFrom":[{"schema":"public","table":"logs_2013"}],\
    "hasChildTables":true}}
    """.data(using: .utf8)!
    let parent = try! JSONDecoder().decode(TableDDL.self, from: parentJSON)
    expectEqual(parent.shape.partitionBy ?? "", "RANGE (seen)", "decode partitionBy")
    expectTrue(parent.shape.isPartitionedParent, "a partition key makes it a partitioned parent")
    expectTrue(parent.shape.hasChildTables, "decode hasChildTables")
    expectTrue(
        parent.shape.inheritsFrom == [QualifiedTableName(schema: "public", table: "logs_2013")],
        "decode inheritsFrom, unquoted and unescaped"
    )

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
