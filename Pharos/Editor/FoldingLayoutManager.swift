import AppKit

/// Custom NSLayoutManager that implements code folding at the display layer.
/// Suppresses glyphs for folded character ranges and draws placeholder pills inline.
/// Text storage is never modified — folding is purely a rendering concern.
final class FoldingLayoutManager: NSLayoutManager {

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

    /// Whether the UTF-16 unit at `charIndex` of an ALREADY-FETCHED backing
    /// store is a hostile invisible scalar.
    ///
    /// Every caller in a loop must use this form and hoist the fetch, because
    /// `NSTextStorage.mutableString` is not a cached accessor: it builds a NEW
    /// proxy object on every call (two consecutive calls are not identical
    /// objects). Calling it once per glyph meant one proxy allocation per
    /// UTF-16 unit of the document and made this class ~39% slower than a stock
    /// layout manager; hoisting cut the scan from 68.6ns to 23.4ns per unit.
    ///
    /// `character(at:)` is O(1) here, but that was never the cost — it is
    /// 16.9ns of the 23.4ns, all of it Objective-C dispatch through the proxy.
    /// The predicate itself is ~3ns.
    ///
    /// Every scalar `DisplayEscape.isHostileInFlowingText` names is in the BMP,
    /// so one UTF-16 unit is always the whole scalar and a surrogate can never
    /// be hostile. `Unicode.Scalar(UInt32:)` returns nil for a lone surrogate —
    /// half of any emoji — so the nil branch answers `false` and must never
    /// force-unwrap. If a non-BMP scalar is ever added to
    /// `DisplayEscape.mustEscape`, this walk must become a scalar walk or it
    /// will silently stop finding it (that invariant is stated there too).
    private func isHostile(_ backing: NSString, at charIndex: Int) -> Bool {
        guard charIndex >= 0, charIndex < backing.length else { return false }
        guard let scalar = Unicode.Scalar(UInt32(backing.character(at: charIndex))) else { return false }
        return DisplayEscape.isHostileInFlowingText(scalar)
    }

    /// Whether the UTF-16 unit at `charIndex` is a hostile invisible scalar.
    /// Fetches the backing store once and delegates. Convenient for a single
    /// probe; never call it in a loop — see `isHostile(_:at:)` for why.
    func isHostileCharacter(at charIndex: Int) -> Bool {
        guard let backing = textStorage?.mutableString else { return false }
        return isHostile(backing, at: charIndex)
    }

    /// The pill label for the scalar at `charIndex` of an already-fetched
    /// backing store, or nil if it is not hostile. Separate from `isHostile`
    /// so the hot path — every glyph of every layout pass — never builds a
    /// string.
    private func hostilePillLabel(_ backing: NSString, at charIndex: Int) -> String? {
        guard isHostile(backing, at: charIndex) else { return nil }
        return String(format: "<U+%04X>", UInt32(backing.character(at: charIndex)))
    }

    /// The pill label for the scalar at `charIndex`, or nil if it is not
    /// hostile. Hostility ALONE — this deliberately ignores fold state, so it
    /// is not the question a renderer should ask; see `disclosedPillLabel`.
    func hostilePillLabel(forCharacterAt charIndex: Int) -> String? {
        guard let backing = textStorage?.mutableString else { return nil }
        return hostilePillLabel(backing, at: charIndex)
    }

