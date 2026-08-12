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

/// Render a row view offscreen and read one pixel. Real AppKit drawing, no window.
///
/// `view.bitmapImageRepForCachingDisplay` + `cacheDisplay` (the obvious first
/// attempt) does NOT work here: it draws into an alpha-preserving bitmap with
/// nothing underneath, so a partially-transparent fill is stored as its full
/// RGB plus a separate alpha channel — there is no backdrop for it to actually
/// blend against. `colorAt` then returns that unblended RGB unchanged
/// regardless of alpha, so a 15% red wash and a 100% red bar come back with
/// IDENTICAL red/green/blue components (only their alpha differs), and a
/// same-channel comparison like "the bar's red is higher than the wash's red"
/// can never see a difference. Confirmed empirically before writing the real
/// assertions below — see the task report for the numbers.
///
/// The fix: paint a real (opaque, white) backdrop into the bitmap first, then
/// invoke `drawBackground(in:)` directly — the exact method under test — so
/// Quartz performs genuine source-over compositing and `colorAt` reports the
/// true blended colour.
func pixel(_ view: TaggedRowView, x: Int, y: Int) -> NSColor? {
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
    view.drawBackground(in: view.bounds)
    NSGraphicsContext.restoreGraphicsState()

    return rep.colorAt(x: x, y: y)?.usingColorSpace(.deviceRGB)
}

/// Two colours are "the same" within a small epsilon — offscreen rendering can
/// carry a hair of rounding noise even for a flat fill.
func closeColor(_ a: NSColor, _ b: NSColor) -> Bool {
    abs(a.redComponent - b.redComponent) < 0.02
        && abs(a.greenComponent - b.greenComponent) < 0.02
        && abs(a.blueComponent - b.blueComponent) < 0.02
}

/// How far a colour sits from a reference (e.g. the untagged baseline), summed
/// across channels. A saturated hue like `.systemRed` keeps its red channel at
/// 1.0 whether it is a faint wash or a solid bar — the difference only shows up
/// in the OTHER channels — so "more saturated" has to be judged by total
/// distance from the baseline, not by any one fixed channel.
func distance(_ a: NSColor, from b: NSColor) -> CGFloat {
    abs(a.redComponent - b.redComponent)
        + abs(a.greenComponent - b.greenComponent)
        + abs(a.blueComponent - b.blueComponent)
}

