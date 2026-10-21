import AppKit
import UniformTypeIdentifiers

// MARK: - DuckDB files

/// File ▸ New DuckDB Database…, Open DuckDB Database…, Open Recent, and a
/// `.duckdb` file opened from Finder or the Dock. A file is a connection
/// record, found or made on demand (`DuckDBFiles.record`), so Sessions,
/// history and tabs treat it like any other connection.
extension AppDelegate {

    @MainActor
    @objc func menuNewDuckDBDatabase(_ sender: Any?) {
        let panel = NSSavePanel()
        panel.allowedContentTypes = [DuckDBFiles.contentType]
        panel.nameFieldStringValue = String(localized: "Untitled.duckdb")
        panel.prompt = String(localized: "Create")
        panel.message = String(localized: "Choose where to create the DuckDB database.")
        panel.begin { [weak self] response in
            guard response == .OK, let url = panel.url else { return }
            // NSSavePanel has already asked about replacing an existing file.
            // DuckDB cannot open a file that is not a database, so the old one
            // goes; a NEW database was asked for.
            if FileManager.default.fileExists(atPath: url.path) {
                do {
                    try FileManager.default.trashItem(at: url, resultingItemURL: nil)
                } catch {
                    NSAlert(error: error).runModal()
                    return
                }
            }
            // A new database was asked for: this is the one connect that may
            // create the file.
            self?.openDuckDBFile(url, create: true)
        }
    }

    @MainActor
    @objc func menuOpenDuckDBDatabase(_ sender: Any?) {
        let panel = NSOpenPanel()
        panel.canChooseFiles = true
        panel.canChooseDirectories = false
        panel.allowsMultipleSelection = true
        panel.message = String(localized: "Choose a DuckDB database file to open")
        panel.prompt = String(localized: "Open")
        panel.begin { [weak self] response in
            guard response == .OK else { return }
            for url in panel.urls { self?.openDuckDBFile(url) }
        }
    }

    /// Open Recent ▸ a file.
    @MainActor
    @objc func menuOpenRecentDuckDB(_ sender: NSMenuItem) {
        guard let url = sender.representedObject as? URL else { return }
        guard FileManager.default.fileExists(atPath: url.path) else {
            // A record names the file: offer to find it (Locate…), as Connect does.
            if let record = DuckDBFiles.record(for: DuckDBFiles.canonicalPath(url.path), in: AppStateManager.shared.connections) {
                PasswordPromptCoordinator.shared.offerMissingFile(record)
                return
            }
            let alert = NSAlert()
            alert.messageText = String(localized: "“\(url.lastPathComponent)” can’t be found.")
            alert.informativeText = String(localized: "It was moved or deleted since you last opened it.")
            alert.runModal()
            return
        }
        openDuckDBFile(url)
    }

    @MainActor
    @objc func menuClearRecentDuckDB(_ sender: Any?) {
        NSDocumentController.shared.clearRecentDocuments(sender)
    }

    /// Open a DuckDB file in a tab: the record that names it, or a new one.
    /// `create`: the user asked for a new database (File ▸ New), so the
    /// connect may create the file; any other connect refuses a missing file.
    @MainActor
    func openDuckDBFile(_ url: URL, create: Bool = false) {
        let manager = AppStateManager.shared
        let path = DuckDBFiles.canonicalPath(url.path)
        let record: ConnectionConfig
        if let existing = DuckDBFiles.record(for: path, in: manager.connections) {
            record = existing
        } else {
            let made = ConnectionConfig.duckDB(path: path)
            manager.saveConnection(made)
            record = made
        }
        NSDocumentController.shared.noteNewRecentDocumentURL(URL(fileURLWithPath: path))
        if create { manager.allowCreateOnNextConnect(record.id) }
        openConnectionInTab(record)
    }

    /// Put a connection in the tab the user is in when it is untouched, else
    /// in a new tab, and connect it.
    @MainActor
    func openConnectionInTab(_ record: ConnectionConfig) {
        showMainWindow()
        let tab = QueryTab(name: record.name, connectionId: record.id, schemaName: record.effectiveDefaultSchema)
        let controller = openItem(tab)
        AppStateManager.shared.useConnection(record.id, forTabId: tab.id, in: controller.session)
        NSApp.activate()
    }
}

/// File ▸ Open Recent: the DuckDB files Pharos opened, newest first, from
/// `NSDocumentController`'s list (the Dock shows the same one). Pharos does
/// not adopt NSDocument, so the menu is filled here when it opens.
final class DuckDBRecentMenuDelegate: NSObject, NSMenuDelegate {
    static let shared = DuckDBRecentMenuDelegate()

    func menuNeedsUpdate(_ menu: NSMenu) {
        menu.removeAllItems()
        let urls = NSDocumentController.shared.recentDocumentURLs.filter(DuckDBFiles.isDuckDBFile)
        for url in urls {
            let item = NSMenuItem(title: url.lastPathComponent,
                                  action: #selector(AppDelegate.menuOpenRecentDuckDB(_:)), keyEquivalent: "")
            item.representedObject = url
            item.toolTip = ConnectionConfig.abbreviatingHome(url.path)
            item.image = NSWorkspace.shared.icon(forFile: url.path)
            item.image?.size = NSSize(width: 16, height: 16)
            menu.addItem(item)
        }
        if !urls.isEmpty { menu.addItem(.separator()) }
        let clear = menu.addItem(withTitle: String(localized: "Clear Menu"),
                                 action: #selector(AppDelegate.menuClearRecentDuckDB(_:)), keyEquivalent: "")
        clear.isEnabled = !urls.isEmpty
    }
}
