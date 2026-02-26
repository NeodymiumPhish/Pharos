import AppKit
import Combine

// MARK: - Toolbar Item Identifiers

private extension NSToolbarItem.Identifier {
    static let connectionPopup = NSToolbarItem.Identifier("ConnectionPopup")
    static let schemaPopup = NSToolbarItem.Identifier("SchemaPopup")
    static let runQuery = NSToolbarItem.Identifier("RunQuery")
    static let formatQuery = NSToolbarItem.Identifier("FormatQuery")
}

class MainWindowController: NSWindowController {

    let splitViewController = PharosSplitViewController()
    private let stateManager = AppStateManager.shared
    private let metadataCache = MetadataCache.shared
    private var cancellables = Set<AnyCancellable>()
    private weak var connectionPopup: NSPopUpButton?
    private weak var schemaPopup: NSPopUpButton?
    private weak var schemaSpinner: NSProgressIndicator?

    init() {
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 1200, height: 800),
            styleMask: [.titled, .closable, .miniaturizable, .resizable, .fullSizeContentView],
            backing: .buffered,
            defer: false
        )
        window.title = "Pharos"
        window.titleVisibility = .hidden
        window.toolbarStyle = .unified
        window.setFrameAutosaveName("PharosMainWindow")
        window.minSize = NSSize(width: 800, height: 400)
        window.center()

        super.init(window: window)

        window.contentViewController = splitViewController

        // Setup toolbar
        let toolbar = NSToolbar(identifier: "PharosToolbar")
        toolbar.delegate = self
        toolbar.displayMode = .iconOnly
        window.toolbar = toolbar

        // Observe connection changes
        stateManager.$connections
            .receive(on: RunLoop.main)
            .sink { [weak self] _ in self?.updateConnectionPopup() }
            .store(in: &cancellables)

        stateManager.$activeConnectionId
            .receive(on: RunLoop.main)
            .sink { [weak self] _ in
                self?.updateConnectionPopup()
                self?.updateSchemaPopup()
            }
            .store(in: &cancellables)

        stateManager.$connectionStatuses
            .receive(on: RunLoop.main)
            .sink { [weak self] _ in self?.updateConnectionPopup() }
            .store(in: &cancellables)

        // Observe schema metadata for schema popup
        metadataCache.$schemas
            .receive(on: RunLoop.main)
            .sink { [weak self] _ in self?.updateSchemaPopup() }
            .store(in: &cancellables)

        stateManager.$activeSchema
            .receive(on: RunLoop.main)
            .sink { [weak self] _ in self?.updateSchemaPopup() }
            .store(in: &cancellables)

        metadataCache.$isLoading
            .receive(on: RunLoop.main)
            .sink { [weak self] loading in self?.updateSchemaLoading(loading) }
            .store(in: &cancellables)
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) not implemented")
    }

    // MARK: - Connection Popup (Pull-Down Button)

    private func updateConnectionPopup() {
        guard let popup = connectionPopup else { return }
        rebuildConnectionMenu(popup)
    }

    private func rebuildConnectionMenu(_ popup: NSPopUpButton) {
        popup.removeAllItems()

        let connections = stateManager.connections
        let activeId = stateManager.activeConnectionId

        // First item in a pull-down button is the button's displayed title
        let buttonTitle: String
        if let activeId,
           let config = connections.first(where: { $0.id == activeId }) {
            let status = stateManager.status(for: config.id)
            let statusIcon = statusString(for: status)
            buttonTitle = "\(statusIcon)\(config.name)"
        } else if connections.isEmpty {
            buttonTitle = "No Connections"
        } else {
            buttonTitle = "Select Connection"
        }
        popup.addItem(withTitle: buttonTitle)
        popup.isEnabled = true

        // Style the title item with colored status indicator
        if let activeId,
           let config = connections.first(where: { $0.id == activeId }) {
            let status = stateManager.status(for: config.id)
            if let titleItem = popup.item(at: 0) {
                titleItem.attributedTitle = styledTitle(buttonTitle, status: status)
            }
        }

        if !connections.isEmpty {
            // Connection items — each with its own action
            popup.menu?.addItem(.separator())
            for config in connections {
                let status = stateManager.status(for: config.id)
                let icon = statusString(for: status)
                let title = "\(icon)\(config.name)"
                let menuItem = NSMenuItem(title: title, action: #selector(connectionItemClicked(_:)), keyEquivalent: "")
                menuItem.target = self
                menuItem.representedObject = config.id
                menuItem.attributedTitle = styledTitle(title, status: status)
                // Checkmark on active connection
                if config.id == activeId {
                    menuItem.state = .on
                }
                popup.menu?.addItem(menuItem)
            }

            // Management items
            popup.menu?.addItem(.separator())

            let connectItem = NSMenuItem(title: "Connect", action: #selector(connectSelected), keyEquivalent: "")
            connectItem.target = self
            popup.menu?.addItem(connectItem)

            let disconnectItem = NSMenuItem(title: "Disconnect", action: #selector(disconnectSelected), keyEquivalent: "")
            disconnectItem.target = self
            popup.menu?.addItem(disconnectItem)

            popup.menu?.addItem(.separator())

            let editItem = NSMenuItem(title: "Edit Connection...", action: #selector(editConnection), keyEquivalent: "")
            editItem.target = self
            popup.menu?.addItem(editItem)

            let deleteItem = NSMenuItem(title: "Delete Connection", action: #selector(deleteConnection), keyEquivalent: "")
            deleteItem.target = self
            popup.menu?.addItem(deleteItem)
        }

        // Always show "New Connection..." at the bottom
        popup.menu?.addItem(.separator())
        let newItem = NSMenuItem(title: "New Connection...", action: #selector(showAddConnectionSheet), keyEquivalent: "")
        newItem.target = self
        popup.menu?.addItem(newItem)
    }

    // MARK: - Schema Popup

    private func updateSchemaPopup() {
        guard let popup = schemaPopup else { return }
        rebuildSchemaMenu(popup)
    }

    private func rebuildSchemaMenu(_ popup: NSPopUpButton) {
        popup.removeAllItems()

        let schemas = metadataCache.schemas
        let activeSchema = stateManager.activeSchema

        // Check if we have a connected database with schemas
        let isConnected: Bool
        if let activeId = stateManager.activeConnectionId {
            isConnected = stateManager.status(for: activeId) == .connected
        } else {
            isConnected = false
        }

        guard isConnected, !schemas.isEmpty else {
            popup.addItem(withTitle: "No Schema")
            popup.isEnabled = false
            return
        }

        popup.isEnabled = true

        // Title item (pull-down: first item is the displayed title)
        let titleText = activeSchema ?? "All Schemas"
        popup.addItem(withTitle: titleText)

        // "All Schemas" option
        let allItem = NSMenuItem(title: "All Schemas", action: #selector(schemaItemClicked(_:)), keyEquivalent: "")
        allItem.target = self
        allItem.representedObject = nil
        if activeSchema == nil { allItem.state = .on }
        popup.menu?.addItem(allItem)

        popup.menu?.addItem(.separator())

        // Individual schema items
        for schema in schemas {
            let item = NSMenuItem(title: schema.name, action: #selector(schemaItemClicked(_:)), keyEquivalent: "")
            item.target = self
            item.representedObject = schema.name
            if activeSchema == schema.name { item.state = .on }
            popup.menu?.addItem(item)
        }
    }

    @objc private func schemaItemClicked(_ sender: NSMenuItem) {
        stateManager.activeSchema = sender.representedObject as? String
    }

    private func updateSchemaLoading(_ loading: Bool) {
        guard let popup = schemaPopup else { return }
        if loading {
            popup.removeAllItems()
            popup.addItem(withTitle: "Loading\u{2026}")
            popup.isEnabled = false
            schemaSpinner?.startAnimation(nil)
        } else {
            schemaSpinner?.stopAnimation(nil)
            rebuildSchemaMenu(popup)
        }
    }

    // MARK: - Styled Titles

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

    // MARK: - Connection Actions

    private func selectedConnectionId() -> String? {
        stateManager.activeConnectionId
    }

    @objc private func connectionItemClicked(_ sender: NSMenuItem) {
        guard let id = sender.representedObject as? String else { return }
        stateManager.activeConnectionId = id
        // Auto-connect if not already connected
        let status = stateManager.status(for: id)
        if status == .disconnected {
            stateManager.connect(id: id)
        }
    }

    @objc private func connectSelected() {
        guard let id = selectedConnectionId() else { return }
        stateManager.connect(id: id)
    }

    @objc private func disconnectSelected() {
        guard let id = selectedConnectionId() else { return }
        stateManager.disconnect(id: id)
    }

    @objc func showAddConnectionSheet() {
        let sheet = ConnectionSheet.forNew { [weak self] config in
            self?.stateManager.saveConnection(config)
        }
        window?.contentViewController?.presentAsSheet(sheet)
    }

    @objc private func editConnection() {
        guard let id = selectedConnectionId(),
              let config = stateManager.connections.first(where: { $0.id == id }) else { return }
        let sheet = ConnectionSheet.forEdit(config) { [weak self] updated in
            self?.stateManager.saveConnection(updated)
        }
        window?.contentViewController?.presentAsSheet(sheet)
    }

    @objc private func deleteConnection() {
        guard let id = selectedConnectionId(),
              let config = stateManager.connections.first(where: { $0.id == id }) else { return }

        let alert = NSAlert()
        alert.messageText = "Delete \"\(config.name)\"?"
        alert.informativeText = "This will remove the connection and its saved password."
        alert.alertStyle = .warning
        alert.addButton(withTitle: "Delete")
        alert.addButton(withTitle: "Cancel")

        guard let window else { return }
        alert.beginSheetModal(for: window) { response in
            if response == .alertFirstButtonReturn {
                self.stateManager.deleteConnection(id: id)
            }
        }
    }
}

// MARK: - NSToolbarDelegate

extension MainWindowController: NSToolbarDelegate {

    func toolbar(_ toolbar: NSToolbar, itemForItemIdentifier itemIdentifier: NSToolbarItem.Identifier, willBeInsertedIntoToolbar flag: Bool) -> NSToolbarItem? {
        switch itemIdentifier {
        case .toggleSidebar:
            let item = NSToolbarItem(itemIdentifier: .toggleSidebar)
            item.label = "Toggle Sidebar"
            item.image = NSImage(systemSymbolName: "sidebar.leading", accessibilityDescription: "Toggle Sidebar")
            item.action = #selector(NSSplitViewController.toggleSidebar(_:))
            return item

        case .connectionPopup:
            let item = NSToolbarItem(itemIdentifier: .connectionPopup)
            item.label = "Connection"
            let popup = NSPopUpButton(frame: NSRect(x: 0, y: 0, width: 200, height: 24), pullsDown: true)
            popup.bezelStyle = .texturedRounded
            (popup.cell as? NSPopUpButtonCell)?.arrowPosition = .arrowAtBottom
            item.view = popup
            popup.widthAnchor.constraint(greaterThanOrEqualToConstant: 180).isActive = true
            popup.widthAnchor.constraint(lessThanOrEqualToConstant: 260).isActive = true
            self.connectionPopup = popup
            rebuildConnectionMenu(popup)
            return item

        case .schemaPopup:
            let item = NSToolbarItem(itemIdentifier: .schemaPopup)
            item.label = "Schema"
            let popup = NSPopUpButton(frame: NSRect(x: 0, y: 0, width: 140, height: 24), pullsDown: true)
            popup.bezelStyle = .texturedRounded
            (popup.cell as? NSPopUpButtonCell)?.arrowPosition = .arrowAtBottom
            item.view = popup
            popup.widthAnchor.constraint(greaterThanOrEqualToConstant: 120).isActive = true
            popup.widthAnchor.constraint(lessThanOrEqualToConstant: 200).isActive = true

            let spinner = NSProgressIndicator()
            spinner.style = .spinning
            spinner.controlSize = .small
            spinner.isDisplayedWhenStopped = false
            spinner.translatesAutoresizingMaskIntoConstraints = false
            popup.addSubview(spinner)
            NSLayoutConstraint.activate([
                spinner.trailingAnchor.constraint(equalTo: popup.trailingAnchor, constant: -20),
                spinner.centerYAnchor.constraint(equalTo: popup.centerYAnchor),
            ])

            self.schemaPopup = popup
            self.schemaSpinner = spinner
            rebuildSchemaMenu(popup)
            return item

        case .runQuery:
            let item = NSToolbarItem(itemIdentifier: .runQuery)
            item.label = "Run"
            item.image = NSImage(systemSymbolName: "play.fill", accessibilityDescription: "Run Query")
            item.toolTip = "Execute query (Cmd+Return)"
            item.action = #selector(ContentViewController.menuRunQuery(_:))
            return item

        case .formatQuery:
            let item = NSToolbarItem(itemIdentifier: .formatQuery)
            item.label = "Format"
            item.image = NSImage(systemSymbolName: "text.alignleft", accessibilityDescription: "Format SQL")
            item.toolTip = "Format SQL (Ctrl+I)"
            item.action = #selector(ContentViewController.menuFormatSQL(_:))
            return item

        case .toggleInspector:
            let item = NSToolbarItem(itemIdentifier: .toggleInspector)
            item.label = "Inspector"
            item.image = NSImage(systemSymbolName: "sidebar.trailing",
                                 accessibilityDescription: "Toggle Inspector")
            item.action = #selector(NSSplitViewController.toggleInspector(_:))
            return item

        case .flexibleSpace:
            return NSToolbarItem(itemIdentifier: .flexibleSpace)

        default:
            return nil
        }
    }

    func toolbarDefaultItemIdentifiers(_ toolbar: NSToolbar) -> [NSToolbarItem.Identifier] {
        return [
            .toggleSidebar,
            .connectionPopup,
            .schemaPopup,
            .formatQuery,
            .runQuery,
            .flexibleSpace,
            .toggleInspector,
        ]
    }

    func toolbarAllowedItemIdentifiers(_ toolbar: NSToolbar) -> [NSToolbarItem.Identifier] {
        return [
            .toggleSidebar,
            .connectionPopup,
            .schemaPopup,
            .formatQuery,
            .runQuery,
            .flexibleSpace,
            .toggleInspector,
        ]
    }
}
