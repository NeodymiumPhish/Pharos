// Standalone test runner for LineNumberGutter's accessibility container — no
// Xcode project or test target involvement. The gutter paints its fold
// chevrons and error markers itself, so there is no subview for
// VoiceOver to find: it publishes one NSAccessibilityElement per control
// instead. These tests build a real gutter over a real text view inside a
// headless (never-shown) NSWindow, so the layout manager lays text out and
// the frames measured here are the frames VoiceOver would get.
//
// Compiled with LineNumberGutter.swift, AccessibilityDisplay.swift,
// SQLFoldingParser.swift, SQLLexer.swift and the rest of the file list in
// scripts/test-gutter-accessibility.sh.
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

private func expectEqual(_ actual: Int, _ expected: Int, _ name: String) {
    if actual == expected { print("PASS \(name)") } else {
        failures += 1
        print("FAIL \(name)\n  expected: \(expected)\n  actual:   \(actual)")
    }
}

// MARK: - Harness

private let sql = """
select 1;
select 2
from (
  select 3
  from t
);
"""

/// A gutter hosted beside a text view in a never-shown window, holding `sql`.
/// A window is required: without one the layout manager still lays out, but
/// the gutter has no screen space to convert its frames into, and this suite
/// checks screen-space frames.
private func makeHostedGutter() -> (window: NSWindow, gutter: LineNumberGutter, textView: NSTextView) {
    let window = NSWindow(
        contentRect: NSRect(x: 0, y: 0, width: 500, height: 300),
        styleMask: [.borderless], backing: .buffered, defer: false
    )
    let container = NSView(frame: NSRect(x: 0, y: 0, width: 500, height: 300))
    window.contentView = container

    let scrollView = NSScrollView(frame: NSRect(x: 50, y: 0, width: 450, height: 300))
    scrollView.hasVerticalScroller = true
    let textView = NSTextView(frame: NSRect(x: 0, y: 0, width: 450, height: 300))
    textView.isVerticallyResizable = true
    textView.isHorizontallyResizable = false
    textView.autoresizingMask = [.width]
    textView.textContainer?.widthTracksTextView = true
    textView.font = .monospacedSystemFont(ofSize: 12, weight: .regular)
    textView.string = sql
    scrollView.documentView = textView

    let gutter = LineNumberGutter(textView: textView, scrollView: scrollView)
    gutter.frame = NSRect(x: 0, y: 0, width: gutter.desiredWidth, height: 300)
    container.addSubview(gutter)
    container.addSubview(scrollView)

    // Force layout so line fragments exist before any frame is measured.
    textView.layoutManager?.ensureLayout(for: textView.textContainer!)
    container.layoutSubtreeIfNeeded()
    gutter.invalidateLineNumbers()

    return (window, gutter, textView)
}

private func makeFoldRegion(startLine: Int, endLine: Int, collapsed: Bool) -> SQLFoldRegion {
    var region = SQLFoldRegion(
        startLine: startLine, endLine: endLine,
        startCharIndex: 0, endCharIndex: 1, closeCharIndex: 1,
        kind: .subquery
    )
    region.isCollapsed = collapsed
    return region
}

private func children(of gutter: LineNumberGutter) -> [LineNumberGutter.GutterElement] {
    (gutter.accessibilityChildren() as? [LineNumberGutter.GutterElement]) ?? []
}

private func role(_ element: LineNumberGutter.GutterElement) -> String {
    element.accessibilityRole()?.rawValue ?? "(none)"
}

private func label(_ element: LineNumberGutter.GutterElement) -> String {
    element.accessibilityLabel() ?? "(none)"
}

// MARK: - Tests

