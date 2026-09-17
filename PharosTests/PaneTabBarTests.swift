// Standalone test runner for PaneTabBar — the editor's tab bar. Compiled by
// scripts/test-pane-tab-bar.sh with the real bar, the real WindowSession (the
// bar holds one weakly) and the model tail behind QueryTab.
//
// Everything is measured off the real NSSegmentedControl: segment widths,
// labels, the control's frame. Hover is driven with a synthetic mouseMoved
// event, so the close-slot rule is exercised through the bar's own tracking
// code rather than through a test-only setter.
import AppKit

var failures = 0

func expectEqual<T: Equatable>(_ actual: T, _ expected: T, _ name: String) {
    if actual == expected { print("PASS \(name)") } else {
        failures += 1
        print("FAIL \(name)\n  expected: \(expected)\n  actual:   \(actual)")
    }
}

func expectClose(_ actual: CGFloat, _ expected: CGFloat, _ name: String, tolerance: CGFloat = 0.5) {
    if abs(actual - expected) <= tolerance { print("PASS \(name)") } else {
        failures += 1
        print("FAIL \(name)\n  expected: \(expected) ± \(tolerance)\n  actual:   \(actual)")
    }
}

func expectTrue(_ actual: Bool, _ name: String) {
    if actual { print("PASS \(name)") } else { failures += 1; print("FAIL \(name) — expected true") }
}

// MARK: - Fixtures

private func tab(_ name: String, dirty: Bool = false, running: Bool = false) -> QueryTab {
    var t = QueryTab(id: name, name: name)
    t.isDirty = dirty
    if running {
        t.runningQueries = [RunningQuery(id: "q-\(name)", normalizedSQL: "select 1", segmentIndex: 0,
                                         lineRange: 1...1, startTime: 0)]
    }
    return t
}

/// The bar in a never-shown window, in a plain root subview with a REQUIRED
/// width — a window grows to its content, a constrained container cannot, so
/// only the container exercises the overflow paths.
private final class Host {
    let window: NSWindow
    let container: NSView
    let bar = PaneTabBar()
    let widthConstraint: NSLayoutConstraint

    init(width: CGFloat) {
        window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: width, height: 32),
                          styleMask: [.borderless], backing: .buffered, defer: false)
        let root = NSView(frame: NSRect(x: 0, y: 0, width: width, height: 32))
        window.contentView = root
        container = NSView()
        container.translatesAutoresizingMaskIntoConstraints = false
        root.addSubview(container)
        widthConstraint = container.widthAnchor.constraint(equalToConstant: width)
        bar.translatesAutoresizingMaskIntoConstraints = false
        container.addSubview(bar)
        NSLayoutConstraint.activate([
            widthConstraint,
            container.heightAnchor.constraint(equalToConstant: 32),
            container.leadingAnchor.constraint(equalTo: root.leadingAnchor),
            container.topAnchor.constraint(equalTo: root.topAnchor),
            bar.leadingAnchor.constraint(equalTo: container.leadingAnchor),
            bar.trailingAnchor.constraint(equalTo: container.trailingAnchor),
            bar.topAnchor.constraint(equalTo: container.topAnchor),
            bar.bottomAnchor.constraint(equalTo: container.bottomAnchor),
        ])
        layout()
    }

    func layout() {
        container.layoutSubtreeIfNeeded()
        bar.layoutSubtreeIfNeeded()
    }

    func set(width: CGFloat) {
        widthConstraint.constant = width
        layout()
    }

    var control: NSSegmentedControl { bar.segmentedControl }

    var widths: [CGFloat] { (0..<control.segmentCount).map { control.width(forSegment: $0) } }

    /// Move the pointer to the middle of segment `index`, through the bar's own
    /// `mouseMoved`, with a real event addressed to the bar's window.
    func hover(segment index: Int) {
        var x: CGFloat = 0
        for i in 0..<index { x += control.width(forSegment: i) }
        x += control.width(forSegment: index) / 2
        let inBar = NSPoint(x: control.frame.minX + x, y: control.frame.midY)
        let inWindow = bar.convert(inBar, to: nil)
        let event = NSEvent.mouseEvent(with: .mouseMoved, location: inWindow, modifierFlags: [],
                                       timestamp: 0, windowNumber: window.windowNumber, context: nil,
                                       eventNumber: 0, clickCount: 0, pressure: 0)!
        bar.mouseMoved(with: event)
    }

    func unhover() {
        let event = NSEvent.enterExitEvent(with: .mouseExited, location: .zero, modifierFlags: [],
                                           timestamp: 0, windowNumber: window.windowNumber, context: nil,
                                           eventNumber: 0, trackingNumber: 0, userData: nil)!
        bar.mouseExited(with: event)
    }
}

