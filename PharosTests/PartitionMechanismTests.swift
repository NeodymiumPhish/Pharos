// Standalone test runner for the two display decisions a legacy inheritance
// tree changes: which parent is given a Partitions folder, and what badge a
// parent carries. Compiled by scripts/test-partition-mechanism.sh.
//
// SchemaBrowserVC is not compiled here — it pulls in the PharosCore FFI
// bridge, which cannot link in a plain swiftc binary. That is why the folder
// rule lives on TableInfo (Pharos/Models/Schema.swift) and not in the view
// controller: the rule is the part worth testing.
import AppKit
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

private func table(_ name: String) -> TableInfo {
    TableInfo(name: name, schemaName: "public", tableType: .table,
              rowCountEstimate: 0, totalSizeBytes: 8192)
}

private func declarative(_ name: String, strategy: PartitionStrategy = .range) -> TableInfo {
    TableInfo(name: name, schemaName: "public", tableType: .partitionedTable,
              rowCountEstimate: 500, totalSizeBytes: 81920,
              isPartitioned: true, partitionStrategy: strategy,
              partitionKey: "RANGE (seen)", partitionCount: 12,
              partitionMechanism: .declarative)
}

private func inherited(_ name: String, children: Int64 = 2) -> TableInfo {
    // No strategy, no key, no bound: pg_get_partkeydef and relpartbound are
    // both null for a table that only has INHERITS children.
    TableInfo(name: name, schemaName: "public", tableType: .table,
              rowCountEstimate: 500, totalSizeBytes: 81920,
              isPartitioned: true, partitionCount: children,
              partitionMechanism: .inheritance)
}

func runTests() {
    // MARK: the folder rule

    expect(!table("logs").hasPartitionsFolder(showLeafPartitions: true),
           "a table with no children never gets a folder")
    expect(!declarative("events").hasPartitionsFolder(showLeafPartitions: false),
           "a declarative parent stays gated by Show leaf partitions")
    expect(declarative("events").hasPartitionsFolder(showLeafPartitions: true),
           "a declarative parent opens when Show leaf partitions is on")
    expect(inherited("logs").hasPartitionsFolder(showLeafPartitions: false),
           "an inheritance parent opens WITHOUT Show leaf partitions")
    expect(inherited("logs").hasPartitionsFolder(showLeafPartitions: true),
           "an inheritance parent opens with it too")

    // MARK: the badge

    let node = SchemaTreeNode(.table(inherited("logs")), parent: nil)
    expectEqual(node.partitionBadge, "INHERITS", "an inheritance parent carries INHERITS")
    expectEqual(SchemaTreeNode(.table(declarative("events")), parent: nil).partitionBadge,
                "RANGE", "a declarative parent still carries its strategy")
    expectEqual(SchemaTreeNode(.table(declarative("h", strategy: .hash)), parent: nil).partitionBadge,
                "HASH", "and HASH")
    expectEqual(SchemaTreeNode(.table(table("logs")), parent: nil).partitionBadge,
                nil, "a plain table carries none")

    // MARK: the row a person reads

    expectEqual(node.subtitle, "2 partitions",
                "no key to print, so the caption is the child count alone")
    expectEqual(SchemaTreeNode(.table(declarative("events")), parent: nil).subtitle,
                "by (seen) \u{00B7} 12 partitions",
                "a declarative parent still prints its key")
    expect(node.icon != nil, "an inheritance parent has the split icon")

    // MARK: the cell puts both on screen

    // The cell builds its subviews in this initializer alone; `init(frame:)`
    // leaves its constraints nil.
    let cell = SchemaTreeCellView(identifier: NSUserInterfaceItemIdentifier("cell"))
    cell.frame = NSRect(x: 0, y: 0, width: 260, height: 24)
    cell.configure(node: node)
    cell.layoutSubtreeIfNeeded()
    let labels = cell.subviews.compactMap { $0 as? NSTextField }.map { $0.stringValue.trimmingCharacters(in: .whitespaces) }
    expect(labels.contains("logs"), "the cell shows the name")
    expect(labels.contains("INHERITS"), "the cell shows the badge")
    expect(labels.contains("2 partitions"), "the cell shows the caption")

    if failures == 0 { print("\nAll tests passed.") } else { print("\n\(failures) failure(s)."); exit(1) }
}