func runTests() {
    let frame = NSRect(x: 0, y: 0, width: 400, height: 24)

    // An untagged row draws nothing, so the grid looks exactly as it did before.
    let plain = TaggedRowView(frame: frame)
    expectEqual(plain.tagColor == nil, true, "an untagged row holds no colour")
    expectEqual(plain.barRect(in: frame), .zero, "an untagged row draws no bar")
    expectClose(plain.tintAlpha, 0, "an untagged row has no tint")

    // A strong match: 15% tint, a 3pt solid bar at the leading edge.
    let strong = TaggedRowView(frame: frame)
    strong.configure(color: .systemRed, isWeak: false)
    expectClose(strong.tintAlpha, 0.15, "a strong match tints at 15%")
    expectClose(strong.barRect(in: frame).width, 3, "the bar is 3pt wide")
    expectClose(strong.barRect(in: frame).minX, 0, "the bar sits at the leading edge")
    expectClose(strong.barRect(in: frame).height, frame.height, "the bar spans the row height")
    expectEqual(strong.isBarDashed, false, "a strong match draws a solid bar")

    // A weak match: 8% tint and a dashed bar, so the two tiers are told apart
    // without reading anything.
    let weak = TaggedRowView(frame: frame)
    weak.configure(color: .systemRed, isWeak: true)
    expectClose(weak.tintAlpha, 0.08, "a weak match tints at 8%")
    expectEqual(weak.isBarDashed, true, "a weak match draws a dashed bar")
    expectClose(weak.barRect(in: frame).width, 3, "the weak bar is the same width")

    // Reuse: NSTableView recycles row views, so configuring one twice must not
    // leave the first tag's state behind.
    let reused = TaggedRowView(frame: frame)
    reused.configure(color: .systemBlue, isWeak: true)
    reused.configure(color: .systemGreen, isWeak: false)
    expectClose(reused.tintAlpha, 0.15, "reuse takes the second tag's alpha")
    expectEqual(reused.isBarDashed, false, "reuse clears the dashed bar")
    reused.clearTag()
    expectEqual(reused.tagColor == nil, true, "clearing removes the colour")
    expectClose(reused.tintAlpha, 0, "clearing removes the tint")
    expectEqual(reused.barRect(in: frame), .zero, "clearing removes the bar")

    // The bar must not scale with the row. A tall row still gets 3pt.
    let tall = NSRect(x: 0, y: 0, width: 400, height: 60)
    expectClose(strong.barRect(in: tall).width, 3, "the bar stays 3pt on a taller row")
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
    strongForPixels.configure(color: .systemRed, isWeak: false)
    let weakForPixels = TaggedRowView(frame: frame)
    weakForPixels.configure(color: .systemRed, isWeak: true)

    if let untaggedMid = pixel(untaggedForPixels, x: midX, y: midY),
       let strongMid = pixel(strongForPixels, x: midX, y: midY),
       let weakMid = pixel(weakForPixels, x: midX, y: midY),
       let strongBar = pixel(strongForPixels, x: barX, y: midY) {

        // 1. An untagged row paints no tag: its mid pixel must differ from a
        //    tagged row's mid pixel.
        let untaggedVsStrongDiffers = abs(untaggedMid.redComponent - strongMid.redComponent) > 0.001
            || abs(untaggedMid.greenComponent - strongMid.greenComponent) > 0.001
            || abs(untaggedMid.blueComponent - strongMid.blueComponent) > 0.001
        expectTrue(untaggedVsStrongDiffers, "an untagged row's mid pixel differs from a strong row's")

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

        // 3. A weak row's wash is fainter than a strong row's: the weak mid
        //    pixel must sit closer to the untagged baseline than the strong
        //    mid pixel does.
        let weakDelta = distance(weakMid, from: untaggedMid)
        let strongDelta = distance(strongMid, from: untaggedMid)
        expectTrue(weakDelta < strongDelta, "a weak row's wash sits closer to the untagged baseline than a strong row's")

        // 4. The dashed bar has gaps; the solid bar does not. Walk the bar
        //    column down every y of both views.
        var strongBarColors: [NSColor] = []
        var weakBarColors: [NSColor] = []
        for y in 0..<Int(frame.height) {
            if let c = pixel(strongForPixels, x: barX, y: y) { strongBarColors.append(c) }
            if let c = pixel(weakForPixels, x: barX, y: y) { weakBarColors.append(c) }
        }
        if strongBarColors.count == Int(frame.height) && weakBarColors.count == Int(frame.height) {
            let strongBarUniform = strongBarColors.dropFirst().allSatisfy { closeColor($0, strongBarColors[0]) }
            expectTrue(strongBarUniform, "the strong (solid) bar column is uniform top to bottom")

            let weakBarHasGap = weakBarColors.contains { !closeColor($0, weakBarColors[0]) }
            expectTrue(weakBarHasGap, "the weak (dashed) bar column has at least one differing pixel — a dash gap")
        } else {
            failures += 1
            print("FAIL could not read every y of the bar column for the dash-gap check")
        }

        // 5. clearTag really stops the drawing: after clearing, the mid pixel
        //    must match the untagged baseline.
        let clearedView = TaggedRowView(frame: frame)
        clearedView.configure(color: .systemRed, isWeak: false)
        _ = pixel(clearedView, x: midX, y: midY) // render once while tagged
        clearedView.clearTag()
        if let clearedMid = pixel(clearedView, x: midX, y: midY) {
            expectTrue(closeColor(clearedMid, untaggedMid), "clearTag's mid pixel matches the untagged baseline")
        } else {
            failures += 1
            print("FAIL cleared view produced no readable pixel")
        }
    } else {
        failures += 1
        print("FAIL pixel rendering produced no readable colour — bitmapImageRepForCachingDisplay/cacheDisplay did not work offscreen")
    }

    if failures == 0 {
        print("\nAll TaggedRowView tests passed.")
    } else {
        print("\n\(failures) failure(s).")
        exit(1)
    }
}
