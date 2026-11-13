// Standalone test for a card's "Describe the query" strip (CardDraftView),
// where the card puts it, and the name row's Describe button. Compiled by
// scripts/test-card-draft-view.sh.
import AppKit

private var failures = 0

private func expect(_ condition: Bool, _ name: String, _ detail: @autoclosure () -> String = "") {
    if condition { print("PASS \(name)") } else {
        failures += 1
        let d = detail()
        print("FAIL \(name)" + (d.isEmpty ? "" : "\n  \(d)"))
    }
}

/// A card with a strip, in an off-screen window.
private final class Fixture {
    let window: NSWindow
    let card = CardView(cardId: "c1")
    let strip = CardDraftView()
    let body = NSView()

    init() {
        window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 720, height: 500),
                          styleMask: [.titled], backing: .buffered, defer: false)
        let root = NSView(frame: NSRect(x: 0, y: 0, width: 720, height: 500))
        window.contentView = root
        card.frame = NSRect(x: 10, y: 10, width: 700, height: 200)
        card.bodyHeight = 120
        card.setBody(body)
        root.addSubview(card)
        window.setFrameOrigin(NSPoint(x: -20_000, y: -20_000))
        window.orderFrontRegardless()
    }

    /// What the card stack does on a layout pass.
    func layout() {
        if card.showsDraft, let draft = card.draftView {
            card.draftHeight = draft.height(forWidth: CardView.contentWidth(cardWidth: card.bounds.width))
        }
        card.frame.size.height = card.fittingHeight
        card.needsLayout = true
        window.contentView?.layoutSubtreeIfNeeded()
        card.layoutSubtreeIfNeeded()
    }

    func click(_ button: NSButton) -> Bool {
        layout()
        let centre = NSPoint(x: button.bounds.midX, y: button.bounds.midY)
        let inRoot = window.contentView!.convert(centre, from: button)
        guard let target = window.contentView!.hitTest(inRoot) as? NSButton else { return false }
        target.performClick(nil)
        return target === button
    }
}

private let draft = CardDraftSession.Draft(
    sql: "SELECT region, count(*)\nFROM orders\nGROUP BY region", note: "Reads public.orders.")

private func visible(_ strip: CardDraftView) -> [String] {
    [(strip.draftButton, "draft"), (strip.stopButton, "stop"), (strip.retryButton, "retry"), (strip.insertButton, "insert")]
        .filter { !$0.0.isHidden }.map(\.1)
}

private func testDescribeButton() {
    let header = CardHeaderView(frame: NSRect(x: 0, y: 0, width: 600, height: CardHeaderView.height))
    let b = header.describeButton
    expect(b.isHidden, "button: hidden until the card offers it")
    header.applyDescribe(CardDescribeState())
    expect(!b.isHidden && b.title.isEmpty && b.imagePosition == .imageOnly, "button: a symbol alone with no description")
    expect(b.toolTip == "Describe the query…" && b.contentTintColor == nil, "button: says what a click does")

    header.applyDescribe(CardDescribeState(isOpen: true, hasSession: true, status: .working))
    expect(b.title.isEmpty && b.contentTintColor == .controlAccentColor, "button: tinted, no words, while the strip shows")
    expect(b.accessibilityValue() as? String == "shown, drafting", "button: VoiceOver hears shown and drafting",
           "\(String(describing: b.accessibilityValue()))")

    header.applyDescribe(CardDescribeState(isOpen: false, hasSession: true, status: .working))
    expect(b.title == "Drafting…" && b.imagePosition == .imageLeading, "button: a hidden draft says it is running")
    header.applyDescribe(CardDescribeState(isOpen: false, hasSession: true, status: .ready))
    expect(b.title == "Draft Ready", "button: a hidden draft says it is ready")
    header.applyDescribe(CardDescribeState(isOpen: false, hasSession: true, status: .failed))
    expect(b.title == "Draft Failed", "button: a hidden draft says it failed")
    header.applyDescribe(CardDescribeState(isOpen: false, hasSession: true, status: .idle))
    expect(b.title.isEmpty && b.toolTip == "Show the description and its draft", "button: a hidden description with no draft")

    var clicks = 0
    header.onDescribe = { clicks += 1 }
    b.performClick(nil)
    expect(clicks == 1, "button: a click goes out")
    header.setIdentifiers(prefix: "editor.card.2")
    expect(b.accessibilityIdentifier() == "editor.card.2.describe", "button: identifier")
    header.applyDescribe(CardDescribeState(adjusts: true))
    expect(b.accessibilityLabel() == "Describe a Change" && b.toolTip?.hasPrefix("Describe a change to this query") == true,
           "button: on a card with SQL it offers a change")
    header.applyDescribe(nil)
    expect(b.isHidden, "button: hidden again when the card stops offering it")
}

