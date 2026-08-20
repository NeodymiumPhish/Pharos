// What the hostile-scalar pills actually PAINT.
//
// The sibling suite (HostileTextRenderingTests) measures GEOMETRY — that a pill
// width is reserved and that offsets do not move. It cannot tell whether a
// single pixel was ever drawn into that reserved space, and it cannot catch a
// pill painted somewhere it should not be. This suite renders offscreen into an
// `NSBitmapImageRep` and counts ink, which is how the fold-precedence bug below
// was found: geometry was correct, the paint was not.
//
// This is NOT screen capture. There is no window and no screenshot API in play,
// so it needs neither Screen Recording nor Accessibility permission and runs
// fine in a plain `swiftc` harness.
//
// Two mechanics are mandatory here, and both fail SILENTLY when got wrong:
//
//  1. A bitmap context is y-up and the layout manager draws y-down. Without the
//     `translateBy` + `scaleBy(y: -1)` flip, the text lands outside the bitmap
//     and every ink count is zero — assertions then "pass" against a blank
//     image. The flip also makes bitmap coordinates equal text coordinates,
//     which is why the rects below are written in text coordinates.
//  2. `NSLayoutManager` does NOT own its `NSTextStorage`. A helper that returns
//     only the rep and the layout manager lets the storage deallocate the
//     moment it returns; `numberOfGlyphs` then reads 0, the layout is empty, and
//     `_NSLayoutTreeLineFragmentRectForGlyphAtIndex invalid glyph index 0`
//     appears on stderr while the assertions pass against nothing. `Rendered`
//     below therefore RETAINS the storage, and `expect(glyphs > 0)` in test 1
//     is a tripwire for exactly that failure.
import AppKit

private var failures = 0

private func expect(_ condition: Bool, _ name: String) {
    if condition { print("PASS \(name)") } else { failures += 1; print("FAIL \(name)") }
}

private func expectGreater(_ actual: Int, _ floor: Int, _ name: String) {
    if actual > floor { print("PASS \(name) [\(actual) > \(floor)]") } else {
        failures += 1
        print("FAIL \(name)\n  expected: more than \(floor)\n  actual:   \(actual)")
    }
}

private func expectEqual(_ actual: Int, _ expected: Int, _ name: String) {
    if actual == expected { print("PASS \(name) [\(actual)]") } else {
        failures += 1
        print("FAIL \(name)\n  expected: \(expected)\n  actual:   \(actual)")
    }
}

// MARK: - Offscreen rendering

/// Everything a rendered sample owns. The `storage` property is load-bearing:
/// see mechanic 2 in the file comment.
private final class Rendered {
    let storage: NSTextStorage
    let layoutManager: NSLayoutManager
    let container: NSTextContainer
    let rep: NSBitmapImageRep
    let size: NSSize

    init(storage: NSTextStorage, layoutManager: NSLayoutManager,
         container: NSTextContainer, rep: NSBitmapImageRep, size: NSSize) {
        self.storage = storage
        self.layoutManager = layoutManager
        self.container = container
        self.rep = rep
        self.size = size
    }
}

private let sampleFont: NSFont = .monospacedSystemFont(ofSize: 13, weight: .regular)

