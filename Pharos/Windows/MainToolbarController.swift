import AppKit
import Combine

extension NSToolbarItem.Identifier {
    static let pharosConnection = NSToolbarItem.Identifier("PharosConnection")
    static let pharosSchema = NSToolbarItem.Identifier("PharosSchema")
    static let pharosRunQuery = NSToolbarItem.Identifier("PharosRunQuery")
    static let pharosCancelQuery = NSToolbarItem.Identifier("PharosCancelQuery")
    static let pharosFilterSidebar = NSToolbarItem.Identifier("PharosFilterSidebar")
    static let pharosFormatSQL = NSToolbarItem.Identifier("PharosFormatSQL")
    static let pharosNewTab = NSToolbarItem.Identifier("PharosNewTab")
    static let pharosSaveQuery = NSToolbarItem.Identifier("PharosSaveQuery")
    /// The grouped navigator selector. Defined by the factory that builds it.
    static let pharosNavigator = NavigatorToolbarGroup.identifier
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
/// Default set, left to right: navigator group | tracking separator |
/// connection pull-down, schema pull-down, Run, Cancel | flexible space |
/// tracking separator | inspector toggle. The navigator group stands where the
/// sidebar toggle used to: it both picks the sidebar's list and, when the lit
/// segment is pressed again, collapses the pane — the way Calendar's
/// Calendars/Invites control behaves. The connection and schema pull-downs
/// are two adjacent items with the same bezel, so the pair reads as "this
/// database, this schema"; both follow the active tab. (Measured 2026-09-17: an
/// `NSToolbarItemGroup` of two view-based items gives each its own glass
/// platter, with the same 8pt gap as two separate items — a group would buy
/// nothing but a shared Customize Toolbar… entry.) Run is the one prominent
/// item and carries a badge with the count of running queries on the active
/// tab. Every item here has a menu command or an editor-side equivalent; the
/// toolbar adds nothing that cannot be reached another way.
///
/// The user can customize the toolbar (View > Customize Toolbar…). The
/// allowed-but-not-default items are the sidebar filter field, Format SQL,
/// New Tab and Save Query.
@MainActor
final class MainToolbarController: NSObject {

    /// The split view controller is the single source for the two panes and
    /// for the sidebar's collapse state; holding one weak reference instead of
    /// three keeps them from disagreeing.
    private weak var splitVC: PharosSplitViewController?
    private var contentVC: ContentViewController? { splitVC?.contentVC }
    private var sidebarVC: SidebarViewController? { splitVC?.sidebarVC }
    private let session: WindowSession
    private let stateManager = AppStateManager.shared
    private let metadataCache = MetadataCache.shared
    private var cancellables = Set<AnyCancellable>()

    /// One toolbar per window; the items are created on demand and kept
    /// weakly so state updates reach the live ones.
    private weak var toolbar: NSToolbar?
    private weak var runItem: NSToolbarItem?
    private weak var cancelItem: NSToolbarItem?
    private weak var navigatorItem: NSToolbarItemGroup?

    private let connectionButton = NSPopUpButton(frame: .zero, pullsDown: true)
    /// The schema for the active tab. Presents `SchemaSelectorPopoverVC` rather
    /// than a menu, so a long schema list scrolls and can be searched.
    private let schemaButton = SchemaPopUpButton(frame: .zero, pullsDown: true)
    private let schemaSpinner = NSProgressIndicator()
    private var schemaPopover: NSPopover?
    private let cancelButton = NSButton()
    private var runningQueriesPopover: NSPopover?
    private var runningQueriesPopoverCloseObserver: NSObjectProtocol?

    init(session: WindowSession, splitVC: PharosSplitViewController) {
        self.session = session
        self.splitVC = splitVC
        super.init()
        configureConnectionButton()
        configureSchemaButton()
        configureCancelButton()
        subscribe()
        // ⌥⌘1/2/3 go straight to the sidebar; this is how the group hears about
        // them. Weak, or the sidebar (owned by the window) would keep this
        // controller alive past `windowWillClose` and its `deinit` would never
        // remove the running-queries observer.
        splitVC.sidebarVC.onNavigatorChanged = { [weak self] navigator in
            self?.navigatorItem?.selectedIndex = navigator.rawValue
        }
    }

    deinit {
        if let observer = runningQueriesPopoverCloseObserver {
            NotificationCenter.default.removeObserver(observer)
        }
    }

