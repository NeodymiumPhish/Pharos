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

func runTests() {
    // MARK: - Geometry

    let shortRow = NSRect(x: 0, y: 0, width: 54, height: 24)
    let tallRow = NSRect(x: 0, y: 0, width: 54, height: 60)

    let shortRect = TagDot.rect(in: shortRow)
    expectClose(shortRect.width, 6, "the dot is 6pt wide")
    expectClose(shortRect.height, 6, "the dot is 6pt tall")
    expectClose(shortRect.minX, TagDot.leading, "the dot's minX equals the leading inset")
    expectClose(shortRect.midY, shortRow.height / 2, "the dot is vertically centred in a 24pt row")

    let tallRect = TagDot.rect(in: tallRow)
    expectClose(tallRect.midY, tallRow.height / 2, "the dot is vertically centred in a 60pt row")

    // The dot must not scale with row height.
    expectClose(tallRect.width, 6, "the dot does not widen on a taller row")
    expectClose(tallRect.height, 6, "the dot does not grow taller on a taller row")
    expectEqual(tallRect.width, shortRect.width, "the dot's width matches across row heights")
    expectEqual(tallRect.height, shortRect.height, "the dot's height matches across row heights")

    // Text inset ordering.
    expectTrue(TagDot.textInsetWithDot > TagDot.textInsetPlain + TagDot.diameter - 0.01,
               "textInsetWithDot clears textInsetPlain by at least the dot's diameter")

    // MARK: - Pixels

    let frame = NSRect(x: 0, y: 0, width: 54, height: 24)
    let dotRect = TagDot.rect(in: frame)
    let centerX = Int(dotRect.midX)
    let centerY = Int(dotRect.midY)
    // A point to the right of the dot, in the zone where the row number sits.
    let farX = Int(dotRect.maxX) + 10

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

    // 3. Nothing is painted outside the dot's rect. A single point (the
    //    row-number zone to the right) cannot prove confinement — a mutant that
    //    painted a second mark elsewhere in the cell would still pass it. Scan a
    //    full row above the dot, a full row below, and a full column to its
    //    right, and require every sample to stay at the white baseline.
    var exteriorClean = true
    var exteriorFailureDetail: String?
    let aboveY = Int(dotRect.minY) - 2
    let belowY = Int(dotRect.maxY) + 2
    if aboveY >= 0 {
        for x in 0..<Int(frame.width) {
            guard let c = pixel(filledRep, x: x, y: aboveY) else { continue }
            if !sameColor(c, white) {
                exteriorClean = false
                exteriorFailureDetail = "row above the dot (y=\(aboveY)) at x=\(x)"
                break
            }
        }
    }
    if exteriorClean, belowY < Int(frame.height) {
        for x in 0..<Int(frame.width) {
            guard let c = pixel(filledRep, x: x, y: belowY) else { continue }
            if !sameColor(c, white) {
                exteriorClean = false
                exteriorFailureDetail = "row below the dot (y=\(belowY)) at x=\(x)"
                break
            }
        }
    }
    if exteriorClean {
        for x in farX..<Int(frame.width) {
            for y in 0..<Int(frame.height) {
                guard let c = pixel(filledRep, x: x, y: y) else { continue }
                if !sameColor(c, white) {
                    exteriorClean = false
                    exteriorFailureDetail = "column to the right of the dot (x=\(x)) at y=\(y)"
                    break
                }
            }
            if !exteriorClean { break }
        }
    }
    if let detail = exteriorFailureDetail {
        print("  detail: \(detail)")
    }
    expectTrue(exteriorClean, "nothing is painted outside the dot's rect — row above, row below, and column to the right of it all stay white")

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
