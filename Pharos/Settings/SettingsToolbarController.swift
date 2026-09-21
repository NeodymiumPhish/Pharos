import AppKit

extension NSToolbarItem.Identifier {
    static let pharosSettingsNav = NSToolbarItem.Identifier("PharosSettingsNav")
    static let pharosSettingsTitle = NSToolbarItem.Identifier("PharosSettingsTitle")
    static let pharosSettingsSearch = NSToolbarItem.Identifier("PharosSettingsSearch")
}

/// The Settings window's toolbar: Back / Forward and the pane's title, both
/// sitting in the TITLE BAR over the detail pane, as Xcode's and System
/// Settings' windows have them.
///
/// This furniture used to be `SettingsDetailHeaderView`, a view inside the
/// detail pane under a deliberately transparent title bar. It looked close
/// from a distance and wrong up close: the traffic lights sat in an empty bar
/// with the window's own furniture drawn a row below them, which no system
/// window does. Putting the same controls in a real `NSToolbar` after
/// `.sidebarTrackingSeparator` is what makes the title bar split at the
/// sidebar divider, and it matches Pharos's own main window
/// (`MainWindowController` sets `toolbarStyle = .unified` too).
///
/// Unlike `MainToolbarController` this toolbar is NOT customisable and does
/// not autosave. Back, Forward and the title are the window's navigation, not
/// a set of conveniences — a user who dragged them out would have no way back
/// — so there is nothing to save and no need for a versioned identifier.
@MainActor
final class SettingsToolbarController: NSObject, NSToolbarDelegate {

    /// Back or Forward was pressed.
    var onNavigate: ((SettingsWindow.NavigationDirection) -> Void)?
    /// The search field's text changed. Empty means "show everything".
    var onSearch: ((String) -> Void)?

    private let navControl = NSSegmentedControl()
    private let titleLabel = NSTextField(labelWithString: "")
    private let searchField = NSSearchField()

    /// Read by the live accessibility check and by the tests.
    var navigationControl: NSSegmentedControl { navControl }
    var title: String { titleLabel.stringValue }
    var canGoBack: Bool { navControl.isEnabled(forSegment: 0) }
    var canGoForward: Bool { navControl.isEnabled(forSegment: 1) }

    override init() {
        super.init()
        configureNav()
        configureTitle()
        configureSearch()
    }

    private func configureNav() {
        navControl.segmentCount = 2
        navControl.trackingMode = .momentary
        navControl.segmentStyle = .separated
        navControl.setImage(NSImage(systemSymbolName: "chevron.left",
                                    accessibilityDescription: String(localized: "Back")),
                            forSegment: 0)
        navControl.setImage(NSImage(systemSymbolName: "chevron.right",
                                    accessibilityDescription: String(localized: "Forward")),
                            forSegment: 1)
        navControl.setToolTip(String(localized: "Back"), forSegment: 0)
        navControl.setToolTip(String(localized: "Forward"), forSegment: 1)
        navControl.setWidth(32, forSegment: 0)
        navControl.setWidth(32, forSegment: 1)
        navControl.target = self
        navControl.action = #selector(navPressed)
        // The identifier the live AX check looks for. It stays on the CONTROL,
        // not on the toolbar item: a view item's own identifier is not what
        // the accessibility tree reports for the view inside it.
        navControl.setAccessibilityIdentifier("settings.nav")
        navControl.setAccessibilityLabel(String(localized: "Navigation"))
    }

    private func configureTitle() {
        titleLabel.font = .systemFont(ofSize: SettingsMetrics.navTitleFontSize, weight: .bold)
        titleLabel.textColor = .labelColor
        titleLabel.lineBreakMode = .byTruncatingTail
        titleLabel.setAccessibilityIdentifier("settings.title")
        titleLabel.setAccessibilityRole(.staticText)
        titleLabel.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
    }

    private func configureSearch() {
        searchField.placeholderString = String(localized: "Search")
        searchField.sendsSearchStringImmediately = true
        searchField.target = self
        searchField.action = #selector(searchChanged)
        searchField.setAccessibilityIdentifier("settings.search")
        searchField.setAccessibilityLabel(String(localized: "Search settings"))
    }

