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

private func testDisclosure() {
    let f = Fixture()
    let h = f.card.header
    var toggled = 0
    h.onToggleCollapse = { toggled += 1 }
    h.apply(presentation(ran("SELECT 1")), color: .systemBlue, isCollapsed: false, meta: "")
    f.layout()
    expect(h.disclosure.isExpanded && h.disclosure.accessibilityLabel() == "Hide SQL", "disclosure: open card says Hide SQL")
    expect(h.disclosure.accessibilityValue() as? String == "expanded", "disclosure: VoiceOver hears expanded")
    // As tall as the Run button beside it: a real button, not a 13 pt triangle.
    expect(abs(h.disclosure.frame.height - h.runButton.frame.height) < 1 && h.disclosure.frame.width >= 20,
           "disclosure: full-size button", "disclosure \(h.disclosure.frame.size), run \(h.runButton.frame.size)")
    expect(f.click(h.disclosure) && toggled == 1, "disclosure: a click reaches it through hit-testing")
    let openNameX = h.nameLabel.frame.minX
    h.apply(presentation(ran("SELECT 1")), color: .systemBlue, isCollapsed: true, meta: "")
    expect(!h.disclosure.isExpanded && h.disclosure.accessibilityLabel() == "Show SQL", "disclosure: folded card says Show SQL")
    f.layout()
    expect(abs(h.nameLabel.frame.minX - openNameX) < 0.5, "disclosure: the name does not move when the card folds",
           "open \(openNameX), folded \(h.nameLabel.frame.minX)")
    h.setIdentifiers(prefix: "editor.card.2")
    expect(h.disclosure.accessibilityIdentifier() == "editor.card.2.disclosure", "disclosure: AX id")
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

/// A tab without a connected database: Run and Run and Replace are greyed
/// out, and say why on hover and on click.
private func testRunUnavailable() {
    let f = Fixture()
    let h = f.card.header
    var ran = 0
    h.onRun = { ran += 1 }
    h.onRunReplace = { ran += 1 }
    let reason = "Not connected to “Prod”."

    h.apply(presentation(ranCard(), edited: true), color: .systemBlue, isCollapsed: false, meta: "")
    f.layout()
    expect(h.runButton.isEnabled && h.runButton.toolTip == "Run (⌘↩)", "available: Run is enabled with its tooltip")

    h.apply(presentation(ranCard(), edited: true), color: .systemBlue, isCollapsed: false, meta: "", runUnavailableReason: reason)
    f.layout()
    expect(!h.runButton.isEnabled && !h.runReplaceButton.isEnabled, "unavailable: Run and Run and Replace are greyed out")
    expect(h.runButton.toolTip == nil, "unavailable: no tooltip over the popover", "got \(String(describing: h.runButton.toolTip))")
    expect(h.runButton.accessibilityHelp() == reason, "unavailable: VoiceOver reads the reason as help")

    // A click goes through hit-testing to the greyed-out button, runs nothing,
    // and shows the reason.
    expect(f.hit(h.runButton) === h.runButton, "unavailable: a click still reaches the button")
    let centre = h.runButton.convert(NSPoint(x: h.runButton.bounds.midX, y: h.runButton.bounds.midY), to: nil)
    let down = NSEvent.mouseEvent(with: .leftMouseDown, location: centre, modifierFlags: [], timestamp: 0,
                                  windowNumber: f.window.windowNumber, context: nil, eventNumber: 0, clickCount: 1, pressure: 1)!
    h.runButton.mouseDown(with: down)
    expect(ran == 0, "unavailable: a click runs nothing")
    expect(h.runButton.isShowingReason, "unavailable: a click shows the reason")

    // One popover at a time: the next button's reason replaces it.
    h.runReplaceButton.showReason(byHover: false)
    expect(h.runReplaceButton.isShowingReason && !h.runButton.isShowingReason, "one popover at a time")
    h.runReplaceButton.closeReason()

    // The window server sends mouseEntered/Exited only through a tracking
    // area; without one the hover below would never happen in the app.
    expect(h.runButton.trackingAreas.contains { $0.owner === h.runButton && $0.options.contains(.mouseEnteredAndExited) },
           "hover: the button has a tracking area for the pointer")
    // Hover: nothing before the delay, the reason after it, gone on exit.
    func crossing(_ type: NSEvent.EventType) -> NSEvent {
        NSEvent.enterExitEvent(with: type, location: centre, modifierFlags: [], timestamp: 0,
                               windowNumber: f.window.windowNumber, context: nil, eventNumber: 0,
                               trackingNumber: 0, userData: nil)!
    }
    h.runButton.mouseEntered(with: crossing(.mouseEntered))
    RunLoop.current.run(until: Date().addingTimeInterval(0.15))
    expect(!h.runButton.isShowingReason, "hover: nothing shows before the delay")
    RunLoop.current.run(until: Date().addingTimeInterval(CardRunButton.hoverDelay + 0.3))
    expect(h.runButton.isShowingReason, "hover: the reason shows after the delay")
    if let popover = f.window.childWindows?.first ?? NSApp.windows.first(where: { $0 !== f.window && $0.isVisible }) {
        let button = h.runButton.window!.convertToScreen(h.runButton.convert(h.runButton.bounds, to: nil))
        expect(popover.frame.maxY <= button.minY + 1, "hover: the popover opens below the button",
               "popover \(popover.frame), button \(button)")
    }
    h.runButton.mouseExited(with: crossing(.mouseExited))
    expect(!h.runButton.isShowingReason, "hover: the reason goes when the pointer leaves")

    // A pointer that passes over without resting opens nothing.
    h.runButton.mouseEntered(with: crossing(.mouseEntered))
    h.runButton.mouseExited(with: crossing(.mouseExited))
    RunLoop.current.run(until: Date().addingTimeInterval(CardRunButton.hoverDelay + 0.3))
    expect(!h.runButton.isShowingReason, "hover: passing over opens nothing")

    // Connected again: enabled, tooltip back, an open reason closes.
    h.runButton.showReason(byHover: false)
    h.apply(presentation(ranCard(), edited: true), color: .systemBlue, isCollapsed: false, meta: "")
    expect(h.runButton.isEnabled && h.runButton.toolTip == "Run (⌘↩)" && h.runButton.accessibilityHelp() == nil,
           "available again: enabled, tooltip back, no help")
    expect(!h.runButton.isShowingReason, "available again: the open reason closes")
    h.runButton.mouseEntered(with: crossing(.mouseEntered))
    RunLoop.current.run(until: Date().addingTimeInterval(CardRunButton.hoverDelay + 0.3))
    expect(!h.runButton.isShowingReason, "available: hover shows no reason")
    expect(f.click(h.runButton) && ran == 1, "available: a click runs the card")
}

private func testIdentifiersAndSizes() {
    let f = Fixture()
    f.card.header.setIdentifiers(prefix: "editor.card.3")
    expect(f.card.header.runButton.accessibilityIdentifier() == "editor.card.3.run", "ids: run")
    expect(f.card.header.resultsButton.accessibilityIdentifier() == "editor.card.3.viewResults", "ids: view results")
    expect(f.card.header.runReplaceButton.accessibilityIdentifier() == "editor.card.3.runReplace", "ids: run and replace")

    f.card.bodyHeight = 120
    expect(f.card.fittingHeight == CardHeaderView.height + 121 + CardView.bodyBottomInset,
           "size: name row + separator + body + bottom inset", "got \(f.card.fittingHeight)")
    f.card.isCollapsed = true
    expect(f.card.fittingHeight == CardHeaderView.height, "size: a collapsed card is its name row")
    f.layout()
    expect(f.card.body?.isHidden == true, "size: a collapsed card hides its body")
}

/// Stands in for an editor: opaque, and drawn (cacheDisplay skips layer backgrounds).
private final class OpaqueRedView: NSView {
    override func draw(_ dirtyRect: NSRect) {
        NSColor(srgbRed: 1, green: 0, blue: 0, alpha: 1).setFill()
        bounds.fill()
    }
    override var isOpaque: Bool { true }
}

/// An opaque body must never paint over the card's border: the bottom edge
/// and the rounded bottom corners stay the card's own (found 2026-10-02 in
/// the app — the body ran to the bottom edge and hid the bottom border).
private func testBodyLeavesTheBorderVisible() {
    let card = CardView(cardId: "c1")
    card.bodyHeight = 60
    let body = OpaqueRedView()
    card.setBody(body)
    card.frame = NSRect(x: 0, y: 0, width: 300, height: card.fittingHeight)
    card.layoutSubtreeIfNeeded()

    let inset = card.bounds.height - body.frame.maxY
    expect(inset >= CardView.bodyBottomInset, "border: the body ends above the bottom edge", "gap \(inset)")
    expect(card.bounds.width - body.frame.maxX >= 2, "border: the body ends left of the 2 pt outline")

    guard let rep = card.bitmapImageRepForCachingDisplay(in: card.bounds) else { expect(false, "border: bitmap"); return }
    card.cacheDisplay(in: card.bounds, to: rep)
    func isBody(_ x: Int, _ y: Int) -> Bool {
        guard let c = rep.colorAt(x: x, y: y), c.numberOfComponents >= 3 else { return false }
        return c.redComponent > 0.8 && c.greenComponent < 0.2 && c.blueComponent < 0.2
    }
    let w = rep.pixelsWide, h = rep.pixelsHigh
    // Either orientation: the rows at both ends, and the columns at the right
    // edge, hold no body pixel; the body itself is there in the middle.
    let scale = max(1, Int((CGFloat(w) / card.bounds.width).rounded()))
    let edge = 3 * scale
    var onBorder = 0
    for x in 0..<w { for y in Array(0..<edge) + Array((h - edge)..<h) where isBody(x, y) { onBorder += 1 } }
    // The displayed-card outline is 2 pt wide: those columns are the border's.
    let right = 2 * scale
    for y in 0..<h { for x in (w - right)..<w where isBody(x, y) { onBorder += 1 } }
    expect(isBody(w / 2, h / 2) || isBody(w / 2, h / 2 + 10 * scale), "border: the body is drawn",
           "body \(body.frame)")
    expect(onBorder == 0, "border: no body pixel on the bottom or right border", "\(onBorder) pixels")
}

/// Required horizontal constraints under `view` that the laid-out alignment
/// rectangles do not satisfy — what Xcode reports as "Conflicting constraints
/// detected … will attempt to recover by breaking". A standalone binary does
/// not print those reports, so the test measures the result instead.
/// Intrinsic-size constraints are skipped: their real priorities are the
/// hugging and compression priorities.
private func brokenRequiredConstraints(in view: NSView, root: NSView) -> [NSLayoutConstraint] {
    func x(_ item: AnyObject?, _ a: NSLayoutConstraint.Attribute) -> CGFloat? {
        let rect: NSRect
        if let v = item as? NSView, let sup = v.superview { rect = sup.convert(v.alignmentRect(forFrame: v.frame), to: root) }
        else if let g = item as? NSLayoutGuide, let owner = g.owningView { rect = owner.convert(g.frame, to: root) }
        else { return nil }
        switch a {
        case .leading, .left: return rect.minX
        case .trailing, .right: return rect.maxX
        case .width: return rect.width
        case .centerX: return rect.midX
        default: return nil
        }
    }
    var broken: [NSLayoutConstraint] = []
    var views = [view]
    while let v = views.popLast() {
        views.append(contentsOf: v.subviews)
        for c in v.constraints where c.isActive && c.priority == .required
            && !String(describing: type(of: c)).contains("ContentSize") {
            guard let v1 = x(c.firstItem, c.firstAttribute) else { continue }
            var v2: CGFloat = 0
            if c.secondItem != nil { guard let s = x(c.secondItem, c.secondAttribute) else { continue }; v2 = s }
            let rhs = c.multiplier * v2 + c.constant
            let holds: Bool = switch c.relation {
            case .equal: abs(v1 - rhs) < 0.5
            case .lessThanOrEqual: v1 <= rhs + 0.5
            case .greaterThanOrEqual: v1 >= rhs - 0.5
            @unknown default: true
            }
            if !holds { broken.append(c) }
        }
    }
    return broken
}

/// A card's name row is laid out once at width 0, before the stack gives the
/// card a frame. No required constraint may break there (found 2026-10-03:
/// Xcode logged a broken constraint for every card on every reload).
private func testNameRowAtZeroWidth() {
    let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 600, height: 100), styleMask: [.titled], backing: .buffered, defer: false)
    let root = NSView(frame: NSRect(x: 0, y: 0, width: 600, height: 100))
    window.contentView = root
    let header = CardHeaderView(frame: .zero)
    root.addSubview(header)
    header.apply(presentation(ran("SELECT 1"), edited: true, activity: .running(startedAt: Date()), versions: 2),
                 color: .systemBlue, isCollapsed: false, meta: "just now · 3 ms")
    root.layoutSubtreeIfNeeded()
    let atZero = brokenRequiredConstraints(in: header, root: root)
    expect(atZero.isEmpty, "zero width: no required constraint breaks in the name row", atZero.map(\.description).joined(separator: "\n  "))
    header.frame = NSRect(x: 0, y: 0, width: 600, height: CardHeaderView.height)
    root.layoutSubtreeIfNeeded()
    expect(brokenRequiredConstraints(in: header, root: root).isEmpty, "full width: none breaks either")

    // The folded-versions row and the results header have the same shape.
    let group = VersionGroupView(frame: .zero)
    root.addSubview(group)
    group.show(name: "A rather long query name", versions: [("a", 1), ("b", 2)])
    let resultsHeader = CardResultsHeaderView(frame: .zero)
    root.addSubview(resultsHeader)
    root.layoutSubtreeIfNeeded()
    expect(brokenRequiredConstraints(in: group, root: root).isEmpty, "zero width: none breaks in the folded-versions row")
    expect(brokenRequiredConstraints(in: resultsHeader, root: root).isEmpty, "zero width: none breaks in the results header")
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
    var toggled = 0
    group.onToggle = { toggled += 1 }
    _ = group.accessibilityPerformPress()
    expect(toggled == 1, "group: VoiceOver press opens the versions")
    expect(!group.disclosure.isExpanded && group.disclosure.accessibilityLabel() == "Show Earlier Versions",
           "group: folded, the chevron says Show Earlier Versions")

    // Open: the same row is the versions' header, and folds them again.
    group.show(name: "Active users", versions: [("a1", 1), ("a2", 2)], isExpanded: true)
    expect(group.disclosure.isExpanded && group.disclosure.accessibilityLabel() == "Hide Earlier Versions",
           "group: open, the chevron says Hide Earlier Versions")
    expect(group.accessibilityLabel() == "2 earlier versions of Active users", "group: open, the same label")
    group.disclosure.performClick(nil)
    expect(toggled == 2, "group: open, the chevron folds them again")
}

