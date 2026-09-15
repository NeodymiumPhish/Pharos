// `SQLTextView.insertDraft` — the one edit that puts a model draft in the
// editor.
//
// Four claims, none of which a policy test can see: the draft replaces the
// selection, it comes back out in ONE undo step under the name "Insert Draft",
// the mark survives a caret move, and the mark goes on the first edit.
//
// Real AppKit, headless. A run-loop turn is taken wherever the test needs two
// separate undo groups: `NSUndoManager` groups by EVENT, and a probe that
// never returns to the run loop puts the whole test in one group — which
// reads exactly like a broken insert.
import AppKit

private var failures = 0

private func expect(_ condition: Bool, _ name: String) {
    if condition { print("PASS \(name)") } else { failures += 1; print("FAIL \(name)") }
}

private func expectEqual<T: Equatable>(_ actual: T, _ expected: T, _ name: String) {
    if actual == expected {
        print("PASS \(name)")
    } else {
        failures += 1
        print("FAIL \(name) — expected \(expected), got \(actual)")
    }
}

/// One event's worth of run loop, so the next edit starts its own undo group.
private func settle() {
    RunLoop.current.run(until: Date().addingTimeInterval(0.15))
}

private func makeEditor() -> SQLTextView {
    let view = SQLTextView()
    let window = NSWindow(
        contentRect: NSRect(x: 0, y: 0, width: 500, height: 300),
        styleMask: [.titled], backing: .buffered, defer: false)
    let scroll = NSScrollView(frame: window.contentLayoutRect)
    scroll.documentView = view
    window.contentView?.addSubview(scroll)
    window.makeFirstResponder(view)
    // The window is retained by the text view's own window reference for as
    // long as the test holds the view.
    return view
}

private func background(of view: SQLTextView, at index: Int) -> NSColor? {
    view.layoutManager?.temporaryAttribute(
        .backgroundColor, atCharacterIndex: index, effectiveRange: nil) as? NSColor
}

// MARK: - The insert itself

private func testInsertReplacesTheSelection() {
    let view = makeEditor()
    view.string = "keep me"
    view.undoManager?.removeAllActions()
    view.setSelectedRange(NSRange(location: 0, length: 4))  // "keep"

    let inserted = view.insertDraft("SELECT 1 FROM t;")

    expectEqual(view.string, "SELECT 1 FROM t; me", "the draft replaces the selection")
    expectEqual(inserted?.location, 0, "the reported range starts where the selection did")
    expectEqual(inserted?.length, 16, "the reported range is the draft's length")
    expectEqual(view.selectedRange(), NSRange(location: 0, length: 16),
                "the inserted statement is left selected")
    expectEqual(view.draftRange, NSRange(location: 0, length: 16), "and marked")
    expect(background(of: view, at: 1) != nil, "the mark is a background temporary attribute")
}

private func testEmptyDraftIsRefused() {
    let view = makeEditor()
    view.string = "untouched"
    expect(view.insertDraft("") == nil, "an empty draft inserts nothing")
    expectEqual(view.string, "untouched", "and leaves the text alone")
    expect(view.draftRange == nil, "and marks nothing")
}

// MARK: - Undo

private func testOneUndoStep() {
    let view = makeEditor()
    view.string = "original"
    view.undoManager?.removeAllActions()
    view.setSelectedRange(NSRange(location: 8, length: 0))

    view.insertDraft("SELECT 1 FROM t;")
    expectEqual(view.undoManager?.undoActionName, "Insert Draft",
                "the undo step is named for what it did")
    expect(view.undoManager?.canUndo == true, "the insert is undoable")

    settle()
    view.undoManager?.undo()
    expectEqual(view.string, "original", "ONE undo takes the whole draft back out")
}

