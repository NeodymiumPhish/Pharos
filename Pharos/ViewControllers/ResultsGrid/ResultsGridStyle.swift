import AppKit

/// The fonts and the row height the results grid draws with, derived once
/// from Settings ▸ Results (density + font size + monospaced) and handed to
/// everything that has to agree on them.
///
/// This replaces the `cellFont` / `cellItalicFont` statics that used to live
/// on `ResultsGridMetrics`. They were constants, so the cell renderer and the
/// column-width measurer could not disagree; now that the user can change
/// them, ONE value has to reach both — the measurer sizes a column for the
/// exact font the cell will draw in, or every column is a little too wide or
/// a little too short.
///
/// `ResultsGridMetrics.cellInset` stays where it is: it is a layout constant
/// the header shares, and nothing in Settings moves it.
struct ResultsGridStyle: Equatable {

    /// Smallest and largest body text the pane offers.
    static let fontSizeRange: ClosedRange<UInt32> = 9...18

    let density: ResultsDensity
    /// The size as stored, BEFORE the density delta and the clamp.
    let requestedFontSize: UInt32
    let monospaced: Bool

    /// What the grid drew before any of this was settable: normal density,
    /// 12pt monospaced, a 22pt row.
    static let `default` = ResultsGridStyle(density: .normal, requestedFontSize: 12, monospaced: true)

    init(density: ResultsDensity, requestedFontSize: UInt32, monospaced: Bool) {
        self.density = density
        self.requestedFontSize = requestedFontSize
        self.monospaced = monospaced
    }

    init(_ settings: ResultsSettings) {
        self.init(density: settings.density,
                  requestedFontSize: settings.fontSize,
                  monospaced: settings.monospacedFont)
    }

    /// The drawn point size: the stored size nudged by the density and held
    /// inside the range the stepper offers, so a stored value from another
    /// build can never produce an unreadable grid.
    var pointSize: CGFloat {
        let clampedRequest = min(max(requestedFontSize, Self.fontSizeRange.lowerBound),
                                 Self.fontSizeRange.upperBound)
        let nudged = CGFloat(clampedRequest) + density.fontDelta
        return min(max(nudged, CGFloat(Self.fontSizeRange.lowerBound)),
                   CGFloat(Self.fontSizeRange.upperBound))
    }

    /// Body cell font. Monospaced by default so digits share one advance and
    /// a right-aligned numeric column lines up on its last digit; the system
    /// face is the alternative for readers who prefer it.
    var cellFont: NSFont {
        monospaced
            ? .monospacedSystemFont(ofSize: pointSize, weight: .regular)
            : .systemFont(ofSize: pointSize)
    }

    /// Body cell font for a NULL — same metrics, italic trait.
    var cellItalicFont: NSFont { cellFont.withTraits(.italic) }

    /// The `#` column's font. A point smaller than the body, as it was when
    /// it was a hard-coded 11 beside a hard-coded 12, and always
    /// monospaced-digit so the numbers stay in a column.
    var rowNumberFont: NSFont {
        .monospacedDigitSystemFont(ofSize: max(8, pointSize - 1), weight: .regular)
    }

    /// Row height: the text's line height plus the density's padding.
    var rowHeight: CGFloat {
        ceil(pointSize) + density.rowPadding
    }
}