/// The image the Notes button shows for `name`, drawn, to compare.
private func symbolData(_ name: String) -> Data? {
    NSImage(systemSymbolName: name, accessibilityDescription: "Notes")?
        .withSymbolConfiguration(.init(pointSize: 12, weight: .medium))?.tiffRepresentation
}

private func testNotesButton() {
    let f = Fixture()
    let b = f.card.header.notesButton
    let trailing = b.superview?.subviews ?? []
    let more = f.card.header.moreButton
    expect(trailing.firstIndex(of: b).map { $0 + 1 } == trailing.firstIndex(of: more), "notes button: just left of ⋯")

    expect(symbolData("doc.text") != nil && symbolData("doc.text") != symbolData("doc.text.fill"),
           "notes button: the two symbols exist and differ")
    f.card.header.applyNotes(hasNotes: false, isOpen: false, offersImport: false)
    expect(b.image?.tiffRepresentation == symbolData("doc.text"), "notes button: hollow without notes")
    expect(b.title.isEmpty && b.imagePosition == .imageOnly, "notes button: icon only")
    expect(b.accessibilityValue() as? String == "no notes" && b.toolTip == "Show Notes", "notes button: says no notes, Show")
    expect(b.contentTintColor == nil, "notes button: no tint while closed")

    f.card.header.applyNotes(hasNotes: true, isOpen: true, offersImport: false)
    expect(b.image?.tiffRepresentation == symbolData("doc.text.fill"), "notes button: filled with notes")
    expect(b.accessibilityValue() as? String == "has notes" && b.toolTip == "Hide Notes", "notes button: says has notes, Hide")
    expect(b.contentTintColor == .controlAccentColor, "notes button: accent while open")

    f.layout()
    let iconWidth = b.frame.width
    f.card.header.applyNotes(hasNotes: false, isOpen: false, offersImport: true)
    f.layout()
    expect(b.title == "Import Comments to Note" && b.imagePosition == .imageLeading, "notes button: offers the import")
    expect(b.accessibilityLabel() == "Import Comments to Note", "notes button: VoiceOver reads the offer")
    expect(b.frame.width > iconWidth + 60, "notes button: the offer widens it", "\(iconWidth) → \(b.frame.width)")

    var clicks = 0
    f.card.header.onNotes = { clicks += 1 }
    expect(f.click(b) && clicks == 1, "notes button: a click reaches it")
    f.card.header.setIdentifiers(prefix: "editor.card.2")
    expect(b.accessibilityIdentifier() == "editor.card.2.notes", "notes button: id")

    // The offer must not break the name row at zero width either.
    let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 600, height: 100), styleMask: [.titled], backing: .buffered, defer: false)
    let root = NSView(frame: NSRect(x: 0, y: 0, width: 600, height: 100))
    window.contentView = root
    let header = CardHeaderView(frame: .zero)
    root.addSubview(header)
    header.apply(presentation(ran("SELECT 1")), color: .systemBlue, isCollapsed: false, meta: "just now")
    header.applyNotes(hasNotes: false, isOpen: false, offersImport: true)
    root.layoutSubtreeIfNeeded()
    let broken = brokenRequiredConstraints(in: header, root: root)
    expect(broken.isEmpty, "notes button: no required constraint breaks at zero width", broken.map(\.description).joined(separator: "\n  "))
}

