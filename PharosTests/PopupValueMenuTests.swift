// Standalone tests for PopupValueMenu — the build-and-read-back rule for a
// popup whose titles are escaped for display and whose real values ride along
// in `representedObject`. Uses real NSPopUpButton/NSMenuItem objects; no window.
import AppKit

private var failures = 0

private func expectEqual<T: Equatable>(_ actual: T, _ expected: T, _ name: String) {
    if actual == expected { print("PASS \(name)") } else {
        failures += 1
        print("FAIL \(name)\n  expected: \(expected)\n  actual:   \(actual)")
    }
}

private func makePopup(_ items: [(title: String, value: String?)]) -> NSPopUpButton {
    let popup = NSPopUpButton(frame: .zero, pullsDown: false)
    popup.removeAllItems()
    for item in items {
        popup.addItem(withTitle: item.title)
        popup.lastItem?.representedObject = item.value
    }
    return popup
}

private func newPopup() -> NSPopUpButton {
    NSPopUpButton(frame: .zero, pullsDown: false)
}

/// Every value the popup offers, in row order, sentinel included as nil.
private func valuesByRow(_ popup: NSPopUpButton) -> [String?] {
    popup.itemArray.map { $0.representedObject as? String }
}

private func testReadBack() {
    // The value comes from representedObject, never from the displayed title —
    // that is the whole point: the title is escaped and the value is not.
    let popup = makePopup([
        (title: "None", value: nil),
        (title: "public", value: "public"),
        (title: "sales<U+200B>", value: "sales\u{200B}"),
    ])

    popup.selectItem(at: 1)
    expectEqual(PopupValueMenu.selectedValue(in: popup), "public",
                "an ordinary selection returns its raw value")

    popup.selectItem(at: 2)
    expectEqual(PopupValueMenu.selectedValue(in: popup), "sales\u{200B}",
                "a hostile selection returns the RAW value, not the escaped title")

    popup.selectItem(at: 0)
    expectEqual(PopupValueMenu.selectedValue(in: popup), nil,
                "a sentinel row carries no value")

    // A row whose value was never set must not fall back to its title: a silent
    // fallback is how the escaped string would reach the store.
    let unset = newPopup()
    unset.addItem(withTitle: "public\u{200B}")
    unset.selectItem(at: 0)
    expectEqual(PopupValueMenu.selectedValue(in: unset), nil,
                "no representedObject means no value — never the title")

    let empty = newPopup()
    empty.removeAllItems()
    expectEqual(PopupValueMenu.selectedValue(in: empty), nil,
                "an empty popup has no value")
}

private func testSentinelCollision() {
    // A schema literally named "None" collides with the "None" sentinel.
    // `NSPopUpButton.addItem(withTitle:)` would DELETE the sentinel here,
    // leaving 2 rows for 2 values and throwing every index off by one — a
    // saved default of "None" then displayed and stored "public".
    // `CREATE SCHEMA "None"` is legal, so this is reachable.
    let popup = newPopup()
    PopupValueMenu.populate(popup, sentinel: "None", values: ["None", "public"])

    expectEqual(popup.numberOfItems, 3,
                "a value equal to the sentinel text does not delete the sentinel")
    expectEqual(valuesByRow(popup), [nil, "None", "public"],
                "the sentinel keeps row 0 and each value keeps its own row")

    popup.selectItem(at: 1)
    expectEqual(PopupValueMenu.selectedValue(in: popup), "None",
                "the row titled None returns the schema None, not the sentinel")
    popup.selectItem(at: 2)
    expectEqual(PopupValueMenu.selectedValue(in: popup), "public",
                "the row after a sentinel collision is not shifted")
}