/// Lay `text` out and draw it into a fresh white bitmap.
///
/// `folds` are added to the fold state BEFORE layout, so glyph generation sees
/// them. `stock: true` uses a plain `NSLayoutManager` as the control.
private func render(
    _ text: String,
    folds: [(NSRange, String)] = [],
    stock: Bool = false,
    width: CGFloat = 700,
    height: CGFloat = 40
) -> Rendered {
    let storage = NSTextStorage(string: text)
    storage.addAttribute(.font, value: sampleFont, range: NSRange(location: 0, length: (text as NSString).length))

    let layoutManager: NSLayoutManager
    if stock {
        layoutManager = NSLayoutManager()
    } else {
        let foldState = FoldState()
        for (range, placeholder) in folds {
            foldState.add(range: range, placeholder: placeholder)
        }
        layoutManager = FoldingLayoutManager(foldState: foldState)
    }
    storage.addLayoutManager(layoutManager)

    let container = NSTextContainer(size: NSSize(width: width, height: height))
    container.lineFragmentPadding = 0
    layoutManager.addTextContainer(container)
    layoutManager.ensureLayout(for: container)

    guard let rep = NSBitmapImageRep(
        bitmapDataPlanes: nil,
        pixelsWide: Int(width), pixelsHigh: Int(height),
        bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
        colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0
    ) else { fatalError("could not create bitmap") }

    NSGraphicsContext.saveGraphicsState()
    guard let context = NSGraphicsContext(bitmapImageRep: rep) else { fatalError("could not create context") }
    NSGraphicsContext.current = context

    NSColor.white.setFill()
    NSRect(x: 0, y: 0, width: width, height: height).fill()

    // Mechanic 1: flip so the layout manager's y-down drawing lands in the
    // bitmap, and so bitmap coordinates match text coordinates.
    context.cgContext.translateBy(x: 0, y: height)
    context.cgContext.scaleBy(x: 1, y: -1)

    let glyphRange = layoutManager.glyphRange(for: container)
    layoutManager.drawGlyphs(forGlyphRange: glyphRange, at: .zero)

    NSGraphicsContext.restoreGraphicsState()

    return Rendered(storage: storage, layoutManager: layoutManager,
                    container: container, rep: rep, size: NSSize(width: width, height: height))
}

// MARK: - Ink counting

/// Pixels that are not the white background. The pill's translucent grey FILL
/// counts as ink here, so this measures "is anything drawn in this rect".
private func inkCount(_ rendered: Rendered, in rect: NSRect) -> Int {
    var count = 0
    for y in Int(rect.minY)..<Int(rect.maxY) {
        for x in Int(rect.minX)..<Int(rect.maxX) {
            guard x >= 0, y >= 0, x < Int(rendered.size.width), y < Int(rendered.size.height) else { continue }
            guard let colour = rendered.rep.colorAt(x: x, y: y) else { continue }
            if colour.redComponent < 0.99 || colour.greenComponent < 0.99 || colour.blueComponent < 0.99 {
                count += 1
            }
        }
    }
    return count
}

/// Pixels dark enough to be GLYPH ink rather than the pill's light grey fill or
/// its border. This is what separates "a pill with its label in it" from "an
/// empty rounded box".
private func darkInkCount(_ rendered: Rendered, in rect: NSRect) -> Int {
    var count = 0
    for y in Int(rect.minY)..<Int(rect.maxY) {
        for x in Int(rect.minX)..<Int(rect.maxX) {
            guard x >= 0, y >= 0, x < Int(rendered.size.width), y < Int(rendered.size.height) else { continue }
            guard let colour = rendered.rep.colorAt(x: x, y: y) else { continue }
            let luminance = 0.299 * colour.redComponent + 0.587 * colour.greenComponent + 0.114 * colour.blueComponent
            if luminance < 0.6 { count += 1 }
        }
    }
    return count
}

/// Pixels that differ between two renders of the same size.
private func differingPixels(_ a: Rendered, _ b: Rendered, in rect: NSRect) -> Int {
    var count = 0
    for y in Int(rect.minY)..<Int(rect.maxY) {
        for x in Int(rect.minX)..<Int(rect.maxX) {
            guard x >= 0, y >= 0, x < Int(a.size.width), y < Int(a.size.height) else { continue }
            guard let ca = a.rep.colorAt(x: x, y: y), let cb = b.rep.colorAt(x: x, y: y) else { continue }
            if abs(ca.redComponent - cb.redComponent) > 0.01
                || abs(ca.greenComponent - cb.greenComponent) > 0.01
                || abs(ca.blueComponent - cb.blueComponent) > 0.01 {
                count += 1
            }
        }
    }
    return count
}

