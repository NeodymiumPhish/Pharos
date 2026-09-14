import AppKit
import Combine

extension NSToolbarItem.Identifier {
    static let pharosConnection = NSToolbarItem.Identifier("PharosConnection")
    static let pharosRunQuery = NSToolbarItem.Identifier("PharosRunQuery")
    static let pharosCancelQuery = NSToolbarItem.Identifier("PharosCancelQuery")
    static let pharosFilterSidebar = NSToolbarItem.Identifier("PharosFilterSidebar")
    static let pharosFormatSQL = NSToolbarItem.Identifier("PharosFormatSQL")
    static let pharosNewTab = NSToolbarItem.Identifier("PharosNewTab")
    static let pharosSaveQuery = NSToolbarItem.Identifier("PharosSaveQuery")
}

/// A toolbar item with a custom view whose enabled state comes from a closure.
/// `NSToolbar` validates image items through their target, but leaves
/// view items alone; this override closes that gap so the Cancel button
/// greys out like a menu item would.
private final class ValidatingViewToolbarItem: NSToolbarItem {
    var isEnabledProvider: (() -> Bool)?

    override func validate() {
        isEnabled = isEnabledProvider?() ?? true
    }
}

/// Delegate and state driver for the main window's `NSToolbar`.
///
/// Default set, left to right: sidebar toggle | tracking separator |
/// connection pull-down, Run, Cancel | flexible space | tracking separator |
/// inspector toggle. Run is the one prominent item and carries a badge with
/// the count of running queries on the active tab. Every item here has a
/// menu command; the toolbar adds nothing that the menu bar cannot reach.
///
/// The user can customize the toolbar (View > Customize Toolbar…). The
/// allowed-but-not-default items are the sidebar filter field, Format SQL,
/// New Tab and Save Query.
@MainActor
final class MainToolbarController: NSObject {

    private weak var contentVC: ContentViewController?
    private weak var sidebarVC: SidebarViewController?
    private let stateManager = AppStateManager.shared
    private let metadataCache = MetadataCache.shared
    private var cancellables = Set<AnyCancellable>()

    /// One toolbar per window; the items are created on demand and kept
    /// weakly so state updates reach the live ones.
    private weak var toolbar: NSToolbar?
    private weak var runItem: NSToolbarItem?
    private weak var cancelItem: NSToolbarItem?

    private let connectionButton = NSPopUpButton(frame: .zero, pullsDown: true)
    private let cancelButton = NSButton()
    private var runningQueriesPopover: NSPopover?
    private var runningQueriesPopoverCloseObserver: NSObjectProtocol?

    init(contentVC: ContentViewController, sidebarVC: SidebarViewController) {
        self.contentVC = contentVC
        self.sidebarVC = sidebarVC
        super.init()
        configureConnectionButton()
        configureCancelButton()
        subscribe()
    }

    deinit {
        if let observer = runningQueriesPopoverCloseObserver {
            NotificationCenter.default.removeObserver(observer)
        }
    }

    /// Installs a customizable toolbar on `window` with this object as delegate.
    func install(on window: NSWindow) {
        let toolbar = NSToolbar(identifier: "PharosToolbar")
        toolbar.delegate = self
        toolbar.displayMode = .iconOnly
        toolbar.allowsUserCustomization = true
        toolbar.autosavesConfiguration = true
        window.toolbar = toolbar
        self.toolbar = toolbar
    }

    // MARK: - State

    private func subscribe() {
        // Tabs: the run badge and the connection title follow the active tab.
        // Dedup on the fields read here so a keystroke (which republishes
        // the tabs) does not rebuild the menu.
        stateManager.tabsSettled
            .removeDuplicates { lhs, rhs in
                guard lhs.count == rhs.count else { return false }
                for i in 0..<lhs.count {
                    if lhs[i].id != rhs[i].id
                        || lhs[i].connectionId != rhs[i].connectionId
                        || lhs[i].runningQueries.count != rhs[i].runningQueries.count
                    {
                        return false
                    }
                }
                return true
            }
            .sink { [weak self] _ in self?.refresh() }
            .store(in: &cancellables)

        stateManager.activeTabIdSettled
            .sink { [weak self] _ in self?.refresh() }
            .store(in: &cancellables)

        Publishers.CombineLatest(stateManager.$connections, stateManager.$connectionStatuses)
            .receive(on: RunLoop.main)
            .sink { [weak self] _, _ in self?.refresh() }
            .store(in: &cancellables)
    }

