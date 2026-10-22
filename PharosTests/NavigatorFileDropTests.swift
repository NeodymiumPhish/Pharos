// D3: a data file dropped on the Database Navigator. A CSV ON a table opens
// that table's import; any data file on a schema row, on the background, or
// a non-CSV on a table, makes a NEW table in the schema the delegate names;
// a schema the delegate refuses (an attached database, a read-only
// connection) refuses the drop. A stand-in NSDraggingInfo carries the file,
// as AppKit's own drag would.
import AppKit

private var failures = 0
private func expect(_ c: Bool, _ name: String) {
    if c { print("PASS \(name)") } else { failures += 1; print("FAIL \(name)") }
}

private final class FakeDrag: NSObject, NSDraggingInfo {
    let draggingPasteboard: NSPasteboard
    init(_ urls: [URL]) {
        draggingPasteboard = NSPasteboard(name: NSPasteboard.Name("pharos-nav-drop-\(UUID().uuidString)"))
        draggingPasteboard.clearContents()
        draggingPasteboard.writeObjects(urls as [NSURL])
    }
    var draggingDestinationWindow: NSWindow? { nil }
    var draggingSourceOperationMask: NSDragOperation { .copy }
    var draggingLocation: NSPoint { .zero }
    var draggedImageLocation: NSPoint { .zero }
    var draggedImage: NSImage? { nil }
    var draggingSource: Any? { nil }
    var draggingSequenceNumber: Int { 1 }
    func slideDraggedImage(to screenPoint: NSPoint) {}
    var draggingFormation: NSDraggingFormation = .default
    var animatesToDestination = false
    var numberOfValidItemsForDrop = 1
    func enumerateDraggingItems(options enumOpts: NSDraggingItemEnumerationOptions = [], for view: NSView?,
                                classes classArray: [AnyClass], searchOptions: [NSPasteboard.ReadingOptionKey: Any] = [:],
                                using block: (NSDraggingItem, Int, UnsafeMutablePointer<ObjCBool>) -> Void) {}
    var springLoadingHighlight: NSSpringLoadingHighlight { .none }
    func resetSpringLoading() {}
}

private final class Delegate: SchemaDataSourceDelegate {
    var refuse: Set<String> = []
    var pinned: String? = nil
    var imported: [(URL, String)] = []
    var created: [(URL, String)] = []
    var schemaRow: SchemaTreeNode?
    func schemaDataSourceItemWillExpand(_ node: SchemaTreeNode) {}
    func schemaDataSourceSelectionDidChange(_ node: SchemaTreeNode?) {}
    var schemaDataSourceConnectionId: String? { "duck" }
    func schemaDataSourceDidDropFile(_ url: URL, onTable node: SchemaTreeNode) { imported.append((url, node.tableName ?? "")) }
    func schemaDataSourceNewTableSchema(forProposedItem item: Any?) -> String? {
        let schema = (item as? SchemaTreeNode)?.schemaName ?? pinned ?? "main"
        return refuse.contains(schema) ? nil : schema
    }
    func schemaDataSourceSchemaRow(named schema: String) -> SchemaTreeNode? { pinned == nil ? schemaRow : nil }
    func schemaDataSourceDidDropFile(_ url: URL, newTableIn schema: String) { created.append((url, schema)) }
    func schemaDataSourceDidDoubleClick(_ node: SchemaTreeNode) -> Bool { false }
}

private func table(_ name: String, schema: String) -> SchemaTreeNode {
    SchemaTreeNode(.table(TableInfo(name: name, schemaName: schema, tableType: .table, rowCountEstimate: nil,
                                    totalSizeBytes: nil, isPartitioned: false, isPartition: false, partitionStrategy: nil,
                                    partitionKey: nil, partitionBound: nil, partitionCount: nil)))
}

func runTests() { MainActor.assumeIsolated { runDropTests() } }

@MainActor
private func runDropTests() {
    let dir = FileManager.default.temporaryDirectory.appendingPathComponent("pharos-nav-drop-\(UUID().uuidString)")
    try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
    let csv = dir.appendingPathComponent("sales.csv"), parquet = dir.appendingPathComponent("p.parquet"),
        sql = dir.appendingPathComponent("q.sql")
    for u in [csv, parquet, sql] { FileManager.default.createFile(atPath: u.path, contents: Data("a\n1\n".utf8)) }

    let outline = NSOutlineView()
    let source = SchemaDataSource(outlineView: outline)
    let delegate = Delegate()
    source.delegate = delegate
    let main = SchemaTreeNode(.schema(SchemaInfo(name: "main", owner: nil)))
    let events = table("events", schema: "main")
    main.children = [events]
    events.parent = main
    let attached = SchemaTreeNode(.schema(SchemaInfo(name: "pg.public", owner: nil, attachedDatabase: "pg")))
    source.rootNodes = [main, attached]
    delegate.schemaRow = main
    delegate.refuse = ["pg.public"]

    func validate(_ urls: [URL], on item: Any?, index: Int = NSOutlineViewDropOnItemIndex) -> NSDragOperation {
        source.outlineView(outline, validateDrop: FakeDrag(urls), proposedItem: item, proposedChildIndex: index)
    }
    func accept(_ urls: [URL], on item: Any?) -> Bool {
        source.outlineView(outline, acceptDrop: FakeDrag(urls), item: item, childIndex: NSOutlineViewDropOnItemIndex)
    }

    expect(validate([csv], on: events) == .copy, "a CSV on a table is accepted")
    expect(accept([csv], on: events) && delegate.imported.last?.1 == "events" && delegate.created.isEmpty,
           "and opens that table's import")
    expect(validate([parquet], on: events) == .copy, "a Parquet file on a table is accepted")
    expect(accept([parquet], on: events) && delegate.created.last?.1 == "main", "and makes a new table in the table's schema")
    expect(validate([csv], on: nil, index: 0) == .copy, "a data file on the background is accepted")
    expect(accept([parquet], on: nil) && delegate.created.last?.1 == "main", "and makes a new table in main")
    expect(validate([parquet], on: attached) == [], "an attached database's schema refuses the drop")
    expect(!accept([parquet], on: attached), "and takes nothing")
    expect(validate([sql], on: nil) == [], "a SQL file is no data file")
    expect(validate([csv, parquet], on: nil) == [], "several files at once are refused")
    delegate.refuse = ["main"]
    expect(validate([parquet], on: nil) == [], "a read-only connection (the delegate names no schema) refuses")

    print(failures == 0 ? "\nAll navigator drop tests passed." : "\n\(failures) FAILURE(S)")
    exit(failures == 0 ? 0 : 1)
}
