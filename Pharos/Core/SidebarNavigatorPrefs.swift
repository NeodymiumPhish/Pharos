import Foundation

/// Which navigator the sidebar was showing when the app last quit. App-wide,
/// like `ResultTabsPanelPrefs.width` — a new window opens on the list the user
/// was last reading, not always on the Query Library.
enum SidebarNavigatorPrefs {

    /// "2", not the original key: the Variables navigator was inserted at raw
    /// value 1, so a stored 1 from an earlier build (Results History) would
    /// now read as Variables. A fresh key makes every old value absent, and an
    /// absent value is the Library — the same first launch every user had.
    private static let lastNavigatorKey = "SidebarLastNavigator2"

    /// Injectable so the suite can round-trip through its own suite domain
    /// instead of the user's defaults.
    static var defaults: UserDefaults = .standard

    static var lastNavigator: Navigator {
        get {
            // `integer(forKey:)` returns 0 for an absent key, which is
            // `.library` — the intended default, but say so rather than lean
            // on the coincidence. An out-of-range stored value (an older or
            // newer build's navigator) also falls back to the Library.
            guard let stored = defaults.object(forKey: lastNavigatorKey) as? Int,
                  let navigator = Navigator(rawValue: stored) else { return .library }
            return navigator
        }
        set { defaults.set(newValue.rawValue, forKey: lastNavigatorKey) }
    }
}

/// The sidebar's filter state: which navigator is showing, and the filter text
/// each one is holding. Kept out of the view controller so the "text is
/// remembered per navigator" rule can be asserted without AppKit.
///
/// A switch must not carry one list's filter into another: the schema tree and
/// the query history match on entirely different text, and a stray filter that
/// follows the user across a switch reads as an empty list.
struct NavigatorFilterState {

    private(set) var current: Navigator
    private var texts: [Navigator: String] = [:]

    init(current: Navigator = .library) {
        self.current = current
    }

    /// The text the showing navigator is filtered by.
    var currentText: String { texts[current] ?? "" }

    /// Record what the user typed into the showing navigator's slot.
    mutating func setText(_ text: String) {
        texts[current] = text
    }

    /// Switch navigators. The outgoing navigator keeps its text; the incoming
    /// one's text (possibly empty) becomes `currentText`.
    mutating func select(_ navigator: Navigator) {
        current = navigator
    }

    /// The text held for any navigator, showing or not.
    func text(for navigator: Navigator) -> String { texts[navigator] ?? "" }
}
