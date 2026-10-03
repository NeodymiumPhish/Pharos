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
    var expanded = false
    group.onExpand = { expanded = true }
    _ = group.accessibilityPerformPress()
    expect(expanded, "group: VoiceOver press opens the versions")
}

func runTests() {
    testNameRowStates()
    testClicksReachTheButtons()
    testIdentifiersAndSizes()
    testBodyLeavesTheBorderVisible()
    testNameRowAtZeroWidth()
    testPreview()
    testVersionGroup()
    if failures == 0 { print("\nAll card view tests passed.") } else { print("\n\(failures) failure(s)."); exit(1) }
}
