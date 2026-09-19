// Standalone tests for the gutter's segment BAND — the statement colour drawn
// behind the line numbers, and the run gesture on it. Compiled by
// scripts/test-gutter-segment-band.sh.
//
// What this suite is FOR. Four things here fail silently:
//
// 1. A band drops out when a fold closes inside its statement. The band's
//    extent used to come from exact dictionary lookups of its first and last
//    line, and a collapsed fold removes those lines from the map entirely —
//    so the whole statement lost its colour. Invisible when it was a 4pt
//    stripe; not invisible now.
// 2. Draw and hit-test disagree about who owns a line. `select 1; select 2;`
//    is two statements that both start AND end on line 1.
// 3. A click lands on nothing and runs the last statement anyway.
//    `lineNumber(at:)` clamps, so a point below the text maps onto the last
//    line. The band is the full width of the gutter now, so the blank area
//    under a short document is a large target.
// 4. The numbers stop being readable through the band. No compiler sees a
//    contrast failure, so it is measured here in real pixels, in both
//    appearances.
import AppKit

private var failures = 0

private func expectTrue(_ actual: Bool, _ name: String) {
    if actual { print("PASS \(name)") } else { failures += 1; print("FAIL \(name)") }
}

private func expectEqual(_ actual: Int, _ expected: Int, _ name: String) {
    if actual == expected { print("PASS \(name)") } else {
        failures += 1
        print("FAIL \(name)\n  expected: \(expected)\n  actual:   \(actual)")
    }
}

private func expectClose(_ actual: CGFloat, _ expected: CGFloat, _ name: String,
                         tolerance: CGFloat = 0.5) {
    if abs(actual - expected) <= tolerance { print("PASS \(name)") } else {
        failures += 1
        print("FAIL \(name)\n  expected: \(expected) ± \(tolerance)\n  actual:   \(actual)")
    }
}

// MARK: - Harness

private func makeGutter(_ text: String, height: CGFloat = 400)
    -> (window: NSWindow, gutter: LineNumberGutter, textView: NSTextView) {
    let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 500, height: height),
                          styleMask: [.borderless], backing: .buffered, defer: false)
    let container = NSView(frame: NSRect(x: 0, y: 0, width: 500, height: height))
    window.contentView = container

    let scrollView = NSScrollView(frame: NSRect(x: 60, y: 0, width: 440, height: height))
    let textView = NSTextView(frame: NSRect(x: 0, y: 0, width: 440, height: height))
    textView.isVerticallyResizable = true
    textView.font = NSFont.monospacedSystemFont(ofSize: 12, weight: .regular)
    textView.string = text
    scrollView.documentView = textView
    container.addSubview(scrollView)

    let gutter = LineNumberGutter(textView: textView, scrollView: scrollView)
    gutter.frame = NSRect(x: 0, y: 0, width: gutter.desiredWidth, height: height)
    container.addSubview(gutter)

    textView.layoutManager?.ensureLayout(for: textView.textContainer!)
    gutter.setSegments(SQLSegmentParser.parse(text), activeIndex: nil)
    paint(gutter)
    return (window, gutter, textView)
}

/// One offscreen render, with the scale that turns a POINT coordinate into the
/// PIXEL coordinate `colorAt` counts in.
///
/// `bitmapImageRepForCachingDisplay` follows the main display's backing scale
/// even for a view in no window, so on a Retina Mac the rep is 2x. A point read
/// straight through therefore lands at HALF the intended x: the band starts at
/// point 16, and x = 18 read as a pixel is point 9 — the plain gutter left of
/// the band. That is why both appearances measured a delta of exactly 0.000
/// while the band was being painted correctly all along.
private struct Rendered {
    /// Retained on purpose: the pixels belong to the rep.
    let rep: NSBitmapImageRep
    /// Pixels per point.
    let scale: Int

    /// The pixel at a POINT coordinate. Top-left origin, as `colorAt` counts —
    /// the gutter is flipped, so its own y already runs the same way.
    func pixel(_ x: CGFloat, _ y: CGFloat) -> NSColor? {
        rep.colorAt(x: Int(x) * scale, y: Int(y) * scale)?.usingColorSpace(.deviceRGB)
    }

