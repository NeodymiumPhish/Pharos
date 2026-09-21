// Standalone test runner for the clone section of TableDDLSheet, and for the
// two pure wording types it uses. Real AppKit: the sheet is hosted in a
// headless, never-shown NSWindow so Auto Layout runs, and the real controls
// are driven through their own target/action wiring — the approach of
// PharosTests/TagManagerSheetTests.swift.
//
// What this suite is FOR. `LIKE ... INCLUDING ALL` carries neither
// `PARTITION BY` nor `INHERITS`, so a clone of a parent used to come out flat
// and, with rows on, to swallow the whole tree. pharos-core now keeps the
// shape and defaults the rows to `FROM ONLY`; what is NEW here is the UI that
// says so, and three of its decisions are ones an ordinary-looking edit would
// quietly reverse:
//
//  - "Include table rows" is DISABLED for a partitioned source. The copy is
//    created with no partitions, so PostgreSQL answers every row with "no
//    partition of relation found for row". The core refuses it as well; this
//    is what stops the analyst asking for it.
//  - The row-scope radios appear ONLY when the source has descendants, and
//    they follow the checkbox. On an ordinary table both would mean the same
//    rows, and a choice with one answer is noise.
//  - The default scope is `ownRows`, and the sheet hands the CHOSEN scope to
//    its callback. A regression here is invisible in the UI and enormous on
//    the wire: 4,700 tables' rows instead of one table's.
//
// Each is asserted here rather than left to a manual pass.
import AppKit

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

func expectContains(_ haystack: String, _ needle: String, _ name: String) {
    if haystack.contains(needle) { print("PASS \(name)") } else {
        failures += 1
        print("FAIL \(name)\n  looked for: \(needle)\n  in:         \(haystack)")
    }
}

// MARK: - Fixtures

private func ddl(partitionBy: String? = nil,
                 inheritsFrom: [QualifiedTableName] = [],
                 hasChildTables: Bool = false,
                 partitionOf: QualifiedTableName? = nil) -> TableDDL {
    let json = """
    {"columnsOnly":"c","withConstraints":"c","full":"c","shape":{
      "partitionBy":\(partitionBy.map { "\"\($0)\"" } ?? "null"),
      "inheritsFrom":[\(inheritsFrom.map { "{\"schema\":\"\($0.schema)\",\"table\":\"\($0.table)\"}" }.joined(separator: ","))],
      "partitionOf":\(partitionOf.map { "{\"schema\":\"\($0.schema)\",\"table\":\"\($0.table)\"}" } ?? "null"),
      "hasChildTables":\(hasChildTables)}}
    """
    // Built by decoding, exactly as the app gets it: the model has no
    // memberwise initialiser in play anywhere else.
    return try! JSONDecoder().decode(TableDDL.self, from: json.data(using: .utf8)!)
}

/// The sheet in a never-shown window, so `loadView` and Auto Layout run.
private func host(_ sheet: TableDDLSheet) -> NSWindow {
    let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 700, height: 600),
                          styleMask: [.borderless], backing: .buffered, defer: false)
    let root = NSView(frame: NSRect(x: 0, y: 0, width: 700, height: 600))
    let content = sheet.view
    content.translatesAutoresizingMaskIntoConstraints = false
    root.addSubview(content)
    NSLayoutConstraint.activate([
        content.leadingAnchor.constraint(equalTo: root.leadingAnchor),
        content.trailingAnchor.constraint(equalTo: root.trailingAnchor),
        content.topAnchor.constraint(equalTo: root.topAnchor),
    ])
    window.contentView = root
    root.layoutSubtreeIfNeeded()
    return window
}

private extension NSView {
    /// The controls are private to the sheet, so the suite reaches them the
    /// way an accessibility client does — by identifier.
    func descendant(id: String) -> NSView? {
        if accessibilityIdentifier() == id { return self }
        for sub in subviews {
            if let found = sub.descendant(id: id) { return found }
        }
        return nil
    }

    func button(id: String) -> NSButton? { descendant(id: id) as? NSButton }
}

// MARK: - Tests

func runTests() {
    testShapeNoteWording()
    testTheLongestNoteFitsItsLabel()
    testOutcomeWording()
    testPlainTableHasNoCloneChrome()
    testPartitionedSourceCannotAskForRows()
    testScopeRadiosFollowTheCheckbox()
    testTheChosenScopeReachesTheCallback()

    if failures == 0 { print("\nAll tests passed.") } else { print("\n\(failures) failure(s)."); exit(1) }
}

// MARK: - The two pure wording types

