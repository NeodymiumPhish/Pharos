import AppKit

/// The four lists the sidebar can show. The raw value is the menu item's tag
/// and the index of the segment in the toolbar's navigator group, so the
/// order must not be rearranged without also bumping the preference key in
/// `SidebarNavigatorPrefs` (the stored value is this raw value).
///
/// Order: Query Library, Variables, Results History, Database Navigator. The
/// Variables navigator is the ONE app-wide list of `{{name}}` variables —
/// see `QueryVariableStore` — not a per-tab panel.
///
/// There is deliberately no `accessibilityIdentifier` here any more. The
/// selector is an `NSToolbarItemGroup` now, and `NSToolbarItem` is
/// `NSObject <NSCopying>` — it does not adopt `NSAccessibility` and has no
/// `setAccessibilityIdentifier`. AX finds these by role and title, the same
/// way it already finds Run and Cancel.
enum Navigator: Int, CaseIterable, Sendable {
    case library
    case variables
    case history
    case schema

    var symbolName: String {
        switch self {
        case .library: return "folder"
        case .variables: return "curlybraces"
        case .history: return "clock.arrow.circlepath"
        case .schema: return "cylinder.split.1x2"
        }
    }

    var title: String {
        switch self {
        case .library: return String(localized: "Query Library")
        case .variables: return String(localized: "Variables")
        case .history: return String(localized: "Results History")
        case .schema: return String(localized: "Database Navigator")
        }
    }
}
