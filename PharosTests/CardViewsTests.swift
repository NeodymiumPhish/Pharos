// Standalone test for the query card views (name row, card, preview, folded
// versions). Compiled by scripts/test-card-views.sh.
//
// Clicks are sent through `hitTest` from the window's content view, the way
// AppKit routes a real click: on macOS 26 scroll chrome and glass can sit over
// a control and take its clicks, and a test that calls `performClick` on the
// button directly would never see that.
import AppKit

private var failures = 0

private func expect(_ condition: Bool, _ name: String, _ detail: @autoclosure () -> String = "") {
    if condition { print("PASS \(name)") } else {
        failures += 1
        let d = detail()
        print("FAIL \(name)" + (d.isEmpty ? "" : "\n  \(d)"))
    }
}

private func ran(_ sql: String, rows: Int = 1420) -> QueryCard {
    var c = QueryCard(name: "Active users", sql: sql)
    c.colorIndex = 0
    c.lastRun = CardRunRecord(runId: "r", rawSQL: sql, renderedSQL: sql, finishedAt: Date(), executionTimeMs: 45,
                              summary: .rows(count: rows, hasMore: false), historyResultId: "h")
    return c
}

private func presentation(_ card: QueryCard, edited: Bool = false, activity: CardActivity = .idle,
                          displayed: Bool = false, versions: Int = 1) -> CardPresentation {
    CardPresentation.make(card: card, position: 1, lineageCount: versions, isEdited: edited, activity: activity,
                          resultInMemory: card.lastRun != nil, isDisplayed: displayed)
}

/// A card in an off-screen window, laid out, ready for hit-testing.
private final class Fixture {
    let window: NSWindow
    let card: CardView

    init() {
        window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 720, height: 300),
                          styleMask: [.titled], backing: .buffered, defer: false)
        let root = NSView(frame: NSRect(x: 0, y: 0, width: 720, height: 300))
        window.contentView = root
        card = CardView(cardId: "c1")
        card.frame = NSRect(x: 10, y: 10, width: 700, height: 200)
        card.bodyHeight = 120
        card.setBody(NSView())
        root.addSubview(card)
        window.setFrameOrigin(NSPoint(x: -20_000, y: -20_000))
        window.orderFrontRegardless()
    }

    func layout() {
        window.contentView?.layoutSubtreeIfNeeded()
        card.layoutSubtreeIfNeeded()
        card.header.layoutSubtreeIfNeeded()
    }

    /// The view a click at the centre of `button` lands on.
    func hit(_ button: NSView) -> NSView? {
        layout()
        let centre = NSPoint(x: button.bounds.midX, y: button.bounds.midY)
        let inRoot = window.contentView!.convert(centre, from: button)
        return window.contentView!.hitTest(inRoot)
    }

    /// Click `button` the way AppKit would: hit-test, then click what was hit.
    func click(_ button: NSButton) -> Bool {
        guard let target = hit(button) as? NSButton else { return false }
        target.performClick(nil)
        return target === button
    }
}

private func testNameRowStates() {
    let f = Fixture()
    let h = f.card.header

    h.apply(presentation(QueryCard(sql: "SELECT 1")), color: nil, isCollapsed: false, meta: "")
    f.layout()
    expect(!h.runButton.isHidden && h.resultsButton.isHidden && h.runReplaceButton.isHidden && h.cancelButton.isHidden,
           "draft: Run only")
    expect(h.nameLabel.stringValue == "Untitled query", "draft: placeholder name")

    h.apply(presentation(ran("SELECT 1"), displayed: true), color: .systemBlue, isCollapsed: false, meta: "just now · 45 ms")
    expect(!h.resultsButton.isHidden && h.resultsButton.attributedTitle.string == "Showing Results · 1,420 rows",
           "displayed: the filled button says Showing Results", "got \(h.resultsButton.attributedTitle.string)")
    expect(h.resultsButton.bezelColor != nil, "displayed: the button is the one prominent button")
    expect(h.metaLabel.stringValue == "just now · 45 ms" && !h.metaLabel.isHidden, "meta shown")

    h.apply(presentation(ran("SELECT 1")), color: .systemBlue, isCollapsed: false, meta: "")
    expect(h.resultsButton.attributedTitle.string == "View Results · 1,420 rows" && h.resultsButton.bezelColor == nil,
           "not displayed: View Results, not filled")

    h.apply(presentation(ran("SELECT 1"), edited: true), color: .systemBlue, isCollapsed: false, meta: "")
    expect(!h.runReplaceButton.isHidden, "edited: Run and Replace appears next to Run")

    h.apply(presentation(ran("SELECT 1"), activity: .running(startedAt: Date())), color: .systemBlue, isCollapsed: false, meta: "")
    expect(!h.cancelButton.isHidden && h.runButton.isHidden, "running: Cancel instead of Run")
}