private func textWidth(_ s: String, _ font: NSFont) -> CGFloat {
    ceil((s as NSString).size(withAttributes: [.font: font]).width)
}

// MARK: - Tests

func runTests() {
    _ = NSApplication.shared
    NSApplication.shared.setActivationPolicy(.prohibited)
    MainActor.assumeIsolated {
        testLabelsCarryNoMarker()
        testWidthsFollowTheTitle()
        testEqualWidthFallbackOnOverflow()
        testCloseSlotGlyphs()
        testTooltipsAndAccessibility()
        testTruncatedTitle()
        testChromeGroundReadsGreyInLight()
    }
    print(failures == 0 ? "\nALL PASSED" : "\n\(failures) FAILURE(S)")
    exit(failures == 0 ? 0 : 1)
}

@MainActor
private func testLabelsCarryNoMarker() {
    let host = Host(width: 800)
    host.bar.update(tabs: [tab("Query 1", dirty: true), tab("Query 2")], activeTabId: "Query 1")
    host.layout()
    expectEqual(host.control.label(forSegment: 0) ?? "", "Query 1", "a dirty tab's label is its name, no marker")
    expectEqual(host.control.label(forSegment: 1) ?? "", "Query 2", "a clean tab's label is its name")
    expectEqual(host.control.alignment(forSegment: 0), .left, "titles are left-aligned so the close slot stays clear")

    host.bar.update(tabs: [tab("Query 1", running: true)], activeTabId: "Query 1")
    host.layout()
    expectEqual(host.control.label(forSegment: 0) ?? "", PaneTabBar.executingTitlePrefix + "Query 1",
                "an executing tab's label keeps a blank in front for the pulse dot")
}

@MainActor
private func testWidthsFollowTheTitle() {
    let host = Host(width: 800)
    let font = host.control.font ?? .systemFont(ofSize: NSFont.systemFontSize)
    let long = "A very very long query name that will not fit in one tab at all"
    host.bar.update(tabs: [tab("Q"), tab("Query 12"), tab(long)], activeTabId: "Q")
    host.layout()

    let w = host.widths
    expectClose(w[0], textWidth("Q", font) + PaneTabBar.titleChrome, "a one-letter title gets text + chrome")
    expectClose(w[1], textWidth("Query 12", font) + PaneTabBar.titleChrome, "a short title gets text + chrome")
    expectClose(w[2], PaneTabBar.maxTabWidth, "a long title is capped at maxTabWidth")
    expectTrue(w[0] < w[1] && w[1] < w[2], "widths order with the titles")

    let shown = host.control.label(forSegment: 2) ?? ""
    expectTrue(shown.hasSuffix("\u{2026}") && shown.count < long.count, "the capped title is truncated with an ellipsis")
    expectTrue(textWidth(shown, font) <= PaneTabBar.maxTabWidth - PaneTabBar.titleChrome,
               "the truncated title fits inside the title area of the capped segment")

    expectClose(host.control.frame.width, w.reduce(0, +), "the control is exactly as wide as its segments")
    expectClose(host.control.frame.minX, 4, "the control is pinned leading")
    // The + keeps its slot at the trailing edge whatever the run's width.
    let plus = host.bar.subviews.compactMap { $0 as? NSButton }.first { $0.toolTip == "New Tab" }
    expectClose(plus?.frame.maxX ?? -1, 800, "the + button sits at the bar's trailing edge")
    expectTrue(host.control.frame.maxX < (plus?.frame.minX ?? 0), "the short tab run leaves room before the +")

    // A rename re-sizes: the same tab set with a longer name for Q.
    host.bar.update(tabs: [tab("Q renamed to something"), tab("Query 12"), tab(long)], activeTabId: "Q")
    host.layout()
    expectTrue(host.widths[0] > w[0], "a renamed tab widens to its new title")
}

