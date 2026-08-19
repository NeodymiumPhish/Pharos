// Standalone test runner for TagRemovalSheet. Uses real AppKit: the sheet is
// hosted in a headless, never-shown NSWindow so Auto Layout runs, and the real
// checkboxes are driven with performClick.
// Compiled with TagRemovalSheet.swift, TagRemovalModel.swift, TagPalette.swift
// and the tag models by scripts/test-tag-removal-sheet.sh.
//
// What this suite is FOR: the sheet's whole reason to exist is disclosure. It
// must show every value of every tuple it is about to delete, it must never
// truncate one, its footer must state a reach that matches the list above it,
// and the ids it commits must be the ones still ticked. Each of those is a
// property an ordinary-looking edit can silently break, so each is asserted
// here rather than left to a manual pass.
import AppKit

// MARK: - Recording remover

/// The sheet commits through `TagTupleRemoving`, which it declares itself, so
/// this suite supplies its own conformer and the real `TagStore` — `@MainActor`
/// and Keychain-bound through the FFI — stays out of the binary entirely.
/// Same shape as `QueryErrorSheetTests`' `SpyDelegate`.
///
/// This is a conformer, NOT a stand-in for the store: `TagStore` conforms in
/// `TagStore.swift`, so if `removeTuples(ids:)` ever changes shape the app
/// build fails rather than this suite passing against something that no longer
/// matches the real store.
private final class RecordingRemover: TagTupleRemoving {
    private(set) var removed: [[String]] = []
    /// Set to make the next commit throw, standing in for a Rust-side failure.
    var failure: Error?

    func removeTuples(ids: [String]) throws {
        if let failure { throw failure }
        removed.append(ids)
    }
}

private struct StoreFailure: Error {}

// MARK: - Assertions

private var failures = 0

private func expectString(_ actual: String, _ expected: String, _ name: String) {
    if actual == expected { print("PASS \(name)") } else {
        failures += 1
        print("FAIL \(name)\n  expected: \(expected.debugDescription)\n  actual:   \(actual.debugDescription)")
    }
}

private func expectTrue(_ actual: Bool, _ name: String) {
    if actual { print("PASS \(name)") } else { failures += 1; print("FAIL \(name) — expected true") }
}

private func expectInt(_ actual: Int, _ expected: Int, _ name: String) {
    expectString("\(actual)", "\(expected)", name)
}

// MARK: - View-tree walking

// The sheet builds its list in code with no outlets, so the assertions read
// the real view tree — which is also what proves the labels exist at all.

private func descendants(_ view: NSView) -> [NSView] {
    view.subviews.flatMap { [$0] + descendants($0) }
}

/// The checkboxes, in list order: the buttons inside the LIST, which is what
/// they are. Not "the buttons with no title" — Cancel and Remove would join
/// that set the moment either lost its title, silently shifting every index in
/// the assertions below. (The accessibility role would be the most semantic
/// filter, but it is not populated in a headless process — measured: it
/// returned no checkboxes at all.)
private func checkboxes(_ root: NSView) -> [NSButton] {
    guard let scroll = descendants(root).compactMap({ $0 as? NSScrollView }).first,
          let document = scroll.documentView else { return [] }
    return descendants(document).compactMap { $0 as? NSButton }
}

private func labels(_ root: NSView) -> [NSTextField] {
    descendants(root).compactMap { $0 as? NSTextField }
}

private func footerText(_ root: NSView) -> String {
    labels(root).first { $0.stringValue.hasPrefix("Removes ")
        || $0.stringValue.hasPrefix("Nothing selected") }?.stringValue ?? "<no footer>"
}

/// The destructive button. A mutation that renames or removes it must fail an
/// assertion naming it, not crash the binary on a force-unwrap: a trap prints
/// no FAIL line and says nothing about what broke.
private func removeButton(_ root: NSView) -> NSButton {
    if let button = (descendants(root).compactMap { $0 as? NSButton }
        .first { $0.title.hasPrefix("Remove ") }) {
        return button
    }
    failures += 1
    print("FAIL there is no button titled 'Remove …' in the sheet")
    return NSButton(title: "<missing>", target: nil, action: nil)
}

/// The Cancel button, by the same rule.
private func cancelButton(_ root: NSView) -> NSButton {
    if let button = (descendants(root).compactMap { $0 as? NSButton }
        .first { $0.title == "Cancel" }) {
        return button
    }
    failures += 1
    print("FAIL there is no button titled 'Cancel' in the sheet")
    return NSButton(title: "<missing>", target: nil, action: nil)
}

