import AppKit

/// What one glyph's property becomes, when folding and hostile-scalar
/// disclosure both have a claim on it.
enum GlyphDisposition: Equatable {
    /// Left exactly as the typesetter produced it.
    case unchanged
    /// Hidden: a non-anchor character inside a folded range.
    case suppressed
    /// Forced to `.controlCharacter` so the control-glyph delegate hooks fire
    /// and can give it the width of its pill.
    case disclosedControl
}

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
        // Its own delegate: the control-glyph hooks below are delegate methods,
        // not overrides, and they are the only way to give an invisible scalar a
        // real advance width. Wiring it here means no construction site can
        // forget it. `delegate` is weak, so this is not a cycle.
        self.delegate = self
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError() }

    /// Folding wins over disclosure. A character hidden inside a fold is
    /// invisible already, so a pill there would be a pill nobody can see, and
    /// the fold's anchor is spoken for — it carries the fold's own pill.
    /// Everything outside every fold is free to be disclosed.
    static func glyphDisposition(charIndex: Int, foldedRanges: [NSRange], isHostile: Bool) -> GlyphDisposition {
        for fold in foldedRanges where charIndex >= fold.location && charIndex < NSMaxRange(fold) {
            return charIndex == fold.location ? .unchanged : .suppressed
        }
        return isHostile ? .disclosedControl : .unchanged
    }

    // MARK: - Hostile Scalar Disclosure

    /// Whether the UTF-16 unit at `charIndex` is a hostile invisible scalar.
    ///
    /// Reads the backing store directly (`character(at:)` is O(1) on
    /// `NSMutableString`) so no scan result has to be cached and invalidated:
    /// `setGlyphs` already runs whenever glyphs are generated. Every scalar
    /// `DisplayEscape.isHostileInFlowingText` names is in the BMP, so one
    /// UTF-16 unit is always the whole scalar and a surrogate can never be
    /// hostile. `Unicode.Scalar(UInt32:)` returns nil for a lone surrogate —
    /// half of any emoji — so the nil branch answers `false` and must never
    /// force-unwrap. If a non-BMP scalar is ever added to
    /// `DisplayEscape.mustEscape`, this walk must become a scalar walk or it
    /// will silently stop finding it (that invariant is stated there too).
    func isHostileCharacter(at charIndex: Int) -> Bool {
        guard let backing = textStorage?.mutableString, charIndex >= 0, charIndex < backing.length else { return false }
        guard let scalar = Unicode.Scalar(UInt32(backing.character(at: charIndex))) else { return false }
        return DisplayEscape.isHostileInFlowingText(scalar)
    }

    /// The pill label for the scalar at `charIndex`, or nil if it is not
    /// hostile. Separate from `isHostileCharacter` so the hot path — every
    /// glyph of every layout pass — never builds a string.
    func hostilePillLabel(forCharacterAt charIndex: Int) -> String? {
        guard let backing = textStorage?.mutableString, charIndex >= 0, charIndex < backing.length else { return nil }
        guard let scalar = Unicode.Scalar(UInt32(backing.character(at: charIndex))),
              DisplayEscape.isHostileInFlowingText(scalar) else { return nil }
        return String(format: "<U+%04X>", scalar.value)
    }

    // MARK: - Glyph Suppression

    override func setGlyphs(
        _ glyphs: UnsafePointer<CGGlyph>,
        properties props: UnsafePointer<NSLayoutManager.GlyphProperty>,
        characterIndexes charIndexes: UnsafePointer<Int>,
        font aFont: NSFont,
        forGlyphRange glyphRange: NSRange
    ) {
        let foldedRanges = foldState.foldedCharacterRanges
        let count = glyphRange.length

        // First pass decides whether anything changes at all. The common case —
        // no folds, no hostile scalar — must not allocate a properties array on
        // every layout pass.
        var dispositions = [GlyphDisposition](repeating: .unchanged, count: count)
        var needsWork = false
        for i in 0..<count {
            let disposition = Self.glyphDisposition(
                charIndex: charIndexes[i],
                foldedRanges: foldedRanges,
                isHostile: isHostileCharacter(at: charIndexes[i])
            )
            dispositions[i] = disposition
            if disposition != .unchanged { needsWork = true }
        }

        guard needsWork else {
            super.setGlyphs(glyphs, properties: props, characterIndexes: charIndexes, font: aFont, forGlyphRange: glyphRange)
            return
        }

        var modifiedProps = Array(UnsafeBufferPointer(start: props, count: count))
        for i in 0..<count {
            switch dispositions[i] {
            case .unchanged: continue
            case .suppressed: modifiedProps[i] = .null
            case .disclosedControl: modifiedProps[i] = .controlCharacter
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

        let charRange = characterRange(forGlyphRange: glyphsToShow, actualGlyphRange: nil)

        // Hostile-scalar pills, drawn into the width the control-glyph
        // bounding box reserved for each one.
        if let backing = textStorage?.mutableString {
            let end = min(NSMaxRange(charRange), backing.length)
            var charIndex = max(charRange.location, 0)
            while charIndex < end {
                if let label = hostilePillLabel(forCharacterAt: charIndex) {
                    let glyphs = glyphRange(forCharacterRange: NSRange(location: charIndex, length: 1),
                                            actualCharacterRange: nil)
                    if glyphs.location != NSNotFound {
                        let fragment = lineFragmentRect(forGlyphAt: glyphs.location, effectiveRange: nil)
                        let glyphLocation = location(forGlyphAt: glyphs.location)
                        let size = measurePill(label: label)
                        let rect = NSRect(
                            x: origin.x + fragment.origin.x + glyphLocation.x,
                            y: origin.y + fragment.origin.y + (fragment.height - size.height) / 2,
                            width: size.width,
                            height: size.height
                        )
                        drawPill(label: label, in: rect)
                    }
                }
                charIndex += 1
            }
        }

        // Then draw fold pills on top of anchor glyphs
        guard !foldState.entries.isEmpty, textContainers.first != nil else { return }

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

// MARK: - Control-Glyph Hooks

/// These two are the mechanism. A bidi override or a zero-width space is a
/// FORMAT character, so AppKit never treats it as a control glyph on its own
/// and never asks about its size — it lays it out with no advance at all, which
/// is exactly why it is invisible. Forcing the glyph property to
/// `.controlCharacter` in `setGlyphs` above makes AppKit ask, and these answer:
/// treat it as whitespace, and make that whitespace as wide as the pill.
///
/// Measured: only the returned rect's WIDTH is honoured; its origin is ignored,
/// and the line's used width grows by that width on its own — so no
/// `setLineFragmentRect` adjustment is needed or wanted here.
extension FoldingLayoutManager: NSLayoutManagerDelegate {

    func layoutManager(
        _ layoutManager: NSLayoutManager,
        shouldUse action: NSLayoutManager.ControlCharacterAction,
        forControlCharacterAt charIndex: Int
    ) -> NSLayoutManager.ControlCharacterAction {
        isHostileCharacter(at: charIndex) ? .whitespace : action
    }

    func layoutManager(
        _ layoutManager: NSLayoutManager,
        boundingBoxForControlGlyphAt glyphIndex: Int,
        for textContainer: NSTextContainer,
        proposedLineFragment proposedRect: NSRect,
        glyphPosition: NSPoint,
        characterIndex charIndex: Int
    ) -> NSRect {
        guard let label = hostilePillLabel(forCharacterAt: charIndex) else {
            return NSRect(origin: glyphPosition, size: .zero)
        }
        return NSRect(x: glyphPosition.x, y: 0,
                      width: measurePill(label: label).width,
                      height: proposedRect.height)
    }
}
