// Standalone test runner for TaggedRowView. Real AppKit, no window needed.
// Compiled with the implementation by scripts/test-tagged-row-view.sh.
import AppKit

var failures = 0

func expectEqual<T: Equatable>(_ actual: T, _ expected: T, _ name: String) {
    if actual == expected { print("PASS \(name)") } else {
        failures += 1
        print("FAIL \(name)\n  expected: \(expected)\n  actual:   \(actual)")
    }
}

func expectClose(_ actual: CGFloat, _ expected: CGFloat, _ name: String) {
    if abs(actual - expected) < 0.01 { print("PASS \(name)") } else {
        failures += 1
        print("FAIL \(name)\n  expected: \(expected)\n  actual:   \(actual)")
    }
}

func expectTrue(_ actual: Bool, _ name: String) {
    if actual { print("PASS \(name)") } else { failures += 1; print("FAIL \(name) — expected true") }
}

/// Render a row view offscreen ONCE into a bitmap that can be sampled
/// repeatedly. Real AppKit drawing, no window.
///
/// `view.bitmapImageRepForCachingDisplay` + `cacheDisplay` (the obvious first
/// attempt) does NOT work here: it draws into an alpha-preserving bitmap with
/// nothing underneath, so a partially-transparent fill is stored as its full
/// RGB plus a separate alpha channel — there is no backdrop for it to actually
/// blend against. `colorAt` then returns that unblended RGB unchanged
/// regardless of alpha, so a 15% red wash and a 100% red bar come back with
/// IDENTICAL red/green/blue components (only their alpha differs), and a
/// same-channel comparison like "the bar's red is higher than the wash's red"
/// can never see a difference.
///
/// The fix: paint a real (opaque, white) backdrop into the bitmap first, then
/// invoke `drawBackground(in:)` directly — the exact method under test — so
/// Quartz performs genuine source-over compositing and `colorAt` reports the
/// true blended colour. This has a second benefit: over an opaque backdrop
/// the sampled alpha is exactly 1.0, so premultiplied 8-bit storage cannot
/// distort the sample either.
func render(_ view: TaggedRowView, selected: Bool = false) -> NSBitmapImageRep? {
    let width = Int(view.bounds.width)
    let height = Int(view.bounds.height)
    guard let rep = NSBitmapImageRep(
        bitmapDataPlanes: nil, pixelsWide: width, pixelsHigh: height,
        bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
        colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0
    ), let context = NSGraphicsContext(bitmapImageRep: rep) else { return nil }

    NSGraphicsContext.saveGraphicsState()
    NSGraphicsContext.current = context
    NSColor.white.setFill()
    NSRect(x: 0, y: 0, width: CGFloat(width), height: CGFloat(height)).fill()
    // `draw(_:)` is the REAL entry point, and it is what AppKit calls. It runs
    // drawBackground (the wash), then drawSelection, then our bar on top. Calling
    // drawBackground alone would miss the bar entirely now that it moved above the
    // selection, and would silently pass every bar assertion by never drawing one.
    view.selectionHighlightStyle = .regular
    view.isSelected = selected
    view.draw(view.bounds)
    NSGraphicsContext.restoreGraphicsState()

    return rep
}

/// Sample one pixel from an already-rendered bitmap. Splitting this from
/// `render` means a multi-point walk (e.g. the dash-gap scan) renders the view
/// exactly once instead of once per sampled point.
func pixel(_ rep: NSBitmapImageRep, x: Int, y: Int) -> NSColor? {
    rep.colorAt(x: x, y: y)?.usingColorSpace(.deviceRGB)
}

