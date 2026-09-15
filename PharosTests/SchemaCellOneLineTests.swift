// Standalone tests for the schema browser's one-line row cell.
//
// The outline view is a system source list now, so its row height comes from
// the user's "Sidebar icon size" setting rather than from this app — measured
// at 24, 28 and 32 points. The cell has to hold icon, name, caption and pill on
// ONE line at every one of them, and when the name is too long to fit it is the
// NAME that truncates: a column's type is only written in this one place, so
// losing it loses the information the row carried.
//
// Compiled by scripts/test-schema-cell-one-line.sh.
import AppKit

private var failures = 0

private func expectTrue(_ actual: Bool, _ name: String) {
    if actual { print("PASS \(name)") } else {
        failures += 1
        print("FAIL \(name)")
    }
}

private func expectEqual(_ actual: String, _ expected: String, _ name: String) {
    if actual == expected { print("PASS \(name)") } else {
        failures += 1
        print("FAIL \(name)\n  expected: \(expected.debugDescription)\n  actual:   \(actual.debugDescription)")
    }
}

// MARK: - Harness

private let longColumnName = "customer_subscription_renewal_reminder_sent_at_utc_timestamp"
private let longType = "timestamp with time zone"

private func makeColumnNode(name: String, type: String) -> SchemaTreeNode {
    SchemaTreeNode(.column(ColumnInfo(
        name: name, dataType: type, isNullable: false,
        isPrimaryKey: false, ordinalPosition: 1, columnDefault: nil
    )))
}

private func makeTableNode(
    name: String, rows: Int64?, bytes: Int64?
) -> SchemaTreeNode {
    let info = TableInfo(
        name: name, schemaName: "public", tableType: .table,
        rowCountEstimate: rows, totalSizeBytes: bytes,
        isPartitioned: false, isPartition: false,
        partitionStrategy: nil, partitionKey: nil,
        partitionBound: nil, partitionCount: nil
    )
    let node = SchemaTreeNode(.table(info))
    node.hasRowCount = rows != nil
    return node
}

/// Lay the cell out at `width` × `height`, the way the outline view would.
private func layout(_ cell: SchemaTreeCellView, width: CGFloat, height: CGFloat) {
    cell.frame = NSRect(x: 0, y: 0, width: width, height: height)
    cell.layoutSubtreeIfNeeded()
}

/// The rect Auto Layout actually placed. An NSTextField label's FRAME sits a
/// couple of points outside its alignment rect on each side (room for a focus
/// ring it never draws), so a frame-based edge test reports an overflow that is
/// not there — and, worse, passes a real one by the same margin.
private func placed(_ view: NSView) -> NSRect {
    view.alignmentRect(forFrame: view.frame)
}

/// How wide the label needs to be for its full text — anything less truncates.
private func intrinsicWidth(_ label: NSTextField) -> CGFloat {
    label.intrinsicContentSize.width
}

private func isTruncated(_ label: NSTextField) -> Bool {
    placed(label).width + 0.5 < intrinsicWidth(label)
}

// MARK: - Tests