private func testEscapedTitleCollision() {
    // Two DISTINCT values whose ESCAPED titles are identical: one holds a real
    // zero-width space, the other is literally named "public<U+200B>". Escaping
    // is what makes them collide, so this only became reachable once titles
    // were escaped — and `representedObject` cannot rescue a row that AppKit
    // has already deleted.
    let hostile = "public\u{200B}"
    let literal = "public<U+200B>"
    expectEqual(DisplayEscape.escaped(hostile), literal,
                "the two values really do share one escaped title")

    let popup = newPopup()
    PopupValueMenu.populate(popup, sentinel: nil, values: [hostile, literal])

    expectEqual(popup.numberOfItems, 2,
                "two values with one escaped title keep two rows")
    expectEqual(valuesByRow(popup), [hostile, literal],
                "each colliding row still carries its own raw value")

    popup.selectItem(at: 0)
    expectEqual(PopupValueMenu.selectedValue(in: popup), hostile,
                "the first colliding row returns the zero-width value")
    popup.selectItem(at: 1)
    expectEqual(PopupValueMenu.selectedValue(in: popup), literal,
                "the second colliding row returns the literal value")
}

private func testRowCountMatchesValueCount() {
    // The invariant the index arithmetic used to assume, now asserted directly.
    let values = ["a", "a", "a", "b"]

    let withSentinel = newPopup()
    PopupValueMenu.populate(withSentinel, sentinel: "None", values: values)
    expectEqual(withSentinel.numberOfItems, values.count + 1,
                "with a sentinel the row count is values.count + 1")

    let without = newPopup()
    PopupValueMenu.populate(without, sentinel: nil, values: values)
    expectEqual(without.numberOfItems, values.count,
                "without a sentinel the row count is values.count")

    // Populate is a replace, not an append: a second call must not stack rows.
    PopupValueMenu.populate(without, sentinel: nil, values: ["only"])
    expectEqual(without.numberOfItems, 1, "populate replaces the previous rows")
}

private func testSelectValueRoundTrip() {
    let hostile = "sales\u{200B}"
    let popup = newPopup()
    PopupValueMenu.populate(popup, sentinel: "None", values: ["public", hostile])

    PopupValueMenu.selectValue(hostile, in: popup)
    expectEqual(PopupValueMenu.selectedValue(in: popup), hostile,
                "selectValue round-trips a hostile value by value, not by index")

    PopupValueMenu.selectValue("public", in: popup)
    expectEqual(PopupValueMenu.selectedValue(in: popup), "public",
                "selectValue finds an ordinary value")

    // An absent value must not move the selection: a connection whose saved
    // schema has since been dropped keeps whatever the popup already showed,
    // rather than silently landing on a different schema.
    PopupValueMenu.selectValue("dropped_schema", in: popup)
    expectEqual(PopupValueMenu.selectedValue(in: popup), "public",
                "an absent value leaves the selection unchanged")

    PopupValueMenu.selectValue(nil, in: popup)
    expectEqual(PopupValueMenu.selectedValue(in: popup), "public",
                "a nil value leaves the selection unchanged")

    // Selecting by value never picks the sentinel, whose value is nil.
    expectEqual(popup.indexOfSelectedItem, 1,
                "selectValue never lands on the sentinel row")
}

private func testRowsCarryDisplayValueAndImageSeparately() {
    // A tag popup shows a tag's NAME but stores its ID, so display and value
    // are different strings. The helper escapes `display` and never touches
    // `value` — the caller does not get to decide either.
    let swatch = NSImage(size: NSSize(width: 8, height: 8))
    let popup = newPopup()
    PopupValueMenu.populate(popup, sentinel: nil, rows: [
        PopupValueMenu.Row(display: "safe\u{202E}gpj.exe", value: "id-1", image: swatch),
    ])
    expectEqual(popup.itemArray[0].title, "safe<U+202E>gpj.exe",
                "the row's display text is escaped by the helper, not the caller")
    expectEqual(popup.itemArray[0].representedObject as? String, "id-1",
                "the row's value is independent of its display text")
    expectEqual(popup.itemArray[0].image === swatch, true,
                "the row keeps the image it was given")
}