@MainActor
private func testEqualWidthFallbackOnOverflow() {
    let host = Host(width: 800)   // available = 800 - 30 - 8 = 762
    let long = "A very very long query name that will not fit in one tab at all"
    let tabs = (1...8).map { tab("\(long) \($0)") }
    host.bar.update(tabs: tabs, activeTabId: tabs[0].id)
    host.layout()
    let natural = host.bar.naturalSegmentWidths().reduce(0, +)
    expectTrue(natural > 762, "eight capped tabs do not fit at their natural widths (\(natural))")
    let w = host.widths
    expectTrue(Set(w).count == 1, "on overflow every segment gets the same width")
    expectClose(w[0], floor(762 / 8), "the equal share is the available width over the count")
    expectClose(host.control.frame.width, w.reduce(0, +), "the control spans its equal segments")

    // Narrow enough that the equal share drops below the floor.
    host.set(width: 400)   // available = 362 → 45 each, floored to 80
    let narrow = host.widths
    expectClose(narrow[0], PaneTabBar.minTabWidth, "the equal share is floored at minTabWidth")
    expectClose(host.control.frame.width, 362, "the control does not run under the + button")
    for i in 0..<8 {
        let shown = host.control.label(forSegment: i) ?? ""
        expectTrue(shown.hasSuffix("\u{2026}"), "tab \(i) truncates its title at the floor width")
    }

    // Widen again: back to natural sizing when it fits.
    host.bar.update(tabs: [tab("A"), tab("B")], activeTabId: "A")
    host.set(width: 800)
    expectTrue(host.widths[0] < PaneTabBar.minTabWidth, "two short tabs go back to their natural (sub-floor) widths")
}

@MainActor
private func testCloseSlotGlyphs() {
    let host = Host(width: 800)
    let tabs = [
        tab("active clean"),
        tab("inactive clean"),
        tab("inactive dirty", dirty: true),
        tab("active dirty", dirty: true),
        tab("running dirty", dirty: true, running: true),
        tab("running clean", running: true),
    ]
    host.bar.update(tabs: tabs, activeTabId: "active clean")
    host.layout()
    expectEqual(host.bar.closeSlotGlyph(at: 0), .close, "active + clean → ✕")
    expectEqual(host.bar.closeSlotGlyph(at: 1), .hidden, "inactive + clean → nothing")
    expectEqual(host.bar.closeSlotGlyph(at: 2), .unsavedDot, "inactive + dirty → the unsaved dot")
    expectEqual(host.bar.closeSlotGlyph(at: 4), .hidden, "an executing dirty tab shows no unsaved dot")
    expectEqual(host.bar.closeSlotGlyph(at: 5), .hidden, "an executing clean inactive tab shows nothing")

    host.bar.update(tabs: tabs, activeTabId: "active dirty")
    host.layout()
    expectEqual(host.bar.closeSlotGlyph(at: 3), .unsavedDot, "active + dirty, not hovered → the dot, not the ✕")
    expectEqual(host.bar.closeSlotGlyph(at: 0), .hidden, "the tab that lost activation hides its ✕")

    host.hover(segment: 3)
    expectEqual(host.bar.closeSlotGlyph(at: 3), .close, "hovering the dirty tab swaps the dot for the ✕")
    host.hover(segment: 2)
    expectEqual(host.bar.closeSlotGlyph(at: 2), .close, "hovering an inactive dirty tab shows the ✕")
    expectEqual(host.bar.closeSlotGlyph(at: 3), .unsavedDot, "the tab the pointer left goes back to its dot")
    host.hover(segment: 1)
    expectEqual(host.bar.closeSlotGlyph(at: 1), .close, "hovering an inactive clean tab shows the ✕")
    host.hover(segment: 4)
    expectEqual(host.bar.closeSlotGlyph(at: 4), .close, "hovering an executing tab shows the ✕")
    host.unhover()
    expectEqual(host.bar.closeSlotGlyph(at: 1), .hidden, "leaving the bar hides the hover ✕ again")
    expectEqual(host.bar.closeSlotGlyph(at: 3), .unsavedDot, "leaving the bar leaves the dot on the dirty tab")

    // The drawn buttons follow the rule: visible exactly when the glyph is not hidden.
    let buttons = host.bar.subviews.compactMap { $0 as? NSButton }.filter { $0.toolTip != "New Tab" }
    expectEqual(buttons.count, tabs.count, "one close-slot button per tab")
    for (i, b) in buttons.sorted(by: { $0.tag < $1.tag }).enumerated() {
        expectEqual(!b.isHidden, host.bar.closeSlotGlyph(at: i) != .hidden, "button \(i) is shown iff its glyph is")
    }
    // And the slot sits inside the segment's trailing pad.
    let dot = buttons.first { $0.tag == 3 }!
    var segMaxX = host.control.frame.minX
    for i in 0...3 { segMaxX += host.control.width(forSegment: i) }
    expectClose(dot.frame.maxX, segMaxX - PaneTabBar.closeTrailingPad, "the slot ends closeTrailingPad before the segment's edge")
    expectClose(dot.frame.width, PaneTabBar.closeSlotWidth, "the slot is closeSlotWidth wide")
}

