import AppKit
import UniformTypeIdentifiers

/// Runs an action once, when a connection's connect attempt ends connected;
/// an error ends the wait with no action. It owns its observer, so the
/// notification block captures only this main-actor object (Sendable) and the
/// id, not a mutable token or the app delegate.
@MainActor
private final class WhenConnected {
    private let connectionId: String
    private let action: @MainActor () -> Void
    private var observer: NSObjectProtocol?

    /// The observer's block keeps the object alive until the wait ends.
    static func run(connectionId: String, action: @escaping @MainActor () -> Void) {
        let waiter = WhenConnected(connectionId: connectionId, action: action)
        waiter.observer = NotificationCenter.default.addObserver(
            forName: AppStateManager.connectionStatusDidChange, object: nil, queue: .main
        ) { note in
            guard (note.userInfo?["connectionId"] as? String) == connectionId else { return }
            MainActor.assumeIsolated { waiter.statusChanged() }
        }
    }

    private init(connectionId: String, action: @escaping @MainActor () -> Void) {
        self.connectionId = connectionId
        self.action = action
    }

    private func statusChanged() {
        let status = AppStateManager.shared.status(for: connectionId)
        guard status == .connected || status == .error else { return }
        if let observer { NotificationCenter.default.removeObserver(observer) }
        observer = nil
        if status == .connected { action() }
    }
}

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
        // The panel holds its delegate weakly; this one lives as long as it.
        let guardDelegate = DuckDBNewPanelDelegate()
        panel.delegate = guardDelegate
        panel.begin { [weak self] response in
            withExtendedLifetime(guardDelegate) {}
            guard response == .OK, let url = panel.url else { return }
            // NSSavePanel has already asked about replacing an existing file.
            // DuckDB cannot open a file that is not a database, so the old one
            // goes; a NEW database was asked for.
            if FileManager.default.fileExists(atPath: url.path) {
                do {
                    for file in DuckDBFiles.databaseFiles(at: url) {
                        try FileManager.default.trashItem(at: file, resultingItemURL: nil)
                    }
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

    /// File ▸ New In-Memory DuckDB Database: a NEW in-memory record each
    /// time ("In-memory DuckDB", "In-memory DuckDB 2", …), in its own tab.
    /// Its tables live until it disconnects; Pharos asks before they go.
    @MainActor
    @objc func menuNewInMemoryDuckDB(_ sender: Any?) {
        let manager = AppStateManager.shared
        let record = ConnectionConfig.duckDB(path: ConnectionConfig.duckDBInMemoryPath,
                                             name: DuckDBFiles.uniqueInMemoryName(in: manager.connections))
        manager.saveConnection(record)
        openConnectionInTab(record)
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
            // A record names the file: offer to find it (Locate…), as Connect
            // does. No tab may show the record, so the choice then opens it
            // in its tab, as a file that is there would open.
            if let record = DuckDBFiles.record(for: DuckDBFiles.canonicalPath(url.path), in: AppStateManager.shared.connections) {
                PasswordPromptCoordinator.shared.offerMissingFile(record) { [weak self] record, create in
                    if create { AppStateManager.shared.allowCreateOnNextConnect(record.id) }
                    self?.openConnectionInTab(record, bringForward: !create)
                }
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
        // A data file chosen in Open DuckDB Database… is read, never saved as
        // a database record (it would be a broken one).
        if !create, DataFiles.isDataFile(url) {
            openDataFiles([url])
            return
        }
        let manager = AppStateManager.shared
        let path = DuckDBFiles.canonicalPath(url.path)
        let record: ConnectionConfig
        if let existing = DuckDBFiles.record(for: path, in: manager.connections) {
            record = existing
        } else {
            let made = ConnectionConfig.duckDB(path: path, name: DuckDBFiles.uniqueName(forPath: path, in: manager.connections))
            manager.saveConnection(made)
            record = made
        }
        RecentFileStore.shared.note([URL(fileURLWithPath: path)])
        if create { manager.allowCreateOnNextConnect(record.id) }
        // A new database is a new file: no tab shows it yet, whatever a tab
        // on the old file at this path holds.
        openConnectionInTab(record, bringForward: !create)
    }

    /// Data files from Finder, the Dock, ⌘O or Open DuckDB Database…: on a
    /// DuckDB tab, one card per file after the current one, `SELECT * FROM
    /// read_csv('<path>')`, run when the tab is connected.
    @MainActor
    func openDataFiles(_ urls: [URL]) {
        // Listed in File ▸ Open Recent and the Files navigator like a
        // database file (review D2 step 7); choosing one reads it again the
        // same way.
        RecentFileStore.shared.note(urls)
        if let content = keyWindowController?.splitViewController.contentVC ?? frontmostWindowController?.splitViewController.contentVC,
           content.isDuckDBTab {
            showMainWindow()
            content.addReadCards(for: urls)
            NSApp.activate()
            return
        }
        openDataFilesWithoutDuckDBTab(urls)
    }

    /// No DuckDB tab to read them in (decision 8): a NEW in-memory database
    /// in a new tab, with one read card per file. The cards run once the
    /// database is connected — a card started before that would fail.
    @MainActor
    func openDataFilesWithoutDuckDBTab(_ urls: [URL]) {
        let manager = AppStateManager.shared
        let record = ConnectionConfig.duckDB(path: ConnectionConfig.duckDBInMemoryPath,
                                             name: DuckDBFiles.uniqueInMemoryName(in: manager.connections))
        manager.saveConnection(record)
        let cards = urls.map { QueryCard(name: $0.lastPathComponent, sql: DataFiles.insertion(for: [$0], cardIsEmpty: true)) }
        var tab = QueryTab(name: record.name, connectionId: record.id, schemaName: record.effectiveDefaultSchema)
        tab.document = CardDocument(cards: cards)
        showMainWindow()
        let controller = frontmostWindowController.map { openTab(tab, beside: $0) } ?? openItem(tab)
        let session = controller.session
        let tabId = tab.id
        let ids = cards.map(\.id)
        // Run the cards when the new database is connected (once).
        WhenConnected.run(connectionId: record.id) { [weak self] in
            self?.contentController(for: session)?.runBatch(ids, inTab: tabId)
        }
        manager.useConnection(record.id, forTabId: tabId, in: session)
        NSApp.activate()
    }

    /// Put a connection in a tab and connect it.
    ///
    /// A DuckDB file is a document: a tab that already shows it comes forward
    /// (`bringForward`), as NSDocumentController does for an open document,
    /// and a tab on ANOTHER DuckDB database is never replaced, so opening
    /// three files gives three tabs. Otherwise the tab the user is in takes
    /// it when it is untouched (`openItem`), else a new tab beside it.
    @MainActor
    func openConnectionInTab(_ record: ConnectionConfig, bringForward: Bool = true) {
        let manager = AppStateManager.shared
        if record.isDuckDB, bringForward, let existing = windowShowing(record) {
            front(existing.session)
            if let tabId = existing.session.tab?.id {
                manager.useConnection(record.id, forTabId: tabId, in: existing.session)
            }
            manager.noteRecentDuckDBFile(record.id)
            NSApp.activate()
            return
        }
        showMainWindow()
        let tab = QueryTab(name: record.name, connectionId: record.id, schemaName: record.effectiveDefaultSchema)
        let current = frontmostWindowController
        let onOtherDuckDB = current?.session.tab?.connectionId.flatMap { id in
            manager.connections.first { $0.id == id }
        }.map { $0.isDuckDB && $0.id != record.id } ?? false
        let controller = record.isDuckDB && onOtherDuckDB ? openTab(tab, beside: current) : openItem(tab)
        manager.useConnection(record.id, forTabId: tab.id, in: controller.session)
        NSApp.activate()
    }

    /// The frontmost window whose tab shows this DuckDB file: the record
    /// itself, or another record on the same file.
    @MainActor
    private func windowShowing(_ record: ConnectionConfig) -> MainWindowController? {
        let path = record.isInMemoryDuckDB ? nil : DuckDBFiles.canonicalPath(record.database)
        let connections = AppStateManager.shared.connections
        func shows(_ controller: MainWindowController) -> Bool {
            guard let id = controller.session.tab?.connectionId else { return false }
            if id == record.id { return true }
            guard let path, let other = connections.first(where: { $0.id == id }), other.isDuckDB,
                  !other.isInMemoryDuckDB else { return false }
            return DuckDBFiles.canonicalPath(other.database) == path
        }
        let ordered = NSApp.orderedWindows.compactMap { $0.windowController as? MainWindowController }
        return ordered.first(where: shows) ?? windowControllers.first(where: shows)
    }
}

/// File ▸ Open Recent: the DuckDB files Pharos opened, newest first, from
/// `NSDocumentController`'s list (the Dock shows the same one). Pharos does
/// not adopt NSDocument, so the menu is filled here when it opens.
final class DuckDBRecentMenuDelegate: NSObject, NSMenuDelegate {
    static let shared = DuckDBRecentMenuDelegate()

    func menuNeedsUpdate(_ menu: NSMenu) {
        menu.removeAllItems()
        let urls = DuckDBFiles.recentFiles(NSDocumentController.shared.recentDocumentURLs,
                                           in: AppStateManager.shared.connections)
        let titles = DuckDBFiles.recentTitles(urls) { FileManager.default.displayName(atPath: $0.path) }
        for (url, title) in zip(urls, titles) {
            let item = NSMenuItem(title: DisplayEscape.escaped(title),
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

/// File ▸ New DuckDB Database…: refuses a place where a file Pharos has open
/// already is, and keeps the panel open. Replacing it would move the open
/// file to the Trash while its tabs go on writing into it.
final class DuckDBNewPanelDelegate: NSObject, NSOpenSavePanelDelegate {
    /// Runs before NSSavePanel asks whether to replace an existing file, so
    /// the user never agrees to a replace that Pharos then refuses.
    @MainActor
    func panel(_ sender: Any, userEnteredFilename filename: String, confirmed okFlag: Bool) -> String? {
        guard okFlag, let panel = sender as? NSSavePanel, let folder = panel.directoryURL else { return filename }
        var url = folder.appendingPathComponent(filename)
        if url.pathExtension.isEmpty, let ext = DuckDBFiles.contentType.preferredFilenameExtension {
            url.appendPathExtension(ext)
        }
        guard let error = Self.openFileError(url) else { return filename }
        NSAlert(error: error).beginSheetModal(for: panel)
        return nil
    }

    /// Second check, for a URL the panel reaches without a typed name.
    @MainActor
    func panel(_ sender: Any, validate url: URL) throws {
        if let error = Self.openFileError(url) { throw error }
    }

    @MainActor
    private static func openFileError(_ url: URL) -> NSError? {
        let manager = AppStateManager.shared
        let open = DuckDBFiles.openRecords(for: url.path, in: manager.connections) { id in
            let status = manager.status(for: id)
            return status == .connected || status == .connecting
        }
        if !open.isEmpty {
            return NSError(domain: NSCocoaErrorDomain, code: NSFileWriteFileExistsError, userInfo: [
                NSLocalizedDescriptionKey: String(localized: "“\(url.lastPathComponent)” is open in Pharos."),
                NSLocalizedRecoverySuggestionErrorKey: String(localized: "Disconnect it, or choose a different name."),
            ])
        }
        // Another app holding the file would go on writing the copy in the
        // Trash: a read-only open finds its lock first (review F4).
        guard FileManager.default.fileExists(atPath: url.path),
              let lock = PharosCore.duckDBLockHolder(path: url.path) else { return nil }
        let holder = DuckDBOpenError.holderPID(lock).flatMap { pid in
            PasswordPromptCoordinator.processName(pid).map { String(localized: "\($0) (process \(String(pid)))") }
                ?? String(localized: "Process \(String(pid))")
        } ?? String(localized: "Another app")
        return NSError(domain: NSCocoaErrorDomain, code: NSFileWriteFileExistsError, userInfo: [
            NSLocalizedDescriptionKey: String(localized: "“\(url.lastPathComponent)” is in use by \(holder)."),
            NSLocalizedRecoverySuggestionErrorKey: String(localized: "Close it in that app, or choose a different name."),
        ])
    }
}
