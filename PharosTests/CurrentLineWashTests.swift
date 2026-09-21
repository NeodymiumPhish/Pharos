// What the caret-line wash actually PAINTS, and what it costs the syntax
// colors drawn on top of it.
//
// The wash sits under the glyphs of the line the caret is on. A user reported
// a green string literal on that line as unreadable: the band had become a
// mid-gray, because `NSColor.quaternaryLabelColor.withAlphaComponent(0.35)`
// REPLACES a color's alpha instead of scaling it. Quaternary's own alpha is
// 0.1, so the intent was a 0.035 wash; what shipped was black at 0.35 — ten
// times the ink, a 65%-gray band under `.systemGreen`.
//
// So this suite measures pixels, not code. It renders the real `SQLTextView`
// offscreen into an `NSBitmapImageRep` — no window is shown, no screen capture,
// no permission — reads the band's composited color out of the bitmap, and
// checks the contrast a reader gets for each token color that lands on it.
import AppKit

private var failures = 0

private func expect(_ condition: Bool, _ name: String) {
    if condition { print("PASS \(name)") } else { failures += 1; print("FAIL \(name)") }
}

private func expectAtLeast(_ actual: Double, _ floor: Double, _ name: String) {
    if actual >= floor {
        print("PASS \(name) — \(String(format: "%.3f", actual)) ≥ \(String(format: "%.3f", floor))")
    } else {
        failures += 1
        print("FAIL \(name) — \(String(format: "%.3f", actual)) is below \(String(format: "%.3f", floor))")
    }
}

// MARK: - Color math

/// WCAG relative luminance of an sRGB color.
private func luminance(_ color: NSColor) -> Double {
    guard let srgb = color.usingColorSpace(.sRGB) else { return 0 }
    func channel(_ value: CGFloat) -> Double {
        let v = Double(value)
        return v <= 0.03928 ? v / 12.92 : pow((v + 0.055) / 1.055, 2.4)
    }
    return 0.2126 * channel(srgb.redComponent)
        + 0.7152 * channel(srgb.greenComponent)
        + 0.0722 * channel(srgb.blueComponent)
}

/// WCAG contrast ratio, 1.0 (identical) to 21.0 (black on white).
private func contrast(_ a: NSColor, _ b: NSColor) -> Double {
    let la = luminance(a), lb = luminance(b)
    return (max(la, lb) + 0.05) / (min(la, lb) + 0.05)
}

// MARK: - Rendering the real view

private let lightAppearance = NSAppearance(named: .aqua)!
private let darkAppearance = NSAppearance(named: .darkAqua)!

/// The editor as the report saw it: a light appearance, a string literal on the
/// line the caret is on, and everything above it left alone.
private func makeEditor(_ appearance: NSAppearance = lightAppearance) -> SQLTextView {
    // `SQLTextView()` — the convenience init — is the only one that builds the
    // text system. `init(frame:textContainer: nil)` leaves `layoutManager` nil,
    // and the wash draws nothing without one.
    let view = SQLTextView()
    view.frame = NSRect(x: 0, y: 0, width: 400, height: 160)
    view.textContainer?.containerSize = NSSize(width: 400, height: 1_000_000)
    view.appearance = appearance
    view.drawsBackground = true
    view.backgroundColor = NSColor.textBackgroundColor
    view.highlightCurrentLine = true
    view.string = "SELECT *\nFROM t\nWHERE label = 'alone'"
    view.layoutManager?.ensureLayout(for: view.textContainer!)
    // Caret at the end, which is inside the string literal's line.
    view.setSelectedRange(NSRange(location: (view.string as NSString).length, length: 0))
    return view
}

/// The caret line's fragment rect, in the view's own coordinates.
private func caretLineRect(_ view: SQLTextView) -> NSRect {
    let layoutManager = view.layoutManager!
    let glyphIndex = max(0, layoutManager.numberOfGlyphs - 1)
    var rect = layoutManager.lineFragmentRect(forGlyphAt: glyphIndex, effectiveRange: nil)
    rect.origin.y += view.textContainerInset.height
    rect.origin.x += view.textContainerOrigin.x
    return rect
}

/// The color the bitmap holds at a point of the view, with the appearance the
/// view carries applied. `cacheDisplay` runs the real `drawBackground(in:)`.
private func rendered(_ view: SQLTextView) -> NSBitmapImageRep {
    let rep = view.bitmapImageRepForCachingDisplay(in: view.bounds)!
    // The view carries the appearance under test, so `cacheDisplay` resolves
    // every dynamic color the drawing touches against it.
    view.cacheDisplay(in: view.bounds, to: rep)
    return rep
}

/// Resolve a dynamic system color against the light appearance. Read outside
/// a drawing appearance, `labelColor` answers for whatever appearance the
/// process happens to carry, and the numbers below would drift with it.
private func inLight<T>(_ body: () -> T) -> T {
    var result: T!
    lightAppearance.performAsCurrentDrawingAppearance { result = body() }
    return result
}

/// Average color over a rect of the bitmap. Averaging, not one pixel, so an
/// anti-aliased edge or a stray caret pixel cannot decide the result.
private func averageColor(_ rep: NSBitmapImageRep, in rect: NSRect) -> NSColor {
    var r = 0.0, g = 0.0, b = 0.0, n = 0.0
    for y in Int(rect.minY)..<Int(rect.maxY) {
        for x in Int(rect.minX)..<Int(rect.maxX) {
            guard x >= 0, y >= 0, x < rep.pixelsWide, y < rep.pixelsHigh,
                  let colour = rep.colorAt(x: x, y: y)?.usingColorSpace(.sRGB) else { continue }
            r += Double(colour.redComponent)
            g += Double(colour.greenComponent)
            b += Double(colour.blueComponent)
            n += 1
        }
    }
    guard n > 0 else { return .white }
    return NSColor(srgbRed: CGFloat(r / n), green: CGFloat(g / n), blue: CGFloat(b / n), alpha: 1)
}

