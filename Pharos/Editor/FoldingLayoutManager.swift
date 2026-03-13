import AppKit

/// Custom NSLayoutManager that implements code folding at the display layer.
/// Suppresses glyphs for folded character ranges and draws placeholder pills inline.
/// Text storage is never modified — folding is purely a rendering concern.
final class FoldingLayoutManager: NSLayoutManager {

    /// The fold state that drives glyph suppression and pill drawing.
    let foldState: FoldState

    private let pillHPad: CGFloat = 6
    private let pillVPad: CGFloat = 2

    init(foldState: FoldState) {
        self.foldState = foldState
        super.init()
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError() }

    // MARK: - Glyph Suppression

    override func setGlyphs(
        _ glyphs: UnsafePointer<CGGlyph>,
        properties props: UnsafePointer<NSLayoutManager.GlyphProperty>,
        characterIndexes charIndexes: UnsafePointer<Int>,
        font aFont: NSFont,
        forGlyphRange glyphRange: NSRange
    ) {
        let foldedRanges = foldState.foldedCharacterRanges
        guard !foldedRanges.isEmpty else {
            super.setGlyphs(glyphs, properties: props, characterIndexes: charIndexes, font: aFont, forGlyphRange: glyphRange)
            return
        }

        // Copy properties so we can modify them
        let count = glyphRange.length
        var modifiedProps = Array(UnsafeBufferPointer(start: props, count: count))

        for i in 0..<count {
            let charIdx = charIndexes[i]
            for fold in foldedRanges {
                if charIdx >= fold.location && charIdx < NSMaxRange(fold) {
                    if charIdx == fold.location {
                        // First character of fold: keep visible as anchor for pill drawing.
                        // Leave property as-is (.regular) — we'll override its drawing.
                        break
                    } else {
                        // All other characters in fold: suppress
                        modifiedProps[i] = .null
                        break
                    }
                }
            }
        }

        modifiedProps.withUnsafeBufferPointer { buffer in
            super.setGlyphs(glyphs, properties: buffer.baseAddress!, characterIndexes: charIndexes, font: aFont, forGlyphRange: glyphRange)
        }
    }

    // MARK: - Pill Drawing

    override func drawGlyphs(forGlyphRange glyphsToShow: NSRange, at origin: NSPoint) {
        // Draw all normal glyphs first
        super.drawGlyphs(forGlyphRange: glyphsToShow, at: origin)

        // Then draw fold pills on top of anchor glyphs
        guard !foldState.entries.isEmpty else { return }
        guard let textContainer = textContainers.first else { return }

        let charRange = characterRange(forGlyphRange: glyphsToShow, actualGlyphRange: nil)

        for entry in foldState.entries {
            let foldStart = entry.range.location
            // Only draw if the fold's anchor character is in the drawn range
            guard foldStart >= charRange.location && foldStart < NSMaxRange(charRange) else { continue }

            // Get the glyph index for the anchor character
            let anchorGlyphRange = glyphRange(forCharacterRange: NSRange(location: foldStart, length: 1), actualCharacterRange: nil)
            guard anchorGlyphRange.location != NSNotFound else { continue }

            // Get the position of the anchor glyph
            let lineFragRect = lineFragmentRect(forGlyphAt: anchorGlyphRange.location, effectiveRange: nil)
            let glyphLocation = location(forGlyphAt: anchorGlyphRange.location)

            let pillSize = measurePill(label: entry.placeholder)
            let pillX = origin.x + lineFragRect.origin.x + glyphLocation.x
            let pillY = origin.y + lineFragRect.origin.y + (lineFragRect.height - pillSize.height) / 2

            let pillRect = NSRect(x: pillX, y: pillY, width: pillSize.width, height: pillSize.height)
            drawPill(label: entry.placeholder, in: pillRect)
        }
    }

    // MARK: - Layout Adjustments

    /// After layout, adjust the position of text following fold anchors to account for pill width.
    override func setLineFragmentRect(
        _ fragmentRect: NSRect,
        forGlyphRange glyphRange: NSRange,
        usedRect: NSRect
    ) {
        // Check if any fold anchor is in this line fragment
        let charRange = characterRange(forGlyphRange: glyphRange, actualGlyphRange: nil)
        var adjustedUsedRect = usedRect

        for entry in foldState.entries {
            let foldStart = entry.range.location
            if foldStart >= charRange.location && foldStart < NSMaxRange(charRange) {
                // Add pill width to the used rect so text after the fold accounts for it
                let pillSize = measurePill(label: entry.placeholder)
                // The fold hides many characters but only the anchor glyph remains.
                // We need the pill width minus the anchor glyph's natural width.
                adjustedUsedRect.size.width = max(adjustedUsedRect.size.width, usedRect.size.width + pillSize.width)
            }
        }

        super.setLineFragmentRect(fragmentRect, forGlyphRange: glyphRange, usedRect: adjustedUsedRect)
    }

