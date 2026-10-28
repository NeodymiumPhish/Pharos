import AppKit

extension NSToolbarItem.Identifier {
    static let pharosManagerAdd = NSToolbarItem.Identifier("PharosManagerAdd")
    static let pharosManagerFilter = NSToolbarItem.Identifier("PharosManagerFilter")
    static let pharosManagerSidebarSeparator = NSToolbarItem.Identifier("PharosManagerSidebarSeparator")
}

/// A manager window's toolbar: **+** (New Variable, New Tag, New
/// Connection) at the trailing edge of the sidebar's part of the bar, a
/// separator that tracks the sidebar's divider, and the filter field at the
/// trailing edge of the window, over the detail. Putting New here keeps it out
/// of the bottom of the sidebar (HIG *Sidebars*).
///
/// The field sits over the detail, not the sidebar, because the sidebar's
/// part of the bar is too narrow for it: at sidebar widths of 220–260 pt
/// AppKit collapsed it to its 36 pt magnifier button.
///
/// Like `SettingsToolbarController`, not customisable and not autosaved:
/// these two items are the window's only way to add a record and find one, so
/// there is nothing a user should be able to drag away.
@MainActor
final class ManagerToolbarController: NSObject, NSToolbarDelegate {

    /// + was pressed.
    var onAdd: (() -> Void)?
    /// The filter text changed. Empty means "show everything".
    /// `ManagerSplitViewController.toolbarController` wires this to the
    /// sidebar.
    var onFilterChange: ((String) -> Void)?

    private let toolbarIdentifier: NSToolbar.Identifier
    private let addLabel: String
    private let addToolTip: String
    private let searchField = NSSearchField()
    /// Held weakly: the split view belongs to its controller. Read when the
    /// toolbar asks for the separator, which happens during `install`.
    private weak var splitView: NSSplitView?

    /// The order of the default items. Over the sidebar: a flexible space
    /// that pushes + to the sidebar's trailing edge. The tracking separator
    /// ends the sidebar's part of the bar. Over the detail: a flexible space
    /// that pushes the filter field to the window's trailing edge.
    static let defaultItems: [NSToolbarItem.Identifier] = [
        .flexibleSpace,
        .pharosManagerAdd,
        .pharosManagerSidebarSeparator,
        .flexibleSpace,
        .pharosManagerFilter,
    ]

    /// The filter field's preferred width. It sits over the detail, which is
    /// never narrower than its minimum, so it does not have to share the
    /// sidebar's width with +.
    static let filterPreferredWidth: CGFloat = 220

    /// - Parameters:
    ///   - identifier: unique per window. Toolbars that share an identifier
    ///     share their configuration across windows.
    ///   - addLabel: the + item's name, such as "New Variable": its label,
    ///     its VoiceOver label, and its tooltip unless `addToolTip` is given.
    init(identifier: String, addLabel: String, addToolTip: String? = nil) {
        toolbarIdentifier = NSToolbar.Identifier(identifier)
        self.addLabel = addLabel
        self.addToolTip = addToolTip ?? addLabel
        super.init()
        searchField.placeholderString = String(localized: "Filter")
        searchField.sendsSearchStringImmediately = true
        searchField.sendsWholeSearchString = false
        searchField.target = self
        searchField.action = #selector(filterChanged)
        searchField.setAccessibilityIdentifier("manager.filter")
        searchField.setAccessibilityLabel(String(localized: "Filter"))
    }

    /// Read by the tests and by an owner that wants ⌘F to focus it.
    var filterField: NSSearchField { searchField }

    // MARK: - Install

    /// Give `window` this toolbar. `splitView` is the manager's split view;
    /// the separator follows its first divider.
    func install(on window: NSWindow, splitView: NSSplitView) {
        self.splitView = splitView
        let toolbar = NSToolbar(identifier: toolbarIdentifier)
        toolbar.delegate = self
        toolbar.displayMode = .iconOnly
        toolbar.allowsUserCustomization = false
        toolbar.autosavesConfiguration = false
        window.toolbar = toolbar
    }

    @objc private func addPressed() {
        onAdd?()
    }

    @objc private func filterChanged() {
        onFilterChange?(searchField.stringValue)
    }

    // MARK: - NSToolbarDelegate

    func toolbar(_ toolbar: NSToolbar, itemForItemIdentifier identifier: NSToolbarItem.Identifier,
                 willBeInsertedIntoToolbar flag: Bool) -> NSToolbarItem? {
        switch identifier {
        case .pharosManagerAdd:
            let item = NSToolbarItem(itemIdentifier: identifier)
            item.label = addLabel
            item.paletteLabel = addLabel
            item.toolTip = addToolTip
            item.image = NSImage(systemSymbolName: "plus", accessibilityDescription: addLabel)
            item.isBordered = true
            item.target = self
            item.action = #selector(addPressed)
            item.visibilityPriority = .high
            return item

        case .pharosManagerFilter:
            let item = NSSearchToolbarItem(itemIdentifier: identifier)
            item.label = String(localized: "Filter")
            item.paletteLabel = item.label
            item.searchField = searchField
            item.resignsFirstResponderWithCancel = true
            item.preferredWidthForSearchField = Self.filterPreferredWidth
            return item

        case .pharosManagerSidebarSeparator:
            guard let splitView else { return nil }
            return NSTrackingSeparatorToolbarItem(identifier: identifier, splitView: splitView, dividerIndex: 0)

        default:
            return nil
        }
    }

    func toolbarDefaultItemIdentifiers(_ toolbar: NSToolbar) -> [NSToolbarItem.Identifier] {
        Self.defaultItems
    }

    func toolbarAllowedItemIdentifiers(_ toolbar: NSToolbar) -> [NSToolbarItem.Identifier] {
        Self.defaultItems
    }

    /// Nothing here may be dragged out (see the type's comment).
    func toolbarImmovableItemIdentifiers(_ toolbar: NSToolbar) -> Set<NSToolbarItem.Identifier> {
        Set(Self.defaultItems.filter { $0 != .flexibleSpace })
    }
}