private func testNotesLayout() {
    // The split of a body between the SQL and the notes.
    let wide = CardView.split(contentWidth: 1000, showsNotes: true)
    expect(wide.notes == 370 && wide.sql == 630, "notes layout: 37% of a wide card", "\(wide)")
    let narrow = CardView.split(contentWidth: 400, showsNotes: true)
    expect(narrow.notes == 180, "notes layout: at least 180 pt", "\(narrow)")
    let tiny = CardView.split(contentWidth: 300, showsNotes: true)
    expect(tiny.notes == 150 && tiny.sql == 150, "notes layout: never more than half", "\(tiny)")
    expect(CardView.split(contentWidth: 1000, showsNotes: false) == (1000, 0), "notes layout: closed, the SQL has it all")

    let card = CardView(cardId: "c1")
    card.bodyHeight = 120
    let body = NSView()
    card.setBody(body)
    let notes = CardNotesView()
    card.setNotesView(notes)
    card.frame = NSRect(x: 0, y: 0, width: 1006, height: card.fittingHeight)
    card.layoutSubtreeIfNeeded()
    expect(notes.isHidden, "notes layout: hidden until shown")
    expect(body.frame.width == CardView.contentWidth(cardWidth: 1006), "notes layout: hidden notes take no width")

    card.showsNotes = true
    card.layoutSubtreeIfNeeded()
    let content = CardView.contentWidth(cardWidth: 1006)
    expect(!notes.isHidden, "notes layout: shown")
    expect(body.frame.width + notes.frame.width == content && notes.frame.minX == body.frame.maxX,
           "notes layout: SQL then notes, edge to edge", "body \(body.frame) notes \(notes.frame)")
    expect(notes.frame.minY == body.frame.minY && notes.frame.height == 120, "notes layout: the full body height",
           "\(notes.frame)")
    expect(card.bounds.width - notes.frame.maxX >= CardView.bodyTrailingInset, "notes layout: the border stays clear")

    // Swapping the body (editor ↔ preview) keeps the notes.
    let preview = NSView()
    card.setBody(preview)
    card.layoutSubtreeIfNeeded()
    expect(notes.superview === card && preview.frame.width == body.frame.width, "notes layout: a body swap keeps the notes")

    card.isCollapsed = true
    card.layoutSubtreeIfNeeded()
    expect(notes.isHidden, "notes layout: a collapsed card hides the notes")
}