/// A blank strip of the caret line, past the end of the text, where the only
/// thing painted is the wash itself. The bitmap is y-down; the view is y-down
/// too (`isFlipped` is true for a text view), so no flip is needed.
private func washSample(_ view: SQLTextView) -> NSColor {
    let line = caretLineRect(view)
    let strip = NSRect(x: view.bounds.width - 60, y: line.minY + 2,
                       width: 40, height: max(2, line.height - 4))
    return averageColor(rendered(view), in: strip)
}

/// The same strip with the wash turned OFF: the plain editor background, and
/// the baseline every contrast claim below is measured against.
private func plainSample(_ view: SQLTextView) -> NSColor {
    view.highlightCurrentLine = false
    defer { view.highlightCurrentLine = true }
    let line = caretLineRect(view)
    let strip = NSRect(x: view.bounds.width - 60, y: line.minY + 2,
                       width: 40, height: max(2, line.height - 4))
    return averageColor(rendered(view), in: strip)
}

// MARK: - The band itself

private func testTheWashIsBarelyThere() {
    let view = makeEditor()
    let wash = washSample(view)
    let plain = plainSample(view)

    expect(contrast(wash, plain) > 1.001, "the wash is visible at all — it differs from the background")
    // Measured: the restored wash composites to luminance 0.93 and stands
    // 1.09:1 off the page. The reported band was luminance 0.38 at 2.43:1 —
    // a separation you read as a filled gray box, not as a marked line. Both
    // bounds sit between the two with room, so neither a rounding change nor
    // a small taste adjustment trips them, and the regression does.
    expectAtLeast(luminance(wash), 0.85, "the band stays near the page's own brightness")
    expect(contrast(wash, plain) < 1.2, "and stands off the page as a mark, not as a box")
}

/// `labelColor` inverts with the appearance — black on a light page, white on
/// a dark one — so the same 0.04 that darkens a light line must LIGHTEN a dark
/// one. A fix that only reads right in one appearance is not a fix.
private func testTheWashSurvivesDarkMode() {
    let view = makeEditor(darkAppearance)
    let wash = washSample(view)
    let plain = plainSample(view)

    expect(luminance(plain) < 0.2, "the dark editor really is dark — the sample is on a dark page")
    expect(luminance(wash) > luminance(plain), "the wash LIGHTENS the caret line rather than darkening it")
    expect(contrast(wash, plain) > 1.001, "and is still visible against the page")
    expect(contrast(wash, plain) < 1.3, "while staying a mark, not a box")
}

// MARK: - What the wash costs the text on it

/// Every token color the editor can put on the caret line. A wash that reads
/// well under blue keywords can still swallow green strings, which is exactly
/// what the report was.
private let tokenColors: [(String, NSColor)] = [
    ("keyword blue", SQLTheme.default.keyword),
    ("function teal", SQLTheme.default.function),
    ("string green", SQLTheme.default.string),
    ("number orange", SQLTheme.default.number),
    ("comment gray", SQLTheme.default.comment),
    ("type purple", SQLTheme.default.type),
    ("plain label", .labelColor),
]

private func testTheWashDoesNotEatTheTokenColors() {
    let view = makeEditor()
    let wash = washSample(view)
    let plain = plainSample(view)

    for (name, colour) in tokenColors {
        let (onWash, onPlain) = inLight { (contrast(colour, wash), contrast(colour, plain)) }
        // The wash may cost a token some contrast; it may not cost it much.
        // Measured, every token keeps about 0.92 of the contrast it has off
        // the caret line — a reader who can read a token anywhere in the
        // editor can read it on that line too. The reported band left them at
        // 0.41 (blue, plain text) to 0.49 (green): the green string in the
        // report had lost half its separation from its own background.
        expectAtLeast(onWash / onPlain, 0.85, "\(name) keeps its contrast on the caret line")
    }
}

// MARK: - The mistake that caused it

/// The regression was not a taste call, it was an API misreading, and the same
/// misreading is available to the next person who edits this line. Pin the
/// behaviour so the comment in `SQLTextView` has a test behind it.
private func testWithAlphaComponentReplacesRatherThanScales() {
    let (quaternary, reAlphaed) = inLight {
        (NSColor.quaternaryLabelColor.usingColorSpace(.sRGB)!,
         NSColor.quaternaryLabelColor.withAlphaComponent(0.35).usingColorSpace(.sRGB)!)
    }

    expect(quaternary.alphaComponent < 0.35,
           "quaternaryLabelColor's own alpha is fainter than 0.35")
    expect(abs(Double(reAlphaed.alphaComponent) - 0.35) < 0.001,
           "withAlphaComponent SETS 0.35 — it does not scale the 0.1 already there")
    expect(Double(reAlphaed.alphaComponent) > Double(quaternary.alphaComponent),
           "so asking for '35% of quaternary' made the color three times HEAVIER")
}

// MARK: - Runner

func runTests() {
    print("Current-line wash tests")
    print("=======================")
    testTheWashIsBarelyThere()
    testTheWashSurvivesDarkMode()
    testTheWashDoesNotEatTheTokenColors()
    testWithAlphaComponentReplacesRatherThanScales()
    print("")
    if failures == 0 {
        print("All tests passed")
    } else {
        print("\(failures) test(s) failed")
        exit(1)
    }
}
