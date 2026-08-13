// Standalone test runner for TagDot. Real AppKit, no window needed.
// Compiled with the implementation by scripts/test-tag-dot.sh.
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

/// Render `TagDot.draw` into an offscreen, opaque-white bitmap so `colorAt`
/// reports genuinely blended pixels.
///
/// `bitmapImageRepForCachingDisplay` + `cacheDisplay` cannot be used here — with
/// nothing underneath, the bitmap preserves alpha rather than blending, so a
/// hollow dot's stroke and a filled dot's fill of the same colour would read
/// back with identical RGB and differ only in an alpha channel that `colorAt`
/// does not factor in. Painting an opaque white backdrop first and drawing
/// through `NSGraphicsContext(bitmapImageRep:)` forces real source-over
/// compositing, so every sampled pixel comes back with alpha 1.0 and a true
/// blended colour. Same technique as PharosTests/TaggedRowViewTests.swift.
func render(color: NSColor, filled: Bool, in bounds: NSRect) -> NSBitmapImageRep? {
    let width = Int(bounds.width)
    let height = Int(bounds.height)
    guard let rep = NSBitmapImageRep(
        bitmapDataPlanes: nil, pixelsWide: width, pixelsHigh: height,
        bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
        colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0
    ), let context = NSGraphicsContext(bitmapImageRep: rep) else { return nil }

    NSGraphicsContext.saveGraphicsState()
    NSGraphicsContext.current = context
    NSColor.white.setFill()
    NSRect(x: 0, y: 0, width: CGFloat(width), height: CGFloat(height)).fill()
    TagDot.draw(color: color, filled: filled, in: bounds)
    NSGraphicsContext.restoreGraphicsState()

    return rep
}

func pixel(_ rep: NSBitmapImageRep, x: Int, y: Int) -> NSColor? {
    rep.colorAt(x: x, y: y)?.usingColorSpace(.deviceRGB)
}

/// Same epsilon and rationale as TaggedRowViewTests.swift: 0.01 per channel
/// leaves headroom over the 1/255 ≈ 0.004 quantization bound without being
/// loose enough to hide a real difference.
func sameColor(_ a: NSColor, _ b: NSColor) -> Bool {
    abs(a.redComponent - b.redComponent) < 0.01
        && abs(a.greenComponent - b.greenComponent) < 0.01
        && abs(a.blueComponent - b.blueComponent) < 0.01
}

/// Returns a human-readable location of the first non-white pixel found in `rep`
/// OUTSIDE a small margin around `dotRect`, or nil if nothing out there is
/// painted. Scans the FULL bitmap, not a handful of sample points — a stray mark
/// anywhere in the cell must be caught, whichever render it turns up in.
///
/// The margin is not the confinement boundary under test; it exists because a
/// 1.5pt stroke centred on the dot's inset path legitimately spans a fraction of
/// a point past the dot's nominal rect (see the comment in `TagDot.draw`), and
/// anti-aliasing softens the true edge further. Anything painted beyond the
/// margin is a defect, not geometry — 2pt comfortably clears both effects while
/// staying tight enough to catch a stray mark or a second dot nearby.
func firstNonWhite(in rep: NSBitmapImageRep, around dotRect: NSRect, margin: CGFloat, white: NSColor) -> String? {
    let excluded = dotRect.insetBy(dx: -margin, dy: -margin)
    for y in 0..<rep.pixelsHigh {
        for x in 0..<rep.pixelsWide {
            let point = NSPoint(x: CGFloat(x) + 0.5, y: CGFloat(y) + 0.5)
            if excluded.contains(point) { continue }
            guard let c = pixel(rep, x: x, y: y), !sameColor(c, white) else { continue }
            return "(\(x), \(y))"
        }
    }
    return nil
}