/// The group headers, in list order: the bold name labels beside the swatches.
private func headers(_ root: NSView) -> [NSTextField] {
    descendants(root).compactMap { $0 as? NSStackView }
        .filter { stack in
            stack.views.count == 2 && stack.views.first is NSImageView
                && stack.views.last is NSTextField
        }
        .compactMap { $0.views.last as? NSTextField }
}

/// The tuple ROWS, in list order: the list's own arranged subviews that hold a
/// checkbox. Not "every stack in the list" — the group header and each tuple's
/// inner value stack would join that set, and their edges are not the ones
/// being measured.
private func rows(_ root: NSView) -> [NSStackView] {
    guard let scroll = descendants(root).compactMap({ $0 as? NSScrollView }).first,
          let document = scroll.documentView as? NSStackView else { return [] }
    return document.arrangedSubviews
        .compactMap { $0 as? NSStackView }
        .filter { row in descendants(row).contains { $0 is NSButton } }
}

/// Where a view's content is DRAWN, in `container`'s coordinates.
///
/// The frame alone would not answer the question this suite asks: an
/// NSTextField's frame overhangs its text by its alignment-rect inset, so a
/// label and a checkbox that line up on screen report different `frame.minX`.
/// Adding the inset back gives the edge a reader actually sees.
private func drawnLeading(_ view: NSView, in container: NSView) -> CGFloat {
    view.convert(view.bounds, to: container).minX + view.alignmentRectInsets.left
}

/// Every label the LIST holds, in the order the list holds them — headers,
/// value lines and captions alike. Order is disclosure here: a header names
/// the tuples that follow it.
private func listLines(_ root: NSView) -> [String] {
    guard let scroll = descendants(root).compactMap({ $0 as? NSScrollView }).first,
          let document = scroll.documentView else { return [] }
    return descendants(document).compactMap { ($0 as? NSTextField)?.stringValue }
}

// MARK: - Fixtures

/// `normalized` defaults to the captured text, so an unqualified fixture is a
/// value whose reach is exactly what it shows and which therefore draws no
/// second line. The cases where the two DIFFER pass it explicitly — the
/// default must never be able to hide a missing disclosure.
private func value(_ column: String, _ display: String,
                   normalized: String? = nil) -> TagRemovalValue {
    TagRemovalValue(column: column, display: display,
                    normalized: normalized ?? display)
}

private func tuple(_ id: String, _ values: [TagRemovalValue]) -> TagRemovalTuple {
    TagRemovalTuple(tupleId: id, values: values)
}

/// What a tuple's values WOULD join to, built here in the test because the
/// model no longer produces such a string anywhere. Used only to prove the
/// collision fixture is a genuine collision.
private func joined(_ t: TagRemovalTuple) -> String {
    t.values.map { "\($0.column): \($0.display)" }.joined(separator: "  +  ")
}

/// Hosting the view is what makes Auto Layout run; an unhosted view keeps
/// whatever frame its initializer gave it, and the width assertions below
/// would then measure the initializer's guess rather than the real list.
/// `contentViewController`, not `contentView`, so the controller's own
/// lifecycle runs as it does in the app.
private func host(_ sheet: TagRemovalSheet) -> NSWindow {
    let window = NSWindow(
        contentRect: NSRect(x: 0, y: 0, width: 480, height: 460),
        styleMask: [.borderless], backing: .buffered, defer: false)
    window.contentViewController = sheet
    sheet.view.layoutSubtreeIfNeeded()
    return window
}

