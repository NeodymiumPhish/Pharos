// D1: a data file dropped on a card editor. On a DuckDB tab it is queried in
// place (a read_* query in an empty card, the quoted path in a card with
// text, one undo step); elsewhere a text file still opens as a tab and a
// Parquet file is refused. A pointer drag from Finder cannot be driven
// headlessly, so the drop arrives through a stand-in NSDraggingInfo — the
// same calls AppKit makes.
import AppKit

private var failures = 0
private func expect(_ c: Bool, _ name: String) {
    if c { print("PASS \(name)") } else { failures += 1; print("FAIL \(name)") }
}

private final class FakeDrag: NSObject, NSDraggingInfo {
    let draggingPasteboard: NSPasteboard
    var draggingLocation: NSPoint
    weak var draggingDestinationWindow: NSWindow?
    init(urls: [URL], at point: NSPoint, window: NSWindow) {
        draggingPasteboard = NSPasteboard(name: NSPasteboard.Name("pharos-test-drop-\(UUID().uuidString)"))
        draggingPasteboard.clearContents()
        draggingPasteboard.writeObjects(urls as [NSURL])
        draggingLocation = point
        draggingDestinationWindow = window
    }
    var draggingSourceOperationMask: NSDragOperation { .copy }
    var draggedImageLocation: NSPoint { draggingLocation }
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

@MainActor
private func makeEditor(duckDB: Bool, text: String = "") -> (SQLTextView, NSWindow) {
    let view = SQLTextView()
    view.frame = NSRect(x: 0, y: 0, width: 500, height: 300)
    let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 500, height: 300), styleMask: [.titled],
                          backing: .buffered, defer: false)
    window.contentView = view
    view.acceptsDataFileDrops = { duckDB }
    view.string = text
    view.undoManager?.removeAllActions()
    return (view, window)
}

/// A point inside the window, at the end of the first line.
private func endOfFirstLine(_ window: NSWindow) -> NSPoint { NSPoint(x: 480, y: window.contentLayoutRect.height - 14) }

private func makeFiles() -> (csv: URL, json: URL, parquet: URL, duck: URL) {
    let dir = FileManager.default.temporaryDirectory.appendingPathComponent("pharos-drop-\(UUID().uuidString)")
    try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
    let csv = dir.appendingPathComponent("sales.csv"), json = dir.appendingPathComponent("e.json")
    let parquet = dir.appendingPathComponent("p.parquet"), duck = dir.appendingPathComponent("d.duckdb")
    for u in [csv, json, parquet, duck] { FileManager.default.createFile(atPath: u.path, contents: Data("a,b\n1,2\n".utf8)) }
    return (csv, json, parquet, duck)
}

func runTests() { MainActor.assumeIsolated { runDropTests() } }

@MainActor
private func runDropTests() {
    let f = makeFiles()
    let path = f.csv.standardizedFileURL.path

    // An empty DuckDB card gets the whole query, in one undo step.
    var (view, window) = makeEditor(duckDB: true)
    var drag = FakeDrag(urls: [f.csv], at: endOfFirstLine(window), window: window)
    expect(view.draggingEntered(drag) == .copy && view.draggingUpdated(drag) == .copy, "a CSV is accepted on a DuckDB card")
    expect(view.performDragOperation(drag), "the drop is taken")
    expect(view.string == "SELECT * FROM read_csv('\(path)')", "an empty card gets SELECT * FROM read_csv(…): \(view.string)")
    expect(view.undoManager?.undoActionName == "Insert File Reference", "one undo step named Insert File Reference")
    view.undoManager?.undo()
    expect(view.string.isEmpty, "Undo removes it")

    // A card with text gets the quoted path at the drop point.
    (view, window) = makeEditor(duckDB: true, text: "SELECT count(*) FROM ")
    drag = FakeDrag(urls: [f.csv], at: endOfFirstLine(window), window: window)
    _ = view.performDragOperation(drag)
    expect(view.string == "SELECT count(*) FROM '\(path)'", "a card with text gets the quoted path: \(view.string)")

    // Mixed kinds: one path per line.
    (view, window) = makeEditor(duckDB: true)
    drag = FakeDrag(urls: [f.csv, f.json], at: endOfFirstLine(window), window: window)
    _ = view.performDragOperation(drag)
    expect(view.string.split(separator: "\n").count == 2 && !view.string.contains("read_"), "mixed kinds: one quoted path per line")

    // On a PostgreSQL tab nothing is inserted: a CSV opens as a tab (text),
    // a Parquet file is refused.
    (view, window) = makeEditor(duckDB: false, text: "SELECT 1")
    drag = FakeDrag(urls: [f.parquet], at: endOfFirstLine(window), window: window)
    expect(view.draggingUpdated(drag) == [], "a Parquet file is refused on a PostgreSQL tab")
    drag = FakeDrag(urls: [f.csv], at: endOfFirstLine(window), window: window)
    expect(view.draggingUpdated(drag) == .copy, "a CSV is accepted (it opens as a tab)")
    _ = view.performDragOperation(drag)
    expect(view.string == "SELECT 1", "and nothing goes into the card")

    // A DuckDB database is accepted on any tab, and never inserted.
    drag = FakeDrag(urls: [f.duck], at: endOfFirstLine(window), window: window)
    expect(view.draggingUpdated(drag) == .copy, "a .duckdb file is accepted on any tab")
    _ = view.performDragOperation(drag)
    expect(view.string == "SELECT 1", "it opens as a connection, not as text")

    print(failures == 0 ? "\nAll data file drop tests passed." : "\n\(failures) FAILURE(S)")
    exit(failures == 0 ? 0 : 1)
}