func runTests() {
    let sidebarWidth: CGFloat = 240

    for height in [CGFloat(24), 28, 32] {
        let cell = SchemaTreeCellView(identifier: NSUserInterfaceItemIdentifier("cell"))
        cell.configure(node: makeColumnNode(name: longColumnName, type: longType))
        layout(cell, width: sidebarWidth, height: height)

        let name = cell.nameLabelForTesting
        let caption = cell.captionLabelForTesting

        // --- One line: both labels share a row, neither leaves it ---
        expectTrue(placed(name).height <= height && placed(name).minY >= -0.5
                       && placed(name).maxY <= height + 0.5,
                   "h=\(Int(height)): the name stays inside the row")
        expectTrue(placed(caption).height <= height && placed(caption).minY >= -0.5
                       && placed(caption).maxY <= height + 0.5,
                   "h=\(Int(height)): the caption stays inside the row")
        expectTrue(abs(placed(name).midY - placed(caption).midY) < height,
                   "h=\(Int(height)): name and caption are on the same line, not stacked")
        expectTrue(placed(cell.iconViewForTesting).maxY <= height + 0.5,
                   "h=\(Int(height)): the icon stays inside the row")

        // --- Nothing overflows sideways either ---
        expectTrue(placed(caption).maxX <= sidebarWidth + 0.5,
                   "h=\(Int(height)): nothing runs past the trailing edge — "
                       + "\(placed(caption))")
        expectTrue(placed(name).minX >= placed(cell.iconViewForTesting).maxX - 0.5,
                   "h=\(Int(height)): the name starts after the icon")

        // --- The name yields, the type does not ---
        expectTrue(isTruncated(name),
                   "h=\(Int(height)): a name too long for the row truncates")
        expectTrue(placed(caption).width >= SchemaTreeCellView.minimumCaptionWidth - 0.5,
                   "h=\(Int(height)): the type keeps at least "
                       + "\(Int(SchemaTreeCellView.minimumCaptionWidth)) pt — got \(placed(caption).width)")
        expectTrue(placed(caption).width > 0 && !caption.isHidden,
                   "h=\(Int(height)): the type is still on the row")
    }

    // --- A short name leaves the type its full width ---
    // A wider sidebar than the 240 above: "timestamp with time zone, NOT NULL"
    // alone is ~190 pt, so at 240 the row is genuinely full and the caption is
    // entitled to clip. This check is about what happens when there IS room.
    let roomy = SchemaTreeCellView(identifier: NSUserInterfaceItemIdentifier("cell"))
    roomy.configure(node: makeColumnNode(name: "id", type: longType))
    layout(roomy, width: 340, height: 28)
    expectTrue(!isTruncated(roomy.nameLabelForTesting),
               "a short name is not truncated")
    expectTrue(!isTruncated(roomy.captionLabelForTesting),
               "with room to spare the type is written out in full — caption "
                   + "\(placed(roomy.captionLabelForTesting).width) of "
                   + "\(intrinsicWidth(roomy.captionLabelForTesting))")

    // --- The caption says what the column is ---
    expectEqual(roomy.captionLabelForTesting.stringValue, "\(longType), NOT NULL",
                "the caption carries the type and the markers")

    // --- No caption: the name gets the whole row, no reserved gap ---
    // A long name, because the point is that the caption's 60 pt floor is NOT
    // held open on a row that has no caption to put in it.
    let schemaCell = SchemaTreeCellView(identifier: NSUserInterfaceItemIdentifier("cell"))
    schemaCell.configure(node: SchemaTreeNode(
        .schema(SchemaInfo(name: "tenant_0f3a9c21_reporting_warehouse", owner: nil))))
    layout(schemaCell, width: 240, height: 28)
    expectTrue(schemaCell.captionLabelForTesting.isHidden,
               "a schema row has no caption")
    expectTrue(placed(schemaCell.nameLabelForTesting).maxX > 200,
               "with no caption the name runs to the trailing edge, no 60 pt gap "
                   + "held open — got \(placed(schemaCell.nameLabelForTesting).maxX)")

    // --- A table's exact figures moved to the tooltip ---
    let table = makeTableNode(name: "events", rows: 1_234_567, bytes: 92_274_688)
    let tableCell = SchemaTreeCellView(identifier: NSUserInterfaceItemIdentifier("cell"))
    tableCell.configure(node: table)
    layout(tableCell, width: 240, height: 28)
    let tip = tableCell.toolTip ?? "(none)"
    expectTrue(tip.contains("rows") && tip.contains("\u{00B7}"),
               "the tooltip carries both the row count and the size — got \(tip)")
    expectTrue(tip.contains("567"),
               "the tooltip carries the EXACT row count, not the row's abbreviation — got \(tip)")
    expectEqual(tableCell.captionLabelForTesting.stringValue, "1.2M rows",
                "the row itself keeps the short form")

    // A table with neither figure has nothing to say in a tooltip.
    let bare = SchemaTreeCellView(identifier: NSUserInterfaceItemIdentifier("cell"))
    bare.configure(node: makeTableNode(name: "empty", rows: nil, bytes: nil))
    expectTrue(bare.toolTip == nil, "no figures, no tooltip")

    // --- Reuse does not carry a previous row's tooltip or pill ---
    tableCell.prepareForReuse()
    expectTrue(tableCell.toolTip == nil, "prepareForReuse clears the tooltip")
    expectTrue(tableCell.badgeLabelForTesting.isHidden, "prepareForReuse clears the pill")

    print(failures == 0 ? "\nAll tests passed" : "\n\(failures) test(s) failed")
    exit(failures == 0 ? 0 : 1)
}