func testShapeNoteWording() {
    expectTrue(CloneShapeNote.text(for: ddl().shape) == nil,
               "an ordinary table has nothing to warn about")

    // A parent whose only consequence is the row scope says nothing either:
    // the radio labels state it.
    expectTrue(CloneShapeNote.text(for: ddl(hasChildTables: true).shape) == nil,
               "descendants alone need no note — the radios say it")

    let partitioned = CloneShapeNote.text(for: ddl(partitionBy: "RANGE (seen)").shape) ?? ""
    expectContains(partitioned, "RANGE (seen)", "the note names the partition key")
    expectContains(partitioned, "cannot take rows", "the note says why rows are refused")

    let child = CloneShapeNote.text(
        for: ddl(inheritsFrom: [QualifiedTableName(schema: "archive", table: "dns_log_2013")]).shape) ?? ""
    expectContains(child, "standalone table", "the note says the copy stands alone")
    // Unquoted, which is what DisplayEscape.escapedQualified produces and
    // what the sheet's own subtitle already shows.
    expectContains(child, "archive.dns_log_2013", "the note names the parent")
    expectContains(child, "inheritance tree.", "one parent, singular")

    let twoParents = CloneShapeNote.text(
        for: ddl(inheritsFrom: [
            QualifiedTableName(schema: "a", table: "p1"),
            QualifiedTableName(schema: "a", table: "p2"),
        ]).shape) ?? ""
    expectContains(twoParents, "inheritance trees.", "two parents, plural")

    // Both facts can be true of one table, and both get said.
    let both = CloneShapeNote.text(
        for: ddl(partitionBy: "LIST (region)",
                 inheritsFrom: [QualifiedTableName(schema: "a", table: "p")]).shape) ?? ""
    expectContains(both, "LIST (region)", "both sentences: the key")
    expectContains(both, "standalone", "both sentences: the standalone copy")

    // A declarative partition reaches its parent by ALTER TABLE, not
    // INHERITS, and `LIKE` carries neither — so the copy stands alone the
    // same way, and the note says so the same way.
    let partition = CloneShapeNote.text(
        for: ddl(partitionOf: QualifiedTableName(schema: "archive", table: "events")).shape) ?? ""
    expectContains(partition, "standalone table", "a partition's copy stands alone too")
    expectContains(partition, "not a partition of archive.events", "the note names the parent")
    expectTrue(!partition.contains("inheritance"),
               "a declarative partition is not an inheritance child")

    // The longest note a real table can produce: a SUB-partitioned partition,
    // which is both a parent with a key and a child with a bound. Three
    // sentences is impossible — a declarative partition has no INHERITS
    // parents — so this pair is the worst case the label has to fit.
    let subPartition = CloneShapeNote.text(
        for: ddl(partitionBy: "RANGE (seen)",
                 partitionOf: QualifiedTableName(schema: "archive", table: "events")).shape) ?? ""
    expectContains(subPartition, "RANGE (seen)", "both sentences: the key")
    expectContains(subPartition, "not a partition of", "both sentences: the standalone copy")
}

/// The note is a wrapping label with a line cap. A sentence added to it is
/// worth nothing if the cap silently truncates the one before it, and the
/// truncation is invisible in a screenshot at the wrong width.
func testTheLongestNoteFitsItsLabel() {
    // The two shapes that produce two sentences: a sub-partitioned partition
    // (a key and a bound), and an inheritance child that is itself a
    // declarative parent.
    expectNoteFits(ddl(partitionBy: "RANGE (seen)",
                       partitionOf: QualifiedTableName(schema: "archive", table: "events")),
                   "a sub-partitioned partition")
    expectNoteFits(ddl(partitionBy: "RANGE (created_at)",
                       inheritsFrom: [QualifiedTableName(schema: "archive", table: "dns_log_2013")]),
                   "a partitioned inheritance child")
}

private func expectNoteFits(_ ddl: TableDDL, _ name: String) {
    let sheet = TableDDLSheet(schema: "s", table: "t", ddl: ddl) { _, _, _ in }
    let window = host(sheet)
    defer { window.close() }

    guard let label = window.contentView?.descendant(id: "sheet.tableddl.shapeNote") as? NSTextField else {
        failures += 1
        print("FAIL \(name) has a note label")
        return
    }
    // What the cap allows against what the text actually needs at the label's
    // own width. `maximumNumberOfLines` clamps the first; the second is what
    // an uncapped measure of the same string returns.
    let width = label.preferredMaxLayoutWidth
    let needed = (label.attributedStringValue as NSAttributedString).boundingRect(
        with: NSSize(width: width, height: .greatestFiniteMagnitude),
        options: [.usesLineFragmentOrigin, .usesFontLeading]).height
    let allowed = label.fittingSize.height
    expectTrue(allowed + 0.5 >= needed,
               "\(name)'s note fits: \(allowed) allowed vs \(needed) needed at \(width)pt")
}