/// The rect the pill for the character at `charIndex` occupies, in text (and so
/// bitmap) coordinates.
private func pillRect(_ rendered: Rendered, charIndex: Int, label: String) -> NSRect {
    let lm = rendered.layoutManager
    let glyphs = lm.glyphRange(forCharacterRange: NSRange(location: charIndex, length: 1), actualCharacterRange: nil)
    let fragment = lm.lineFragmentRect(forGlyphAt: glyphs.location, effectiveRange: nil)
    let location = lm.location(forGlyphAt: glyphs.location)
    let size = (lm as! FoldingLayoutManager).measurePill(label: label)
    return NSRect(x: fragment.origin.x + location.x,
                  y: fragment.origin.y + (fragment.height - size.height) / 2,
                  width: size.width, height: size.height)
}

func runTests() {

    // MARK: - 1. Drawing happens at all (and the storage is still alive)

    do {
        let plain = render("SELECT 1")
        expectGreater(plain.layoutManager.numberOfGlyphs, 0,
                      "the layout is not empty — the text storage outlived the helper")
        expectGreater(inkCount(plain, in: NSRect(x: 0, y: 0, width: 700, height: 40)), 100,
                      "plain text puts ink on the bitmap, so the flip and the context are right")
    }

    // MARK: - 2. The reserved pill space is actually painted

    do {
        let label = "<U+200B>"
        let hostile = render("AB\u{200B}CD")
        let plain = render("ABXCD")
        let rect = pillRect(hostile, charIndex: 2, label: label)

        let pillInk = inkCount(hostile, in: rect)
        let plainInk = inkCount(plain, in: rect)
        // Reference measurement: ~1142px for the pill (its fill covers the whole
        // rect) versus ~55px for the glyph strokes of ordinary text in the same
        // rect. The pill must be at least several times the plain-text ink.
        expectGreater(pillInk, plainInk * 4,
                      "the reserved pill rect is painted, not left blank [plain text there: \(plainInk)px]")
    }

    // MARK: - 3. The pill carries its LABEL, not just an empty box

    do {
        let label = "<U+202E>"
        let hostile = render("AB\u{202E}CD")
        let rect = pillRect(hostile, charIndex: 2, label: label)
        let pillDarkInk = darkInkCount(hostile, in: rect)

        // Reference: the same label drawn as ordinary text. The pill's font is
        // 11pt to the sample's 13pt, so the pill's glyph ink is expected to be
        // somewhat LESS than this reference — but an empty box would score ~0.
        let reference = render(label)
        let referenceDarkInk = darkInkCount(reference, in: NSRect(x: 0, y: 0, width: 700, height: 40))

        expectGreater(pillDarkInk, referenceDarkInk / 3,
                      "the pill's label is drawn inside it [bare-string reference: \(referenceDarkInk)px]")
        expectGreater(pillDarkInk, 60,
                      "the pill's label ink is substantial in absolute terms, not a stray border pixel")
    }

    // MARK: - 4. Ordinary text left of a pill is pixel-identical to stock

    do {
        let hostile = render("SELECT ab\u{200B}cd")
        let stock = render("SELECT ab\u{200B}cd", stock: true)
        // Everything before the hostile scalar is laid out and painted by the
        // same code in both, so it must match exactly.
        let leftOfPill = NSRect(x: 0, y: 0, width: 60, height: 40)
        let compared = Int(leftOfPill.width) * Int(leftOfPill.height)
        expectEqual(differingPixels(hostile, stock, in: leftOfPill), 0,
                    "text left of the pill is byte-identical to the stock rendering [\(compared)px compared]")
    }

    // MARK: - 5. REGRESSION (fold precedence): no pill inside a fold

    do {
        // Same text, same length, same fold — the ONLY difference is whether the
        // character at index 10 is hostile. Index 10 sits inside the fold
        // 7..<19 and is not its anchor, so under the documented precedence rule
        // it is SUPPRESSED and must paint exactly like an ordinary character
        // would. Any difference is a pill that should not exist.
        //
        // This is the assertion that catches the real bug: because
        // `glyphRange(forCharacterRange:)` maps a suppressed glyph back to the
        // fold's ANCHOR glyph, a hostile scalar in a fold used to paint its pill
        // at the anchor's x — ink stacked over the fold's own pill, with every
        // hostile scalar in the fold landing on the same spot. Verified by
        // reverting the fix: 1,114 differing pixels before, 0 after.
        let fold = (NSRange(location: 7, length: 12), "…")
        let withHostile = render("SELECT (aa\u{200B}bbbbbbbb) FROM t", folds: [fold])
        let withOrdinary = render("SELECT (aaXbbbbbbbb) FROM t", folds: [fold])

        let whole = NSRect(x: 0, y: 0, width: 700, height: 40)
        expectEqual(differingPixels(withHostile, withOrdinary, in: whole), 0,
                    "a hostile scalar hidden in a fold paints no pill — identical to an ordinary character there")

        // And the fold itself still renders: its own pill is present.
        expectGreater(inkCount(withHostile, in: whole), 100,
                      "the folded line is still drawn (the comparison above is not two blank images)")
    }

    // MARK: - 6. A fold ANCHORED on a hostile scalar reserves no dead space

    do {
        // The precedence rule says a fold's anchor is `.unchanged` — the fold's
        // own pill speaks for it. The delegate hooks must agree, or the anchor
        // reserves a hostile pill width that nothing ever paints. Verified by
        // reverting the fix: the anchor reserved 68.4pt — a full pill width — of
        // dead space before, and 0.0pt after.
        //
        // Measure the ANCHOR'S OWN ADVANCE, not a delta against a different
        // string: the characters between the anchor and the next visible glyph
        // are all suppressed and so contribute 0, which makes
        // x(afterFold) - x(anchor) exactly what the anchor reserved. Comparing
        // two different texts instead would fold in the anchor character's own
        // natural width (an 'X' is 8.04pt, U+200B is 0pt) and measure the wrong
        // thing.
        let fold = (NSRange(location: 2, length: 6), "…")
        let anchoredOnHostile = render("AB\u{200B}CDEFGH ok", folds: [fold])
        let lm = anchoredOnHostile.layoutManager
        func glyphX(_ charIndex: Int) -> CGFloat {
            let glyphs = lm.glyphRange(forCharacterRange: NSRange(location: charIndex, length: 1),
                                       actualCharacterRange: nil)
            return lm.location(forGlyphAt: glyphs.location).x
        }
        let anchorAdvance = glyphX(8) - glyphX(2)
        let hostilePillWidth = (lm as! FoldingLayoutManager).measurePill(label: "<U+200B>").width

        expect(anchorAdvance < 1.0,
               "a fold anchored on a hostile scalar reserves no width [advance \(anchorAdvance)pt]")
        expect(anchorAdvance < hostilePillWidth / 2,
               "and specifically not a pill's worth of dead space [pill would be \(hostilePillWidth)pt]")
    }

    // MARK: - 7. A CRLF document gets no pills

    do {
        // A Windows .sql file is ordinary data. CR is the document's own line
        // ending here, so it must be as invisible as LF — otherwise every single
        // line of the file ends in a `<U+000D>` pill.
        let crlf = render("SELECT a\r\n  FROM t\r\n", height: 60)
        let lf = render("SELECT a\n  FROM t\n", height: 60)
        let whole = NSRect(x: 0, y: 0, width: 700, height: 60)
        expectEqual(differingPixels(crlf, lf, in: whole), 0,
                    "a CRLF document renders exactly like the LF version — no pill per line")

        let lm = crlf.layoutManager as! FoldingLayoutManager
        expect(lm.disclosedPillLabel(forCharacterAt: 8) == nil,
               "the CR itself gets no pill")
    }

    if failures == 0 { print("\nAll hostile-text pixel tests passed.") } else {
        print("\n\(failures) failure(s).")
        exit(1)
    }
}