private func testSentinelSurvivesARowDisplayedLikeIt() {
    // THE REGRESSION. A tag named literally "New tag" collided with the
    // sentinel, AppKit's `addItem(withTitle:)` deleted the sentinel row, and
    // `isNew` could never be true again — so the user could never create
    // another tag. Plain ASCII; no hostile input required.
    let popup = newPopup()
    PopupValueMenu.populate(popup, sentinel: "New tag", sentinelTag: 7, rows: [
        PopupValueMenu.Row(display: "New tag", value: "tag-1"),
        PopupValueMenu.Row(display: "Other", value: "tag-2"),
    ])
    expectEqual(popup.numberOfItems, 3,
                "a row displayed exactly like the sentinel does not delete it")
    expectEqual(valuesByRow(popup), [nil, "tag-1", "tag-2"],
                "every row keeps its own value")
    expectEqual(popup.itemArray[0].tag, 7,
                "the sentinel is identified positively, by its tag")
    expectEqual(popup.itemArray[1].tag, 0,
                "a value row carries no sentinel tag")
    popup.selectItem(at: 1)
    expectEqual(PopupValueMenu.selectedValue(in: popup), "tag-1",
                "selecting the colliding row returns ITS value, not the sentinel's nil")
}

private func testTwoRowsWithCollidingEscapedTitlesBothSurvive() {
    // Escaping is not injective: a real zero-width space and the literal text
    // `<U+200B>` produce one title. Neither row may disappear.
    let popup = newPopup()
    PopupValueMenu.populate(popup, sentinel: nil, rows: [
        PopupValueMenu.Row(display: "foo\u{200B}", value: "id-a"),
        PopupValueMenu.Row(display: "foo<U+200B>", value: "id-b"),
    ])
    expectEqual(popup.itemArray[0].title, popup.itemArray[1].title,
                "the two titles really are identical — the collision is real")
    expectEqual(popup.numberOfItems, 2,
                "two rows whose escaped titles collide both survive")
    expectEqual(valuesByRow(popup), ["id-a", "id-b"],
                "each collided row keeps its own value")
}

private func testIsSentinelDecidesTheMode() {
    // The mode rule TagSheet branches on. It has no harness of its own, so the
    // rule lives here where it can be tested.
    let popup = newPopup()
    PopupValueMenu.populate(popup, sentinel: "New tag", sentinelTag: 1, rows: [
        PopupValueMenu.Row(display: "Case Alpha", value: "tag-1"),
    ])
    expectEqual(PopupValueMenu.isSentinel(popup.itemArray[0], tag: 1), true,
                "the sentinel row is the sentinel")
    expectEqual(PopupValueMenu.isSentinel(popup.itemArray[1], tag: 1), false,
                "a value row is not the sentinel")
    // The state the first version of this fix got wrong: no selection must fall
    // to the SAME side as the sentinel, or the sheet shows "add to existing"
    // with its fields disabled while the save path creates a new tag.
    expectEqual(PopupValueMenu.isSentinel(nil, tag: 1), true,
                "no selection counts as the sentinel, not as a value row")
}

private func testEmptyRowsIsWellDefined() {
    let withSentinel = newPopup()
    PopupValueMenu.populate(withSentinel, sentinel: "None", rows: [])
    expectEqual(withSentinel.numberOfItems, 1, "a sentinel and no rows is one item")
    expectEqual(PopupValueMenu.selectedValue(in: withSentinel), nil,
                "the sentinel still carries no value")

    let bare = newPopup()
    PopupValueMenu.populate(bare, sentinel: nil, rows: [])
    expectEqual(bare.numberOfItems, 0, "no sentinel and no rows is an empty popup")
    expectEqual(PopupValueMenu.selectedValue(in: bare), nil,
                "an empty popup has no value")
}

func runTests() {
    testReadBack()
    testSentinelCollision()
    testEscapedTitleCollision()
    testRowCountMatchesValueCount()
    testSelectValueRoundTrip()
    testRowsCarryDisplayValueAndImageSeparately()
    testSentinelSurvivesARowDisplayedLikeIt()
    testTwoRowsWithCollidingEscapedTitlesBothSurvive()
    testIsSentinelDecidesTheMode()
    testEmptyRowsIsWellDefined()

    if failures == 0 { print("\nAll tests passed.") } else {
        print("\n\(failures) failure(s).")
        exit(1)
    }
}
