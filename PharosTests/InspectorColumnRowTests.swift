// Standalone tests for the Inspector's Columns section row.
//
// The schema browser's rows are one line each now and no longer spell a
// column's type out beside its name, so this row is where a reader goes for it.
// Two things have to hold: the row states the type and the markers, and its
// context menu puts a usable identifier on the pasteboard — the RAW name for
// "Copy Name", and the QUOTED three-part name for "Copy Qualified Name", so a
// hostile identifier cannot break out of the query it is pasted into.
//
// Compiled by scripts/test-inspector-column-row.sh.
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

private func column(
    _ name: String, _ type: String, pk: Bool = false, nullable: Bool = true
) -> ColumnInfo {
    ColumnInfo(name: name, dataType: type, isNullable: nullable,
               isPrimaryKey: pk, ordinalPosition: 1, columnDefault: nil)
}

/// Lay the row out at `width`, the way the Inspector's stack view does: the
/// row is pinned inside a host of that width. Laying out a bare root view
/// instead leaves its own width unconstrained, and the labels then resolve to
/// sizes the real pane would never give them.
private func layout(_ row: ColumnRowView, width: CGFloat) {
    let host = NSView(frame: NSRect(x: 0, y: 0, width: width, height: 24))
    row.translatesAutoresizingMaskIntoConstraints = false
    host.addSubview(row)
    NSLayoutConstraint.activate([
        row.leadingAnchor.constraint(equalTo: host.leadingAnchor),
        row.trailingAnchor.constraint(equalTo: host.trailingAnchor),
        row.topAnchor.constraint(equalTo: host.topAnchor),
    ])
    host.layoutSubtreeIfNeeded()
}

/// The rect Auto Layout actually placed. An NSTextField label's FRAME sits a
/// couple of points outside its alignment rect on each side (room for a focus
/// ring it never draws), so a frame-based edge test reports an overflow that
/// is not there.
private func placed(_ view: NSView) -> NSRect {
    view.alignmentRect(forFrame: view.frame)
}

private func pasteboardAfter(_ action: () -> Void) -> String {
    NSPasteboard.general.clearContents()
    action()
    return NSPasteboard.general.string(forType: .string) ?? "(nothing)"
}

// MARK: - Tests

func runTests() {
    let row = ColumnRowView(
        schema: "public", table: "orders",
        column: column("created_at", "timestamp with time zone", pk: false, nullable: false))
    layout(row, width: 260)

    // --- What the row says ---
    expectEqual(row.nameLabel.stringValue, "created_at", "the row names the column")
    expectEqual(row.typeLabel.stringValue, "timestamp with time zone", "the row states the type")
    expectEqual(row.markerLabel.stringValue, "NOT NULL", "a non-nullable column is marked")
    expectTrue(row.typeLabel.font?.isFixedPitch == true, "the type column is monospaced")
    expectTrue(row.typeLabel.alignment == .right,
               "the types are right-aligned, so they line up down the list")

    let pkRow = ColumnRowView(
        schema: "public", table: "orders",
        column: column("id", "bigint", pk: true, nullable: false))
    expectEqual(pkRow.markerLabel.stringValue, "PK \u{00B7} NOT NULL",
                "a primary key carries both markers")
    let plain = ColumnRowView(
        schema: "public", table: "orders", column: column("note", "text"))
    expectTrue(plain.markerLabel.isHidden, "a plain nullable column has no markers")

    // --- The type keeps its floor when the name is long ---
    let long = ColumnRowView(
        schema: "public", table: "orders",
        column: column("customer_subscription_renewal_reminder_sent_at_utc", "timestamp with time zone"))
    layout(long, width: 220)
    expectTrue(long.typeLabel.frame.width >= ColumnRowView.minimumTypeWidth - 0.5,
               "the type keeps at least \(Int(ColumnRowView.minimumTypeWidth)) pt — "
                   + "got \(long.typeLabel.frame.width)")
    expectTrue(long.nameLabel.frame.width < long.nameLabel.intrinsicContentSize.width,
               "the name truncates first")
    expectTrue(placed(long.nameLabel).minX >= -0.5 && placed(long.typeLabel).maxX <= 220.5,
               "the row stays inside its width — name \(placed(long.nameLabel)) "
                   + "type \(placed(long.typeLabel))")

    // --- The context menu ---
    let menu = row.menu(for: NSEvent())
    expectEqual(menu?.items.count ?? 0 == 2 ? "2" : "\(menu?.items.count ?? 0)", "2",
                "two menu items")
    expectEqual(menu?.items.first?.title ?? "(none)", "Copy Name", "first item is Copy Name")
    expectEqual(menu?.items.last?.title ?? "(none)", "Copy Qualified Name",
                "second item is Copy Qualified Name")

    // --- What they copy ---
    expectEqual(pasteboardAfter { row.copyName() }, "created_at",
                "Copy Name puts the bare name on the pasteboard")
    expectEqual(pasteboardAfter { row.copyQualifiedName() },
                "\"public\".\"orders\".\"created_at\"",
                "Copy Qualified Name puts the quoted three-part name on the pasteboard")

    // --- A hostile identifier stays one identifier ---
    let hostile = ColumnRowView(
        schema: "public", table: "orders",
        column: column("a\"; DROP TABLE x; --", "text"))
    expectEqual(pasteboardAfter { hostile.copyQualifiedName() },
                "\"public\".\"orders\".\"a\"\"; DROP TABLE x; --\"",
                "an embedded quote is doubled, so the name cannot break out")
    // The RAW name is copied, not the escaped display string: an analyst pastes
    // this into a query, and "<U+202E>" is not an identifier.
    expectEqual(pasteboardAfter { hostile.copyName() }, "a\"; DROP TABLE x; --",
                "Copy Name copies the raw name, not the display escaping")

    // --- VoiceOver reads the whole row, not just the name ---
    let spoken = row.accessibilityLabel() ?? "(none)"
    expectTrue(spoken.contains("created_at") && spoken.contains("timestamp")
                   && spoken.contains("NOT NULL"),
               "the row reads out name, type and markers — got \(spoken)")

    print(failures == 0 ? "\nAll tests passed" : "\n\(failures) test(s) failed")
    exit(failures == 0 ? 0 : 1)
}