    /// Installs a customizable toolbar on `window` with this object as delegate.
    func install(on window: NSWindow) {
        // "PharosToolbar3", not "PharosToolbar2". `autosavesConfiguration` is
        // on, and AppKit reconciles a saved configuration by DROPPING unknown
        // identifiers, never by adding new default ones — so a window that had
        // saved the old set would never show the schema pull-down (as, one
        // bump earlier, it would never have shown the navigator group). The
        // new name costs one reset of the user's own toolbar customisation,
        // display mode and size mode.
        let toolbar = NSToolbar(identifier: "PharosToolbar3")
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
        session.tabsSettled
            .removeDuplicates { lhs, rhs in
                guard lhs.count == rhs.count else { return false }
                for i in 0..<lhs.count {
                    if lhs[i].id != rhs[i].id
                        || lhs[i].connectionId != rhs[i].connectionId
                        || lhs[i].schemaName != rhs[i].schemaName
                        || lhs[i].runningQueries.count != rhs[i].runningQueries.count
                    {
                        return false
                    }
                }
                return true
            }
            .sink { [weak self] _ in self?.refresh() }
            .store(in: &cancellables)

        session.activeTabIdSettled
            .sink { [weak self] _ in self?.refresh() }
            .store(in: &cancellables)

        Publishers.CombineLatest(stateManager.$connections, stateManager.$connectionStatuses)
            .receive(on: RunLoop.main)
            .sink { [weak self] _, _ in self?.refresh() }
            .store(in: &cancellables)

        // The schema pull-down also follows the (app-wide) metadata cache; the
        // tab it describes is always THIS window's, through `session` above.
        Publishers.CombineLatest(metadataCache.$schemas, metadataCache.$isLoading)
            .receive(on: RunLoop.main)
            .sink { [weak self] _, _ in self?.refreshSchemaButton() }
            .store(in: &cancellables)
    }

    private func refresh() {
        rebuildConnectionMenu()
        refreshSchemaButton()
        updateRunState()
        toolbar?.validateVisibleItems()
    }

    private var activeTab: QueryTab? { session.activeTab }
    private var tabConnectionId: String? { activeTab?.connectionId }
    private var tabSchemaName: String? { activeTab?.schemaName }

