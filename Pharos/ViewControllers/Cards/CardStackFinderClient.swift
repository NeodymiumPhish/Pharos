import AppKit

/// Find across every card of a tab with one find bar (Edit ▸ Find, ⌘F / ⌘G).
///
/// `NSTextFinder` searches one string through this client: the cards' SQL in
/// stack order (`CardFindIndex`). Each card's text view does the drawing and
/// the geometry for its own part — `NSTextView` is itself an
/// `NSTextFinderClient`, so the client hands each range to the view that owns
/// it. A card whose editor is a preview is given a live editor (without the
/// keyboard focus) when a match lands in it.
@MainActor
// `@preconcurrency`: the SDK does not mark NSTextFinderClient main-actor, but
// NSTextFinder calls its client only on the main thread; Swift checks that at
// run time (SE-0423) instead of every member being `nonisolated`.
final class CardStackFinderClient: NSObject, @preconcurrency NSTextFinderClient {
    weak var stack: CardStackVC?
    private var cachedIndex: CardFindIndex?

    init(stack: CardStackVC) {
        self.stack = stack
    }

    /// The cards' text changed: rebuild the string at the next read.
    func invalidate() { cachedIndex = nil }

    private var index: CardFindIndex {
        if let cachedIndex { return cachedIndex }
        let built = CardFindIndex(cards: stack?.findableCards() ?? [])
        cachedIndex = built
        return built
    }

    // MARK: - The string

    var string: String { index.text }

    func stringLength() -> Int { index.length }

    // NSObject already declares `isSelectable` (an AppKit category).
    override var isSelectable: Bool { true }
    var allowsMultipleSelection: Bool { false }
    var isEditable: Bool { false }

    // MARK: - Views and geometry

    func contentView(at index: Int, effectiveCharacterRange outRange: NSRangePointer) -> NSView {
        guard let segment = self.index.segment(at: index), let stack,
              let editor = stack.editor(for: segment.cardId) else {
            outRange.pointee = NSRange(location: 0, length: self.index.length)
            return stack?.view ?? NSView()
        }
        outRange.pointee = segment.range
        return editor.textView
    }

    func rects(forCharacterRange range: NSRange) -> [NSValue]? {
        guard let (cardId, local) = index.local(range),
              let textView = stack?.editor(for: cardId)?.textView else { return nil }
        return textView.findRects(forCharacterRange: local)
    }

    var visibleCharacterRanges: [NSValue] {
        guard let stack else { return [] }
        return stack.visibleCardIds().compactMap { id in
            index.segments.first { $0.cardId == id }.map { NSValue(range: $0.range) }
        }
    }

    func drawCharacters(in range: NSRange, forContentView view: NSView) {
        guard let (_, local) = index.local(range), let textView = view as? NSTextView else { return }
        textView.drawFoundCharacters(in: local)
    }

    func scrollRangeToVisible(_ range: NSRange) {
        guard let (cardId, local) = index.local(range) else { return }
        stack?.revealMatch(cardId: cardId, range: local)
    }

    // MARK: - Selection

    var firstSelectedRange: NSRange {
        guard let stack, let (cardId, local) = stack.focusedSelection(),
              let global = index.global(cardId: cardId, local) else { return NSRange(location: 0, length: 0) }
        return global
    }

    var selectedRanges: [NSValue] {
        get { [NSValue(range: firstSelectedRange)] }
        set {
            guard let range = newValue.first?.rangeValue, let (cardId, local) = index.local(range) else { return }
            stack?.selectMatch(cardId: cardId, range: local)
        }
    }
}

extension NSTextView {
    /// The rectangles of a character range, in this view's coordinates
    /// (TextKit 1: the card editors use `FoldingLayoutManager`).
    func findRects(forCharacterRange range: NSRange) -> [NSValue] {
        guard let layoutManager, let textContainer else { return [] }
        let glyphs = layoutManager.glyphRange(forCharacterRange: range, actualCharacterRange: nil)
        let origin = textContainerOrigin
        var rects: [NSValue] = []
        layoutManager.enumerateEnclosingRects(
            forGlyphRange: glyphs, withinSelectedGlyphRange: NSRange(location: NSNotFound, length: 0),
            in: textContainer) { rect, _ in
                rects.append(NSValue(rect: rect.offsetBy(dx: origin.x, dy: origin.y)))
            }
        return rects
    }

    /// Draw a character range's glyphs, for the find indicator.
    func drawFoundCharacters(in range: NSRange) {
        guard let layoutManager else { return }
        let glyphs = layoutManager.glyphRange(forCharacterRange: range, actualCharacterRange: nil)
        layoutManager.drawGlyphs(forGlyphRange: glyphs, at: textContainerOrigin)
    }
}