private func testStripInTheCard() {
    let f = Fixture()
    f.layout()
    let plain = f.card.fittingHeight
    let bodyY = f.body.frame.minY
    expect(bodyY == CardHeaderView.height + 1, "card: without a strip the body is under the name row")

    f.card.setDraftView(f.strip)
    f.card.showsDraft = true
    f.strip.show(request: "", phase: .editing, adjusts: false, unavailableReason: nil)
    f.layout()
    let h = f.card.draftHeight
    expect(h > 60, "card: the strip has a height", "\(h)")
    expect(f.strip.frame.minY == CardHeaderView.height + 1 && f.strip.frame.height == h, "card: the strip is under the name row")
    expect(f.body.frame.minY == bodyY + h, "card: the body moves down by the strip", "\(f.body.frame)")
    expect(f.card.fittingHeight == plain + h, "card: the card grows by the strip")
    expect(f.card.bodyHeight(forBottomAt: f.card.fittingHeight) == f.card.bodyHeight,
           "card: the height handle still measures the body", "\(f.card.bodyHeight(forBottomAt: f.card.fittingHeight))")

    // Minimized: the strip is kept and hidden, and takes no room.
    f.card.showsDraft = false
    f.layout()
    expect(f.strip.isHidden && f.body.frame.minY == bodyY && f.card.fittingHeight == plain, "card: a hidden strip takes no room")
    expect(f.card.draftView === f.strip, "card: a hidden strip is kept")

    f.card.showsDraft = true
    f.card.isCollapsed = true
    f.layout()
    expect(f.strip.isHidden && f.card.fittingHeight == CardHeaderView.height, "card: a folded card hides its strip")
    f.card.isCollapsed = false
    f.card.setDraftView(nil)
    f.layout()
    expect(f.strip.superview == nil && f.card.fittingHeight == plain, "card: a closed strip is gone")
}