@MainActor
private func testTooltipsAndAccessibility() {
    let host = Host(width: 800)
    host.bar.update(tabs: [tab("Plain"), tab("Edited", dirty: true), tab("Busy", running: true),
                           tab("Both", dirty: true, running: true)], activeTabId: "Plain")
    host.layout()
    expectEqual(PaneTabBar.tooltip(for: tab("Plain")), "Plain", "a clean idle tab's tooltip is its name")
    expectEqual(PaneTabBar.tooltip(for: tab("Edited", dirty: true)), "Edited — unsaved", "a dirty tab's tooltip says unsaved")
    expectEqual(PaneTabBar.tooltip(for: tab("Busy", running: true)), "Busy — running", "an executing tab's tooltip says running")
    expectEqual(PaneTabBar.tooltip(for: tab("Both", dirty: true, running: true)), "Both — running, unsaved",
                "a tab that is both says both")

    let proxies = (host.bar.accessibilityChildren() ?? []).compactMap { $0 as? AccessibilityProxyElement }
    expectEqual(proxies.count, 4, "one close proxy per tab")
    expectEqual(proxies[1].accessibilityValue() as? String, "edited", "the dirty tab's close proxy carries the value 'edited'")
    expectTrue(proxies[0].accessibilityValue() == nil, "a clean tab's close proxy has no value")
    expectEqual(proxies[1].accessibilityLabel() ?? "", "Close Edited", "the proxy's label names the tab")
}

@MainActor
private func testTruncatedTitle() {
    let font = NSFont.systemFont(ofSize: 13)
    expectEqual(PaneTabBar.truncatedTitle("Query 1", toFit: 200, font: font), "Query 1", "a title that fits is returned whole")
    let long = "A very very long query name that will not fit"
    let cut = PaneTabBar.truncatedTitle(long, toFit: 100, font: font)
    expectTrue(cut.hasSuffix("\u{2026}"), "a cut title ends in an ellipsis")
    expectTrue(textWidth(cut, font) <= 100, "the cut title fits the width")
    // Maximal: one more character would not fit.
    let oneMore = String(long.prefix(cut.count)) + "\u{2026}"
    expectTrue(textWidth(oneMore, font) > 100, "the cut is the longest prefix that fits")
    expectEqual(PaneTabBar.truncatedTitle("abc", toFit: 0, font: font), "\u{2026}", "no room at all leaves the ellipsis alone")
}

/// The bar's ground is what makes the white lit capsule visible in Light mode:
/// on macOS 26 every candidate system ground resolves to pure white there, so
/// the bar paints `ContrastInk.chromeGround` (≈0.88) instead. `draw(_:)` output
/// lands in an offscreen render, so this is measurable; the capsule itself is
/// not, so its contrast against this ground is for the user's eyes.
@MainActor
private func testChromeGroundReadsGreyInLight() {
    func groundLuminance(_ appearance: NSAppearance.Name) -> CGFloat {
        let host = Host(width: 400)
        host.window.appearance = NSAppearance(named: appearance)
        host.bar.update(tabs: [tab("Q")], activeTabId: "Q")
        host.layout()
        let rep = host.bar.bitmapImageRepForCachingDisplay(in: host.bar.bounds)!
        host.bar.cacheDisplay(in: host.bar.bounds, to: rep)
        // Bare ground: right of the one tab, left of the +.
        let scale = CGFloat(rep.pixelsWide) / host.bar.bounds.width
        let c = rep.colorAt(x: Int(300 * scale), y: Int(16 * scale))!.usingColorSpace(.deviceRGB)!
        return 0.2126 * c.redComponent + 0.7152 * c.greenComponent + 0.0722 * c.blueComponent
    }
    let light = groundLuminance(.aqua)
    let dark = groundLuminance(.darkAqua)
    expectTrue(light > 0.80 && light < 0.93, "in Light the bar's ground is a light grey, not white (\(light))")
    expectTrue(dark < 0.20, "in Dark the bar's ground stays the dark control ground (\(dark))")
    // Non-vacuity: the two appearances really did resolve differently.
    expectTrue(light - dark > 0.5, "light and dark grounds differ")
}
