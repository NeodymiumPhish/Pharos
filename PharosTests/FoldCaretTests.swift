// Standalone tests for the caret around a folded region: a fold hides its
// text, so the caret and the selection must never stop inside it, and
// Backspace/Delete next to a pill must not delete text nobody can see. A fold
// inside another fold draws no pill of its own.
//
// Compiled with SQLTextView.swift, SQLFoldingParser.swift and their
// dependencies by scripts/test-fold-caret.sh. The text view lives in a
// borderless window that is never shown; mouse clicks use the queued mouse-up
// pattern (see EditorCompletionTests.testTokenClicks).
import AppKit

private var failures = 0

private func expectEqual<T: Equatable>(_ actual: T, _ expected: T, _ name: String) {
    if actual == expected { print("PASS \(name)") } else {
        failures += 1
        print("FAIL \(name)\n  expected: \(expected)\n  actual:   \(actual)")
    }
}

private func expectTrue(_ actual: Bool, _ name: String) {
    if actual { print("PASS \(name)") } else {
        failures += 1
        print("FAIL \(name)")
    }
}

private let parenSQL = "SELECT *\nFROM http\nWHERE orig_h IN (\n    '8.8.8.8',\n    '1.1.1.1',\n    '2.2.2.2'\n  )\n;\n"
private let caseSQL = "SELECT\n  CASE\n    WHEN a THEN 1\n    WHEN b THEN 2\n    ELSE 3\n  END AS x\nFROM t\n;\n"
private let nestedSQL = "SELECT * FROM (\n  SELECT\n    CASE\n      WHEN a THEN 1\n      WHEN b THEN 2\n      ELSE 3\n    END AS x\n  FROM t\n) s\n;\n"

private final class Editor {
    let window: NSWindow
    let textView: SQLTextView

    init(_ sql: String) {
        window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 600, height: 400),
                          styleMask: [.borderless], backing: .buffered, defer: false)
        textView = SQLTextView()
        textView.frame = NSRect(x: 0, y: 0, width: 600, height: 400)
        window.contentView = textView
        window.makeFirstResponder(textView)
        textView.string = sql
        // What QueryEditorVC does with a pill click.
        textView.onPlaceholderClicked = { [unowned self] in self.textView.unfold(id: $0) }
    }

    /// Fold the region of `kind` with QueryEditorVC.toggleFold's range math.
    @discardableResult
    func fold(_ kind: FoldKind, placeholder: String = " \u{25B8} 4 lines ") -> NSRange {
        let region = SQLFoldingParser.parse(textView.string).first { $0.kind == kind }!
        let end: Int
        switch region.kind {
        case .parenBlock, .subquery, .cte: end = region.closeCharIndex - 1
        default: end = region.endCharIndex
        }
        let range = NSRange(location: region.startCharIndex, length: end - region.startCharIndex + 1)
        textView.fold(range: range, placeholder: placeholder)
        textView.layoutManager?.ensureLayout(for: textView.textContainer!)
        return range
    }

    var text: String { textView.string }
    var selection: NSRange { textView.selectedRange() }
    var caret: Int { textView.selectedRange().location }
    var folds: Int { textView.foldState.entries.count }
    func place(_ location: Int, _ length: Int = 0) {
        textView.setSelectedRange(NSRange(location: location, length: length))
    }
    func isHidden(_ index: Int) -> Bool {
        textView.foldState.entries.contains { index > $0.range.location && index < NSMaxRange($0.range) }
    }

    func click(at point: NSPoint) {
        func mouse(_ type: NSEvent.EventType) -> NSEvent {
            NSEvent.mouseEvent(
                with: type, location: textView.convert(point, to: nil), modifierFlags: [], timestamp: 0,
                windowNumber: window.windowNumber, context: nil, eventNumber: 0, clickCount: 1, pressure: 0)!
        }
        NSApp.postEvent(mouse(.leftMouseUp), atStart: false)
        textView.mouseDown(with: mouse(.leftMouseDown))
        while NSApp.nextEvent(matching: .any, until: nil, inMode: .default, dequeue: true) != nil {}
    }

    /// The pill of the only fold, in view coordinates.
    func pillRect() -> NSRect {
        let lm = textView.layoutManager as! FoldingLayoutManager
        let rect = lm.pillRect(for: textView.foldState.entries[0], in: textView.textContainer!)!
        let origin = textView.textContainerOrigin
        return rect.offsetBy(dx: origin.x, dy: origin.y)
    }
}

// MARK: - Arrow keys