private func testNotesHeight() {
    let notes = CardNotesView(frame: NSRect(x: 0, y: 0, width: 300, height: 100))
    expect(notes.height(forWidth: 300) == CardNotesView.minHeight, "notes height: empty notes are the minimum")
    notes.setText((1...20).map { "Line \($0) of the notes." }.joined(separator: "\n"))
    let tall = notes.height(forWidth: 300)
    expect(tall > 200, "notes height: twenty lines are taller", "\(tall)")
    notes.setText(String(repeating: "word ", count: 200))
    expect(notes.height(forWidth: 150) > notes.height(forWidth: 400), "notes height: a narrower area wraps taller")

    var changes: [String] = []
    notes.onChange = { changes.append($0) }
    notes.setText("set by the model")
    expect(changes.isEmpty, "notes height: setText is not an edit")
    notes.textView.insertText("!", replacementRange: NSRange(location: notes.text.utf16.count, length: 0))
    expect(changes.last == "set by the model!", "notes height: typing is an edit", "\(changes)")
    expect(!notes.textView.isAutomaticQuoteSubstitutionEnabled && !notes.textView.isRichText,
           "notes height: plain text, typed quotes kept")

    // While the user types in the notes, the model does not reset them; an
    // import (force) does, or the next keystroke would write the old text back.
    let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 400, height: 200), styleMask: [.titled], backing: .buffered, defer: false)
    window.contentView = NSView(frame: NSRect(x: 0, y: 0, width: 400, height: 200))
    window.contentView!.addSubview(notes)
    window.setFrameOrigin(NSPoint(x: -20_000, y: -20_000))
    window.orderFrontRegardless()
    // Ordering the window front can already focus the text view, so the
    // reset is forced.
    notes.setText("", force: true)
    expect(window.makeFirstResponder(notes.textView), "notes focus: the text view takes the keyboard")
    notes.setText("from the model")
    expect(notes.text.isEmpty, "notes focus: a focused view keeps what the user has")
    notes.setText("imported", force: true)
    expect(notes.text == "imported", "notes focus: an import replaces it anyway")
    window.orderOut(nil)
}