func testOutcomeWording() {
    expectEqual(CloneOutcomeText.message(rowsCopied: nil, partitionBy: nil),
                "Table structure cloned.", "structure only, ordinary table")

    let partitioned = CloneOutcomeText.message(rowsCopied: nil, partitionBy: "RANGE (seen)")
    expectContains(partitioned, "partitioned by RANGE (seen)", "the outcome names the key")
    expectContains(partitioned, "no partitions yet", "the outcome says the copy is empty by shape")

    // The count is pluralised, which the old inline string was not.
    expectEqual(CloneOutcomeText.message(rowsCopied: 1, partitionBy: nil),
                "Table cloned with 1 row.", "one row is singular")
    expectEqual(CloneOutcomeText.message(rowsCopied: 4, partitionBy: nil),
                "Table cloned with 4 rows.", "four rows is plural")
}

// MARK: - The sheet

func testPlainTableHasNoCloneChrome() {
    let sheet = TableDDLSheet(schema: "s", table: "t", ddl: ddl()) { _, _, _ in }
    let window = host(sheet)
    defer { window.close() }

    expectTrue(window.contentView?.descendant(id: "sheet.tableddl.shapeNote") == nil,
               "no note for an ordinary table")
    expectTrue(window.contentView?.button(id: "sheet.tableddl.rowScope.ownRows") == nil,
               "no radios for a table with nothing below it")
    let include = window.contentView?.button(id: "sheet.tableddl.includeRows")
    expectTrue(include?.isEnabled == true, "rows can be copied from an ordinary table")
    expectTrue(sheet.selectedRowScope == .ownRows, "the scope falls back to the safe one")
}

func testPartitionedSourceCannotAskForRows() {
    let sheet = TableDDLSheet(schema: "s", table: "ev", ddl: ddl(partitionBy: "RANGE (seen)")) { _, _, _ in }
    let window = host(sheet)
    defer { window.close() }

    let include = window.contentView?.button(id: "sheet.tableddl.includeRows")
    expectTrue(include != nil, "the checkbox is present")
    expectTrue(include?.isEnabled == false, "rows are disabled for a partitioned source")
    expectTrue(include?.state == .off, "and it is off, not just greyed while ticked")
    expectTrue(window.contentView?.descendant(id: "sheet.tableddl.shapeNote") != nil,
               "the note explains the disabled checkbox")
}

func testScopeRadiosFollowTheCheckbox() {
    let sheet = TableDDLSheet(schema: "s", table: "lg", ddl: ddl(hasChildTables: true)) { _, _, _ in }
    let window = host(sheet)
    defer { window.close() }

    let own = window.contentView?.button(id: "sheet.tableddl.rowScope.ownRows")
    let tree = window.contentView?.button(id: "sheet.tableddl.rowScope.wholeTree")
    expectTrue(own != nil && tree != nil, "both scopes are offered")
    expectTrue(own?.state == .on && tree?.state == .off, "the safe scope is the default")

    // Rows are not being copied yet, so the choice is not live.
    expectTrue(own?.isEnabled == false, "the radios start disabled")

    // performClick toggles the state AND sends the action, which is what a
    // real click does — the enablement must come from the wiring, not from
    // the test setting it.
    let include = window.contentView?.button(id: "sheet.tableddl.includeRows")
    include?.performClick(nil)
    expectTrue(include?.state == .on, "the click ticked it")
    expectTrue(own?.isEnabled == true, "ticking the checkbox makes the choice live")

    include?.performClick(nil)
    expectTrue(include?.state == .off, "the second click unticked it")
    expectTrue(own?.isEnabled == false, "unticking it takes the choice away again")
}

func testTheChosenScopeReachesTheCallback() {
    var seen: (name: String, include: Bool, scope: CloneRowScope)?
    let sheet = TableDDLSheet(schema: "s", table: "lg", ddl: ddl(hasChildTables: true)) { name, include, scope in
        seen = (name, include, scope)
    }
    let window = host(sheet)
    defer { window.close() }

    window.contentView?.button(id: "sheet.tableddl.includeRows")?.performClick(nil)

    // Choose the big one the way a click does: the group turns the others off.
    let own = window.contentView?.button(id: "sheet.tableddl.rowScope.ownRows")
    let tree = window.contentView?.button(id: "sheet.tableddl.rowScope.wholeTree")
    tree?.performClick(nil)
    expectTrue(own?.state == .off, "the radios are one group")
    expectTrue(sheet.selectedRowScope == .wholeTree, "the sheet reads the chosen scope")

    (window.contentView?.button(id: "sheet.tableddl.default"))?.performClick(nil)
    expectTrue(seen?.include == true, "the callback is told rows are wanted")
    expectTrue(seen?.scope == .wholeTree, "the callback carries the CHOSEN scope, not the default")
    expectEqual(seen?.name ?? "", "lg_copy", "the seeded name comes through")
}