func runTests() {
    let (window, gutter, _) = makeHostedGutter()
    _ = window

    // One fold region, one error.
    gutter.setFoldRegions([makeFoldRegion(startLine: 3, endLine: 6, collapsed: false)])
    gutter.setErrors([4: "relation \"t\" does not exist"])

    // --- Container itself ---
    expectTrue(gutter.isAccessibilityElement(), "gutter.isAccessibilityElement")
    expectEqual(gutter.accessibilityRole()?.rawValue ?? "(none)",
                NSAccessibility.Role.group.rawValue, "gutter.role is group")
    expectEqual(gutter.accessibilityLabel() ?? "(none)", "Line gutter", "gutter.label")
    expectEqual(gutter.accessibilityIdentifier(), "editor.gutter", "gutter.identifier")
    // Each query card's gutter is named for its card, so an accessibility
    // walk can tell many gutters apart.
    let cardScroll = NSScrollView(frame: NSRect(x: 0, y: 0, width: 200, height: 100))
    let cardText = NSTextView(frame: NSRect(x: 0, y: 0, width: 200, height: 100))
    cardScroll.documentView = cardText
    let cardGutter = LineNumberGutter(textView: cardText, scrollView: cardScroll,
                                      accessibilityIdentifier: "editor.card.3.gutter")
    expectEqual(cardGutter.accessibilityIdentifier(), "editor.card.3.gutter", "gutter.identifier.custom")

    // --- Children: count and roles ---
    let kids = children(of: gutter)
    expectEqual(kids.count, 2, "child count = 1 fold + 1 error")

    let folds = kids.filter { role($0) == NSAccessibility.Role.disclosureTriangle.rawValue }
    let errorKids = kids.filter { role($0) == NSAccessibility.Role.image.rawValue }
    expectEqual(kids.filter { role($0) == NSAccessibility.Role.button.rawValue }.count, 0,
                "no run buttons — a card's own Run button runs its statement")
    expectTrue(kids.allSatisfy { $0.isAccessibilityEnabled() },
               "every child is enabled — VoiceOver will not press a disabled control")
    expectEqual(folds.count, 1, "one fold chevron")
    expectEqual(errorKids.count, 1, "one error marker")

    // --- Labels ---
    expectEqual(label(folds[0]), "Fold lines 3\u{2013}6", "fold label")
    expectEqual(label(errorKids[0]), "Error on line 4", "error label")
    expectTrue(kids.first === folds[0], "children read top to bottom: fold (line 3) before error (line 4)")

    // --- Error value carries the message ---
    expectEqual((errorKids[0].accessibilityValue() as? String) ?? "(none)",
                "relation \"t\" does not exist", "error value is the message")
    expectEqual(gutter.errorMessage(forLine: 4) ?? "(none)",
                "relation \"t\" does not exist", "errorMessage(forLine:)")

    // A message-free error still reads as an error.
    gutter.setErrorLines([2])
    let bare = children(of: gutter).first { role($0) == NSAccessibility.Role.image.rawValue }
    expectEqual((bare?.accessibilityValue() as? String) ?? "(none)", "Error",
                "message-free error value falls back to \"Error\"")
    expectTrue(gutter.errorMessage(forLine: 2) == nil, "setErrorLines records no message")

    // --- Fold value: 1 expanded, 0 collapsed ---
    expectEqual((folds[0].accessibilityValue() as? NSNumber)?.intValue ?? -1, 1,
                "expanded fold value = 1")
    gutter.setFoldRegions([makeFoldRegion(startLine: 3, endLine: 6, collapsed: true)])
    let collapsedFold = children(of: gutter).first {
        role($0) == NSAccessibility.Role.disclosureTriangle.rawValue
    }
    expectEqual((collapsedFold?.accessibilityValue() as? NSNumber)?.intValue ?? -1, 0,
                "collapsed fold value = 0")

    // --- Frames sit inside the gutter, in screen coordinates ---
    let gutterOnScreen = gutter.window!.convertToScreen(gutter.convert(gutter.bounds, to: nil))
    var allInside = true
    for kid in children(of: gutter) {
        let frame = kid.accessibilityFrame()
        if frame.isEmpty || !gutterOnScreen.insetBy(dx: -1, dy: -1).contains(frame) {
            allInside = false
            print("  out of bounds: \(label(kid)) \(frame) vs gutter \(gutterOnScreen)")
        }
    }
    expectTrue(allInside, "every child frame lies inside the gutter, in screen space")

    // --- Hit testing returns the child under the point ---
    let foldFrame = children(of: gutter)
        .first { role($0) == NSAccessibility.Role.disclosureTriangle.rawValue }!
        .accessibilityFrame()
    let hit = gutter.accessibilityHitTest(NSPoint(x: foldFrame.midX, y: foldFrame.midY))
    expectTrue((hit as? LineNumberGutter.GutterElement) != nil, "hit test finds a child")
    expectEqual(label((hit as? LineNumberGutter.GutterElement)!), "Fold lines 3\u{2013}6",
                "hit test finds the right child")
    let miss = gutter.accessibilityHitTest(NSPoint(x: gutterOnScreen.maxX + 500,
                                                   y: gutterOnScreen.maxY + 500))
    expectTrue((miss as? LineNumberGutter) === gutter, "hit test off every child returns the gutter")

    // --- Pressing a fold child toggles that region ---
    var toggled: Int?
    gutter.onToggleFold = { toggled = $0 }
    let foldKid = children(of: gutter)
        .first { role($0) == NSAccessibility.Role.disclosureTriangle.rawValue }!
    expectTrue(foldKid.accessibilityPerformPress(), "fold press reports handled")
    expectEqual(toggled ?? -1, 0, "fold press fires onToggleFold with the region index")

    // --- Identity survives a redraw; stale keys are dropped ---
    let isFold = { (el: LineNumberGutter.GutterElement) in
        role(el) == NSAccessibility.Role.disclosureTriangle.rawValue
    }
    let foldBefore = children(of: gutter).first(where: isFold)
    gutter.clearErrors()
    let after = children(of: gutter)
    expectEqual(after.filter { role($0) == NSAccessibility.Role.image.rawValue }.count, 0,
                "clearErrors drops the error child")
    let foldsAfter = after.filter(isFold)
    expectEqual(foldsAfter.count, 1, "the fold child survives clearErrors")
    expectTrue(foldsAfter.first === foldBefore, "the same fold index keeps the same element object")

    // Dropping a fold region drops its element, and the survivors keep identity.
    gutter.setFoldRegions([
        makeFoldRegion(startLine: 3, endLine: 6, collapsed: false),
        makeFoldRegion(startLine: 4, endLine: 5, collapsed: false),
    ])
    let twoFolds = children(of: gutter).filter(isFold)
    expectEqual(twoFolds.count, 2, "a second fold region adds a second fold child")
    gutter.setFoldRegions([makeFoldRegion(startLine: 3, endLine: 6, collapsed: false)])
    let trimmed = children(of: gutter).filter(isFold)
    expectEqual(trimmed.count, 1, "removing a fold region removes its child")
    expectTrue(trimmed.first === foldBefore, "the surviving fold region keeps its element object")

    print(failures == 0 ? "\nAll tests passed" : "\n\(failures) test(s) failed")
    exit(failures == 0 ? 0 : 1)
}
