// Standalone test runner for TaggedRowView. Real AppKit; most checks need no
// window — the needsDisplay block near the end hosts one on purpose, since
// that flag only behaves once a view actually has one (see its comment there).
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
/// repeatedly. Real AppKit drawing, no window. See the Phase 4 test file's
/// long comment for why cacheDisplay does NOT work here (no backdrop to
/// blend against): paint an opaque white backdrop, then call `draw(_:)`,
/// the real entry point.
///
/// - Parameter calibrateAt: when set, paints a single black pixel at this
///   VIEW-space y, in the column `bounds.maxX - 1` (a column the 4pt bar
///   never touches). A caller can then locate which BITMAP row corresponds
///   to that view-space y by searching for the mark, instead of assuming a
///   flip direction. See the calibration-mark test below for why that
///   distinction matters here. Painted AFTER `view.draw(_:)`, not before:
///   the wash's `bounds.fill()` in `drawBackground(in:)` spans the FULL
///   width and is TRANSLUCENT, so a mark painted first — at any x — does
///   not get overwritten, it gets BLENDED under the wash (a black mark
///   reads back as roughly (0.149, 0.031, 0.035) at the 15% red wash), which
///   is no longer pure black either — the search below fails all the same,
///   just not for the reason "overwritten" would suggest.
func render(_ view: TaggedRowView, selected: Bool = false, calibrateAt calibrationY: CGFloat? = nil) -> NSBitmapImageRep? {
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
    view.selectionHighlightStyle = .regular
    view.isSelected = selected
    view.draw(view.bounds)
    if let calibrationY {
        NSColor.black.setFill()
        NSRect(x: view.bounds.maxX - 1, y: calibrationY, width: 1, height: 1).fill()
    }
    NSGraphicsContext.restoreGraphicsState()

    return rep
}

func pixel(_ rep: NSBitmapImageRep, x: Int, y: Int) -> NSColor? {
    rep.colorAt(x: x, y: y)?.usingColorSpace(.deviceRGB)
}

/// The ONE colour-equality comparator. 0.01 per channel — see Phase 4's
/// comment on the epsilon.
func sameColor(_ a: NSColor, _ b: NSColor) -> Bool {
    abs(a.redComponent - b.redComponent) < 0.01
        && abs(a.greenComponent - b.greenComponent) < 0.01
        && abs(a.blueComponent - b.blueComponent) < 0.01
}

/// α·C + (1−α)·white, from the RESOLVED colour.
func expectedBlend(_ c: NSColor, alpha: CGFloat) -> NSColor {
    let resolved = c.usingColorSpace(.deviceRGB) ?? c
    return NSColor(
        deviceRed: alpha * resolved.redComponent + (1 - alpha),
        green: alpha * resolved.greenComponent + (1 - alpha),
        blue: alpha * resolved.blueComponent + (1 - alpha),
        alpha: 1.0
    )
}