    /// The rep's width back in points, so a sampling loop can be clamped in the
    /// same units the band rect is in.
    var pointsWide: CGFloat { CGFloat(rep.pixelsWide) / CGFloat(scale) }

    /// Every PIXEL across a horizontal span given in points, left to right.
    ///
    /// Counting ink one point at a time is not enough on a 2x rep: a line
    /// number's stroke is about a point wide, so a point-by-point walk steps
    /// over half of it and the digit count reads far lower than the digit is.
    func row(y: CGFloat, fromX: CGFloat, toX: CGFloat) -> [(x: Int, color: NSColor)] {
        let yPixel = Int(y) * scale
        let lo = max(0, Int(fromX * CGFloat(scale)))
        let hi = min(rep.pixelsWide, Int(toX * CGFloat(scale)))
        guard lo < hi, yPixel >= 0, yPixel < rep.pixelsHigh else { return [] }
        return (lo..<hi).compactMap { x in
            rep.colorAt(x: x, y: yPixel)?.usingColorSpace(.deviceRGB).map { (x, $0) }
        }
    }
}

/// Draw the gutter for real. A draw is what fills `paintedBands`, and nothing
/// else does — but `draw(_:)` cannot be called directly with no focused
/// graphics context (it traps in the first fill). `cacheDisplay` supplies one.
///
/// `view.appearance` is set, not just made current: `cacheDisplay` walks the
/// hierarchy and restores each view's own `effectiveAppearance` as it draws, so
/// `performAsCurrentDrawingAppearance` alone left the "dark" pass rendering the
/// light gutter. Both passes then measured the same pixels.
@discardableResult
private func paint(_ view: NSView, appearance name: NSAppearance.Name? = nil) -> Rendered? {
    let appearance = name.flatMap(NSAppearance.init(named:)) ?? view.effectiveAppearance
    if name != nil { view.appearance = appearance }
    guard let rep = view.bitmapImageRepForCachingDisplay(in: view.bounds) else { return nil }
    appearance.performAsCurrentDrawingAppearance {
        view.cacheDisplay(in: view.bounds, to: rep)
    }
    let scale = max(1, Int((CGFloat(rep.pixelsWide) / view.bounds.width).rounded()))
    return Rendered(rep: rep, scale: scale)
}

/// Tick the cross-fade until it settles. Real time must pass: the fade is
/// driven by the wall clock, not by a tick count, so that it looks the same on
/// a 60 Hz and a 120 Hz display.
private func settle(_ gutter: LineNumberGutter, seconds: TimeInterval = 0.4) {
    let deadline = Date().addingTimeInterval(seconds)
    while Date() < deadline {
        gutter.advanceHoverFade()
        Thread.sleep(forTimeInterval: 0.01)
    }
    gutter.advanceHoverFade()
}

// MARK: - Cases

private let twoStatements = """
select 1
from a;
select 2
from b;
"""

private func testBandSpansItsStatement() {
    let (window, gutter, _) = makeGutter(twoStatements)
    defer { window.close() }

    expectEqual(gutter.paintedBands.count, 2, "one band per statement")
    guard gutter.paintedBands.count == 2 else { return }

    // Every band starts where the error marker's hit box ends. These two are
    // derived from one constant on purpose: nudging either alone would have
    // made error markers unhoverable with no test failing.
    for band in gutter.paintedBands {
        expectClose(band.rect.minX, LineNumberGutter.errorHitWidth,
                    "band \(band.index) starts clear of the error marker")
        expectTrue(band.rect.maxX <= gutter.desiredWidth,
                   "band \(band.index) stays inside the gutter")
    }

    // The band covers both of its statement's lines and neither of the other's.
    let first = gutter.paintedBands[0].rect
    let second = gutter.paintedBands[1].rect
    expectTrue(first.maxY <= second.minY, "the bands do not overlap")
    expectTrue(second.minY - first.maxY >= 2,
               "a visible gap separates neighbouring statements")
    expectTrue(first.height > second.height * 0.5,
               "a two-line statement gets a band taller than one line")
}