    /// The pill label for the character at `charIndex`, or nil if it gets no
    /// pill. This is the ONE answer to "is a pill reserved and drawn here?" —
    /// the delegate hooks that reserve the width and the draw loop that paints
    /// it must agree, and they can only agree by asking the same question.
    /// Folding wins: a character hidden inside a fold is invisible, and a fold's
    /// anchor is spoken for by the fold's own pill.
    ///
    /// Two bugs came from the hooks and the draw loop each answering for
    /// themselves, and `HostileTextPixelTests` pins both:
    ///
    /// - A hostile scalar INSIDE a fold painted its pill anyway. Worse, because
    ///   `glyphRange(forCharacterRange:)` maps a SUPPRESSED glyph back to the
    ///   fold's anchor glyph, every such scalar painted at the same x — ink
    ///   stacked on top of the fold's own pill. Measured 1,114 differing pixels
    ///   against the same fold holding an ordinary character; now 0.
    /// - A fold anchored ON a hostile scalar reserved a pill width that the
    ///   draw loop never filled. Measured 68.4pt of dead space (a full pill
    ///   width) between the anchor and the next visible glyph; now 0.0pt.
    ///
    /// `FoldState.entry(containing:)` covers the anchor as well as the interior,
    /// which is exactly what the second case needs.
    private func disclosedPillLabel(_ backing: NSString, at charIndex: Int) -> String? {
        if foldState.entry(containing: charIndex) != nil { return nil }
        return hostilePillLabel(backing, at: charIndex)
    }

