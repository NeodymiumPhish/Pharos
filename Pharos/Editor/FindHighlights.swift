import AppKit

/// The find matches one card's text shows, and the one the find bar is on.
/// The card's editor (`SQLTextView`) and its preview (`CardPreviewView`) draw
/// them under the glyphs in their own draw pass, so a highlight is part of the
/// text and moves with it when the stack scrolls.
struct FindHighlights: Equatable {
    /// In text order.
    var ranges: [NSRange] = []
    /// The current match; one of `ranges`.
    var current: NSRange?

    var isEmpty: Bool { ranges.isEmpty }

    /// Fill each match that touches `visible` (characters), at `origin` (the
    /// text container's origin in the drawing view). The current match is
    /// solid; the others are a wash of the same system find colour.
    func draw(in visible: NSRange, layoutManager: NSLayoutManager,
              textContainer: NSTextContainer, origin: NSPoint) {
        let others = NSColor.findHighlightColor.withAlphaComponent(0.35)
        let none = NSRange(location: NSNotFound, length: 0)
        for range in ranges {
            if range.location > NSMaxRange(visible) { break }
            guard NSMaxRange(range) >= visible.location else { continue }
            (range == current ? NSColor.findHighlightColor : others).setFill()
            let glyphs = layoutManager.glyphRange(forCharacterRange: range, actualCharacterRange: nil)
            layoutManager.enumerateEnclosingRects(forGlyphRange: glyphs, withinSelectedGlyphRange: none,
                                                  in: textContainer) { rect, _ in
                let box = rect.offsetBy(dx: origin.x, dy: origin.y).insetBy(dx: -1, dy: 0)
                NSBezierPath(roundedRect: box, xRadius: 3, yRadius: 3).fill()
            }
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
}