    private func refresh() {
        rebuildConnectionMenu()
        updateRunState()
        toolbar?.validateVisibleItems()
    }

    private var activeTab: QueryTab? { stateManager.activeTab }
    private var tabConnectionId: String? { activeTab?.connectionId }

    private func updateRunState() {
        let count = activeTab?.runningQueries.count ?? 0
        runItem?.badge = count > 0 ? .count(count) : nil
        cancelButton.toolTip = count > 1
            ? "\(count) queries running — click to manage"
            : "Cancel Query (⌘.)"
    }

    // MARK: - Actions

    @objc private func runTapped(_ sender: Any?) {
        contentVC?.menuRunQuery(sender)
    }

    @objc private func cancelTapped(_ sender: Any?) {
        let running = activeTab?.runningQueries ?? []
        switch running.count {
        case 0:
            return
        case 1:
            contentVC?.menuCancelQuery(sender)
        default:
            showRunningQueriesPopover()
        }
    }

    @objc private func filterChanged(_ sender: NSSearchField) {
        sidebarVC?.setFilterText(sender.stringValue)
    }

    private func showRunningQueriesPopover() {
        runningQueriesPopover?.close()
        guard let tabId = activeTab?.id else { return }

        let vc = RunningQueriesPopoverVC(stateManager: stateManager, tabId: tabId)
        vc.delegate = self

        let popover = NSPopover()
        popover.contentViewController = vc
        popover.behavior = .transient
        popover.show(relativeTo: cancelButton.bounds, of: cancelButton, preferredEdge: .minY)
        runningQueriesPopover = popover

        if let existing = runningQueriesPopoverCloseObserver {
            NotificationCenter.default.removeObserver(existing)
        }
        runningQueriesPopoverCloseObserver = NotificationCenter.default.addObserver(
            forName: NSPopover.didCloseNotification, object: popover, queue: .main
        ) { [weak self] _ in
            Task { @MainActor in self?.runningQueriesPopover = nil }
        }
    }

    // MARK: - Connection pull-down

    private func configureConnectionButton() {
        connectionButton.bezelStyle = .toolbar
        connectionButton.controlSize = .regular
        connectionButton.translatesAutoresizingMaskIntoConstraints = false
        (connectionButton.cell as? NSPopUpButtonCell)?.arrowPosition = .arrowAtBottom
        NSLayoutConstraint.activate([
            connectionButton.widthAnchor.constraint(greaterThanOrEqualToConstant: 150),
            connectionButton.widthAnchor.constraint(lessThanOrEqualToConstant: 260),
        ])
        connectionButton.setAccessibilityLabel("Connection")
    }

