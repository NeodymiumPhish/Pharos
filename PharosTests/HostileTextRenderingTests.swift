// Standalone tests for hostile-scalar disclosure in FoldingLayoutManager.
//
// These exercise REAL AppKit layout inside a real (never-shown) NSTextView,
// because the whole mechanism is an AppKit behaviour: forcing a glyph to
// `.controlCharacter` is what makes the control-glyph delegate hooks fire for
// a format character, and those hooks are what give an invisible scalar the
// width of its pill. A pure test could not observe any of that.
import AppKit

private var failures = 0

private func expect(_ condition: Bool, _ name: String) {
    if condition { print("PASS \(name)") } else { failures += 1; print("FAIL \(name)") }
}

private func expectClose(_ actual: CGFloat, _ expected: CGFloat, _ name: String, tolerance: CGFloat = 0.5) {
    if abs(actual - expected) <= tolerance { print("PASS \(name)") } else {
        failures += 1
        print("FAIL \(name)\n  expected: \(expected) ± \(tolerance)\n  actual:   \(actual)")
    }
}

/// A real text view driven by the disclosing layout manager.
private func makeDisclosingView(_ text: String) -> (NSTextView, FoldingLayoutManager) {
    let storage = NSTextStorage()
    let layoutManager = FoldingLayoutManager(foldState: FoldState())
    storage.addLayoutManager(layoutManager)
    let container = NSTextContainer(size: NSSize(width: 10_000, height: 10_000))
    layoutManager.addTextContainer(container)
    let view = NSTextView(frame: NSRect(x: 0, y: 0, width: 800, height: 300), textContainer: container)
    view.font = .monospacedSystemFont(ofSize: 13, weight: .regular)
    view.string = text
    layoutManager.ensureLayout(for: container)
    return (view, layoutManager)
}

/// The same text under a STOCK layout manager — the control for "did we change
/// anything we shouldn't have?"
private func makeStockView(_ text: String) -> (NSTextView, NSLayoutManager) {
    let storage = NSTextStorage()
    let layoutManager = NSLayoutManager()
    storage.addLayoutManager(layoutManager)
    let container = NSTextContainer(size: NSSize(width: 10_000, height: 10_000))
    layoutManager.addTextContainer(container)
    let view = NSTextView(frame: NSRect(x: 0, y: 0, width: 800, height: 300), textContainer: container)
    view.font = .monospacedSystemFont(ofSize: 13, weight: .regular)
    view.string = text
    layoutManager.ensureLayout(for: container)
    return (view, layoutManager)
}

/// The x position of the glyph for one UTF-16 index.
private func glyphX(_ charIndex: Int, _ layoutManager: NSLayoutManager) -> CGFloat {
    let range = layoutManager.glyphRange(forCharacterRange: NSRange(location: charIndex, length: 1),
                                         actualCharacterRange: nil)
    guard range.location != NSNotFound else { return -1 }
    return layoutManager.location(forGlyphAt: range.location).x
}

func runTests() {

    // MARK: - 1. An invisible scalar occupies exactly its pill's width

    do {
        let (_, plain) = makeDisclosingView("ABCD")
        let (_, hostile) = makeDisclosingView("AB\u{200B}CD")
        let pillWidth = hostile.measurePill(label: "<U+200B>").width
        // 'C' is at index 2 without the scalar, index 3 with it.
        expectClose(glyphX(3, hostile) - glyphX(2, plain), pillWidth,
                    "a zero-width space is widened to exactly its pill's width")
        expect(glyphX(3, hostile) > glyphX(2, plain),
               "the following character is pushed right, so the pill cannot overlap it")
    }

    // MARK: - 2. Character offsets never move

    do {
        let text = "AB\u{200B}CD"
        let (_, hostile) = makeDisclosingView(text)
        expect(hostile.numberOfGlyphs == (text as NSString).length,
               "one glyph per UTF-16 unit — selection and error offsets stay valid")
        let range = hostile.glyphRange(forCharacterRange: NSRange(location: 2, length: 1),
                                       actualCharacterRange: nil)
        expect(range.location != NSNotFound && range.length == 1,
               "the hostile scalar still maps to exactly one glyph")
    }

    // MARK: - 3. Ordinary text is laid out exactly as a stock manager lays it out

    do {
        for sample in ["SELECT 1", "SELECT *\n  FROM t", "A\tB", "  indented"] {
            let (_, disclosing) = makeDisclosingView(sample)
            let (_, stock) = makeStockView(sample)
            let last = (sample as NSString).length - 1
            expectClose(glyphX(last, disclosing), glyphX(last, stock),
                        "ordinary text is untouched: \(sample.debugDescription)")
        }
    }

    // MARK: - 4. Newlines, tabs and indentation are the text's own formatting

    do {
        let (_, withTab) = makeDisclosingView("A\tB")
        let (_, stockTab) = makeStockView("A\tB")
        expectClose(glyphX(2, withTab), glyphX(2, stockTab),
                    "a tab keeps its own advance — no pill")
    }

    // MARK: - 5. The pill label names the scalar

    do {
        let (_, hostile) = makeDisclosingView("A\u{202E}B")
        expect(hostile.hostilePillLabel(forCharacterAt: 1) == "<U+202E>",
               "the pill names the scalar it discloses")
        expect(hostile.hostilePillLabel(forCharacterAt: 0) == nil,
               "an ordinary character has no pill")
    }

    // MARK: - 6. The measured limitation: the override is disclosed, NOT neutralised

    do {
        // "AB<RLO>CD": the bidi algorithm still reverses CD, so 'D' renders to
        // the LEFT of 'C'. The pill tells the reader an override is present; it
        // cannot restore reading order, because that would mean changing the
        // characters. Documented in the spec; pinned here so a later change
        // cannot quietly claim otherwise.
        let (_, rlo) = makeDisclosingView("AB\u{202E}CD")
        expect(glyphX(4, rlo) < glyphX(3, rlo),
               "the override is still obeyed — the pill discloses it, it does not undo it")
    }

    // MARK: - 7. Fold precedence (pure rule)

    do {
        let fold = NSRange(location: 0, length: 6)
        expect(FoldingLayoutManager.glyphDisposition(charIndex: 0, foldedRanges: [fold], isHostile: true) == .unchanged,
               "a fold's anchor keeps its own pill, even when the anchor is hostile")
        expect(FoldingLayoutManager.glyphDisposition(charIndex: 3, foldedRanges: [fold], isHostile: true) == .suppressed,
               "a hostile scalar hidden inside a fold is suppressed, not pilled")
        expect(FoldingLayoutManager.glyphDisposition(charIndex: 9, foldedRanges: [fold], isHostile: true) == .disclosedControl,
               "a hostile scalar outside every fold is disclosed")
        expect(FoldingLayoutManager.glyphDisposition(charIndex: 9, foldedRanges: [fold], isHostile: false) == .unchanged,
               "an ordinary scalar outside every fold is left alone")
        expect(FoldingLayoutManager.glyphDisposition(charIndex: 2, foldedRanges: [], isHostile: true) == .disclosedControl,
               "with no folds at all, a hostile scalar is disclosed")
    }

    if failures == 0 { print("\nAll hostile-text rendering tests passed.") } else {
        print("\n\(failures) failure(s).")
        exit(1)
    }
}