private func testArrows() {
    do {
        let e = Editor(caseSQL)
        let fold = e.fold(.caseBlock)
        e.place(fold.location)
        e.textView.moveRight(nil)
        expectEqual(e.caret, NSMaxRange(fold), "→: one press crosses a CASE fold")
        e.textView.moveLeft(nil)
        expectEqual(e.caret, fold.location, "←: one press crosses it back")
    }
    do {
        let e = Editor(parenSQL)
        let fold = e.fold(.parenBlock)
        e.place(fold.location)
        e.textView.moveRight(nil)
        expectEqual(e.caret, NSMaxRange(fold), "→: one press crosses a paren fold")
        e.textView.moveLeft(nil)
        expectEqual(e.caret, fold.location, "←: one press crosses it back")
    }
    for (name, sql, kind) in [("paren", parenSQL, FoldKind.parenBlock), ("CASE", caseSQL, .caseBlock)] {
        let e = Editor(sql)
        let fold = e.fold(kind)
        e.place(fold.location)
        e.textView.moveWordRight(nil)
        expectEqual(e.caret, NSMaxRange(fold), "⌥→: from a \(name) fold's start lands after the pill")
        e.textView.moveWordLeft(nil)
        expectTrue(!e.isHidden(e.caret), "⌥←: back over a \(name) fold never stops inside it")
    }
    // Up and Down never stop inside.
    do {
        let e = Editor(caseSQL)
        _ = e.fold(.caseBlock)
        e.place((e.text as NSString).length)
        var visited: [Int] = []
        for _ in 0..<6 { e.textView.moveUp(nil); visited.append(e.caret) }
        for _ in 0..<6 { e.textView.moveDown(nil); visited.append(e.caret) }
        expectTrue(!visited.contains(where: e.isHidden), "↑/↓: never stop inside a fold (\(visited))")
    }
    // Nested folds: the outer one wins.
    do {
        let e = Editor(nestedSQL)
        _ = e.fold(.caseBlock)
        let outer = e.fold(.subquery)
        e.place(outer.location)
        e.textView.moveRight(nil)
        expectEqual(e.caret, NSMaxRange(outer), "→: one press crosses nested folds")
        e.textView.moveLeft(nil)
        expectEqual(e.caret, outer.location, "←: one press crosses them back")
    }
}

// MARK: - Selections

private func testSelections() {
    let e = Editor(caseSQL)
    let fold = e.fold(.caseBlock)
    e.place(fold.location)
    e.textView.moveRightAndModifySelection(nil)
    expectEqual(e.selection, fold, "⇧→: selects the whole folded block")
    e.textView.moveLeftAndModifySelection(nil)
    expectEqual(e.selection, NSRange(location: fold.location, length: 0), "⇧←: shrinks back past it")

    // A selection set in code that ends inside a fold grows to cover it.
    e.place(fold.location - 3, 10)
    expectEqual(e.selection, NSRange(location: fold.location - 3, length: NSMaxRange(fold) - fold.location + 3),
                "set in code: an end inside a fold grows to the fold's end")
    e.place(fold.location + 5, NSMaxRange(fold) - fold.location - 5 + 2)
    expectEqual(e.selection, NSRange(location: fold.location, length: fold.length + 2),
                "set in code: a start inside a fold grows to the fold's start")
}

// MARK: - Folding with the caret inside

private func testFoldAroundCaret() {
    let e = Editor(parenSQL)
    e.place((parenSQL as NSString).range(of: "1.1.1.1").location)
    let fold = e.fold(.parenBlock)
    expectEqual(e.caret, NSMaxRange(fold), "fold: a caret inside moves after the pill")
    e.textView.insertText("X", replacementRange: e.selection)
    expectEqual(e.folds, 1, "fold: typing next does not open the fold")
    expectTrue(!e.text.contains("'X1.1.1.1'"), "fold: typing next does not edit hidden text")

    let s = Editor(caseSQL)
    s.place((caseSQL as NSString).range(of: "WHEN b").location, 3)
    let caseFold = s.fold(.caseBlock)
    expectEqual(s.selection, caseFold, "fold: a selection inside grows to the whole fold")
}

// MARK: - Typing and undo next to a fold

private func testEditsBesideFold() {
    let e = Editor(parenSQL)
    let fold = e.fold(.parenBlock)
    e.place(fold.location)
    e.textView.insertText("X", replacementRange: e.selection)
    expectEqual(e.caret, fold.location + 1, "typing before a pill: the caret stays after the typed text")
    expectEqual(e.folds, 1, "typing before a pill: the fold stays")
    expectEqual(e.textView.foldState.entries.first?.range.location, fold.location + 1, "typing before a pill: the fold moves along")
    e.textView.undoManager?.undo()
    expectTrue(!e.isHidden(e.caret), "undo beside a fold: the caret is not inside it")

    let t = Editor(caseSQL)
    let caseFold = t.fold(.caseBlock)
    t.place(NSMaxRange(caseFold))
    t.textView.insertText("Y", replacementRange: t.selection)
    expectEqual(t.caret, NSMaxRange(caseFold) + 1, "typing after a pill: the caret stays after the typed text")
    expectEqual(t.folds, 1, "typing after a pill: the fold stays")
}

