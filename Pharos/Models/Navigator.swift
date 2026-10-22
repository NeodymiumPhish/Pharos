import AppKit

/// The three lists the sidebar can show, in toolbar order. The raw value is
/// the menu item's tag and the index of the segment in the toolbar's
/// navigator group, so the order must not be rearranged without also bumping
/// the preference key in `SidebarNavigatorPrefs` (the stored value is this raw
/// value).
///
/// Order: Library (Sessions and Results History, switched by its scope bar),
/// Files, Database Navigator — last, because it is the one a user reads most
/// while writing queries. Query variables and tags have their own windows
/// (Window ▸ Variable Manager, Window ▸ Tag Manager).
///
/// There is deliberately no `accessibilityIdentifier` here. The selector is an
/// `NSToolbarItemGroup`, and `NSToolbarItem` does not adopt `NSAccessibility`;
/// AX finds the segments by role and title.
enum Navigator: Int, CaseIterable, Sendable {
    case library
    /// The DuckDB databases and data files the user opened (`FilesNavigatorVC`).
    case files
    case schema

    var symbolName: String {
        switch self {
        case .library: return "books.vertical"
        case .files: return "doc.on.doc"
        case .schema: return "cylinder.split.1x2"
        }
    }

    var title: String {
        switch self {
        case .library: return String(localized: "Library")
        case .files: return String(localized: "Files")
        case .schema: return String(localized: "Database Navigator")
        }
    }
}

/// The Library navigator's two lists, switched by the scope bar at its top.
enum LibraryScope: Int, CaseIterable, Sendable {
    case sessions
    case history

    var title: String {
        switch self {
        case .sessions: return String(localized: "Sessions")
        case .history: return String(localized: "Results History")
        }
    }

    /// The scope bar's short label.
    var shortTitle: String {
        switch self {
        case .sessions: return String(localized: "Sessions")
        case .history: return String(localized: "History")
        }
    }
}

/// One list of the sidebar: what the filter text is remembered for.
enum SidebarList: Hashable, Sendable {
    case sessions, history, files, schema

    init(navigator: Navigator, scope: LibraryScope) {
        switch navigator {
        case .library: self = scope == .sessions ? .sessions : .history
        case .files: self = .files
        case .schema: self = .schema
        }
    }
}