private func mouse(_ type: NSEvent.EventType, at p: NSPoint, in view: NSView, clicks: Int = 1) -> NSEvent {
    NSEvent.mouseEvent(with: type, location: view.convert(p, to: nil), modifierFlags: [], timestamp: 0,
                       windowNumber: view.window!.windowNumber, context: nil, eventNumber: 0,
                       clickCount: clicks, pressure: 1)!
}

private func testNotesDivider() {
    // The width rule with a dragged fraction.
    expect(CardNotesView.width(forBody: 1000, fraction: 0.5) == 500, "divider: half")
    expect(CardNotesView.width(forBody: 1000, fraction: 0.05) == 180, "divider: never narrower than 180")
    expect(CardNotesView.width(forBody: 1000, fraction: 0.95) == 760, "divider: the SQL keeps 240")
    expect(CardView.split(contentWidth: 1000, showsNotes: true, fraction: 0.6) == (400, 600), "divider: split follows the fraction")

    let f = Fixture()
    let card = f.card
    card.frame = NSRect(x: 10, y: 10, width: 700, height: 200)
    let notes = CardNotesView()
    card.setNotesView(notes)
    f.layout()
    expect(card.notesDivider.isHidden, "divider: hidden while the notes are")
    card.showsNotes = true
    f.layout()
    let line = notes.frame.minX
    expect(!card.notesDivider.isHidden && abs(card.notesDivider.frame.midX - line) < 0.5,
           "divider: centred on the line", "\(card.notesDivider.frame) line \(line)")
    expect(card.notesDivider.frame.height == notes.frame.height, "divider: the notes' full height")
    for dx: CGFloat in [-3, 0, 3] {
        let p = window(f).contentView!.convert(NSPoint(x: line + dx, y: notes.frame.midY), from: card)
        expect(window(f).contentView!.hitTest(p) === card.notesDivider, "divider: a click \(dx) pt from the line reaches it")
    }
    expect(card.notesDivider.accessibilityRole() == .splitter, "divider: VoiceOver reads a splitter")

    // The fraction for a divider position, clamped.
    let content = CardView.contentWidth(cardWidth: 700)
    let half = card.notesFraction(forDividerAt: CardView.stripeWidth + content / 2)
    expect(abs(half - 0.5) < 0.01, "divider: the middle is half", "\(half)")
    expect(card.notesFraction(forDividerAt: card.bounds.width) * content == 180, "divider: dragged to the edge stops at 180")
    expect(card.notesFraction(forDividerAt: 0) * content == content - 240, "divider: dragged left stops at the SQL's 240")

    // A drag: the tracking loop reports each position and the end.
    var xs: [CGFloat] = []
    var ended = 0
    card.notesDivider.onDrag = { xs.append($0) }
    card.notesDivider.onDragEnd = { ended += 1 }
    let d = card.notesDivider
    NSApp.postEvent(mouse(.leftMouseUp, at: NSPoint(x: 4, y: 20), in: d), atStart: false)
    NSApp.postEvent(mouse(.leftMouseDragged, at: NSPoint(x: -96, y: 20), in: d), atStart: true)
    d.mouseDown(with: mouse(.leftMouseDown, at: NSPoint(x: 4, y: 20), in: d))
    expect(ended == 1 && xs.count == 2, "divider: a drag reports its moves and its end", "\(xs) ended \(ended)")
    expect(xs.first.map { abs($0 - (d.frame.minX - 96)) < 0.5 } == true, "divider: positions are in the card's coordinates",
           "\(xs) divider \(d.frame)")
    card.notesFraction = card.notesFraction(forDividerAt: xs[0])
    f.layout()
    expect(abs(notes.frame.minX - xs[0]) < 1, "divider: the notes follow the drag", "\(notes.frame.minX) vs \(xs[0])")

    var resets = 0
    d.onReset = { resets += 1 }
    d.mouseDown(with: mouse(.leftMouseDown, at: NSPoint(x: 4, y: 20), in: d, clicks: 2))
    expect(resets == 1, "divider: a double-click resets")
    while NSApp.nextEvent(matching: .any, until: nil, inMode: .default, dequeue: true) != nil {}
}

private func window(_ f: Fixture) -> NSWindow { f.window }

func runTests() {
    testNameRowStates()
    testClicksReachTheButtons()
    testRunUnavailable()
    testDisclosure()
    testIdentifiersAndSizes()
    testBodyLeavesTheBorderVisible()
    testNameRowAtZeroWidth()
    testPreview()
    testVersionGroup()
    testNotesButton()
    testNotesLayout()
    testNotesHeight()
    testNotesDivider()
    if failures == 0 { print("\nAll card view tests passed.") } else { print("\n\(failures) failure(s)."); exit(1) }
}