/// The ONE colour-equality comparator, used everywhere two pixels are checked
/// for being "the same colour". 0.01 per channel: the real 8-bit quantization
/// bound is 1/255 ≈ 0.004, so 0.01 leaves headroom for offscreen-rendering
/// noise without being loose enough to hide a real difference. (Previously
/// this repo had three competing epsilons here — 0.001, 0.01 on a summed
/// distance, 0.02 per channel — which is worse than any one of them: three
/// different units for "the same" is not a stricter check, just a confusing
/// one.)
func sameColor(_ a: NSColor, _ b: NSColor) -> Bool {
    abs(a.redComponent - b.redComponent) < 0.01
        && abs(a.greenComponent - b.greenComponent) < 0.01
        && abs(a.blueComponent - b.blueComponent) < 0.01
}

/// How far a colour sits from a reference (e.g. the untagged baseline), summed
/// across channels. A saturated hue like `.systemRed` keeps its red channel at
/// 1.0 whether it is a faint wash or a solid bar — the difference only shows up
/// in the OTHER channels — so "more saturated" has to be judged by total
/// distance from the baseline, not by any one fixed channel. This is for
/// ORDERING two pixels against each other (farther / closer); it is not a
/// colour-equality comparator — use `sameColor` for that.
func distance(_ a: NSColor, from b: NSColor) -> CGFloat {
    abs(a.redComponent - b.redComponent)
        + abs(a.greenComponent - b.greenComponent)
        + abs(a.blueComponent - b.blueComponent)
}

/// α·C + (1−α)·white, computed from the RESOLVED colour so an appearance
/// change cannot stale the expectation. Over an opaque white backdrop the
/// blend is exact — this is what pins the label COLOUR and the exact alpha.
/// A distance-from-baseline check proves neither: drawing in the wrong
/// colour, or tinting at 0.30/0.60 instead of 0.08/0.15, passes every
/// distance assertion in this file unchanged. Measured error against the
/// real render is ~0.001–0.002 per channel, so the 0.01 epsilon in
/// `sameColor` is comfortable.
func expectedBlend(_ c: NSColor, alpha: CGFloat) -> NSColor {
    let resolved = c.usingColorSpace(.deviceRGB) ?? c
    let white: CGFloat = 1.0
    return NSColor(
        deviceRed: alpha * resolved.redComponent + (1 - alpha) * white,
        green: alpha * resolved.greenComponent + (1 - alpha) * white,
        blue: alpha * resolved.blueComponent + (1 - alpha) * white,
        alpha: 1.0
    )
}

