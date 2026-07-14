import CoreGraphics

/// Pure sizing math for the column filter popover. No AppKit — unit-testable via
/// the standalone swiftc harness (scripts/test-filter-popover-sizing.sh).
enum FilterPopoverSizing {
    /// Narrowest the popover may be (the historical fixed width).
    static let minWidth: CGFloat = 260
    /// Shortest the value list may be (~5 rows at rowHeight 20 + spacing 2).
    static let minListHeight: CGFloat = 120
    /// The value list's height when the popover first opens.
    static let defaultListHeight: CGFloat = 180
    /// Fraction of the reference (results pane) size used as the upper bound.
    static let maxFraction: CGFloat = 0.6

    /// Upper bound for popover width given the reference (results pane) width.
    static func maxWidth(referenceWidth: CGFloat) -> CGFloat {
        max(minWidth, referenceWidth * maxFraction)
    }

    /// Upper bound for the value-list height given the reference height.
    static func maxListHeight(referenceHeight: CGFloat) -> CGFloat {
        max(minListHeight, referenceHeight * maxFraction)
    }

    /// Clamp a desired popover width into [minWidth, maxWidth(referenceWidth)].
    static func clampWidth(_ desired: CGFloat, referenceWidth: CGFloat) -> CGFloat {
        min(max(desired, minWidth), maxWidth(referenceWidth: referenceWidth))
    }

    /// Clamp a desired list height into [minListHeight, maxListHeight(referenceHeight)].
    static func clampListHeight(_ desired: CGFloat, referenceHeight: CGFloat) -> CGFloat {
        min(max(desired, minListHeight), maxListHeight(referenceHeight: referenceHeight))
    }
}