func runTests() {
    // MARK: - Geometry

    let shortRow = NSRect(x: 0, y: 0, width: 54, height: 24)
    let tallRow = NSRect(x: 0, y: 0, width: 54, height: 60)
    // The row height that actually ships — ResultsGridVC.swift:115 sets
    // tableView.rowHeight = 22. (22 − 6) / 2 is a different number than either
    // of the two round-number heights above, so it is its own check, not
    // implied by them.
    let productionRow = NSRect(x: 0, y: 0, width: 54, height: 22)

    let shortRect = TagDot.rect(in: shortRow)
    expectClose(shortRect.width, 6, "the dot is 6pt wide")
    expectClose(shortRect.height, 6, "the dot is 6pt tall")
    expectClose(shortRect.midY, shortRow.height / 2, "the dot is vertically centred in a 24pt row")

    let tallRect = TagDot.rect(in: tallRow)
    expectClose(tallRect.midY, tallRow.height / 2, "the dot is vertically centred in a 60pt row")
    // The dot must not scale with row height.
    expectClose(tallRect.width, 6, "the dot does not widen on a taller row")
    expectClose(tallRect.height, 6, "the dot does not grow taller on a taller row")

    let productionRect = TagDot.rect(in: productionRow)
    expectClose(productionRect.midY, productionRow.height / 2, "the dot is vertically centred in a 22pt row — the production row height")
    expectClose(productionRect.width, 6, "the dot stays 6pt wide at the production row height")
    expectClose(productionRect.height, 6, "the dot stays 6pt tall at the production row height")

    // Pin every constant except `diameter` (already pinned indirectly, above,
    // via the derived rect's width) to a literal. Comparing a derived value
    // back against the constant that produced it — e.g. `shortRect.minX` against
    // `TagDot.leading` — is a tautology that can never fail; these compare
    // against fixed numbers instead.
    expectClose(TagDot.leading, 5, "leading is 5pt")
    expectClose(TagDot.textInsetPlain, 6, "textInsetPlain is 6pt")
    expectClose(TagDot.textInsetWithDot, 15, "textInsetWithDot is 15pt")

    // MARK: - Polarity

    // The feature's one decision, pinned at the one function that makes it. A
    // fingerprint match (isWeak: true) is HOLLOW; inverting this passes every
    // other check in the repository, which is exactly why it gets its own name
    // and its own pin rather than living as `!isWeak` at each call site.
    expectEqual(TagDot.filled(forWeakMatch: false), true, "a strong match (isWeak: false) is filled")
    expectEqual(TagDot.filled(forWeakMatch: true), false, "a fingerprint match (isWeak: true) is hollow")

    // MARK: - Pixels

    let frame = NSRect(x: 0, y: 0, width: 54, height: 24)
    let dotRect = TagDot.rect(in: frame)
    let centerX = Int(dotRect.midX)
    let centerY = Int(dotRect.midY)

    guard let filledRep = render(color: .systemRed, filled: true, in: frame),
          let hollowRep = render(color: .systemRed, filled: false, in: frame),
          let filledMid = pixel(filledRep, x: centerX, y: centerY),
          let hollowMid = pixel(hollowRep, x: centerX, y: centerY) else {
        failures += 1
        print("FAIL pixel rendering produced no readable colour — the offscreen bitmap technique did not work")
        printSummary()
        return
    }

    let resolvedRed = NSColor.systemRed.usingColorSpace(.deviceRGB) ?? .systemRed
    let white = NSColor.white.usingColorSpace(.deviceRGB) ?? .white

    // 1. A filled dot paints its centre in the resolved colour.
    expectTrue(sameColor(filledMid, resolvedRed), "a filled dot paints its centre in the resolved colour")

    // 2. A hollow dot leaves the centre (close to) white, unlike the filled dot.
    expectTrue(sameColor(hollowMid, white), "a hollow dot leaves its centre white")
    expectTrue(!sameColor(hollowMid, filledMid), "a hollow dot's centre differs from a filled dot's centre")

    // 3. Nothing is painted outside a small margin around the dot — swept pixel
    //    by pixel across the FULL bitmap, on BOTH the filled and the hollow
    //    render. A single sampled point cannot prove confinement: a stray mark
    //    anywhere else in the cell, or a second dot drawn only in the hollow
    //    branch, would both slip past a point sample unnoticed.
    let filledStray = firstNonWhite(in: filledRep, around: dotRect, margin: 2, white: white)
    if let filledStray { print("  detail: \(filledStray)") }
    expectTrue(filledStray == nil,
               "nothing is painted outside a 2pt margin around the dot in the filled render, swept pixel by pixel across the full bitmap")

    let hollowStray = firstNonWhite(in: hollowRep, around: dotRect, margin: 2, white: white)
    if let hollowStray { print("  detail: \(hollowStray)") }
    expectTrue(hollowStray == nil,
               "nothing is painted outside a 2pt margin around the dot in the hollow render, swept pixel by pixel across the full bitmap")

    // 4. The colour argument actually reaches the drawing — render with a
    //    second colour and confirm the centre pixel moves. Without this, a
    //    `draw` that ignored `color` entirely would pass everything above.
    if let blueRep = render(color: .systemBlue, filled: true, in: frame),
       let blueMid = pixel(blueRep, x: centerX, y: centerY) {
        expectTrue(!sameColor(blueMid, filledMid), "a filled dot's colour tracks the `color` argument, not a fixed colour")
        let resolvedBlue = NSColor.systemBlue.usingColorSpace(.deviceRGB) ?? .systemBlue
        expectTrue(sameColor(blueMid, resolvedBlue), "a blue filled dot paints its centre in the resolved blue")
    } else {
        failures += 1
        print("FAIL could not render the blue filled dot")
    }

    // 5. The hollow dot's rim IS painted (unlike its centre) — this is the
    //    entire distinction between the two states.
    let rimX = centerX
    let rimY = Int(dotRect.minY) // top edge of the dot's bounding box
    if let hollowRim = pixel(hollowRep, x: rimX, y: rimY) {
        expectTrue(!sameColor(hollowRim, white), "a hollow dot's rim is painted, unlike its centre")
    } else {
        failures += 1
        print("FAIL could not read the hollow dot's rim pixel")
    }

    // 6. The hollow rim is EXACTLY the resolved colour, not merely "not white".
    //    A stroke drawn in the wrong colour (e.g. black) or at reduced alpha
    //    (e.g. 30%) both still satisfy "not white" and would pass check 5
    //    unchanged. Sample the rim at its waist — the left edge, at the dot's
    //    vertical centre — which is fully covered at the real lineWidth (1.5).
    let waistX = Int(dotRect.minX)
    let waistY = centerY
    if let hollowWaist = pixel(hollowRep, x: waistX, y: waistY) {
        expectTrue(sameColor(hollowWaist, resolvedRed),
                   "a hollow dot's rim at the waist is exactly the resolved colour, not merely non-white")
    } else {
        failures += 1
        print("FAIL could not read the hollow dot's waist pixel")
    }

    printSummary()
}

func printSummary() {
    if failures == 0 {
        print("\nAll TagDot tests passed.")
    } else {
        print("\n\(failures) failure(s).")
        exit(1)
    }
}