private func testClicksReachTheButtons() {
    let f = Fixture()
    let h = f.card.header
    var ran = 0, replaced = 0, viewed = 0, cancelled = 0
    h.onRun = { ran += 1 }
    h.onRunReplace = { replaced += 1 }
    h.onViewResults = { viewed += 1 }
    h.onCancel = { cancelled += 1 }

    h.apply(presentation(ranCard(), edited: true), color: .systemBlue, isCollapsed: false, meta: "")
    expect(f.click(h.runButton) && ran == 1, "click: Run reaches its button through hit-testing")
    expect(f.click(h.runReplaceButton) && replaced == 1, "click: Run and Replace reaches its button")
    expect(f.click(h.resultsButton) && viewed == 1, "click: View Results reaches its button")
    h.apply(presentation(ranCard(), activity: .waiting), color: .systemBlue, isCollapsed: false, meta: "")
    expect(f.click(h.cancelButton) && cancelled == 1, "click: Cancel on a waiting card reaches its button")
}

private func ranCard() -> QueryCard { ran("SELECT 1") }

private func testIdentifiersAndSizes() {
    let f = Fixture()
    f.card.header.setIdentifiers(prefix: "editor.card.3")
    expect(f.card.header.runButton.accessibilityIdentifier() == "editor.card.3.run", "ids: run")
    expect(f.card.header.resultsButton.accessibilityIdentifier() == "editor.card.3.viewResults", "ids: view results")
    expect(f.card.header.runReplaceButton.accessibilityIdentifier() == "editor.card.3.runReplace", "ids: run and replace")

    f.card.bodyHeight = 120
    expect(f.card.fittingHeight == CardHeaderView.height + 121, "size: name row + body + separator", "got \(f.card.fittingHeight)")
    f.card.isCollapsed = true
    expect(f.card.fittingHeight == CardHeaderView.height, "size: a collapsed card is its name row")
    f.layout()
    expect(f.card.body?.isHidden == true, "size: a collapsed card hides its body")
}

private func testPreview() {
    let preview = CardPreviewView(frame: NSRect(x: 0, y: 0, width: 600, height: 100))
    let font = NSFont.monospacedSystemFont(ofSize: 13, weight: .regular)
    preview.show(sql: "SELECT 1", font: font, theme: .default, wraps: false, showsLineNumbers: true, variableNames: [])
    let one = preview.height(forWidth: 600)
    preview.show(sql: "SELECT 1\nFROM t\nWHERE x", font: font, theme: .default, wraps: false, showsLineNumbers: true, variableNames: [])
    let three = preview.height(forWidth: 600)
    let line = NSLayoutManager().defaultLineHeight(for: font)
    expect(abs((three - one) - 2 * line) < 1, "preview: each extra line adds one line height", "one \(one), three \(three), line \(line)")
    let long = String(repeating: "x ", count: 400)
    preview.show(sql: long, font: font, theme: .default, wraps: true, showsLineNumbers: false, variableNames: [])
    expect(preview.height(forWidth: 300) > preview.height(forWidth: 1200), "preview: with wrap on, a narrower card is taller")

    var activated: Int?
    preview.onActivate = { activated = $0 }
    preview.show(sql: "SELECT 1\nFROM t", font: font, theme: .default, wraps: false, showsLineNumbers: false, variableNames: [])
    _ = preview.height(forWidth: 600)
    let window = NSWindow(contentRect: preview.frame, styleMask: [.titled], backing: .buffered, defer: false)
    window.contentView = preview
    let lineHeight = NSLayoutManager().defaultLineHeight(for: font)
    let point = preview.convert(NSPoint(x: CardPreviewView.inset.width + 2, y: CardPreviewView.inset.height + lineHeight * 1.5), to: nil)
    let event = NSEvent.mouseEvent(with: .leftMouseDown, location: point, modifierFlags: [], timestamp: 0,
                                   windowNumber: window.windowNumber, context: nil, eventNumber: 0, clickCount: 1, pressure: 1)!
    preview.mouseDown(with: event)
    expect(activated == 9, "preview: a click on the second line's start asks for the editor there", "got \(String(describing: activated))")
}

private func testVersionGroup() {
    let group = VersionGroupView(frame: NSRect(x: 0, y: 0, width: 500, height: VersionGroupView.height))
    group.show(name: "Active users", versions: [("a1", 1), ("a2", 2)])
    expect(group.accessibilityLabel() == "2 earlier versions of Active users", "group: label", "got \(String(describing: group.accessibilityLabel()))")
    var expanded = false
    group.onExpand = { expanded = true }
    _ = group.accessibilityPerformPress()
    expect(expanded, "group: VoiceOver press opens the versions")
}

func runTests() {
    testNameRowStates()
    testClicksReachTheButtons()
    testIdentifiersAndSizes()
    testPreview()
    testVersionGroup()
    if failures == 0 { print("\nAll card view tests passed.") } else { print("\n\(failures) failure(s)."); exit(1) }
}