func runTests() {
    let frame = NSRect(x: 0, y: 0, width: 400, height: 24)
    let resolvedRed = NSColor.systemRed.usingColorSpace(.deviceRGB) ?? .systemRed
    let resolvedBlue = NSColor.systemBlue.usingColorSpace(.deviceRGB) ?? .systemBlue
    let resolvedBlack = NSColor.black.usingColorSpace(.deviceRGB) ?? .black

    // MARK: - Untagged

    let plain = TaggedRowView(frame: frame)
    expectTrue(plain.segments.isEmpty, "an untagged row holds no segments")
    expectEqual(plain.barRect(in: frame), .zero, "an untagged row draws no bar")
    expectTrue(plain.segmentRects(in: frame).isEmpty, "an untagged row has no segment rects")
    expectClose(plain.tintAlpha, 0, "an untagged row has no tint")

    // MARK: - One solid segment behaves exactly like Phase 4

    let strong = TaggedRowView(frame: frame)
    strong.configure(segments: [(color: .systemRed, isPartial: false)])
    expectClose(strong.tintAlpha, 0.15, "a solid match tints at 15%")
    expectClose(strong.barRect(in: frame).width, 4, "the bar is 4pt wide")
    expectClose(strong.barRect(in: frame).minX, 0, "the bar sits at the leading edge")
    expectClose(strong.barRect(in: frame).height, frame.height, "the bar spans the row height")
    expectEqual(strong.segmentRects(in: frame).count, 1, "one segment, one rect")
    expectEqual(strong.segmentRects(in: frame)[0], strong.barRect(in: frame),
                "a single segment's rect IS the bar rect")
    expectEqual(strong.isPartial, false, "a solid first segment is not partial")

    let partial = TaggedRowView(frame: frame)
    partial.configure(segments: [(color: .systemRed, isPartial: true)])
    expectClose(partial.tintAlpha, 0.08, "a partial match tints at 8%")
    expectEqual(partial.isPartial, true, "a dashed first segment is partial")

    // MARK: - Segment geometry: equal bands, first at the visual top

    // FACT PIN: NSTableRowView is flipped — band 0 at minY is the visual top;
    // the drawing code depends on this. If AppKit ever changes it, this
    // assertion fails and whoever sees it reintroduces an `isFlipped` branch
    // in `segmentRects(in:)` deliberately, instead of it silently drawing
    // bands upside down in the real table.
    expectTrue(TaggedRowView(frame: frame).isFlipped,
               "NSTableRowView is flipped — band 0 at minY is the visual top; the drawing code depends on this")

    let two = TaggedRowView(frame: frame)
    two.configure(segments: [(color: .systemRed, isPartial: false),
                             (color: .systemBlue, isPartial: false)])
    do {
        let rects = two.segmentRects(in: frame)
        expectEqual(rects.count, 2, "two segments, two rects")
        expectClose(rects[0].height, 12, "two segments split the 24pt row into 12pt bands")
        expectClose(rects[1].height, 12, "the second band is the same height")
        expectClose(rects[0].width, 4, "bands keep the 4pt bar width")
        expectClose(rects[0].minY, frame.minY, "the FIRST segment takes the visual top band (bounds.minY)")
        expectTrue(!rects[0].intersects(rects[1]), "the two bands do not overlap")
        expectClose(rects[0].height + rects[1].height, frame.height,
                    "the bands cover the full row height")
    }

    let three = TaggedRowView(frame: frame)
    three.configure(segments: [(color: .systemRed, isPartial: false),
                               (color: .systemBlue, isPartial: true),
                               (color: .systemGreen, isPartial: false)])
    expectEqual(three.segmentRects(in: frame).count, 3, "three segments, three rects")
    expectClose(three.segmentRects(in: frame)[1].height, 8, "three segments make 8pt bands")

    // A non-zero frame origin: every other frame in this file starts at
    // (0, 0), so replacing `bar.minY + offset` with plain `offset`, or
    // `bar.minX` with a hardcoded `0`, would still pass every check above.
    let offsetFrame = NSRect(x: 7, y: 5, width: 400, height: 24)
    let offsetView = TaggedRowView(frame: offsetFrame)
    offsetView.configure(segments: [(color: .systemRed, isPartial: false),
                                    (color: .systemBlue, isPartial: false)])
    let offsetRects = offsetView.segmentRects(in: offsetFrame)
    expectClose(offsetRects[0].minX, 7, "segmentRects uses the frame's actual minX, not a hardcoded 0")
    expectClose(offsetRects[0].minY, 5, "the FIRST band starts at the frame's actual minY, not a hardcoded 0")
    expectClose(offsetRects[1].minY, 17, "the second band still starts one band height further down the bar")

    // A height where the drift is actually REPRESENTABLE: 20 / 3 does NOT
    // work here — 2×6.666... + 6.666... rounds to exactly 20.0 bit for bit,
    // so summing three equal bandHeights and taking the remainder produce
    // IDENTICAL output and this could never fail either way. 24.05 / 3 =
    // 8.016666...; three of those sum to 24.050000000000004 (not 24.05),
    // so this DOES distinguish the remainder branch from equal bandHeights.
    let unevenFrame = NSRect(x: 0, y: 0, width: 400, height: 24.05)
    let uneven = TaggedRowView(frame: unevenFrame)
    uneven.configure(segments: [(color: .systemRed, isPartial: false),
                                (color: .systemBlue, isPartial: false),
                                (color: .systemGreen, isPartial: false)])
    expectEqual(uneven.segmentRects(in: unevenFrame).last!.maxY, unevenFrame.maxY,
                "the LAST band's far edge lands EXACTLY on the row's far edge (24.05/3 does NOT round-trip)")

    // MARK: - The wash comes from the FIRST segment only

    if let rep = render(two), let mid = pixel(rep, x: 200, y: 12) {
        expectTrue(sameColor(mid, expectedBlend(resolvedRed, alpha: 0.15)),
                   "the wash is the FIRST segment's colour at 15%, unaffected by the second segment")
    } else {
        failures += 1
        print("FAIL could not render the two-segment view for the wash check")
    }

    // A partial FIRST segment drops the wash to 8% even when a solid segment follows.
    let partialFirst = TaggedRowView(frame: frame)
    partialFirst.configure(segments: [(color: .systemRed, isPartial: true),
                                      (color: .systemBlue, isPartial: false)])
    expectClose(partialFirst.tintAlpha, 0.08, "a partial FIRST segment washes at 8%")

    // MARK: - WHICH colour lands in which band (not just that both appear)
    //
    // Counting reds/blues below (next section) proves both colours are
    // painted and contiguous, but not WHICH one sits in the visual top band
    // — reversing `zip(segments, segmentRects(in:))` in `draw(_:)` would put
    // the wrong colour on top and still pass a pure count. Do not assume
    // which bitmap row corresponds to bounds.minY either way: measure it
    // with a calibration mark in a column the bar never touches.
    if let rep = render(two, calibrateAt: frame.minY) {
        var calibrationRow: Int?
        for y in 0..<Int(frame.height) {
            if let c = pixel(rep, x: Int(frame.maxX) - 1, y: y), sameColor(c, resolvedBlack) {
                calibrationRow = y
                break
            }
        }
        if let calibrationRow, let c = pixel(rep, x: 1, y: calibrationRow) {
            expectTrue(sameColor(c, resolvedRed),
                       "the FIRST segment's colour paints the band at bounds.minY (the visual top), located via the calibration mark")
        } else {
            failures += 1
            print("FAIL could not locate the calibration mark to determine which bitmap row is bounds.minY")
        }
    } else {
        failures += 1
        print("FAIL could not render the two-segment view for the calibration check")
    }

    // MARK: - Both band colours actually reach the pixels, each contiguous

    if let rep = render(two) {
        var reds = 0, blues = 0, other = 0
        var transitions = 0
        var previous: String?
        for y in 0..<Int(frame.height) {
            guard let c = pixel(rep, x: 1, y: y) else { continue }
            let label: String
            if sameColor(c, resolvedRed) { label = "red"; reds += 1 }
            else if sameColor(c, resolvedBlue) { label = "blue"; blues += 1 }
            else { label = "other"; other += 1 }
            if let previous, previous != label { transitions += 1 }
            previous = label
        }
        expectEqual(reds, 12, "the red band paints exactly half the bar column")
        expectEqual(blues, 12, "the blue band paints exactly the other half")
        expectEqual(other, 0, "no bar-column pixel is anything but the two band colours")
        expectEqual(transitions, 1, "the two bands are contiguous — exactly one colour change down the column")
    } else {
        failures += 1
        print("FAIL could not render the two-segment view for the band-pixel check")
    }

    // MARK: - A dashed band has gaps; a solid band does not

    let mixed = TaggedRowView(frame: frame)
    mixed.configure(segments: [(color: .systemRed, isPartial: false),
                               (color: .systemRed, isPartial: true)])
    if let rep = render(mixed) {
        // Split the column into its two 12pt halves by y-position, then
        // check each half's uniformity. Splitting by y-position is fine —
        // the two bands ARE contiguous 12pt halves, pinned above. What this
        // does NOT claim is WHICH half is band 0; that is the calibration-
        // mark test's job, above.
        var bandA: [NSColor] = [], bandB: [NSColor] = []
        for y in 0..<Int(frame.height) {
            guard let c = pixel(rep, x: 1, y: y) else { continue }
            if y < 12 { bandA.append(c) } else { bandB.append(c) }
        }
        let aUniformRed = bandA.allSatisfy { sameColor($0, resolvedRed) }
        let bUniformRed = bandB.allSatisfy { sameColor($0, resolvedRed) }
        expectTrue(aUniformRed != bUniformRed,
                   "exactly one half of the bar column is uniform red (the solid band); the other has dash gaps")
    } else {
        failures += 1
        print("FAIL could not render the mixed solid/dashed view")
    }

    // MARK: - The dash RHYTHM itself is pinned, not just "some gaps exist"
    //
    // The check above is satisfied by ANY alternating pattern — swapping
    // `Self.dashPattern` from [4, 3] to [3, 4] still leaves a dashed band
    // with gaps and a solid one without, so it passes there unchanged.
    // Count the exact number of "on" pixels down a full-height dashed band:
    // for [4, 3] over this 24pt row the cycle is on 4 / off 3 / on 4 / off 3
    // / on 4 / off 3 / on 3 (the partial final cycle) = 15 "on" rows of 24.
    // [3, 4] instead gives on 3 / off 4 ×3 plus a partial on 3 = 12 "on"
    // rows — a different, checkable number.
    if let rep = render(partial) {
        var onCount = 0
        for y in 0..<Int(frame.height) {
            if let c = pixel(rep, x: 1, y: y), sameColor(c, resolvedRed) { onCount += 1 }
        }
        expectEqual(onCount, 15,
                    "the dash rhythm paints exactly 15 of 24 rows \"on\" — [4, 3], not [3, 4] or any other pattern")
    } else {
        failures += 1
        print("FAIL could not render the partial view for the dash-rhythm check")
    }

    // MARK: - The bar's painted WIDTH is a true 4pt, both solid and dashed
    //
    // Every pixel check above samples only x=1, which cannot tell a 4pt bar
    // from a narrower one — both cover x=1. x=3 must still be the full band
    // colour; x=4 must already be wash-only, for a solid band AND for a
    // dash's "on" segment. This is what catches a hardcoded `lineWidth = 2`
    // (or any other narrower draw width) that a single-column sample cannot.

    if let rep = render(strong), let atThree = pixel(rep, x: 3, y: 12), let atFour = pixel(rep, x: 4, y: 12) {
        expectTrue(sameColor(atThree, resolvedRed),
                   "a solid band still paints x=3 — the bar is a true 4pt, not narrower")
        expectTrue(sameColor(atFour, expectedBlend(resolvedRed, alpha: 0.15)),
                   "x=4 has already fallen back to the wash — the solid band does not overrun 4pt")
    } else {
        failures += 1
        print("FAIL could not render the strong view for the solid-band width check")
    }

    if let rep = render(partial), let atThreeOn = pixel(rep, x: 3, y: 1), let atFourOn = pixel(rep, x: 4, y: 1) {
        expectTrue(sameColor(atThreeOn, resolvedRed),
                   "a dashed band's ON segment still paints x=3 — lineWidth is a true 4pt")
        expectTrue(sameColor(atFourOn, expectedBlend(resolvedRed, alpha: 0.08)),
                   "x=4 has already fallen back to the wash even on a dash's ON segment")
    } else {
        failures += 1
        print("FAIL could not render the partial view for the dashed-band width check")
    }

    // MARK: - Reuse: reconfiguring replaces the bands entirely

    let reused = TaggedRowView(frame: frame)
    reused.configure(segments: [(color: .systemBlue, isPartial: true),
                                (color: .systemGreen, isPartial: false)])
    reused.configure(segments: [(color: .systemGreen, isPartial: false)])
    expectEqual(reused.segments.count, 1, "reuse takes the second configuration's band count")
    expectClose(reused.tintAlpha, 0.15, "reuse takes the second configuration's alpha")
    expectClose(reused.segmentRects(in: frame)[0].height, frame.height,
                "the surviving band spans the full row again")
    reused.clearTag()
    expectTrue(reused.segments.isEmpty, "clearing removes the bands")
    expectClose(reused.tintAlpha, 0, "clearing removes the tint")
    expectEqual(reused.barRect(in: frame), .zero, "clearing removes the bar")

    // MARK: - The bar must not scale with the row

    let tall = NSRect(x: 0, y: 0, width: 400, height: 60)
    expectClose(strong.barRect(in: tall).width, 4, "the bar stays 4pt on a taller row")
    expectClose(strong.barRect(in: tall).height, 60, "the bar still spans the row")

    // MARK: - isSelected does not change the bar's own drawing
    //
    // LIMIT: a bare NSTableRowView outside a real table paints NO opaque
    // selection fill, so this cannot see a z-order regression. Moving the
    // bands into drawBackground(in:) still passes here. That the bar sits
    // ABOVE the table's selection fill is Task 10's manual check.

    if let selectedRep = render(strong, selected: true),
       let selectedBar = pixel(selectedRep, x: 1, y: 12) {
        expectTrue(sameColor(selectedBar, resolvedRed),
                   "isSelected = true does not change the bar's colour (z-order NOT covered — see LIMIT above)")
    } else {
        failures += 1
        print("FAIL could not render a selected row for the isSelected check")
    }

    // MARK: - The Phase 4 single-tag shim still works (deleted in Task 3)

    let shim = TaggedRowView(frame: frame)
    shim.configure(color: .systemRed, isPartial: true)
    expectEqual(shim.segments.count, 1, "the shim configures one segment")
    expectClose(shim.tintAlpha, 0.08, "the shim carries isPartial through")

    // MARK: - needsDisplay (reuse correctness) — needs a window, see Phase 4 comment
    //
    // A freshly hosted view's `needsDisplay` starts `true`, and that initial
    // invalidation does NOT clear on its own: setting `needsDisplay = false`
    // right after hosting and reading it back immediately still returns
    // `true`. That made the two checks below pass with `needsDisplay = true`
    // deleted from `configure`/`clearTag` entirely — caught during Task 2
    // review, and NOT fixed by spinning the run loop: in this offscreen,
    // never-ordered-front window, AppKit reconciles after the first run-loop
    // turn that the window can never actually flush, and from then on it
    // discards every invalidation, `true` ones included — so a "spin, then
    // assert the flag cleared" precondition made the postcondition fail even
    // for CORRECT code. `displayIfNeeded()` sidesteps this: it forces a real,
    // synchronous display pass through the same code path the window server
    // would use, with no dependency on wall-clock timing or screen presence.
    // Calling it settles the flag to `false` deterministically; asserting
    // THAT is the precondition that makes each postcondition non-vacuous.

    let hostWindow = NSWindow(
        contentRect: frame, styleMask: [.borderless], backing: .buffered, defer: false
    )
    let hostedView = TaggedRowView(frame: frame)
    hostWindow.contentView = hostedView

    hostedView.displayIfNeeded()
    expectEqual(hostedView.needsDisplay, false,
                "PRECONDITION: needsDisplay is settled (false) after a real display pass")
    hostedView.configure(segments: [(color: .systemRed, isPartial: false)])
    expectTrue(hostedView.needsDisplay, "configure requests a redraw when hosted in a window")

    hostedView.displayIfNeeded()
    expectEqual(hostedView.needsDisplay, false,
                "PRECONDITION: needsDisplay is settled again before the clearTag check")
    hostedView.clearTag()
    expectTrue(hostedView.needsDisplay, "clearTag requests a redraw when hosted in a window")

    if failures == 0 {
        print("\nAll TaggedRowView tests passed.")
    } else {
        print("\n\(failures) failure(s).")
        exit(1)
    }
}