func runTests() {
    // Two tags: one with two single-value tuples, one with a multi-value tuple.
    let groups = [
        TagRemovalGroup(tagId: "t1", tagName: "Case Alpha", colorIndex: 0, tuples: [
            tuple("u1", [value("ip", "10.0.0.1")]),
            tuple("u2", [value("md5", "D41D8C")]),
        ]),
        TagRemovalGroup(tagId: "t2", tagName: "Case Beta", colorIndex: 1, tuples: [
            tuple("u3", [value("ip", "10.0.0.2"), value("subject", "CN=evil")]),
        ]),
    ]
    let remover = RecordingRemover()
    let sheet = TagRemovalSheet(groups: groups, remover: remover)
    _ = host(sheet)
    let root = sheet.view

    // MARK: the list renders from `values`, one token per value

    let boxes = checkboxes(root)
    expectInt(boxes.count, 3, "one checkbox per tuple, none per value")
    // Everything below indexes into `boxes`. A mutation that changes the count
    // must fail the assertion above and stop here, not trap on an index — a
    // trap prints no FAIL line and names nothing.
    guard boxes.count == 3 else {
        print("\n\(failures) FAILURE(S) — cannot continue with \(boxes.count) checkboxes")
        exit(1)
    }
    expectTrue(boxes.allSatisfy { $0.state == .on }, "everything starts checked")

    let text = labels(root).map(\.stringValue)
    expectTrue(text.contains("ip: 10.0.0.1"), "a single value renders as its own label")
    expectTrue(text.contains("ip: 10.0.0.2"), "a multi-value tuple's first value is its own label")
    expectTrue(text.contains("subject: CN=evil"), "its second value is a separate label")
    expectTrue(!text.contains("ip: 10.0.0.2  +  subject: CN=evil"),
               "the joined title is never rendered as one line")
    expectInt(text.filter { $0.hasPrefix("Removed together") }.count, 1,
              "only the multi-value tuple carries the atomicity caption")
    expectString(boxes[2].accessibilityLabel() ?? "",
                 "ip: 10.0.0.2, subject: CN=evil",
                 "VoiceOver reads the multi-value tuple's values")

    // MARK: the group headers — WHICH TAG each block belongs to

    // A header is how the sheet discloses that a removal SPANS TAGS, the
    // second of the three understatements it exists to correct. Nothing else
    // in the list names the tag.
    let heads = headers(root)
    expectInt(heads.count, 2, "one header per tag, no more and no fewer")
    expectString(heads.map(\.stringValue).joined(separator: "|"), "Case Alpha|Case Beta",
                 "each header carries its OWN tag's name, in the store's order")
    expectString(heads.first?.toolTip ?? "", "Case Alpha",
                 "the header's tooltip carries the name in full")

    // Order is the disclosure: a header names the tuples BELOW it. Rendered
    // after its tuples instead, every header would label the next tag's block.
    expectString(listLines(root).joined(separator: " / "),
                 "Case Alpha / ip: 10.0.0.1 / md5: D41D8C / Case Beta / "
                    + "ip: 10.0.0.2 / subject: CN=evil / "
                    + "Removed together — a tuple matches only as a whole.",
                 "the list reads header, that tag's values, next header")

    // The swatch is the other half of the identification, and two tags with
    // the same colour would be indistinguishable at a glance.
    let swatches = descendants(root).compactMap { $0 as? NSImageView }
    expectInt(swatches.count, 2, "one swatch per header")
    // Same rule as the checkboxes above: a wrong count fails its own
    // assertion and stops, rather than trapping on an index and naming
    // nothing.
    guard swatches.count == 2 else {
        print("\n\(failures) FAILURE(S) — cannot continue with \(swatches.count) swatches")
        exit(1)
    }
    expectTrue(swatches[0].image !== swatches[1].image,
               "the two tags' swatches are different images — the colour identifies the tag")
    expectTrue(swatches[0].image === TagPalette.swatch(colorIndex: 0)
                && swatches[1].image === TagPalette.swatch(colorIndex: 1),
               "each header shows ITS OWN tag's colour")

    // MARK: footer, button and payload with everything checked

    expectString(footerText(root),
                 "Removes 3 tuples from 2 tags. The values stop matching in every result, on every connection — not only here.",
                 "the footer states reach with everything checked")
    expectString(removeButton(root).title, "Remove 3 Tuples", "the button counts the tuples")
    expectTrue(removeButton(root).isEnabled, "Remove is enabled with tuples checked")
    expectString(sheet.checkedTupleIds.joined(separator: ","), "u1,u2,u3",
                 "the commit's payload is every ticked tuple, in list order")

    // MARK: unchecking the only tuple of a tag drops that TAG from the count

    boxes[2].performClick(nil)
    expectString(footerText(root),
                 "Removes 2 tuples from 1 tag. The values stop matching in every result, on every connection — not only here.",
                 "an emptied tag stops being counted, and both words singularise")
    expectString(removeButton(root).title, "Remove 2 Tuples", "the button follows the list")
    expectString(sheet.checkedTupleIds.joined(separator: ","), "u1,u2",
                 "the unchecked tuple leaves the payload and the others stay")

    // MARK: one tuple left

    boxes[1].performClick(nil)
    expectString(footerText(root),
                 "Removes 1 tuple from 1 tag. The values stop matching in every result, on every connection — not only here.",
                 "one tuple, one tag, both singular")
    expectString(removeButton(root).title, "Remove 1 Tuple", "the button singularises too")
    expectString(sheet.checkedTupleIds.joined(separator: ","), "u1",
                 "the payload is the one tuple still ticked")

    // MARK: nothing checked

    boxes[0].performClick(nil)
    expectString(footerText(root), "Nothing selected. Nothing will be removed.",
                 "no 'Removes 0 tuples from 0 tags' non-sentence")
    expectTrue(!removeButton(root).isEnabled, "Remove disables when nothing is checked")
    expectTrue(sheet.checkedTupleIds.isEmpty, "an empty list commits nothing")

    // A disabled button is the guard a user meets; `removeChecked` refusing an
    // empty payload is the guard BEHIND it, and only that second one is
    // asserted here. `performClick` on a disabled button does nothing at all,
    // so the button is forced enabled first — otherwise this would silently
    // re-assert the enablement rule above it and never reach the guard.
    let beforeEmptyCommit = remover.removed.count
    removeButton(root).isEnabled = true
    removeButton(root).performClick(nil)
    expectInt(remover.removed.count, beforeEmptyCommit,
              "an empty payload is refused even if the button is somehow enabled")

    // MARK: the commit sends exactly what is ticked

    boxes[0].performClick(nil)
    boxes[2].performClick(nil)
    expectString(footerText(root),
                 "Removes 2 tuples from 2 tags. The values stop matching in every result, on every connection — not only here.",
                 "re-checking across both tags restores a two-tag reach")
    removeButton(root).performClick(nil)
    expectString((remover.removed.last ?? []).joined(separator: ","), "u1,u3",
                 "the store is sent the ticked tuples only — not the whole list")

    // MARK: a failing commit keeps the sheet up

    // The observable is the ERROR ALERT: a commit that fails in Rust must say
    // so, not just write an NSLog and look like it worked. `beginSheetModal`
    // attaches the alert to the sheet's window even on a window that was never
    // shown, so the attachment is what this reads. (Whether the sheet then
    // stays up is NOT observable here — `dismiss(nil)` is a no-op on a
    // controller that was never presented — so it stays a manual check.)
    let failingRemover = RecordingRemover()
    failingRemover.failure = StoreFailure()
    let failing = TagRemovalSheet(groups: groups, remover: failingRemover)
    let failingWindow = host(failing)
    expectInt(failingWindow.sheets.count, 0, "a fresh sheet has no alert on it")
    removeButton(failing.view).performClick(nil)
    expectInt(failingWindow.sheets.count, 1,
              "a commit that fails in Rust raises an error alert, never a silent no-op")

    // MARK: a value holding the separator stays one token

    // Two tuples whose joined TITLES are byte-identical. Only `values` tells
    // them apart, which is why the sheet may never render `title`.
    let colliding = [
        TagRemovalGroup(tagId: "t3", tagName: "Case Gamma", colorIndex: 2, tuples: [
            tuple("u4", [value("note", "a  +  b: c")]),
            tuple("u5", [value("note", "a"), value("b", "c")]),
        ]),
    ]
    let trap = TagRemovalSheet(groups: colliding, remover: RecordingRemover())
    _ = host(trap)
    let trapText = labels(trap.view).map(\.stringValue)
    expectString(joined(colliding[0].tuples[0]), joined(colliding[0].tuples[1]),
                 "the fixture really is a collision: joined, these two tuples are identical")
    expectTrue(trapText.contains("note: a  +  b: c"),
               "a value containing the separator renders whole, in one label")
    expectTrue(trapText.contains("note: a") && trapText.contains("b: c"),
               "the tuple whose TITLE collides with it renders as two separate labels")
    expectInt(checkboxes(trap.view).count, 2, "the two colliding tuples stay two rows")

    // MARK: a long, multi-line value wraps rather than truncating

    let long = String(repeating: "abcdefgh ", count: 300) + "\nsecond line"
    let big = TagRemovalSheet(
        groups: [
            TagRemovalGroup(tagId: "t4", tagName: "Case Delta", colorIndex: 3, tuples: [
                tuple("u6", [value("payload", long)]),
            ]),
        ],
        remover: RecordingRemover())
    _ = host(big)
    big.view.layoutSubtreeIfNeeded()
    guard let payload = labels(big.view).first(where: { $0.stringValue.hasPrefix("payload: ") })
    else {
        failures += 1
        print("FAIL the long value has no label at all")
        print("\n\(failures) FAILURE(S)")
        exit(1)
    }
    // Held WHOLE, and escaped: the fixture ends in a newline plus "second
    // line", and a raw newline in one value would read as two values.
    expectTrue(!payload.stringValue.contains("\n"),
               "no raw newline survives into a row")
    expectTrue(payload.stringValue.hasSuffix("<U+000A>second line"),
               "the value's tail is shown, with its newline as a visible escape")
    expectInt(payload.stringValue.count, "payload: ".count + long.count + 7,
              "every character is held — the length grows by exactly 7, the one escaped newline")
    expectTrue(payload.frame.height > 100,
               "the long value wraps to many lines (height \(Int(payload.frame.height)) > 100)")

    // The width assertions, which are the ones with teeth. "It fits inside the
    // sheet" passes at ANY width — it passed while the list had collapsed to a
    // 160pt column jammed against the right edge, wrapping a long value into a
    // 434pt ribbon. Disclosure is about the width the values actually GET, so
    // both the scroll view and the label are measured against the form.
    let formWidth = big.view.frame.width - 40  // the form's 20pt insets
    let scroll = descendants(big.view).compactMap { $0 as? NSScrollView }.first!
    expectTrue(abs(scroll.frame.width - formWidth) < 0.5,
               "the list takes the full form width (scroll \(Int(scroll.frame.width)) vs form \(Int(formWidth)))")
    expectTrue(payload.frame.width >= formWidth * 2 / 3,
               "a value wraps at close to the sheet's width, not in a narrow column (label \(Int(payload.frame.width)) vs form \(Int(formWidth)))")
    expectTrue(payload.frame.width <= big.view.frame.width,
               "the wrapped label stays inside the sheet")

    // ...and TALL enough for every line at the width it actually got. The
    // reserved height comes from `preferredMaxLayoutWidth`; set that wider
    // than the label ends up and AppKit reserves too little, cutting the last
    // lines off. No width assertion can see that.
    let ruler = NSTextField(wrappingLabelWithString: payload.stringValue)
    ruler.font = payload.font
    ruler.preferredMaxLayoutWidth = payload.frame.width
    expectTrue(payload.frame.height >= ruler.fittingSize.height - 1,
               "the value label is tall enough for its text at its own width (\(Int(payload.frame.height)) vs needs \(Int(ruler.fittingSize.height)))")

    // MARK: an unbroken token — no wrap opportunities at all

    // The values this app captures are hashes, URLs and base64 blobs, so a long
    // value with NO space in it is the normal case, not the exotic one. A
    // wrapping label breaks such a token mid-character; what must be checked is
    // that the height reserved still covers every line it produced.
    let unbroken = String(repeating: "a1b2c3d4e5f6", count: 160)  // 1920 chars, no breaks
    let hash = TagRemovalSheet(
        groups: [
            TagRemovalGroup(tagId: "t5", tagName: "Case Epsilon", colorIndex: 4, tuples: [
                tuple("u7", [value("sha256", unbroken)]),
            ]),
        ],
        remover: RecordingRemover())
    _ = host(hash)
    hash.view.layoutSubtreeIfNeeded()
    guard let token = labels(hash.view).first(where: { $0.stringValue.hasPrefix("sha256: ") })
    else {
        failures += 1
        print("FAIL the unbroken value has no label at all")
        print("\n\(failures) FAILURE(S)")
        exit(1)
    }
    let hashFormWidth = hash.view.frame.width - 40
    expectString(token.stringValue, "sha256: \(unbroken)", "the unbroken value is held whole")
    expectTrue(token.frame.width <= hash.view.frame.width,
               "an unbroken token does not force the label wider than the sheet (label \(Int(token.frame.width)))")
    expectTrue(token.frame.width >= hashFormWidth * 2 / 3,
               "an unbroken token still gets most of the sheet's width (label \(Int(token.frame.width)) vs form \(Int(hashFormWidth)))")
    let tokenRuler = NSTextField(wrappingLabelWithString: token.stringValue)
    tokenRuler.font = token.font
    tokenRuler.preferredMaxLayoutWidth = token.frame.width
    expectTrue(token.frame.height >= tokenRuler.fittingSize.height - 1,
               "every line of the unbroken token is shown, not clipped (\(Int(token.frame.height)) vs needs \(Int(tokenRuler.fittingSize.height)))")

    // MARK: Cancel takes Return, and cannot delete

    // The reason this sheet exists is to slow the hand down. Return must land
    // on Cancel — the removal is permanent and global — and neither Cancel
    // path may commit anything on its way out.
    let escapeGroups = [
        TagRemovalGroup(tagId: "t6", tagName: "Case Zeta", colorIndex: 0, tuples: [
            tuple("u8", [value("ip", "10.0.0.9")]),
        ]),
    ]
    let cancelRemover = RecordingRemover()
    let cancelSheet = TagRemovalSheet(groups: escapeGroups, remover: cancelRemover)
    _ = host(cancelSheet)
    expectString(cancelButton(cancelSheet.view).keyEquivalent, "\r",
                 "Cancel is the DEFAULT button: Return cancels")
    expectTrue(removeButton(cancelSheet.view).keyEquivalent.isEmpty,
               "the destructive button carries NO key equivalent at all")
    cancelButton(cancelSheet.view).performClick(nil)
    expectTrue(cancelRemover.removed.isEmpty, "clicking Cancel removes nothing")

    // Escape reaches the same place through the responder chain.
    let escapeRemover = RecordingRemover()
    let escapeSheet = TagRemovalSheet(groups: escapeGroups, remover: escapeRemover)
    _ = host(escapeSheet)
    escapeSheet.cancelOperation(nil)
    expectTrue(escapeRemover.removed.isEmpty, "cancelOperation removes nothing")

    // MARK: the list's HEIGHT — the other half of the collapse the width fix caught

    let listScroll = descendants(root).compactMap { $0 as? NSScrollView }.first!
    expectTrue(abs(listScroll.frame.height - 260) < 0.5,
               "the list keeps its full height (\(Int(listScroll.frame.height)) of 260)")
    let document = listScroll.documentView?.frame.height ?? 0
    expectTrue(listScroll.contentSize.height >= document,
               "a three-tuple list is shown whole, not through a slot (\(Int(listScroll.contentSize.height)) of \(Int(document)))")

    // MARK: every row starts at the same leading edge

    // A reader compares this list DOWN a column: the checkboxes say which
    // tuples go, and the value labels say what they are. Rows that start at
    // different places break that reading, and the way they broke was not
    // uniform — `NSStackView` silently discards `.width` as a vertical
    // alignment, which left each row's width to the solver, so rows with
    // identical content drifted by different amounts and the misalignment
    // looked like a repeating cycle. Seven tuples, and the multi-value ones
    // NOT on a fixed stride, so neither a content-driven nor an index-driven
    // cycle can hide inside the fixture.
    let mixed = (0..<7).map { index -> TagRemovalTuple in
        var values = [value("ip", "10.0.0.\(index)")]
        if index == 1 || index == 2 || index == 5 {
            values.append(value("subject", "CN=evil-\(index)"))
        }
        if index == 2 { values.append(value("sha256", "d41d8cd98f00b204e9800998ecf8427e")) }
        return tuple("m\(index)", values)
    }
    let column = TagRemovalSheet(
        groups: [TagRemovalGroup(tagId: "t9", tagName: "Case Theta",
                                 colorIndex: 2, tuples: mixed)],
        remover: RecordingRemover())
    _ = host(column)
    column.view.layoutSubtreeIfNeeded()
    let columnRows = rows(column.view)
    expectInt(columnRows.count, 7, "all seven tuples are rows in the list")
    guard let list = descendants(column.view).compactMap({ $0 as? NSScrollView })
        .first?.documentView, columnRows.count == 7 else {
        print("\n\(failures) FAILURE(S) — cannot measure \(columnRows.count) rows")
        exit(1)
    }

    let rowEdges = columnRows.map { drawnLeading($0, in: list) }
    expectTrue((rowEdges.max() ?? 0) - (rowEdges.min() ?? 0) < 0.5,
               "every tuple row starts at one leading edge (spread \(rowEdges.map { Int($0) }))")
    expectTrue(columnRows.allSatisfy { abs($0.frame.width - list.frame.width) < 0.5 },
               "and spans the list rather than hugging its content (widths \(columnRows.map { Int($0.frame.width) }) of \(Int(list.frame.width)))")

    // The checkbox is the control the hand goes to, so its edge is the one a
    // misalignment is felt through.
    let boxEdges = columnRows.map { row in
        descendants(row).compactMap { $0 as? NSButton }
            .map { drawnLeading($0, in: list) }.min() ?? -1
    }
    expectTrue((boxEdges.max() ?? 0) - (boxEdges.min() ?? 0) < 0.5,
               "every checkbox sits at one leading edge (\(boxEdges.map { Int($0) }))")

    // And the values themselves, single-value tuples and multi-value tuples
    // alike: a value indented past its neighbours reads as belonging to
    // something else.
    let valueEdges = columnRows.flatMap { row in
        descendants(row).compactMap { $0 as? NSTextField }
            .map { drawnLeading($0, in: list) }
    }
    // 11 values across the seven tuples, plus the "removed together" caption
    // each of the three multi-value tuples carries. A fixture that quietly
    // stopped mixing would pass the edge assertions on rows that are all the
    // same shape, so the shape is pinned here.
    expectInt(valueEdges.count, 14, "every value and caption of every tuple is measured")
    expectTrue((valueEdges.max() ?? 0) - (valueEdges.min() ?? 0) < 0.5,
               "every value label sits at one leading edge (\(valueEdges.map { Int($0) }))")
    expectTrue((boxEdges.min() ?? 0) < (valueEdges.min() ?? 0),
               "with the values nested to the right of the checkbox that governs them")

    // The same rule one level up. The title, the list, the footer and the
    // button row are arranged subviews of one vertical stack that was aligned
    // the same broken way, and the title drifted right of the list it names —
    // a heading that does not sit above its own content.
    guard let formStack = column.view.subviews.compactMap({ $0 as? NSStackView }).first
    else {
        failures += 1
        print("FAIL the sheet has no form stack to measure")
        print("\n\(failures) FAILURE(S)")
        exit(1)
    }
    let formEdges = formStack.arrangedSubviews.map { drawnLeading($0, in: formStack) }
    expectInt(formEdges.count, 4, "title, list, footer and buttons are the form's four rows")
    expectTrue((formEdges.max() ?? 0) - (formEdges.min() ?? 0) < 0.5,
               "the title, the list and the footer share the form's leading edge (\(formEdges.map { Int($0) }))")

    // MARK: a value that would otherwise render blank, and one that lies

    // Both reachable in production: TagDraft fills `display` from the raw cell,
    // and the values in a tag came out of somebody else's dataset.
    let nasty = TagRemovalSheet(
        groups: [
            TagRemovalGroup(tagId: "t7", tagName: "Case Eta", colorIndex: 2, tuples: [
                tuple("u9", [value("ip", "")]),
                tuple("u10", [value("", "")]),
                tuple("u11", [value("host", "safe\u{202E}gpj.exe")]),
                tuple("u12", [value("ip", "10.0.0.1 ")]),
            ]),
        ],
        remover: RecordingRemover())
    _ = host(nasty)
    let nastyLines = listLines(nasty.view)
    expectTrue(nastyLines.contains("ip: (empty)"),
               "an empty value says so, rather than drawing a checkbox beside nothing")
    expectTrue(nastyLines.contains("(no column): (empty)"),
               "the worst case reads as words, not as a bare colon")
    expectTrue(nastyLines.contains("host: safe<U+202E>gpj.exe"),
               "a bidi override is shown, not obeyed — the row must not read as a .jpg")
    expectTrue(nastyLines.contains("ip: 10.0.0.1<U+0020>"),
               "a trailing space is visible, so this row cannot be confused with a clean one")
    // A placeholder is not captured data and is styled apart from it.
    let placeholder = labels(nasty.view).first { $0.stringValue == "ip: (empty)" }
    let real = labels(nasty.view).first { $0.stringValue == "ip: 10.0.0.1<U+0020>" }
    expectTrue(placeholder?.textColor != real?.textColor,
               "the placeholder does not read as a captured value")

    // MARK: the sheet draws the REACH of a value whose text understates it

    // `cc` is a char(20): PostgreSQL pads it, capture keeps the padding, and
    // `us` is what actually stops matching — including in a plain `text` column
    // holding lowercase `us` with no padding at all.
    let reason = "matching compares this form, so other spellings can match too"
    let padded = "US" + String(repeating: " ", count: 18)
    let reach = TagRemovalSheet(
        groups: [
            TagRemovalGroup(tagId: "t9", tagName: "Case Reach", colorIndex: 2, tuples: [
                tuple("u14", [value("cc", padded, normalized: "us"),
                              value("ip", "10.0.0.1")]),
                tuple("u15", [value("note", "   ", normalized: "")]),
            ]),
        ],
        remover: RecordingRemover())
    _ = host(reach)
    let reachLines = listLines(reach.view)
    expectTrue(reachLines.contains("cc: US<U+0020\u{00D7}18>"),
               "the captured text keeps its padding — that provenance is what makes the tuple auditable")
    expectTrue(reachLines.contains("matches as \u{201C}us\u{201D} — \(reason)"),
               "and the form that actually stops matching is disclosed beside it, on its own label")
    expectInt(reachLines.filter { $0.hasPrefix("matches as") }.count, 2,
              "one line for the padded value and one for the blank one — and NONE for ip: 10.0.0.1, whose text is already the matching form")
    expectTrue(reachLines.contains("matches as (empty) — \(reason)"),
               "an all-whitespace value matches every blank cell, and says so in words rather than in empty quotes")
    // The reach is a separate label, never merged into the value's: a captured
    // value can legally contain any separator this could have used.
    expectTrue(!reachLines.contains(where: { $0.hasPrefix("cc: ") && $0.contains("matches as") }),
               "the reach is never appended to the value label")
    // Read from `attributedStringValue`, which is what the reach label actually
    // DRAWS. `NSTextField.font` and `.textColor` report the field's own
    // defaults and go on reporting them after an attributed string is set, so
    // asserting on those would pass whatever the reader ends up seeing.
    func drawn(_ label: NSTextField) -> (font: NSFont?, color: NSColor?, indent: CGFloat) {
        let attrs = label.attributedStringValue.length == 0
            ? [:] : label.attributedStringValue.attributes(at: 0, effectiveRange: nil)
        return (attrs[.font] as? NSFont, attrs[.foregroundColor] as? NSColor,
                (attrs[.paragraphStyle] as? NSParagraphStyle)?.headIndent ?? 0)
    }
    if let reachLabel = labels(reach.view).first(where: { $0.stringValue.hasPrefix("matches as \u{201C}us") }),
       let blankReach = labels(reach.view).first(where: { $0.stringValue.hasPrefix("matches as (empty)") }),
       let valueLabel = labels(reach.view).first(where: { $0.stringValue.hasPrefix("cc: ") }) {
        // Not `maximumNumberOfLines != 1`, which was tried and is too weak to
        // catch the real failure: a plain `labelWithString` label has
        // `cell.wraps == false`, and neither that property nor the paragraph
        // style's `.byWordWrapping` turns wrapping back on — the label just
        // measures one line tall and the sentence is cut mid-clause. Only the
        // HEIGHT sees that. (It was measured happening in the Inspector's copy
        // of this recipe.)
        let needed = ceil(reachLabel.attributedStringValue.boundingRect(
            with: NSSize(width: reachLabel.frame.width, height: .greatestFiniteMagnitude),
            options: [.usesLineFragmentOrigin, .usesFontLeading]).height)
        expectTrue(reachLabel.frame.height + 0.5 >= needed,
                   "every line of the reach is drawn at its own width (\(Int(reachLabel.frame.height)) vs needs \(Int(needed))) — a cut sentence would understate again")
        expectTrue(reachLabel.cell?.wraps == true,
                   "the reach label wraps rather than truncating")
        let (reachFont, reachColor, reachIndent) = drawn(reachLabel)
        let (valueFont, valueColor, _) = drawn(valueLabel)
        expectTrue(reachFont != valueFont,
                   "the app's explanation is drawn in a different font from the captured data it explains")
        expectTrue(reachColor != valueColor,
                   "and in a different colour, so the reader never has to work out which line came out of the database")
        expectTrue(reachIndent > 0,
                   "the reach is indented under the value it belongs to — in a multi-value tuple it must not read as the next value's")
        expectTrue(drawn(blankReach).color != reachColor,
                   "the (empty) stand-in is styled apart from a real matching form, the same rule the value labels apply")
    } else {
        failures += 1
        print("FAIL the reach sheet is missing its value label, its reach label, or its (empty) reach label")
    }
    // The screen reader hears what the screen shows, disclosure included.
    let reachBoxes = checkboxes(reach.view)
    if reachBoxes.count == 2 {
        expectString(reachBoxes[0].accessibilityLabel() ?? "",
                     "cc: US<U+0020\u{00D7}18>, matches as \u{201C}us\u{201D} — \(reason), ip: 10.0.0.1",
                     "the checkbox is spoken from exactly the text that is shown")
    } else {
        failures += 1
        print("FAIL the reach sheet has \(reachBoxes.count) checkboxes, not 2")
    }

    // MARK: a long tag name truncates instead of sizing the sheet

    // A tag name is free text. Unbounded, the label grows, `fittingSize` grows
    // with it and `presentAsSheet` sizes the sheet from that; when the parent
    // window clamps instead, the name overflows the clip with no ellipsis and
    // two names differing only past the cut read as the same tag.
    let longName = String(repeating: "Case Omega ", count: 15) + "END"
    let wide = TagRemovalSheet(
        groups: [
            TagRemovalGroup(tagId: "t8", tagName: longName, colorIndex: 3, tuples: [
                tuple("u13", [value("ip", "10.0.0.1")]),
            ]),
        ],
        remover: RecordingRemover())
    _ = host(wide)
    wide.view.layoutSubtreeIfNeeded()
    expectTrue(wide.view.fittingSize.width <= 481,
               "a 168-character tag name does not size the sheet (fitting \(Int(wide.view.fittingSize.width)) vs 480)")
    if let head = headers(wide.view).first {
        expectTrue(head.frame.width <= wide.view.frame.width - 40,
                   "the header label stays inside the form (\(Int(head.frame.width)) vs \(Int(wide.view.frame.width - 40)))")
        expectString(head.toolTip ?? "", longName,
                     "the full name is still readable, as a tooltip")
        // Truncation vs clipping is not measurable from the frame — both keep
        // the label inside the form — but it is the whole difference between
        // a name that SHOWS it was cut and one that silently ends mid-word.
        // AppKit's default here is `.byClipping`, so this is a real setting.
        expectTrue(head.lineBreakMode == .byTruncatingTail,
                   "the name truncates with an ellipsis rather than clipping silently")
    } else {
        failures += 1
        print("FAIL the long-name sheet has no header at all")
    }

    print(failures == 0 ? "\nAll TagRemovalSheet tests passed." : "\n\(failures) FAILURE(S)")
    exit(failures == 0 ? 0 : 1)
}