func runTests() {
    let frame = NSRect(x: 0, y: 0, width: 400, height: 24)

    // An untagged row draws nothing, so the grid looks exactly as it did before.
    let plain = TaggedRowView(frame: frame)
    expectEqual(plain.tagColor == nil, true, "an untagged row holds no colour")
    expectEqual(plain.barRect(in: frame), .zero, "an untagged row draws no bar")
    expectClose(plain.tintAlpha, 0, "an untagged row has no tint")

    // A solid match: 15% tint, a 3pt solid bar at the leading edge.
    let strong = TaggedRowView(frame: frame)
    strong.configure(color: .systemRed, isPartial: false)
    expectClose(strong.tintAlpha, 0.15, "a solid match tints at 15%")
    expectClose(strong.barRect(in: frame).width, 4, "the bar is 4pt wide")
    expectClose(strong.barRect(in: frame).minX, 0, "the bar sits at the leading edge")
    expectClose(strong.barRect(in: frame).height, frame.height, "the bar spans the row height")
    expectEqual(strong.isBarDashed, false, "a solid match draws an unbroken bar")

    // A partial match: 8% tint and a dashed bar, so the two states are told apart
    // without reading anything.
    let partial = TaggedRowView(frame: frame)
    partial.configure(color: .systemRed, isPartial: true)
    expectClose(partial.tintAlpha, 0.08, "a partial match tints at 8%")
    expectEqual(partial.isBarDashed, true, "a partial match draws a dashed bar")
    expectClose(partial.barRect(in: frame).width, 4, "the partial bar is the same width")

    // Reuse: NSTableView recycles row views, so configuring one twice must not
    // leave the first tag's state behind.
    let reused = TaggedRowView(frame: frame)
    reused.configure(color: .systemBlue, isPartial: true)
    reused.configure(color: .systemGreen, isPartial: false)
    expectClose(reused.tintAlpha, 0.15, "reuse takes the second tag's alpha")
    expectEqual(reused.isBarDashed, false, "reuse clears the dashed bar")
    reused.clearTag()
    expectEqual(reused.tagColor == nil, true, "clearing removes the colour")
    expectClose(reused.tintAlpha, 0, "clearing removes the tint")
    expectEqual(reused.barRect(in: frame), .zero, "clearing removes the bar")

    // The bar must not scale with the row. A tall row still gets 3pt.
    let tall = NSRect(x: 0, y: 0, width: 400, height: 60)
    expectClose(strong.barRect(in: tall).width, 4, "the bar stays 4pt on a taller row")
    expectClose(strong.barRect(in: tall).height, 60, "the bar still spans the row")

    // MARK: - Pixel assertions
    //
    // Everything above tests the geometry ACCESSORS. None of it proves that
    // `drawBackground(in:)` actually reads them — `tintAlpha`, `barRect`, and
    // `isBarDashed` could all be ignored by the drawing code and every check
    // above would still pass. Render each view into an offscreen bitmap and
    // read pixels back so the drawing itself is on trial.

    let midX = 200
    let midY = 12
    let barX = 1

    let untaggedForPixels = TaggedRowView(frame: frame)
    let strongForPixels = TaggedRowView(frame: frame)
    strongForPixels.configure(color: .systemRed, isPartial: false)
    let partialForPixels = TaggedRowView(frame: frame)
    partialForPixels.configure(color: .systemRed, isPartial: true)

    // Render each view exactly once — the dash-gap walk below samples 24
    // points down the same bitmap instead of re-rendering per point.
    if let untaggedRep = render(untaggedForPixels),
       let strongRep = render(strongForPixels),
       let partialRep = render(partialForPixels),
       let untaggedMid = pixel(untaggedRep, x: midX, y: midY),
       let strongMid = pixel(strongRep, x: midX, y: midY),
       let partialMid = pixel(partialRep, x: midX, y: midY),
       let strongBar = pixel(strongRep, x: barX, y: midY) {

        // 1. The exact blend. This is what pins the label COLOUR and the exact
        //    alpha — every other check here works by ORDERING or DIFFERENCE,
        //    which a drawBackground that ignores tagColor entirely, or tints
        //    at 0.30/0.60 instead of 0.08/0.15, can pass by accident. Compare
        //    against the RESOLVED colour, never a hardcoded triple.
        let resolvedRed = NSColor.systemRed.usingColorSpace(.deviceRGB) ?? .systemRed
        expectTrue(sameColor(strongMid, expectedBlend(resolvedRed, alpha: 0.15)),
                   "the strong wash pixel is exactly a 15% blend of the resolved colour over white")
        expectTrue(sameColor(partialMid, expectedBlend(resolvedRed, alpha: 0.08)),
                   "the partial wash pixel is exactly an 8% blend of the resolved colour over white")
        expectTrue(sameColor(strongBar, resolvedRed),
                   "the bar pixel is the resolved colour at full strength, not just A colour")

        // 1b. A SECOND colour, so nothing here can pass by having special-cased
        //     red. `.systemGreen` deliberately, not `.systemBlue`, so this
        //     cannot coincidentally match a `drawBackground` that hardcodes
        //     some other fixed colour.
        let greenForPixels = TaggedRowView(frame: frame)
        greenForPixels.configure(color: .systemGreen, isPartial: false)
        if let greenRep = render(greenForPixels), let greenMid = pixel(greenRep, x: midX, y: midY) {
            let resolvedGreen = NSColor.systemGreen.usingColorSpace(.deviceRGB) ?? .systemGreen
            expectTrue(sameColor(greenMid, expectedBlend(resolvedGreen, alpha: 0.15)),
                       "a green tag blends its OWN resolved colour, not a colour fixed in the drawing code")
        } else {
            failures += 1
            print("FAIL could not render the green-tag view")
        }

        // 2. The bar is more saturated than the wash: the bar-column pixel
        //    must sit farther from the untagged baseline than the mid-row wash
        //    pixel does. (Not a raw red-component comparison — `.systemRed`
        //    already has red = 1.0 at every alpha over a white backdrop, so
        //    that single channel cannot tell a 15% wash from a 100% bar apart.
        //    Total distance from the baseline can, because it is the green/
        //    blue channels that move.)
        let barDistance = distance(strongBar, from: untaggedMid)
        let strongWashDistance = distance(strongMid, from: untaggedMid)
        expectTrue(barDistance > strongWashDistance,
                   "the strong bar pixel sits farther from the untagged baseline than the strong wash pixel")

        // 2b. The bar's WIDTH in the output, not just in `barRect`. Reading
        //     x=1 alone cannot tell a 4pt bar from a 2pt one, because both
        //     cover it. x=3 must still be full bar colour and x=4 must already
        //     have fallen back to wash — otherwise a `drawBackground` that
        //     hardcodes a narrower rect while `barRect` keeps reporting 4
        //     would pass every other check, this one included at x=1.
        if let leadingEdge = pixel(strongRep, x: 0, y: midY),
           let lastBarPixel = pixel(strongRep, x: 3, y: midY),
           let firstWashPixel = pixel(strongRep, x: 4, y: midY) {
            expectTrue(sameColor(lastBarPixel, leadingEdge),
                       "x=3 matches x=0 — both still full bar colour")
            expectTrue(sameColor(firstWashPixel, strongMid),
                       "x=4 has already fallen back to the wash colour")
        } else {
            failures += 1
            print("FAIL could not read the bar's right-edge pixels (x=0, x=3, x=4)")
        }

        // 3. A partial row's wash is fainter than a solid row's: the partial mid
        //    pixel must sit closer to the untagged baseline than the strong
        //    mid pixel does.
        let partialDelta = distance(partialMid, from: untaggedMid)
        let strongDelta = distance(strongMid, from: untaggedMid)
        expectTrue(partialDelta < strongDelta, "a partial row's wash sits closer to the untagged baseline than a strong row's")

        // 4. The dashed bar has gaps; the solid bar does not. Walk the bar
        //    column down every y of both views (same rendered bitmap, sampled
        //    repeatedly — no re-render per y).
        var strongBarColors: [NSColor] = []
        var partialBarColors: [NSColor] = []
        for y in 0..<Int(frame.height) {
            if let c = pixel(strongRep, x: barX, y: y) { strongBarColors.append(c) }
            if let c = pixel(partialRep, x: barX, y: y) { partialBarColors.append(c) }
        }
        if strongBarColors.count == Int(frame.height) && partialBarColors.count == Int(frame.height) {
            let strongBarUniform = strongBarColors.dropFirst().allSatisfy { sameColor($0, strongBarColors[0]) }
            expectTrue(strongBarUniform, "the strong (solid) bar column is uniform top to bottom")

            let partialBarHasGap = partialBarColors.contains { !sameColor($0, partialBarColors[0]) }
            expectTrue(partialBarHasGap, "the partial (dashed) bar column has at least one differing pixel — a dash gap")
        } else {
            failures += 1
            print("FAIL could not read every y of the bar column for the dash-gap check")
        }

        // 4b. The dashed bar's WIDTH, by column, not a single point — a 1pt
        //     line (missing `lineWidth`) or an off-centre line (drawn at
        //     `midX + 1` instead of `midX`) both still cover x=1 and would
        //     slip past every check above. Verified ground truth for this
        //     implementation, dash pattern [4,3] over a 24pt row with a 4pt
        //     bar: 15 of 24 rows painted at x=0..3, and 0 of 24 at x=4 —
        //     measured, not assumed. A 1pt line leaves x=0 and x=3 clean; an
        //     off-centre line leaves x=0 clean and paints x=4.
        let partialBarFullColor = resolvedRed // dash "on" segments stroke at full colour, same as the solid bar
        func paintedRowCount(in rep: NSBitmapImageRep, x: Int) -> Int? {
            var count = 0
            for y in 0..<Int(frame.height) {
                guard let c = pixel(rep, x: x, y: y) else { return nil }
                if sameColor(c, partialBarFullColor) { count += 1 }
            }
            return count
        }
        let expectedPaintedCounts = [0: 15, 1: 15, 2: 15, 3: 15, 4: 0]
        for (x, expected) in expectedPaintedCounts.sorted(by: { $0.key < $1.key }) {
            if let actual = paintedRowCount(in: partialRep, x: x) {
                expectEqual(actual, expected, "the dashed bar paints \(expected) of 24 rows at x=\(x)")
            } else {
                failures += 1
                print("FAIL could not read column x=\(x) for the dash-width check")
            }
        }

        // 4c. The bar survives SELECTION. This is why the bar is painted in
        //     `draw(_:)` after `super` rather than in `drawBackground`:
        //     `NSTableRowView` paints selection AFTER the background, so a bar
        //     drawn there sits underneath an opaque selection fill. It used to
        //     survive only because the table's `.inset` style insets the
        //     selection past the leading edge — an accident that disappeared
        //     when the table moved to `.fullWidth`. Since the bar is now the
        //     ONLY marker on a tagged row, losing it on a selected row would
        //     lose the tag altogether.
        if let selectedRep = render(strong, selected: true),
           let selectedBar = pixel(selectedRep, x: barX, y: midY) {
            expectTrue(sameColor(selectedBar, resolvedRed),
                       "the bar is still the full label colour on a SELECTED row")
        } else {
            failures += 1
            print("FAIL could not render a selected row for the bar-survives-selection check")
        }

        // 5. clearTag really stops the drawing: after clearing, the mid pixel
        //    must match the untagged baseline.
        let clearedView = TaggedRowView(frame: frame)
        clearedView.configure(color: .systemRed, isPartial: false)
        clearedView.clearTag()
        if let clearedRep = render(clearedView), let clearedMid = pixel(clearedRep, x: midX, y: midY) {
            expectTrue(sameColor(clearedMid, untaggedMid), "clearTag's mid pixel matches the untagged baseline")
        } else {
            failures += 1
            print("FAIL cleared view produced no readable pixel")
        }
    } else {
        failures += 1
        print("FAIL pixel rendering produced no readable colour — the offscreen bitmap technique did not work")
    }

    // MARK: - needsDisplay (reuse correctness)
    //
    // `render` above calls `drawBackground(in:)` directly, bypassing the real
    // entry point: `NSTableView` recycles row views and relies on
    // `needsDisplay = true` to get them repainted. A `configure`/`clearTag`
    // that forgot to invalidate would still pass every pixel check above,
    // because `render` never goes through invalidation at all — this is the
    // highest-risk reuse bug in the class, and the only way to see it is to
    // ask the real property. `needsDisplay` reads back false outside a
    // window — AppKit discards the invalidation when there's nothing to
    // display — but true inside a window, even an offscreen, never-shown one.
    // Same pattern as PharosTests/ToastClickTests.swift,
    // VariableRowLayoutTests.swift, and ErrorBadgeButtonTests.swift.
    let hostWindow = NSWindow(
        contentRect: frame, styleMask: [.borderless], backing: .buffered, defer: false
    )
    let hostedView = TaggedRowView(frame: frame)
    hostWindow.contentView = hostedView

    hostedView.needsDisplay = false
    hostedView.configure(color: .systemRed, isPartial: false)
    expectTrue(hostedView.needsDisplay, "configure requests a redraw when hosted in a window")

    hostedView.needsDisplay = false
    hostedView.clearTag()
    expectTrue(hostedView.needsDisplay, "clearTag requests a redraw when hosted in a window")

    if failures == 0 {
        print("\nAll TaggedRowView tests passed.")
    } else {
        print("\n\(failures) failure(s).")
        exit(1)
    }
}