private func testBandSurvivesACollapsedFold() {
    let sql = """
    select 1
    from (
      select 2
      from t
    );
    """
    let (window, gutter, _) = makeGutter(sql)
    defer { window.close() }

    expectTrue(!gutter.paintedBands.isEmpty, "the statement has a band to begin with")

    // Collapse the fold whose body is inside the statement. The statement's
    // own last line then has no entry in the visible-line list, which used to
    // drop the whole band.
    var regions = SQLFoldingParser.parse(sql)
    guard !regions.isEmpty else {
        print("FAIL no fold region parsed — the fixture no longer folds")
        failures += 1
        return
    }
    for i in regions.indices { regions[i].isCollapsed = true }
    gutter.setFoldRegions(regions)
    paint(gutter)

    expectTrue(!gutter.paintedBands.isEmpty,
               "the statement keeps its band with a fold collapsed inside it")
}

private func testTwoStatementsOnOneLine() {
    let (window, gutter, _) = makeGutter("select 1; select 2;")
    defer { window.close() }

    let segments = SQLSegmentParser.parse("select 1; select 2;")
    expectEqual(segments.count, 2, "two statements parsed")
    expectTrue(segments.allSatisfy { $0.startLine == 1 && $0.endLine == 1 },
               "both statements live on line 1")

    // Draw and hit-test must name the SAME statement, or the band shows one
    // colour and the click runs the other.
    let owner = gutter.segmentIndex(owningLine: 1)
    expectTrue(owner == 0, "line 1 is owned by the first statement")
    guard let band = gutter.paintedBands.first(where: { $0.index == owner }) else {
        print("FAIL the owning statement has no band"); failures += 1; return
    }
    let hit = gutter.bandIndex(at: NSPoint(x: band.rect.midX, y: band.rect.midY))
    expectTrue(hit == owner, "a click inside the band names the same statement")
}

private func testEmptyGutterAreaRunsNothing() {
    // A short document in a tall gutter: most of the view is blank.
    let (window, gutter, _) = makeGutter("select 1;", height: 400)
    defer { window.close() }

    guard let band = gutter.paintedBands.first else {
        print("FAIL no band"); failures += 1; return
    }
    let farBelow = NSPoint(x: band.rect.midX, y: band.rect.maxY + 200)
    expectTrue(gutter.bandIndex(at: farBelow) == nil,
               "a point far below the last line is over no band")
    expectTrue(gutter.bandIndex(at: NSPoint(x: 2, y: band.rect.midY)) == nil,
               "the error-marker column is over no band")
}

private func testHoverCrossFade() {
    let (window, gutter, _) = makeGutter(twoStatements)
    defer { window.close() }

    expectClose(gutter.hoverProgress, 0, "nothing is faded at rest")

    gutter.setHovered(0)
    expectTrue(gutter.fadeSegmentIndex == 0, "the hovered statement owns the fade")
    // The fade is wall-clock based, as it must be to look the same on any
    // refresh rate — so real time has to pass, not just iterations.
    settle(gutter)
    expectClose(gutter.hoverProgress, 1, "the fade reaches the play glyph")

    gutter.setHovered(nil)
    expectTrue(gutter.fadeSegmentIndex == 0,
               "the outgoing statement keeps the fade so its numbers do not pop back")
    settle(gutter)
    expectClose(gutter.hoverProgress, 0, "the fade returns to the numbers")
    expectTrue(gutter.fadeSegmentIndex == nil, "the settled fade is released")
}

@MainActor
private func testReduceMotionSnaps() {
    let (window, gutter, _) = makeGutter(twoStatements)
    defer { window.close() }

    AccessibilityDisplay.shared.overrideForTesting(reduceMotion: true)
    defer { AccessibilityDisplay.shared.overrideForTesting(reduceMotion: false) }

    // No settle(): the point is that no time has to pass.
    gutter.setHovered(0)
    expectClose(gutter.hoverProgress, 1, "Reduce Motion snaps straight to the play glyph")
    gutter.setHovered(nil)
    expectClose(gutter.hoverProgress, 0, "Reduce Motion snaps straight back")
    expectTrue(gutter.fadeSegmentIndex == nil, "Reduce Motion leaves no fade running")
}