/// Edit ▸ Undo reaches the editor's OWN undo stack. The menu sends `undo:`
/// down the responder chain; without the editor answering it, the first
/// responder to do so is the window, whose manager holds nothing — the fault
/// that left ⌘Z dead in the app from 2026-09-04 until 2026-09-15.
private func testMenuUndoReachesTheEditorStack() {
    let view = makeEditor()
    view.string = "original"
    view.undoManager?.removeAllActions()
    view.setSelectedRange(NSRange(location: 8, length: 0))
    view.insertDraft("SELECT 1 FROM t;")
    settle()

    let undo = Selector(("undo:"))
    let redo = Selector(("redo:"))
    expect(view.responds(to: undo), "the editor answers undo: itself")
    let menuItem = NSMenuItem(title: "Undo", action: undo, keyEquivalent: "z")
    expect(view.validateUserInterfaceItem(menuItem), "Undo validates while the stack has a step")

    // What the Edit menu does: the action travels down the chain from the
    // first responder. The window is the first responder's window.
    _ = view.window?.perform(undo, with: nil) // the OLD path: must be harmless now
    view.string = "original"; view.undoManager?.removeAllActions()
    view.setSelectedRange(NSRange(location: 8, length: 0))
    view.insertDraft("SELECT 1 FROM t;"); settle()
    _ = view.perform(undo, with: nil)
    expectEqual(view.string, "original", "undo: on the editor takes the draft out")
    expect(view.validateUserInterfaceItem(NSMenuItem(title: "Redo", action: redo, keyEquivalent: "Z")),
           "Redo validates after an undo")
    _ = view.perform(redo, with: nil)
    expectEqual(view.string, "originalSELECT 1 FROM t;", "redo: puts it back")
}

/// The analyst's own typing must not join the insert's undo group — otherwise
/// one ⌘Z after a draft would delete work they did afterwards.
private func testLaterTypingIsItsOwnUndoStep() {
    let view = makeEditor()
    view.string = "original"
    view.undoManager?.removeAllActions()
    view.setSelectedRange(NSRange(location: 8, length: 0))
    view.insertDraft("SELECT 1;")

    settle()
    view.setSelectedRange(NSRange(location: 0, length: 0))
    view.insertText("z", replacementRange: view.selectedRange())
    expectEqual(view.string, "zoriginalSELECT 1;", "the analyst types after the draft")

    settle()
    view.undoManager?.undo()
    expectEqual(view.string, "originalSELECT 1;", "the first undo takes back only the typing")

    settle()
    view.undoManager?.undo()
    expectEqual(view.string, "original", "the second takes back the draft")
}

// MARK: - The mark

/// `updateBracketHighlight` clears every `.backgroundColor` temporary
/// attribute in the document on each caret move. The mark has to be laid on
/// again after it, or it would go on the first arrow key instead of the first
/// edit.
private func testMarkSurvivesACaretMove() {
    let view = makeEditor()
    view.string = ""
    view.setSelectedRange(NSRange(location: 0, length: 0))
    view.insertDraft("SELECT 1 FROM t;")

    view.setSelectedRange(NSRange(location: 3, length: 0))
    expect(background(of: view, at: 1) != nil, "the mark survives a caret move")
    expectEqual(view.draftRange, NSRange(location: 0, length: 16), "and the range is still held")

    view.setSelectedRange(NSRange(location: 16, length: 0))
    expect(background(of: view, at: 5) != nil, "…and a second one")
}

private func testMarkGoesOnTheFirstEdit() {
    let view = makeEditor()
    view.string = ""
    view.setSelectedRange(NSRange(location: 0, length: 0))
    view.insertDraft("SELECT 1 FROM t;")
    expect(view.draftRange != nil, "the mark is on before the edit")

    settle()
    view.setSelectedRange(NSRange(location: 16, length: 0))
    view.insertText("z", replacementRange: view.selectedRange())

    expect(view.draftRange == nil, "the first edit takes the mark away")
    expect(background(of: view, at: 5) == nil, "and the background attribute with it")
}

private func testMarkGoesOnATabSwitch() {
    let view = makeEditor()
    view.string = ""
    view.setSelectedRange(NSRange(location: 0, length: 0))
    view.insertDraft("SELECT 1 FROM t;")

    // What `QueryEditorVC.setSQL` calls when the pane shows another tab: the
    // marked range names characters in text that is about to be replaced.
    view.clearDraftHighlight()
    expect(view.draftRange == nil, "a tab switch clears the mark")
    expect(background(of: view, at: 1) == nil, "and its background attribute")
}

// MARK: - Entry point

func runTests() {
    testMenuUndoReachesTheEditorStack()
    testInsertReplacesTheSelection()
    testEmptyDraftIsRefused()
    testOneUndoStep()
    testLaterTypingIsItsOwnUndoStep()
    testMarkSurvivesACaretMove()
    testMarkGoesOnTheFirstEdit()
    testMarkGoesOnATabSwitch()

    if failures == 0 {
        print("\nAll SQL draft insert tests passed.")
    } else {
        print("\n\(failures) test(s) FAILED.")
        exit(1)
    }
}