// MARK: - Backspace and Delete next to a pill

private func testDeleteBesidePill() {
    for (name, sql, kind) in [("paren", parenSQL, FoldKind.parenBlock), ("CASE", caseSQL, .caseBlock)] {
        let e = Editor(sql)
        let fold = e.fold(kind)
        e.place(NSMaxRange(fold))
        e.textView.deleteBackward(nil)
        expectEqual(e.text, sql, "⌫ after a \(name) pill: deletes nothing")
        expectEqual(e.folds, 0, "⌫ after a \(name) pill: unfolds")
        expectEqual(e.caret, NSMaxRange(fold), "⌫ after a \(name) pill: the caret stays")

        let f = Editor(sql)
        let fold2 = f.fold(kind)
        f.place(fold2.location)
        f.textView.deleteForward(nil)
        expectEqual(f.text, sql, "⌦ before a \(name) pill: deletes nothing")
        expectEqual(f.folds, 0, "⌦ before a \(name) pill: unfolds")

        let w = Editor(sql)
        let fold3 = w.fold(kind)
        w.place(NSMaxRange(fold3))
        w.textView.deleteWordBackward(nil)
        expectEqual(w.text, sql, "⌥⌫ after a \(name) pill: deletes nothing")
        expectEqual(w.folds, 0, "⌥⌫ after a \(name) pill: unfolds")
        w.textView.string = sql
        _ = w.fold(kind)
        w.place(fold3.location)
        w.textView.deleteWordForward(nil)
        expectEqual(w.text, sql, "⌥⌦ before a \(name) pill: deletes nothing")
        expectEqual(w.folds, 0, "⌥⌦ before a \(name) pill: unfolds")
    }
    // Deleting a selection that holds a whole fold is an ordinary delete.
    let e = Editor(caseSQL)
    let fold = e.fold(.caseBlock)
    e.place(fold.location, fold.length)
    e.textView.deleteBackward(nil)
    expectEqual((e.text as NSString).length, (caseSQL as NSString).length - fold.length,
                "⌫ with the fold selected: deletes the selection")
}

// MARK: - Clicks

private func testClicks() {
    for (name, sql, kind) in [("paren", parenSQL, FoldKind.parenBlock), ("CASE", caseSQL, .caseBlock)] {
        let e = Editor(sql)
        let fold = e.fold(kind)
        let pill = e.pillRect()
        e.place(0)
        e.click(at: NSPoint(x: pill.maxX + 40, y: pill.midY))
        expectEqual(e.caret, NSMaxRange(fold), "click right of a \(name) pill: the caret goes after it")
        expectEqual(e.folds, 1, "click right of a \(name) pill: the fold stays")
    }
    let e = Editor(parenSQL)
    _ = e.fold(.parenBlock)
    let pill = e.pillRect()
    e.click(at: NSPoint(x: pill.midX, y: pill.midY))
    expectEqual(e.folds, 0, "click on a pill: unfolds")
}

// MARK: - Nested pills

/// A fold inside another fold is hidden with the rest of the outer fold's
/// text, so it must draw nothing and reserve no width: the view must render
/// exactly as with the outer fold alone.
private func testNestedPills() {
    func render(_ e: Editor) -> (Data, CGFloat) {
        let tv = e.textView
        tv.layoutManager?.ensureLayout(for: tv.textContainer!)
        let rep = tv.bitmapImageRepForCachingDisplay(in: tv.bounds)!
        tv.cacheDisplay(in: tv.bounds, to: rep)
        let lm = tv.layoutManager!
        let glyph = lm.glyphIndexForCharacter(at: tv.foldState.entries[0].range.location)
        return (rep.tiffRepresentation!, lm.lineFragmentUsedRect(forGlyphAt: glyph, effectiveRange: nil).width)
    }
    let outerOnly = Editor(nestedSQL)
    _ = outerOnly.fold(.subquery)
    let nested = Editor(nestedSQL)
    // A wider label than the outer pill's, so reserving it would show.
    _ = nested.fold(.caseBlock, placeholder: " \u{25B8} 5 lines of a CASE block ")
    _ = nested.fold(.subquery)
    let (outerPixels, outerWidth) = render(outerOnly)
    let (nestedPixels, nestedWidth) = render(nested)
    expectTrue(outerPixels == nestedPixels, "nested: a fold inside a fold draws no second pill")
    expectEqual(nestedWidth, outerWidth, "nested: a fold inside a fold reserves no pill width")
}

func runTests() {
    _ = NSApplication.shared
    testArrows()
    testSelections()
    testFoldAroundCaret()
    testEditsBesideFold()
    testDeleteBesidePill()
    testClicks()
    testNestedPills()
    if failures == 0 { print("\nAll fold caret tests passed.") } else {
        print("\n\(failures) failure(s).")
        exit(1)
    }
}