private func testPhases() {
    let f = Fixture()
    let s = f.strip
    f.card.setDraftView(s)
    f.card.showsDraft = true

    s.show(request: "", phase: .editing, adjusts: false, unavailableReason: nil)
    f.layout()
    expect(visible(s) == ["draft"] && !s.draftButton.isEnabled, "editing: Draft alone, off with nothing to ask", "\(visible(s))")
    expect(s.noteLabel.isHidden && s.field.isEnabled, "editing: no note, the field takes text")
    let empty = f.card.draftHeight

    s.show(request: "orders per region", phase: .editing, adjusts: false, unavailableReason: nil)
    expect(s.field.stringValue == "orders per region" && s.draftButton.isEnabled && s.canDraft, "editing: Draft is on with a request")
    var drafts = 0
    s.onDraft = { drafts += 1 }
    expect(f.click(s.draftButton) && drafts == 1, "editing: a click on Draft goes out")

    s.show(request: "orders per region", phase: .editing, adjusts: false,
           unavailableReason: "Connect this tab to a database to draft a query.")
    expect(!s.draftButton.isEnabled && !s.noteLabel.isHidden && s.noteLabel.stringValue.hasPrefix("Connect this tab"),
           "editing: no database, Draft is off and the strip says why")

    s.show(request: "orders per region", phase: .waiting, adjusts: false, unavailableReason: nil)
    f.layout()
    expect(visible(s) == ["stop"] && !s.field.isEnabled, "waiting: Stop alone, the field is held", "\(visible(s))")
    expect(s.progressLabel.stringValue == "Waiting for another card’s draft…", "waiting: says what it waits for")
    s.show(request: "orders per region", phase: .drafting(progress: ""), adjusts: false, unavailableReason: nil)
    expect(s.progressLabel.stringValue == "Drafting…", "drafting: a plain word before the first step")
    s.show(request: "orders per region", phase: .drafting(progress: "Writing the query…"), adjusts: false, unavailableReason: nil)
    expect(s.progressLabel.stringValue == "Writing the query…" && visible(s) == ["stop"], "drafting: the step is named")
    var stops = 0
    s.onStop = { stops += 1 }
    expect(f.click(s.stopButton) && stops == 1, "drafting: a click on Stop goes out")

    s.show(request: "orders per region", phase: .ready(draft), adjusts: true, unavailableReason: nil)
    f.layout()
    expect(visible(s) == ["retry", "insert"] && s.field.isEnabled, "ready: Retry and Insert", "\(visible(s))")
    expect(s.insertButton.title == "Insert as New Version", "ready: Insert says what it will do to a card with text")
    expect(s.field.placeholderString == "Only the last 30 days, newest first"
           && s.field.accessibilityLabel() == "How should this query change?", "a card with text asks for a change")
    s.show(request: "orders per region", phase: .ready(draft), adjusts: false, unavailableReason: nil)
    expect(s.insertButton.title == "Insert" && s.field.accessibilityLabel() == "What should the query return?",
           "ready: and a card with none asks for a query")
    s.show(request: "orders per region", phase: .ready(draft), adjusts: true, unavailableReason: nil)
    f.layout()
    expect(!s.preview.isHidden && s.preview.accessibilityValue() as? String == draft.sql, "ready: the draft is shown")
    expect(s.noteLabel.stringValue == "Reads public.orders." && s.noteLabel.textColor == .secondaryLabelColor, "ready: what it reads")
    expect(f.card.draftHeight > empty + 40, "ready: the strip grows for the draft", "\(f.card.draftHeight) vs \(empty)")
    expect(s.preview.frame.height > 30 && s.preview.window != nil, "ready: the preview has room", "\(s.preview.frame)")
    var inserts = 0, retries = 0
    s.onInsert = { inserts += 1 }
    s.onRetry = { retries += 1 }
    expect(f.click(s.insertButton) && inserts == 1, "ready: a click on Insert goes out")
    expect(f.click(s.retryButton) && retries == 1, "ready: a click on Retry goes out")
    expect(!s.canDraft, "ready: Return does not ask the same question again")

    var caution = draft
    caution.noteIsCaution = true
    s.show(request: "orders per region", phase: .ready(caution), adjusts: false, unavailableReason: nil)
    expect(s.noteLabel.textColor == .systemOrange, "ready: something to check is orange")

    s.show(request: "orders per region", phase: .failed("The model is busy. Try again in a moment."),
           adjusts: false, unavailableReason: nil)
    f.layout()
    expect(visible(s) == ["retry"] && s.preview.superview?.isHidden == true, "failed: Retry alone, no draft", "\(visible(s))")
    expect(s.noteLabel.stringValue.hasPrefix("The model is busy") && s.noteLabel.textColor == .systemOrange, "failed: says why")
}