    private func rebuildConnectionMenu() {
        connectionButton.removeAllItems()

        let connections = stateManager.connections
        let activeId = tabConnectionId

        // First item in a pull-down button is the button's displayed title.
        let buttonTitle: String
        if let activeId, let config = connections.first(where: { $0.id == activeId }) {
            let status = stateManager.status(for: config.id)
            buttonTitle = "\(statusString(for: status))\(DisplayEscape.escaped(config.name))"
        } else if connections.isEmpty {
            buttonTitle = "No Connections"
        } else {
            buttonTitle = "Select Connection"
        }
        connectionButton.addItem(withTitle: buttonTitle)
        if let activeId, let config = connections.first(where: { $0.id == activeId }),
           let titleItem = connectionButton.item(at: 0) {
            titleItem.attributedTitle = styledTitle(buttonTitle, status: stateManager.status(for: config.id))
        }

        if !connections.isEmpty {
            connectionButton.menu?.addItem(.separator())
            for config in connections {
                let status = stateManager.status(for: config.id)
                let title = "\(statusString(for: status))\(DisplayEscape.escaped(config.name))"
                let item = NSMenuItem(title: title, action: #selector(connectionItemClicked(_:)), keyEquivalent: "")
                item.target = self
                item.representedObject = config.id
                item.attributedTitle = styledTitle(title, status: status)
                if config.id == activeId { item.state = .on }
                connectionButton.menu?.addItem(item)
            }

            connectionButton.menu?.addItem(.separator())

            let connect = NSMenuItem(title: "Connect", action: #selector(connectSelected), keyEquivalent: "")
            connect.target = self
            connect.isEnabled = contentVC?.canConnect ?? false
            connectionButton.menu?.addItem(connect)

            let disconnect = NSMenuItem(title: "Disconnect", action: #selector(disconnectSelected), keyEquivalent: "")
            disconnect.target = self
            disconnect.isEnabled = contentVC?.canDisconnect ?? false
            connectionButton.menu?.addItem(disconnect)

            let refresh = NSMenuItem(title: "Refresh Metadata", action: #selector(refreshMetadata), keyEquivalent: "")
            refresh.target = self
            refresh.isEnabled = contentVC?.canRefreshMetadata ?? false
            connectionButton.menu?.addItem(refresh)
        }

        connectionButton.menu?.addItem(.separator())
        let manage = NSMenuItem(title: "Manage Connections…", action: #selector(showConnectionsManager), keyEquivalent: "")
        manage.target = self
        connectionButton.menu?.addItem(manage)
        connectionButton.menu?.autoenablesItems = false
    }

    private func statusString(for status: ConnectionStatus) -> String {
        switch status {
        case .connected: return "\u{25CF} "   // filled circle
        case .connecting: return "\u{25CB} "   // empty circle
        case .error: return "\u{25CF} "        // filled circle (red)
        case .disconnected: return "  "
        }
    }

    private func styledTitle(_ title: String, status: ConnectionStatus) -> NSAttributedString {
        let attributed = NSMutableAttributedString(string: title)
        let color: NSColor?
        switch status {
        case .connected: color = .systemGreen
        case .error: color = .systemRed
        default: color = nil
        }
        if let color {
            attributed.addAttribute(.foregroundColor, value: color, range: NSRange(location: 0, length: 2))
        }
        return attributed
    }

    @objc private func connectionItemClicked(_ sender: NSMenuItem) {
        guard let id = sender.representedObject as? String, let tabId = activeTab?.id else { return }
        stateManager.useConnection(id, forTabId: tabId)
    }

    @objc private func connectSelected() { contentVC?.menuConnect(nil) }
    @objc private func disconnectSelected() { contentVC?.menuDisconnect(nil) }
    @objc private func refreshMetadata() { contentVC?.menuRefreshMetadata(nil) }
    @objc private func showConnectionsManager() { ConnectionsManagerWindowController.show() }

    // MARK: - Cancel button

    private func configureCancelButton() {
        cancelButton.bezelStyle = .toolbar
        cancelButton.image = NSImage(systemSymbolName: "stop.fill", accessibilityDescription: "Cancel Query")
        cancelButton.imagePosition = .imageOnly
        cancelButton.target = self
        cancelButton.action = #selector(cancelTapped(_:))
        cancelButton.toolTip = "Cancel Query (⌘.)"
        cancelButton.setAccessibilityLabel("Cancel Query")
    }
}

// MARK: - NSToolbarDelegate

extension MainToolbarController: NSToolbarDelegate {

    func toolbar(_ toolbar: NSToolbar, itemForItemIdentifier itemIdentifier: NSToolbarItem.Identifier, willBeInsertedIntoToolbar flag: Bool) -> NSToolbarItem? {
        switch itemIdentifier {
        case .toggleSidebar, .sidebarTrackingSeparator, .flexibleSpace, .space,
             .inspectorTrackingSeparator, .toggleInspector:
            return NSToolbarItem(itemIdentifier: itemIdentifier)

        case .pharosConnection:
            let item = NSToolbarItem(itemIdentifier: itemIdentifier)
            item.label = "Connection"
            item.paletteLabel = "Connection"
            item.toolTip = "Connection for the active tab"
            item.view = connectionButton
            item.visibilityPriority = .high
            if flag { rebuildConnectionMenu() }
            return item

        case .pharosRunQuery:
            let item = NSToolbarItem(itemIdentifier: itemIdentifier)
            item.label = "Run"
            item.paletteLabel = "Run Query"
            item.toolTip = "Run Query (⌘↩)"
            item.image = NSImage(systemSymbolName: "play.fill", accessibilityDescription: "Run Query")
            item.isBordered = true
            item.style = .prominent
            item.target = self
            item.action = #selector(runTapped(_:))
            item.visibilityPriority = .high
            if flag {
                runItem = item
                updateRunState()
            }
            return item

        case .pharosCancelQuery:
            let item = ValidatingViewToolbarItem(itemIdentifier: itemIdentifier)
            item.label = "Cancel"
            item.paletteLabel = "Cancel Query"
            item.view = cancelButton
            item.isEnabledProvider = { [weak self] in self?.contentVC?.canCancelQuery ?? false }
            item.visibilityPriority = .high
            if flag { cancelItem = item }
            return item

        case .pharosFilterSidebar:
            let item = NSSearchToolbarItem(itemIdentifier: itemIdentifier)
            item.label = "Filter"
            item.paletteLabel = "Filter Sidebar"
            item.toolTip = "Filter the sidebar list"
            item.searchField.placeholderString = "Filter"
            item.searchField.sendsSearchStringImmediately = true
            item.searchField.sendsWholeSearchString = false
            item.searchField.target = self
            item.searchField.action = #selector(filterChanged(_:))
            item.preferredWidthForSearchField = 180
            return item

        case .pharosFormatSQL:
            return imageItem(itemIdentifier, label: "Format", palette: "Format SQL",
                             symbol: "text.alignleft", tip: "Format SQL (⌃I)",
                             action: #selector(ContentViewController.menuFormatSQL(_:)))

        case .pharosNewTab:
            return imageItem(itemIdentifier, label: "New Tab", palette: "New Tab",
                             symbol: "plus", tip: "New Tab (⌘T)",
                             action: #selector(ContentViewController.menuNewTab(_:)))

        case .pharosSaveQuery:
            return imageItem(itemIdentifier, label: "Save", palette: "Save Query",
                             symbol: "square.and.arrow.down", tip: "Save Query… (⌘S)",
                             action: #selector(ContentViewController.menuSaveQuery(_:)))

        default:
            return nil
        }
    }

    /// An image item whose action goes up the responder chain, so it is
    /// validated and dispatched exactly like the menu item with the same
    /// selector.
    private func imageItem(_ identifier: NSToolbarItem.Identifier, label: String, palette: String,
                           symbol: String, tip: String, action: Selector) -> NSToolbarItem {
        let item = NSToolbarItem(itemIdentifier: identifier)
        item.label = label
        item.paletteLabel = palette
        item.toolTip = tip
        item.image = NSImage(systemSymbolName: symbol, accessibilityDescription: palette)
        item.isBordered = true
        item.target = nil
        item.action = action
        return item
    }

    func toolbarDefaultItemIdentifiers(_ toolbar: NSToolbar) -> [NSToolbarItem.Identifier] {
        [
            .toggleSidebar,
            .sidebarTrackingSeparator,
            .pharosConnection,
            .pharosRunQuery,
            .pharosCancelQuery,
            .flexibleSpace,
            .inspectorTrackingSeparator,
            .toggleInspector,
        ]
    }

    func toolbarAllowedItemIdentifiers(_ toolbar: NSToolbar) -> [NSToolbarItem.Identifier] {
        [
            .toggleSidebar,
            .sidebarTrackingSeparator,
            .pharosConnection,
            .pharosRunQuery,
            .pharosCancelQuery,
            .pharosFilterSidebar,
            .pharosFormatSQL,
            .pharosNewTab,
            .pharosSaveQuery,
            .space,
            .flexibleSpace,
            .inspectorTrackingSeparator,
            .toggleInspector,
        ]
    }
}

// MARK: - NSToolbarItemValidation

extension MainToolbarController: NSToolbarItemValidation {
    func validateToolbarItem(_ item: NSToolbarItem) -> Bool {
        switch item.itemIdentifier {
        case .pharosRunQuery: return contentVC?.canRunQuery ?? false
        default: return true
        }
    }
}

// MARK: - RunningQueriesPopoverDelegate

extension MainToolbarController: RunningQueriesPopoverDelegate {
    func runningQueriesPopover(_ vc: RunningQueriesPopoverVC, didRequestCancelQueryId id: String) {
        contentVC?.cancelQuery(id: id)
    }
}
