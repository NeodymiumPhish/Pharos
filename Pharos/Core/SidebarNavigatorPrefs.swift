import Foundation

/// Which navigator — and which Library list — the sidebar was showing when
/// the app last quit. App-wide: a new window opens on the list the user was
/// last reading.
enum SidebarNavigatorPrefs {

    /// "3": the sidebar went from five navigators to three (Library, Files,
    /// Database Navigator), so a raw value stored under "2" means something
    /// else now. It is read once and mapped (`migrated(fromVersion2:)`).
    private static let lastNavigatorKey = "SidebarLastNavigator3"
    private static let previousNavigatorKey = "SidebarLastNavigator2"
    private static let libraryScopeKey = "SidebarLibraryScope"

    /// Injectable so the suite can round-trip through its own suite domain
    /// instead of the user's defaults.
    static var defaults: UserDefaults = .standard

    static var lastNavigator: Navigator {
        get {
            migrateIfNeeded()
            // An absent or out-of-range value (an older or newer build) is the
            // Library — the same first launch every user had.
            guard let stored = defaults.object(forKey: lastNavigatorKey) as? Int,
                  let navigator = Navigator(rawValue: stored) else { return .library }
            return navigator
        }
        set { defaults.set(newValue.rawValue, forKey: lastNavigatorKey) }
    }

    static var libraryScope: LibraryScope {
        get {
            migrateIfNeeded()
            guard let stored = defaults.object(forKey: libraryScopeKey) as? Int,
                  let scope = LibraryScope(rawValue: stored) else { return .sessions }
            return scope
        }
        set { defaults.set(newValue.rawValue, forKey: libraryScopeKey) }
    }

    /// The five-navigator build stored 0 Sessions, 1 Variables, 2 Results
    /// History, 3 Database Navigator, 4 Files. Variables has its own window
    /// now, so it lands on the Library.
    static func migrated(fromVersion2 raw: Int) -> (Navigator, LibraryScope) {
        switch raw {
        case 2: return (.library, .history)
        case 3: return (.schema, .sessions)
        case 4: return (.files, .sessions)
        default: return (.library, .sessions)
        }
    }

    private static func migrateIfNeeded() {
        guard defaults.object(forKey: lastNavigatorKey) == nil,
              let old = defaults.object(forKey: previousNavigatorKey) as? Int else { return }
        let (navigator, scope) = migrated(fromVersion2: old)
        defaults.set(navigator.rawValue, forKey: lastNavigatorKey)
        defaults.set(scope.rawValue, forKey: libraryScopeKey)
    }
}

/// The sidebar's filter state: which navigator and Library list is showing,
/// and the filter text each LIST is holding. Kept out of the view controller
/// so the "text is remembered per list" rule can be asserted without AppKit.
///
/// A switch must not carry one list's filter into another: the schema tree and
/// the query history match on entirely different text, and a stray filter that
/// follows the user across a switch reads as an empty list.
struct NavigatorFilterState {

    private(set) var current: Navigator
    private(set) var libraryScope: LibraryScope
    private var texts: [SidebarList: String] = [:]

    init(current: Navigator = .library, libraryScope: LibraryScope = .sessions) {
        self.current = current
        self.libraryScope = libraryScope
    }

    /// The list on screen.
    var currentList: SidebarList { SidebarList(navigator: current, scope: libraryScope) }

    /// The text the showing list is filtered by.
    var currentText: String { texts[currentList] ?? "" }

    /// Record what the user typed into the showing list's slot.
    mutating func setText(_ text: String) {
        texts[currentList] = text
    }

    /// Switch navigators. The outgoing list keeps its text.
    mutating func select(_ navigator: Navigator) {
        current = navigator
    }

    /// Switch the Library's list. The outgoing list keeps its text.
    mutating func selectScope(_ scope: LibraryScope) {
        libraryScope = scope
    }

    /// The text held for any list, showing or not.
    func text(for list: SidebarList) -> String { texts[list] ?? "" }
}