private func testNumbersStayReadableOverTheBand() {
    // The band is a wash behind text. If its alpha creeps up, the numbers stop
    // being readable and no compiler notices — so count real pixels.
    var grounds: [String: CGFloat] = [:]
    for (label, name) in [("light", NSAppearance.Name.aqua),
                          ("dark", NSAppearance.Name.darkAqua)] {
        let (window, gutter, _) = makeGutter(twoStatements)
        defer { window.close() }
        // A result tab's colour, so this measures the level a statement with
        // results actually shows — the one the screenshots were taken of.
        gutter.setSegmentColor(.systemPink, forSegmentIndex: 0)
        guard let rendered = paint(gutter, appearance: name) else {
            print("FAIL could not render the gutter in \(label)"); failures += 1; continue
        }
        guard let band = gutter.paintedBands.first else {
            print("FAIL no band in \(label)"); failures += 1; continue
        }

        // Sample a row through the middle of the band's first line and count
        // how many pixels differ from the band's own flat colour: the digits.
        // Start INSIDE the band's rounded corner, not on it, or the corner's
        // own antialiasing counts as ink and the row passes with no digit in it.
        let y = band.rect.minY + 6
        let row = rendered.row(y: y, fromX: band.rect.minX + 4,
                               toX: min(band.rect.maxX, rendered.pointsWide))
        var distinct: [Int] = []
        if let b = row.first?.color {
            for (x, c) in row {
                let dr = abs(c.redComponent - b.redComponent)
                let dg = abs(c.greenComponent - b.greenComponent)
                let db = abs(c.blueComponent - b.blueComponent)
                if dr + dg + db > 0.12 { distinct.append(x) }
            }
        }
        expectTrue(!row.isEmpty, "\(label): the band row was sampled")
        expectTrue(!distinct.isEmpty,
                   "\(label): the line number is still drawn over the band "
                       + "(\(distinct.count) px)")
        // And it is the NUMBER's ink, not the band's own right edge: the digits
        // are right-aligned against `numberTrailingPadding`, so every differing
        // pixel has to sit inside the band, clear of its boundary.
        if let rightmost = distinct.max() {
            expectTrue(CGFloat(rightmost) / CGFloat(rendered.scale) < band.rect.maxX - 2,
                       "\(label): the ink is the line number, not the band's edge")
        }

        // And the band is actually VISIBLE. It was shipped at half this
        // strength once and read as "very dim" in both appearances, so the
        // floor is pinned: the band must move the surface away from the plain
        // gutter background by a measurable amount.
        //
        // The comparison point is the LEADING column at the same y — the fold
        // chevron's strip, which no band ever covers. Sampling below the band
        // instead lands inside the next statement's band and reads zero.
        if let inside = rendered.pixel(band.rect.minX + 4, band.rect.minY + 4),
           let outside = rendered.pixel(1, band.rect.minY + 4) {
            let delta = abs(inside.redComponent - outside.redComponent)
                + abs(inside.greenComponent - outside.greenComponent)
                + abs(inside.blueComponent - outside.blueComponent)
            expectTrue(delta > 0.08,
                       "\(label): the band is visible against the gutter background "
                           + "(delta \(String(format: "%.3f", delta)))")
            grounds[label] = 0.2126 * outside.redComponent
                + 0.7152 * outside.greenComponent
                + 0.0722 * outside.blueComponent
        }
    }

    // Non-vacuity: the two passes really did render in different appearances.
    // They did not once — `performAsCurrentDrawingAppearance` does not survive
    // `cacheDisplay`, so "dark" drew the light gutter and both passes measured
    // the same white pixels. A colour check that cannot tell light from dark
    // is not measuring anything.
    if let light = grounds["light"], let dark = grounds["dark"] {
        expectTrue(light - dark > 0.5,
                   "the light and dark gutter grounds really differ "
                       + "(\(String(format: "%.2f", light)) vs \(String(format: "%.2f", dark)))")
    } else {
        print("FAIL both appearances were not measured"); failures += 1
    }
}

func runTests() {
    testBandSpansItsStatement()
    testBandSurvivesACollapsedFold()
    testTwoStatementsOnOneLine()
    testEmptyGutterAreaRunsNothing()
    testHoverCrossFade()
    MainActor.assumeIsolated { testReduceMotionSnaps() }
    testNumbersStayReadableOverTheBand()

    if failures == 0 { print("\nAll gutter segment band tests passed.") }
    else { print("\n\(failures) failure(s).") ; exit(1) }
}