    // MARK: - Install

    func install(on window: NSWindow) {
        let toolbar = NSToolbar(identifier: "PharosSettingsToolbar")
        toolbar.delegate = self
        toolbar.displayMode = .iconOnly
        toolbar.allowsUserCustomization = false
        toolbar.autosavesConfiguration = false
        window.toolbar = toolbar
    }

    // MARK: - State

    func update(title: String, canGoBack: Bool, canGoForward: Bool) {
        titleLabel.stringValue = title
        navControl.setEnabled(canGoBack, forSegment: 0)
        navControl.setEnabled(canGoForward, forSegment: 1)
    }

    /// Clear the field without telling anyone — for closing a search from the
    /// outside, where the caller is already restoring the sidebar itself.
    func clearSearchSilently() {
        searchField.stringValue = ""
    }

    @objc private func navPressed() {
        onNavigate?(navControl.selectedSegment == 0 ? .back : .forward)
    }

    @objc private func searchChanged() {
        onSearch?(searchField.stringValue)
    }

    // MARK: - NSToolbarDelegate

    func toolbar(_ toolbar: NSToolbar, itemForItemIdentifier identifier: NSToolbarItem.Identifier,
                 willBeInsertedIntoToolbar flag: Bool) -> NSToolbarItem? {
        switch identifier {
        case .pharosSettingsNav:
            let item = NSToolbarItem(itemIdentifier: identifier)
            item.label = String(localized: "Navigation")
            item.paletteLabel = item.label
            item.view = navControl
            // NOT `isNavigational`. The header says a navigational item "may
            // be specially positioned by the system OUTSIDE the normal list of
            // items" — which is the one thing this item must not do: its place
            // just right of the sidebar separator is the whole look. Measured
            // both ways (2026-09-20): the frame is identical, so the flag buys
            // nothing and risks a reposition on a future macOS.
            item.visibilityPriority = .high
            return item

        case .pharosSettingsTitle:
            let item = NSToolbarItem(itemIdentifier: identifier)
            item.label = String(localized: "Pane")
            item.paletteLabel = item.label
            item.view = titleLabel
            // A label is not a control: without this AppKit dims it whenever
            // the window is not key, and a greyed-out title reads as broken.
            item.isEnabled = true
            return item

        case .pharosSettingsSearch:
            let item = NSSearchToolbarItem(itemIdentifier: identifier)
            item.label = String(localized: "Search")
            item.paletteLabel = item.label
            item.searchField = searchField
            item.resignsFirstResponderWithCancel = true
            return item

        default:
            return NSToolbarItem(itemIdentifier: identifier)
        }
    }

    /// `.sidebarTrackingSeparator` first: everything after it is laid out over
    /// the DETAIL pane, which is where Xcode puts the chevrons and the title.
    func toolbarDefaultItemIdentifiers(_ toolbar: NSToolbar) -> [NSToolbarItem.Identifier] {
        var items: [NSToolbarItem.Identifier] = [
            .sidebarTrackingSeparator,
            .pharosSettingsNav,
            .pharosSettingsTitle,
        ]
        // The field is only offered once something is listening to it. A
        // search box that silently does nothing is worse than no search box.
        if onSearch != nil {
            items += [.flexibleSpace, .pharosSettingsSearch]
        }
        return items
    }

    /// Every item this toolbar can ever show, search included — the default
    /// set is validated against this one, and an allowed set that omitted an
    /// item would silently drop it.
    func toolbarAllowedItemIdentifiers(_ toolbar: NSToolbar) -> [NSToolbarItem.Identifier] {
        [
            .sidebarTrackingSeparator,
            .pharosSettingsNav,
            .pharosSettingsTitle,
            .flexibleSpace,
            .pharosSettingsSearch,
        ]
    }

    /// Nothing here is removable, so nothing is immovable either — but say so
    /// explicitly: an empty answer here is what lets a drag pull an item out
    /// when customisation is turned on later by accident.
    func toolbarImmovableItemIdentifiers(_ toolbar: NSToolbar) -> Set<NSToolbarItem.Identifier> {
        Set(toolbarAllowedItemIdentifiers(toolbar))
    }
}
