import AppKit

// MARK: - FindMatchDecoration

/// How the results grid marks a find match, as a pure rule.
///
/// Find used to be a wash and nothing else: a yellow fill at one alpha for the
/// current match and a weaker one for the others. A tag's matched-cell tint is
/// also a fill, at an alpha in between (`TagPalette.cellTintAlpha`), and one of
/// the six palette hues IS yellow — so telling a find result from a tagged cell
/// meant comparing two washes by shade. Users could not.
///
/// The fix is that find now carries a BORDER as well as a fill, and a tag tint
/// never does. That makes the two different KINDS of mark rather than two
/// shades of one, so the distinction survives even when the hues collide. The
/// fills still separate the current match from the rest, but they no longer
/// have to carry the find-vs-tag signal on their own, which is why they moved
/// (see `fillAlpha`).
///
/// Pure, and here rather than inside `ResultsDataSource`, because the data
/// source is `@MainActor` and too entangled to compile in a standalone
/// harness. Everything worth asserting about the rule lives in this file. See
/// `scripts/test-find-decoration.sh`.
enum FindMatchDecoration {

    /// What a cell is to the current find, strongest first when read as a
    /// precedence chain. `none` covers both "find is closed" and "find is open
    /// and this cell did not match".
    enum State: Equatable {
        case current
        case other
        case none
    }

    /// Resolve the two booleans `ResultsDataSource` already computes per cell
    /// into one value. `isCurrent` wins: the caller derives `isOther` from a
    /// set that may or may not also hold the current address, and the current
    /// match must never be demoted by that overlap.
    static func state(isCurrent: Bool, isOther: Bool) -> State {
        if isCurrent { return .current }
        if isOther { return .other }
        return .none
    }

    /// The find hue. One colour for both fill and border so the two read as
    /// one mark; the border earns its contrast from `borderColor`, not from a
    /// second hue.
    static let hue: NSColor = .systemYellow

    /// Border width in points. Zero for a non-match, which is what clears the
    /// border off a RECYCLED cell — the caller assigns this unconditionally
    /// rather than only when there is something to draw.
    ///
    /// The current match is twice the others so the thickness alone ranks
    /// them. It stops at 2pt rather than going louder: a `CALayer` border
    /// draws INSIDE the cell's bounds on all four sides, the grid's rows are
    /// 22pt, and a 12pt monospaced label centred in that leaves only about 3pt
    /// of clearance above the ascenders and below the descenders. 3pt would
    /// clip a descender; 2pt does not.
    static func borderWidth(_ state: State) -> CGFloat {
        switch state {
        case .current: return 2
        case .other: return 1
        case .none: return 0
        }
    }

    /// Fill alpha for the find wash, or nil when the cell is not a match and
    /// the caller should fall through to selection / tag tint / clear.
    ///
    /// Both numbers came DOWN when the border arrived (current 0.4 → 0.3,
    /// other 0.15 → 0.1). The border now carries "this is a find result", so
    /// the fills were free to move to where they rank cleanly against the tag
    /// paints instead of colliding with them:
    ///
    ///     other find 0.1 < row wash 0.15 < cell tint 0.2 < current find 0.3
    ///
    /// A non-current find match is now the LIGHTEST wash in the grid and is
    /// recognised by its outline; the current match is the heaviest, and is
    /// the only cell anywhere with a 2pt one.
    static func fillAlpha(_ state: State) -> CGFloat? {
        switch state {
        case .current: return 0.3
        case .other: return 0.1
        case .none: return nil
        }
    }

    /// The border colour for one appearance.
    ///
    /// `hue` at full strength is not usable on its own: system yellow is a
    /// light colour, so a bare yellow hairline nearly vanishes against a white
    /// grid. Shading it toward the ground's OPPOSITE is what makes one rule
    /// work on both — darkened to an amber for light appearance, lifted toward
    /// white for dark. Deriving both from `hue` also keeps the border in the
    /// find family rather than introducing a colour a tag might own.
    ///
    /// Falls back to the unblended hue if the blend fails, which it can only
    /// do if the colours stop converting to a common space.
    static func borderColor(isDark: Bool) -> NSColor {
        let towards: NSColor = isDark ? .white : .black
        let fraction: CGFloat = isDark ? 0.15 : 0.4
        return hue.blended(withFraction: fraction, of: towards) ?? hue
    }
}
