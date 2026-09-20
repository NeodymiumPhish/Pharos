import AppKit

/// The numbers and colours every piece of Settings furniture shares, so a
/// pane built from `SettingsGroupBox` + `SettingsRow` lines up with the next
/// one without either knowing the other's constants.
///
/// AppKit only. This file is compiled standalone by
/// `scripts/test-settings-furniture.sh`, so nothing here may reach for the
/// FFI, `AppStateManager` or `PharosCore`.
enum SettingsMetrics {

    // MARK: Pane

    /// Side inset of the whole pane content.
    static let paneInsetH: CGFloat = 20
    static let paneInsetTop: CGFloat = 8
    static let paneInsetBottom: CGFloat = 24
    /// Gap between one section (header + box) and the next.
    static let sectionSpacing: CGFloat = 24
    /// Gap between a section header and the box below it.
    static let headerToBoxGap: CGFloat = 8

    // MARK: Group box

    static let boxCornerRadius: CGFloat = 10

    // MARK: Row

    static let rowMinHeight: CGFloat = 40
    static let rowInsetH: CGFloat = 12
    static let rowInsetV: CGFloat = 8
    static let rowIconSize: CGFloat = 20
    static let iconTextGap: CGFloat = 10
    static let textControlGap: CGFloat = 16
    /// Extra leading inset for a row that depends on the row above it.
    static let dependentIndent: CGFloat = 30

    // MARK: Controls

    static let controlMinWidth: CGFloat = 140
    static let numberFieldWidth: CGFloat = 56
    static let textFieldWidth: CGFloat = 200
    static let sliderWidth: CGFloat = 180

    // MARK: Type

    static let captionFontSize: CGFloat = 11
    static let titleFontSize: CGFloat = 13
    /// Bold.
    static let headerFontSize: CGFloat = 13
    /// The pane name in the window's toolbar. Bold.
    static let navTitleFontSize: CGFloat = 15

    // MARK: Colours

    /// The pane's background, behind the group boxes.
    ///
    /// Why these two are NOT `windowBackgroundColor` and `controlBackgroundColor`
    /// (the obvious "surface" and "card" pair): measured 2026-09-19 on macOS
    /// 26 and 27, `controlBackgroundColor` and `windowBackgroundColor` resolve
    /// to the IDENTICAL value in both appearances — #FFFEFF in light and
    /// #1E1E1E in dark. A card in one on a surface in the other is therefore
    /// invisible. `underPageBackgroundColor` is the one system background that
    /// differs from them (#F6F6F6 light, #282828 dark), so it plays the
    /// darker role in light mode (the surface) and the lighter role in dark
    /// mode (the plate), and the pair contrasts in both.
    static let paneSurfaceColor = NSColor(name: nil) { appearance in
        appearance.isDark ? .windowBackgroundColor : .underPageBackgroundColor
    }

    /// The group box's rounded plate. See `paneSurfaceColor` for why.
    static let plateColor = NSColor(name: nil) { appearance in
        appearance.isDark ? .underPageBackgroundColor : .controlBackgroundColor
    }

    /// The group box's hairline border and its row separators.
    static let borderColor = NSColor.separatorColor
}

extension NSAppearance {
    /// True when this appearance is closer to dark than to light.
    var isDark: Bool {
        bestMatch(from: [.aqua, .darkAqua]) == .darkAqua
    }
}