    private func updateRunState() {
        let count = activeTab?.runningQueries.count ?? 0
        runItem?.badge = count > 0 ? .count(count) : nil
        cancelButton.toolTip = count > 1
            ? String(localized: "\(count) queries running — click to manage")
            : String(localized: "Cancel Query (⌘.)")
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

        let vc = RunningQueriesPopoverVC(session: session, tabId: tabId)
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
        connectionButton.setAccessibilityLabel(String(localized: "Connection"))
        connectionButton.setAccessibilityIdentifier("toolbar.connection")
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
            buttonTitle = String(localized: "No Connections")
        } else {
            buttonTitle = String(localized: "Select Connection")
        }
        connectionButton.addItem(withTitle: buttonTitle)
        if let activeId, let config = connections.first(where: { $0.id == activeId }),
           let titleItem = connectionButton.item(at: 0) {
            let status = stateManager.status(for: config.id)
            titleItem.attributedTitle = styledTitle(buttonTitle, status: status)
            // A failed connect carries its reason; "Connection error" alone
            // sent the user to the Connections window to find out why.
            let reason = status == .error
                ? stateManager.connectionError(for: config.id).map { DisplayEscape.escaped($0) }
                : nil
            connectionButton.toolTip = [
                DisplayEscape.escaped(config.name), statusName(for: status), reason,
            ].compactMap { $0 }.joined(separator: " — ")
            connectionButton.setAccessibilityValue(
                [statusName(for: status), reason].compactMap { $0 }.joined(separator: ", "))
        } else {
            connectionButton.toolTip = String(localized: "Connection for the active tab")
            connectionButton.setAccessibilityValue(nil)
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

            let connect = NSMenuItem(title: String(localized: "Connect"), action: #selector(connectSelected), keyEquivalent: "")
            connect.target = self
            connect.isEnabled = contentVC?.canConnect ?? false
            connectionButton.menu?.addItem(connect)

            let disconnect = NSMenuItem(title: String(localized: "Disconnect"), action: #selector(disconnectSelected), keyEquivalent: "")
            disconnect.target = self
            disconnect.isEnabled = contentVC?.canDisconnect ?? false
            connectionButton.menu?.addItem(disconnect)

            let refresh = NSMenuItem(title: String(localized: "Refresh Metadata"), action: #selector(refreshMetadata), keyEquivalent: "")
            refresh.target = self
            refresh.isEnabled = contentVC?.canRefreshMetadata ?? false
            connectionButton.menu?.addItem(refresh)
        }

        connectionButton.menu?.addItem(.separator())
        let manage = NSMenuItem(title: String(localized: "Manage Connections…"), action: #selector(showConnectionsManager), keyEquivalent: "")
        manage.target = self
        connectionButton.menu?.addItem(manage)
        connectionButton.menu?.autoenablesItems = false
    }

    /// One glyph per state, so the state reads without its colour
    /// (Differentiate Without Color, monochrome menus, VoiceOver text).
    private func statusString(for status: ConnectionStatus) -> String {
        switch status {
        case .connected: return "\u{25CF} "    // ● filled circle
        case .connecting: return "\u{25D0} "   // ◐ half circle
        case .error: return "\u{2715} "        // ✕ multiplication x
        case .disconnected: return "\u{25CB} " // ○ empty circle
        }
    }

    private func statusName(for status: ConnectionStatus) -> String {
        switch status {
        case .connected: return String(localized: "Connected")
        case .connecting: return String(localized: "Connecting")
        case .error: return String(localized: "Connection error")
        case .disconnected: return String(localized: "Disconnected")
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
        stateManager.useConnection(id, forTabId: tabId, in: session)
    }

    @objc private func connectSelected() { contentVC?.menuConnect(nil) }
    @objc private func disconnectSelected() { contentVC?.menuDisconnect(nil) }
    @objc private func refreshMetadata() { contentVC?.menuRefreshMetadata(nil) }
    @objc private func showConnectionsManager() { ConnectionsManagerWindowController.show() }

    // MARK: - Schema pull-down

    private func configureSchemaButton() {
        schemaButton.bezelStyle = .toolbar
        schemaButton.controlSize = .regular
        schemaButton.translatesAutoresizingMaskIntoConstraints = false
        (schemaButton.cell as? NSPopUpButtonCell)?.arrowPosition = .arrowAtBottom
        NSLayoutConstraint.activate([
            schemaButton.widthAnchor.constraint(greaterThanOrEqualToConstant: 100),
            schemaButton.widthAnchor.constraint(lessThanOrEqualToConstant: 180),
        ])
        schemaButton.toolTip = String(localized: "Schema for the active tab")
        schemaButton.setAccessibilityLabel(String(localized: "Schema"))
        schemaButton.setAccessibilityIdentifier("toolbar.schema")
        schemaButton.onActivate = { [weak self] button in
            self?.presentSchemaPopover(from: button)
        }

        // Spinner overlay for "Loading…"
        schemaSpinner.style = .spinning
        schemaSpinner.controlSize = .small
        schemaSpinner.isDisplayedWhenStopped = false
        schemaSpinner.translatesAutoresizingMaskIntoConstraints = false
        schemaButton.addSubview(schemaSpinner)
        NSLayoutConstraint.activate([
            schemaSpinner.trailingAnchor.constraint(equalTo: schemaButton.trailingAnchor, constant: -20),
            schemaSpinner.centerYAnchor.constraint(equalTo: schemaButton.centerYAnchor),
        ])
    }

    /// Title, enabled state and spinner from `SchemaButtonState` — the pure
    /// rule — fed from this window's active tab and the shared cache.
    private func refreshSchemaButton() {
        let connectionId = tabConnectionId
        let state = SchemaButtonState(
            hasConnection: connectionId != nil,
            isConnected: connectionId.map { stateManager.status(for: $0) == .connected } ?? false,
            isLoading: metadataCache.isLoading,
            hasSchemas: !metadataCache.schemas.isEmpty,
            activeSchema: tabSchemaName)

        // The button shows a single title item; the full schema list and the
        // "All Schemas" / "Set as Default" actions live in the popover.
        schemaButton.removeAllItems()
        schemaButton.addItem(withTitle: state.title)
        schemaButton.isEnabled = state.isEnabled
        schemaButton.setAccessibilityValue(state.title)
        if state.showsSpinner {
            schemaSpinner.startAnimation(nil)
        } else {
            schemaSpinner.stopAnimation(nil)
        }
    }

    /// Update the active tab's schema and the window's schema-following state
    /// (the Database Navigator reads `activeSchema`).
    private func setTabSchema(_ schemaName: String?) {
        guard let tab = activeTab else { return }
        session.updateTab(id: tab.id) { $0.schemaName = schemaName }
        session.activeSchema = schemaName
    }

    private func presentSchemaPopover(from button: NSView) {
        let schemaNames = metadataCache.schemas.map { $0.name }
        let defaultSchema: String? = {
            guard let connId = tabConnectionId else { return nil }
            return stateManager.connections.first(where: { $0.id == connId })?.defaultSchema
        }()

        let vc = SchemaSelectorPopoverVC(
            schemas: schemaNames,
            activeSchema: tabSchemaName,
            defaultSchema: defaultSchema
        )
        vc.onSelectSchema = { [weak self] schema in
            self?.setTabSchema(schema)
            self?.schemaPopover?.close()
        }
        vc.onSetDefault = { [weak self] in
            self?.setDefaultSchema()
            self?.schemaPopover?.close()
        }

        let popover = NSPopover()
        popover.contentViewController = vc
        popover.behavior = .transient
        popover.show(relativeTo: button.bounds, of: button, preferredEdge: .maxY)
        schemaPopover = popover
    }

    /// The tab's current schema becomes the connection's default (nil — "All
    /// Schemas" — clears it). The connection store republishes, which
    /// refreshes this button.
    private func setDefaultSchema() {
        guard let connId = tabConnectionId,
              var config = stateManager.connections.first(where: { $0.id == connId }) else { return }
        config.defaultSchema = tabSchemaName
        stateManager.saveConnection(config)
    }

    // MARK: - Navigator group

    /// The sidebar's navigator group was pressed.
    ///
    /// Pressing the segment that is already lit collapses the sidebar, and
    /// pressing it again brings it back — Calendar's behaviour. Any other
    /// segment shows the sidebar on that list.
    @objc private func navigatorChanged(_ sender: NSToolbarItemGroup) {
        guard let splitVC,
              let sidebarVC,
              let navigator = NavigatorToolbarGroup.navigator(forSelectedIndex: sender.selectedIndex)
        else { return }

        if navigator == sidebarVC.currentNavigator && !splitVC.isSidebarCollapsed {
            splitVC.setSidebarCollapsed(true)
        } else {
            splitVC.setSidebarCollapsed(false)
            sidebarVC.showNavigator(navigator)
        }
    }

    /// Lights the segment for the navigator on screen.
    ///
    /// The lit segment deliberately stays lit while the sidebar is hidden: it
    /// then reads as "the list the sidebar will come back on", which is
    /// already how the View ▸ Navigators menu items behave (they keep their
    /// checkmark when the pane is collapsed). It is also the only option —
    /// measured live, `NSToolbarItemGroup` in `.selectOne` mode ignores
    /// `selectedIndex = -1` and keeps the previous segment lit, with or
    /// without the macOS 27 `.tabs` role.
    private func syncNavigatorSelection(group: NSToolbarItemGroup? = nil) {
        guard let group = group ?? navigatorItem, let sidebarVC else { return }
        group.selectedIndex = sidebarVC.currentNavigator.rawValue
    }

    // MARK: - Cancel button

    private func configureCancelButton() {
        cancelButton.bezelStyle = .toolbar
        // Run beside it is prominent; a second bezel at rest made the pair
        // read as two equal calls to action. The bezel comes back under the
        // pointer, so the target is still visible when it matters.
        cancelButton.showsBorderOnlyWhileMouseInside = true
        cancelButton.image = NSImage(systemSymbolName: "stop.fill", accessibilityDescription: String(localized: "Cancel Query"))
        cancelButton.imagePosition = .imageOnly
        cancelButton.target = self
        cancelButton.action = #selector(cancelTapped(_:))
        cancelButton.toolTip = String(localized: "Cancel Query (⌘.)")
        cancelButton.setAccessibilityLabel(String(localized: "Cancel Query"))
        cancelButton.setAccessibilityIdentifier("toolbar.cancel")
    }
}

// MARK: - NSToolbarDelegate

extension MainToolbarController: NSToolbarDelegate {

    func toolbar(_ toolbar: NSToolbar, itemForItemIdentifier itemIdentifier: NSToolbarItem.Identifier, willBeInsertedIntoToolbar flag: Bool) -> NSToolbarItem? {
        switch itemIdentifier {
        case .toggleSidebar, .sidebarTrackingSeparator, .flexibleSpace, .space,
             .inspectorTrackingSeparator, .toggleInspector:
            return NSToolbarItem(itemIdentifier: itemIdentifier)

        case .pharosNavigator:
            let group = NavigatorToolbarGroup.make(target: self,
                                                   action: #selector(navigatorChanged(_:)))
            if flag {
                navigatorItem = group
                // Seeded HERE, not from the sidebar's change callback. The
                // sidebar restores its last navigator in `loadView`, which runs
                // when the window's content view controller is set — before this
                // controller exists — so the callback would fire into nothing and
                // the group would always launch lit on Query Library.
                syncNavigatorSelection(group: group)
            }
            return group

        case .pharosConnection:
            let item = NSToolbarItem(itemIdentifier: itemIdentifier)
            item.label = String(localized: "Connection")
            item.paletteLabel = String(localized: "Connection")
            item.toolTip = String(localized: "Connection for the active tab")
            item.view = connectionButton
            item.visibilityPriority = .high
            if flag { rebuildConnectionMenu() }
            return item

        case .pharosSchema:
            let item = NSToolbarItem(itemIdentifier: itemIdentifier)
            item.label = String(localized: "Schema")
            item.paletteLabel = String(localized: "Schema")
            item.toolTip = String(localized: "Schema for the active tab")
            item.view = schemaButton
            // `.standard`, below Run/Cancel/Connection's `.high`: in a narrow
            // window the schema goes to the overflow menu before they do.
            item.visibilityPriority = .standard
            if flag { refreshSchemaButton() }
            return item

        case .pharosRunQuery:
            let item = NSToolbarItem(itemIdentifier: itemIdentifier)
            item.label = String(localized: "Run")
            item.paletteLabel = String(localized: "Run Query")
            item.toolTip = String(localized: "Run Query (⌘↩)")
            item.image = NSImage(systemSymbolName: "play.fill", accessibilityDescription: String(localized: "Run Query"))
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
            item.label = String(localized: "Cancel")
            item.paletteLabel = String(localized: "Cancel Query")
            item.view = cancelButton
            item.isEnabledProvider = { [weak self] in self?.contentVC?.canCancelQuery ?? false }
            item.visibilityPriority = .high
            if flag { cancelItem = item }
            return item

        case .pharosFilterSidebar:
            let item = NSSearchToolbarItem(itemIdentifier: itemIdentifier)
            item.label = String(localized: "Filter")
            item.paletteLabel = String(localized: "Filter Sidebar")
            item.toolTip = String(localized: "Filter the sidebar list")
            item.searchField.placeholderString = String(localized: "Filter")
            item.searchField.sendsSearchStringImmediately = true
            item.searchField.sendsWholeSearchString = false
            item.searchField.target = self
            item.searchField.action = #selector(filterChanged(_:))
            item.preferredWidthForSearchField = 180
            return item

        case .pharosFormatSQL:
            return imageItem(itemIdentifier, label: String(localized: "Format"), palette: String(localized: "Format SQL"),
                             symbol: "text.alignleft", tip: String(localized: "Format SQL (⌃I)"),
                             action: #selector(ContentViewController.menuFormatSQL(_:)))

        case .pharosNewTab:
            return imageItem(itemIdentifier, label: String(localized: "New Tab"), palette: String(localized: "New Tab"),
                             symbol: "plus", tip: String(localized: "New Tab (⌘T)"),
                             action: #selector(ContentViewController.menuNewTab(_:)))

        case .pharosSaveQuery:
            return imageItem(itemIdentifier, label: String(localized: "Save"), palette: String(localized: "Save Query"),
                             symbol: "square.and.arrow.down", tip: String(localized: "Save Query… (⌘S)"),
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
            .pharosNavigator,
            .sidebarTrackingSeparator,
            .pharosConnection,
            .pharosSchema,
            .pharosRunQuery,
            .pharosCancelQuery,
            .flexibleSpace,
            .inspectorTrackingSeparator,
            .toggleInspector,
        ]
    }

    func toolbarAllowedItemIdentifiers(_ toolbar: NSToolbar) -> [NSToolbarItem.Identifier] {
        [
            .pharosNavigator,
            // Still offered in Customize Toolbar… for anyone who wants a plain
            // toggle back. ⌃⌘S works either way; it goes to the split view
            // controller, never to a toolbar item.
            .toggleSidebar,
            .sidebarTrackingSeparator,
            .pharosConnection,
            .pharosSchema,
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