    /// Single-probe form of `disclosedPillLabel(_:at:)`.
    func disclosedPillLabel(forCharacterAt charIndex: Int) -> String? {
        if foldState.entry(containing: charIndex) != nil { return nil }
        return hostilePillLabel(forCharacterAt: charIndex)
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

        // The backing store is fetched ONCE for the whole batch. This is the
        // single most expensive thing in the method if got wrong:
        // `mutableString` is not a cached accessor, it mints a fresh proxy on
        // every call. Fetching per glyph cost 68.6ns per UTF-16 unit against
        // 23.4ns hoisted (8,000-line document, -O, median of 7), which showed up
        // as +39.1% on a full layout versus a stock manager; hoisting brings
        // that to +22.3%.
        //
        // The disposition array below is NOT the thing to worry about — it
        // measures ~3ns per unit, and the predicate itself ~3ns. The `needsWork`
        // guard therefore exists only to skip the SECOND allocation (the
        // properties copy) and hand AppKit's own buffer straight back when
        // nothing changes, not to avoid this array.
        //
        // The residual overhead is the delegate round-trip: both control-glyph
        // hooks fire for every newline in the document, which no amount of
        // hoisting avoids. A bulk `getCharacters` into a buffer would take the
        // scan itself from 23.4ns to 3.8ns per unit if this ever needs revisiting.
        let backing = textStorage?.mutableString

        var dispositions = [GlyphDisposition](repeating: .unchanged, count: count)
        var needsWork = false
        for i in 0..<count {
            let disposition = Self.glyphDisposition(
                charIndex: charIndexes[i],
                foldedRanges: foldedRanges,
                isHostile: backing.map { isHostile($0, at: charIndexes[i]) } ?? false
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
        // bounding box reserved for each one. The backing store is fetched once
        // for the whole run, and `disclosedPillLabel` is the SAME question the
        // bounding-box hook answered — reserving and painting must not disagree.
        if let backing = textStorage?.mutableString {
            let end = min(NSMaxRange(charRange), backing.length)
            var charIndex = max(charRange.location, 0)
            while charIndex < end {
                if let label = disclosedPillLabel(backing, at: charIndex) {
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
        guard !foldState.entries.isEmpty else { return }

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

    /// Measured sizes, keyed by label. `size(withAttributes:)` is a full text
    /// measurement and every pill is measured at least twice — once in the
    /// bounding-box hook that reserves the width, once in `drawGlyphs` that
    /// paints it — so a cache halves that. It is bounded by construction: the
    /// hostile label set is the 33 `<U+XXXX>` strings, plus one entry per
    /// distinct fold placeholder.
    private var pillSizeCache: [String: NSSize] = [:]

    /// The size of a pill, including padding.
    ///
    /// The `+ 2` on the width (pre-existing) is the room `drawPill` gives back:
    /// it draws into `rect.insetBy(dx: 1, dy: 1)`, losing 1pt on each side. The
    /// same is true vertically — a 13pt label plus `pillVPad * 2` measures 18pt
    /// in a 16pt line, and the inset brings the painted pill back to 16pt, so
    /// nothing bleeds into the line above or below. The raw numbers look one
    /// size too big on purpose.
    func measurePill(label: String) -> NSSize {
        if let cached = pillSizeCache[label] { return cached }
        let attrs: [NSAttributedString.Key: Any] = [.font: pillFont]
        let textSize = (label as NSString).size(withAttributes: attrs)
        let size = NSSize(width: textSize.width + pillHPad * 2 + 2, height: textSize.height + pillVPad * 2)
        pillSizeCache[label] = size
        return size
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

/// These two hooks do most of the work, and the `.controlCharacter` marking in
/// `setGlyphs` covers what they cannot reach. The division of labour was
/// measured across all 33 hostile scalars, and it is not the obvious one:
///
/// - The stock typesetter ALREADY classifies the bidi, zero-width and C0/C1
///   families as `.controlCharacter` — U+200B, U+202E, U+2060, U+FEFF, U+2028
///   and even `\t` arrive here without any help from us. For those, the
///   `setGlyphs` marking is redundant and THESE HOOKS are the whole mechanism.
/// - The marking earns its place on the families the typesetter calls
///   `.regular` or `.elastic`: NBSP, ZWJ, MVS and U+2000. A hooks-only manager
///   gives those their natural advances — 8.04pt, 0pt, 5.06pt, 7.83pt — instead
///   of a pill, so they stay invisible.
///
/// Together, marking plus hooks, all 33 get exactly one pill width and none is
/// missed. Neither half is redundant; they cover different scalars.
///
/// Measured: only the returned rect's WIDTH is honoured; its origin is ignored,
/// and the line's used width grows by that width on its own — so no
/// `setLineFragmentRect` adjustment is needed or wanted here.
///
/// # What `.whitespace` neutralises, and what it does not
///
/// `.whitespace` is the only control-character action that can carry a width
/// (`.zeroAdvancement` cannot), so the two effects below are the accepted cost
/// of having a pill at all — not oversights:
///
/// - It DOES neutralise a mandatory line break. U+2028, U+2029 and U+0085 split
///   a line under a stock manager (2 lines); here they read inline as a pill
///   (1 line). That is the outcome we want — a hostile line separator should be
///   visible in place rather than silently splitting the statement.
/// - It does NOT neutralise bidi reordering. `AB<U+202E>CD` still renders `CD`
///   reversed, because reordering is decided from the CHARACTERS and this class
///   never changes a character. The pill discloses the override; it cannot undo
///   it. `HostileTextRenderingTests` pins this so nobody reads the line above
///   as a claim that overrides are defused.
extension FoldingLayoutManager: NSLayoutManagerDelegate {

    func layoutManager(
        _ layoutManager: NSLayoutManager,
        shouldUse action: NSLayoutManager.ControlCharacterAction,
        forControlCharacterAt charIndex: Int
    ) -> NSLayoutManager.ControlCharacterAction {
        // `.whitespace` also makes each pill a line-break OPPORTUNITY. Measured:
        // "AAAAAAAAAAAAAAAA\u{200B}BBBBBBBBBBBBBBBB" in a 150pt container wraps
        // to three lines with the pill stranded alone on the middle one, away
        // from the text it belongs to. Ugly, and accepted: no other action can
        // carry the width that makes the scalar visible in the first place.
        disclosedPillLabel(forCharacterAt: charIndex) != nil ? .whitespace : action
    }

    func layoutManager(
        _ layoutManager: NSLayoutManager,
        boundingBoxForControlGlyphAt glyphIndex: Int,
        for textContainer: NSTextContainer,
        proposedLineFragment proposedRect: NSRect,
        glyphPosition: NSPoint,
        characterIndex charIndex: Int
    ) -> NSRect {
        guard let label = disclosedPillLabel(forCharacterAt: charIndex) else {
            return NSRect(origin: glyphPosition, size: .zero)
        }
        return NSRect(x: glyphPosition.x, y: 0,
                      width: measurePill(label: label).width,
                      height: proposedRect.height)
    }
}