    // MARK: - Pill Rendering

    private let pillFont: NSFont = .monospacedSystemFont(ofSize: 11, weight: .medium)

    func measurePill(label: String) -> NSSize {
        let attrs: [NSAttributedString.Key: Any] = [.font: pillFont]
        let textSize = (label as NSString).size(withAttributes: attrs)
        return NSSize(width: textSize.width + pillHPad * 2 + 2, height: textSize.height + pillVPad * 2)
    }

    private func drawPill(label: String, in rect: NSRect) {
        let pillRect = rect.insetBy(dx: 1, dy: 1)

        // Background
        NSColor.systemGray.withAlphaComponent(0.18).setFill()
        let path = NSBezierPath(roundedRect: pillRect, xRadius: 4, yRadius: 4)
        path.fill()

        // Border
        NSColor.separatorColor.withAlphaComponent(0.5).setStroke()
        path.lineWidth = 0.5
        path.stroke()

        // Text
        let attrs: [NSAttributedString.Key: Any] = [
            .font: pillFont,
            .foregroundColor: NSColor.secondaryLabelColor,
        ]
        let textSize = (label as NSString).size(withAttributes: attrs)
        let textX = pillRect.origin.x + (pillRect.width - textSize.width) / 2
        let textY = pillRect.origin.y + (pillRect.height - textSize.height) / 2
        (label as NSString).draw(at: NSPoint(x: textX, y: textY), withAttributes: attrs)
    }

    // MARK: - Hit Testing

    /// Returns the fold entry if the given point (in text container coordinates) hits a pill.
    func foldEntry(at point: NSPoint, in textContainer: NSTextContainer) -> FoldEntry? {
        guard !foldState.entries.isEmpty else { return nil }

        let charIndex = characterIndex(for: point, in: textContainer, fractionOfDistanceBetweenInsertionPoints: nil)

        // Check if the character is inside any fold range
        if let entry = foldState.entry(containing: charIndex) {
            return entry
        }

        // Also check by visual bounds — the pill may extend beyond the anchor character
        for entry in foldState.entries {
            let foldStart = entry.range.location
            let anchorGlyphRange = glyphRange(forCharacterRange: NSRange(location: foldStart, length: 1), actualCharacterRange: nil)
            guard anchorGlyphRange.location != NSNotFound else { continue }

            let lineFragRect = lineFragmentRect(forGlyphAt: anchorGlyphRange.location, effectiveRange: nil)
            let glyphLocation = location(forGlyphAt: anchorGlyphRange.location)

            let pillSize = measurePill(label: entry.placeholder)
            let pillX = lineFragRect.origin.x + glyphLocation.x
            let pillY = lineFragRect.origin.y + (lineFragRect.height - pillSize.height) / 2

            let pillRect = NSRect(x: pillX, y: pillY, width: pillSize.width, height: pillSize.height)
            if pillRect.contains(point) {
                return entry
            }
        }

        return nil
    }

    /// Returns the bounding rect of a fold's pill in text container coordinates.
    func pillRect(for entry: FoldEntry, in textContainer: NSTextContainer) -> NSRect? {
        let foldStart = entry.range.location
        let anchorGlyphRange = glyphRange(forCharacterRange: NSRange(location: foldStart, length: 1), actualCharacterRange: nil)
        guard anchorGlyphRange.location != NSNotFound else { return nil }

        let lineFragRect = lineFragmentRect(forGlyphAt: anchorGlyphRange.location, effectiveRange: nil)
        let glyphLocation = location(forGlyphAt: anchorGlyphRange.location)

        let pillSize = measurePill(label: entry.placeholder)
        let pillX = lineFragRect.origin.x + glyphLocation.x
        let pillY = lineFragRect.origin.y + (lineFragRect.height - pillSize.height) / 2

        return NSRect(x: pillX, y: pillY, width: pillSize.width, height: pillSize.height)
    }
}