private func testHideAndClose() {
    let f = Fixture()
    let s = f.strip
    f.card.setDraftView(s)
    f.card.showsDraft = true
    s.show(request: "q", phase: .drafting(progress: ""), adjusts: false, unavailableReason: nil)
    var hides = 0, closes = 0
    s.onMinimize = { hides += 1 }
    s.onClose = { closes += 1 }
    expect(f.click(s.hideButton) && hides == 1 && closes == 0, "hide: a click on Hide goes out, and is not Close")
    expect(f.click(s.closeButton) && closes == 1, "close: a click on Close goes out")
    s.setIdentifiers(prefix: "editor.card.4")
    expect(s.field.accessibilityIdentifier() == "editor.card.4.draft.field"
           && s.insertButton.accessibilityIdentifier() == "editor.card.4.draft.insert"
           && s.hideButton.accessibilityIdentifier() == "editor.card.4.draft.hide", "identifiers")
}

private func testKeysAndTyping() {
    let f = Fixture()
    let s = f.strip
    f.card.setDraftView(s)
    f.card.showsDraft = true
    s.show(request: "", phase: .editing, adjusts: false, unavailableReason: nil)
    f.layout()
    var drafts = 0, hides = 0
    var typed: [String] = []
    s.onDraft = { drafts += 1 }
    s.onMinimize = { hides += 1 }
    s.onRequestChanged = { typed.append($0) }

    f.window.makeKeyAndOrderFront(nil)
    s.focusField()
    guard let editor = s.field.currentEditor() as? NSTextView else {
        expect(false, "keys: the field takes the keyboard")
        return
    }
    expect(s.fieldHasFocus, "keys: the field takes the keyboard")
    expect(s.control(s.field, textView: editor, doCommandBy: #selector(NSResponder.insertNewline(_:))) && drafts == 0,
           "keys: Return with nothing to ask drafts nothing")
    editor.insertText("orders per region", replacementRange: editor.selectedRange())
    expect(typed.last == "orders per region", "typing: every change goes out", "\(typed)")
    expect(s.draftButton.isEnabled, "typing: Draft comes on")

    // A refresh while the analyst types must not write the field back.
    s.show(request: "orders", phase: .editing, adjusts: false, unavailableReason: nil)
    expect(editor.string == "orders per region", "typing: a refresh leaves the field alone")

    expect(s.control(s.field, textView: editor, doCommandBy: #selector(NSResponder.insertNewline(_:))) && drafts == 1,
           "keys: Return drafts")
    expect(!s.control(s.field, textView: editor, doCommandBy: #selector(NSResponder.insertNewlineIgnoringFieldEditor(_:))),
           "keys: Option-Return is left to the field (a new line)")
    expect(s.control(s.field, textView: editor, doCommandBy: #selector(NSResponder.cancelOperation(_:))) && hides == 1,
           "keys: Escape hides the strip")

    let commandReturn = NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: .command, timestamp: 0,
                                         windowNumber: f.window.windowNumber, context: nil, characters: "\r",
                                         charactersIgnoringModifiers: "\r", isARepeat: false, keyCode: 36)!
    expect(s.performKeyEquivalent(with: commandReturn) && drafts == 2, "keys: ⌘↩ in the field drafts, and goes no further")
    f.window.makeFirstResponder(nil)
    expect(!s.performKeyEquivalent(with: commandReturn) && drafts == 2, "keys: ⌘↩ elsewhere is left for Run")

    // A long description gets more lines, up to the limit.
    let before = s.height(forWidth: 690)
    s.show(request: String(repeating: "orders per region and per month ", count: 12), phase: .editing,
           adjusts: false, unavailableReason: nil)
    let after = s.height(forWidth: 690)
    expect(after > before && after - before <= CardDraftView.fieldHeights.upperBound - CardDraftView.fieldHeights.lowerBound,
           "typing: the field grows with the text, to a limit", "\(before) -> \(after)")
}

func runTests() {
    testDescribeButton()
    testStripInTheCard()
    testPhases()
    testHideAndClose()
    testKeysAndTyping()
    if failures == 0 { print("\nAll card draft view tests passed.") } else { print("\n\(failures) failure(s)."); exit(1) }
}
