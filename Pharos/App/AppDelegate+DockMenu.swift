import AppKit

/// Dock icon menu: New Tab, and one item per PostgreSQL connection and
/// in-memory DuckDB database that jumps straight to a fresh tab bound to it.
/// DuckDB files are left out: the Dock already lists them as recent
/// documents (File ▸ Open Recent's list), and a short custom menu is easier
/// to use.
extension AppDelegate {
    @MainActor
    func applicationDockMenu(_ sender: NSApplication) -> NSMenu? {
        let menu = NSMenu()
        menu.autoenablesItems = false

        let newTabItem = NSMenuItem(title: String(localized: "New Tab"), action: #selector(dockMenuNewTab(_:)), keyEquivalent: "")
        newTabItem.target = self
        menu.addItem(newTabItem)

        menu.addItem(.separator())

        let all = AppStateManager.shared.connections
        let connections = all.filter { !$0.isDuckDB || $0.isInMemoryDuckDB }
        if connections.isEmpty && !all.isEmpty {
            // Only DuckDB files: the Dock's recent documents list them.
            menu.removeItem(at: menu.numberOfItems - 1)
        } else if connections.isEmpty {
            let noneItem = NSMenuItem(title: String(localized: "No Connections"), action: nil, keyEquivalent: "")
            noneItem.isEnabled = false
            menu.addItem(noneItem)
        } else {
            for connection in connections {
                let item = NSMenuItem(title: connection.name, action: #selector(dockMenuUseConnection(_:)), keyEquivalent: "")
                item.target = self
                item.representedObject = connection.id
                menu.addItem(item)
            }
        }

        return menu
    }

    @MainActor
    @objc private func dockMenuNewTab(_ sender: Any?) {
        openTab(nil, beside: frontmostWindowController)
    }

    @MainActor
    @objc private func dockMenuUseConnection(_ sender: NSMenuItem) {
        guard let connectionId = sender.representedObject as? String else { return }
        let controller = openItem(QueryTab(name: AppStateManager.shared.nextTabName()))
        guard let tab = controller.session.tab else { return }
        AppStateManager.shared.useConnection(connectionId, forTabId: tab.id, in: controller.session)
    }
}
