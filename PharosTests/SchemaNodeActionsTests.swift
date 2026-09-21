// Standalone test runner for the rule that decides which table actions a row
// inside the Navigator's "Partitions" folder offers. Compiled by
// scripts/test-schema-node-actions.sh.
//
// Why the rule lives on TableInfo and not in SchemaContextMenu: the menu
// needs an NSOutlineView with a clicked row and the PharosCore FFI bridge,
// neither of which links in a plain swiftc binary. `menuNeedsUpdate` is
// therefore a two-line switch over `offersFullTableActions`, and this suite
// pins the part that decides.
//
// What it is FOR. The folder holds two different objects:
//
//  - An INHERITS child is an ordinary table that happens to have a parent.
//    With Settings ▸ Navigator ▸ Group inherited tables OFF the SAME row
//    lists at the top level with the full menu. A display toggle must not
//    take Describe, Import, Truncate or Drop away from an object.
//  - A declarative partition is storage owned by its parent. It never reaches
//    the top level under any setting, and Truncate / Drop / Import stay off
//    it: dropping one silently changes what the parent returns.
//
// They are told apart by the BOUND, which `partitions_sql` fills from
// pg_get_expr(relpartbound). Reverse that test and a DROP appears on a
// declarative partition — invisible until someone uses it.
import Foundation

var failures = 0

func expect(_ condition: Bool, _ name: String) {
    if condition { print("PASS \(name)") } else {
        failures += 1
        print("FAIL \(name)")
    }
}

func expectEqual<T: Equatable>(_ actual: T, _ expected: T, _ name: String) {
    if actual == expected { print("PASS \(name)") } else {
        failures += 1
        print("FAIL \(name)\n  expected: \(expected)\n  actual:   \(actual)")
    }
}

// MARK: - Fixtures, spelled as get_tables / get_partitions fill them

/// A plain top-level table.
private func plain(_ name: String) -> TableInfo {
    TableInfo(name: name, schemaName: "public", tableType: .table,
              rowCountEstimate: 0, totalSizeBytes: 8192)
}

/// A leaf of a declarative tree: a bound, no key of its own.
private func declarativePartition(_ name: String) -> TableInfo {
    TableInfo(name: name, schemaName: "public", tableType: .table,
              rowCountEstimate: 0, totalSizeBytes: 8192,
              isPartition: true,
              partitionBound: "FOR VALUES FROM ('2013-01-01') TO ('2014-01-01')")
}

/// A child of an INHERITS parent: no bound, whatever else it carries.
private func inheritsChild(_ name: String, hasChildren: Bool = false) -> TableInfo {
    TableInfo(name: name, schemaName: "public", tableType: .table,
              rowCountEstimate: 0, totalSizeBytes: 8192,
              isPartitioned: hasChildren, isPartition: true,
              partitionCount: hasChildren ? 2 : nil,
              partitionMechanism: hasChildren ? .inheritance : nil,
              hasChildTables: hasChildren)
}

func runTests() {
    testTheRoleOfEachRow()
    testWhichRowsOfferTheFullMenu()
    testTheBoundIsWhatDecides()

    if failures == 0 { print("\nAll tests passed.") } else { print("\n\(failures) failure(s)."); exit(1) }
}

// MARK: - Tests

func testTheRoleOfEachRow() {
    expectEqual(plain("settings_flat").partitionRole, .none,
                "a table with no parent is not a partition")

    expectEqual(declarativePartition("events_2013").partitionRole, .declarative,
                "a bound makes it a declarative partition")

    expectEqual(inheritsChild("dns_log_20130101").partitionRole, .inheritsChild,
                "no bound makes it an INHERITS child")

    // A MID-TREE child: both a parent and a child. This is the row the
    // grouping setting puts inside the folder, and the row the clone note
    // about a standalone copy was written for.
    expectEqual(inheritsChild("dns_log_2013", hasChildren: true).partitionRole, .inheritsChild,
                "a mid-tree child is still an INHERITS child")

    // A DECLARATIVE parent is not itself a partition of anything.
    let parent = TableInfo(name: "events", schemaName: "public",
                           tableType: .partitionedTable,
                           rowCountEstimate: 1, totalSizeBytes: 8192,
                           isPartitioned: true,
                           partitionStrategy: .range, partitionKey: "RANGE (seen)",
                           partitionCount: 2, partitionMechanism: .declarative)
    expectEqual(parent.partitionRole, .none, "a declarative parent is no one's partition")
}

func testWhichRowsOfferTheFullMenu() {
    expect(plain("settings_flat").offersFullTableActions,
           "a plain table offers the full menu")

    // The point of the change: the SAME object at the top level has all of
    // these, so being drawn inside a folder must not remove them.
    expect(inheritsChild("dns_log_2013", hasChildren: true).offersFullTableActions,
           "an INHERITS child offers the full menu wherever it is drawn")
    expect(inheritsChild("dns_log_20130101").offersFullTableActions,
           "a leaf INHERITS child offers the full menu too")

    expect(!declarativePartition("events_2013").offersFullTableActions,
           "a declarative partition offers the read-only subset")
}

func testTheBoundIsWhatDecides() {
    // A SUB-partitioned partition: a key of its own AND a bound. It is still
    // owned storage, so the bound wins over every other signal.
    let sub = TableInfo(name: "events_2013", schemaName: "public",
                        tableType: .partitionedTable,
                        rowCountEstimate: 0, totalSizeBytes: 8192,
                        isPartitioned: true, isPartition: true,
                        partitionStrategy: .range, partitionKey: "RANGE (seen)",
                        partitionBound: "FOR VALUES FROM ('2013-01-01') TO ('2014-01-01')",
                        partitionCount: 12, partitionMechanism: .declarative)
    expectEqual(sub.partitionRole, .declarative,
                "a sub-partitioned partition is still a declarative partition")
    expect(!sub.offersFullTableActions,
           "and it still offers the read-only subset")

    // A DEFAULT partition's bound is the bare word, not a FOR VALUES clause.
    let defaultPartition = TableInfo(name: "events_rest", schemaName: "public",
                                     tableType: .table, rowCountEstimate: 0, totalSizeBytes: 8192,
                                     isPartition: true, partitionBound: "DEFAULT")
    expectEqual(defaultPartition.partitionRole, .declarative,
                "a DEFAULT partition is a declarative partition")

    // isPartition is what puts a row in the folder at all; without it a bound
    // cannot occur, and the row is an ordinary table.
    let notInFolder = TableInfo(name: "t", schemaName: "public", tableType: .table,
                                rowCountEstimate: 0, totalSizeBytes: 8192,
                                isPartition: false,
                                partitionBound: "FOR VALUES FROM (1) TO (2)")
    expectEqual(notInFolder.partitionRole, .none,
                "a row that is not a partition has no partition role")
}
