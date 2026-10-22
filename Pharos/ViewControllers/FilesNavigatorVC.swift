import AppKit
import Combine
import UniformTypeIdentifiers

/// The sidebar's Files navigator: the DuckDB databases and data files the user
/// opened, in three sections (`FilesListRule`): Open, Recent, and Older (not
/// opened in the last 60 days; collapsed until the user opens it).
///
/// Double-click opens a row the way File ▸ Open Recent does. A row drags out
/// as a file URL, so a drop on a DuckDB tab's editor inserts a reference to
/// it; files dropped on the list open. The right-click menu acts on the
/// clicked row, or on the selection when the clicked row is part of it.
final class FilesNavigatorVC: NSViewController {

    private enum Item {
        case header(FilesListRule.Section, count: Int)
        case file(FilesListRule.Row)
    }

    private let scrollView = NSScrollView()
    private let tableView = NSTableView()
    private let emptyState = EmptyStateView()
    private var items: [Item] = []
    private var sections: [(section: FilesListRule.Section, rows: [FilesListRule.Row])] = []
    private var filterText = ""
    private var cancellables = Set<AnyCancellable>()
    private var observers: [NSObjectProtocol] = []
    private let stateManager = AppStateManager.shared

    private static let olderExpandedKey = "FilesNavigatorOlderExpanded"
    private var olderExpanded: Bool {
        get { UserDefaults.standard.bool(forKey: Self.olderExpandedKey) }
        set { UserDefaults.standard.set(newValue, forKey: Self.olderExpandedKey) }
    }

    /// Does a file exist? Network volumes count as present: a stat on one that
    /// stopped answering can block (the same rule as the connection pop-up).
    var fileExists: (String) -> Bool = { path in
        guard !path.hasPrefix("/Volumes/"), !path.hasPrefix("/net/") else { return true }
        return FileManager.default.fileExists(atPath: path)
    }

    deinit {
        for observer in observers { NotificationCenter.default.removeObserver(observer) }
    }

    override func loadView() {
        let container = NSView()
        view = container

        let column = NSTableColumn(identifier: NSUserInterfaceItemIdentifier("file"))
        tableView.addTableColumn(column)
        tableView.headerView = nil
        tableView.style = .sourceList
        tableView.rowSizeStyle = .default
        tableView.allowsMultipleSelection = true
        tableView.dataSource = self
        tableView.delegate = self
        tableView.target = self
        tableView.doubleAction = #selector(doubleClicked(_:))
        tableView.action = #selector(clicked(_:))
        let menu = NSMenu()
        menu.delegate = self
        tableView.menu = menu
        tableView.setAccessibilityIdentifier("sidebar.files.list")
        tableView.setAccessibilityLabel(String(localized: "Files"))
        // Out: a row is a file URL. In: files from Finder open.
        tableView.setDraggingSourceOperationMask(.copy, forLocal: false)
        tableView.setDraggingSourceOperationMask(.copy, forLocal: true)
        tableView.registerForDraggedTypes([.fileURL])

        scrollView.documentView = tableView
        scrollView.hasVerticalScroller = true
        scrollView.autohidesScrollers = true
        scrollView.drawsBackground = false
        scrollView.contentView.drawsBackground = false
        tableView.backgroundColor = .clear

        for v in [scrollView, emptyState] as [NSView] {
            v.translatesAutoresizingMaskIntoConstraints = false
            container.addSubview(v)
            NSLayoutConstraint.activate([
                v.topAnchor.constraint(equalTo: container.topAnchor),
                v.leadingAnchor.constraint(equalTo: container.leadingAnchor),
                v.trailingAnchor.constraint(equalTo: container.trailingAnchor),
                v.bottomAnchor.constraint(equalTo: container.bottomAnchor),
            ])
        }
        emptyState.show(symbol: "doc.on.doc", title: String(localized: "No Files"),
                        message: String(localized: "Open a DuckDB database or a data file, or drop one here."))

        observers.append(NotificationCenter.default.addObserver(
            forName: RecentFileStore.didChange, object: nil, queue: .main) { [weak self] _ in
                MainActor.assumeIsolated { self?.reload() }
            })
        // A tab that starts or stops using a file changes which rows are open.
        observers.append(NotificationCenter.default.addObserver(
            forName: NSWindow.didBecomeMainNotification, object: nil, queue: .main) { [weak self] _ in
                MainActor.assumeIsolated { self?.reload() }
            })
        stateManager.$connections.combineLatest(stateManager.$connectionStatuses)
            .receive(on: RunLoop.main)
            .sink { [weak self] _ in self?.reload() }
            .store(in: &cancellables)
        reload()
    }

    // MARK: - Data

    func reload() {
        let records = stateManager.connections
        let open = stateManager.connectionIdsInUse.union(
            stateManager.connectionStatuses.filter { $0.value == .connected || $0.value == .connecting }.map(\.key))
        sections = FilesListRule.sections(
            files: RecentFileStore.shared.files, records: records, openRecordIds: open,
            recordForPath: { DuckDBFiles.record(for: DuckDBFiles.canonicalPath($0), in: records) }, now: Date())
        rebuildItems()
    }

    private func rebuildItems() {
        let needle = filterText.lowercased()
        var built: [Item] = []
        for (section, rows) in sections {
            let shown = needle.isEmpty ? rows : rows.filter {
                $0.title.lowercased().contains(needle) || ($0.path?.lowercased().contains(needle) ?? false)
            }
            guard !shown.isEmpty else { continue }
            built.append(.header(section, count: shown.count))
            // Older stays closed until opened; a filter opens it, so a match
            // is never hidden.
            if section == .older && !olderExpanded && needle.isEmpty { continue }
            built.append(contentsOf: shown.map { Item.file($0) })
        }
        items = built
        tableView.reloadData()
        // The empty state is for an empty list, not for a filter that matches
        // nothing.
        emptyState.isHidden = !sections.isEmpty
        scrollView.isHidden = sections.isEmpty
    }

    func applyFilter(_ text: String) {
        filterText = text
        rebuildItems()
    }

    func clearFilter() {
        guard !filterText.isEmpty else { return }
        filterText = ""
        rebuildItems()
    }

    private func row(at index: Int) -> FilesListRule.Row? {
        guard items.indices.contains(index), case .file(let row) = items[index] else { return nil }
        return row
    }

    /// The rows a right-click acts on: the selection when the clicked row is
    /// part of it, else the clicked row alone.
    private func targetRows() -> [FilesListRule.Row] {
        let clicked = tableView.clickedRow
        let indexes = tableView.selectedRowIndexes.contains(clicked) ? Array(tableView.selectedRowIndexes) : [clicked]
        return indexes.compactMap(row(at:))
    }

    private func record(_ id: String?) -> ConnectionConfig? {
        id.flatMap { id in stateManager.connections.first { $0.id == id } }
    }

    private var appDelegate: AppDelegate? { NSApp.delegate as? AppDelegate }

    // MARK: - Actions

    @objc private func clicked(_ sender: Any?) {
        let index = tableView.clickedRow
        guard items.indices.contains(index), case .header(.older, _) = items[index] else { return }
        olderExpanded.toggle()
        rebuildItems()
    }

    @objc private func doubleClicked(_ sender: Any?) {
        guard let row = row(at: tableView.clickedRow) else { return }
        open(row)
    }

    private func open(_ row: FilesListRule.Row) {
        if row.kind == .memory {
            if let record = record(row.recordId) { appDelegate?.openConnectionInTab(record) }
        } else if let path = row.path {
            appDelegate?.openRecentFile(URL(fileURLWithPath: path))
        }
    }

    @objc private func menuOpen(_ sender: Any?) { targetRows().forEach(open) }

    @objc private func menuOpenInNewTab(_ sender: Any?) {
        guard let delegate = appDelegate else { return }
        for row in targetRows() {
            guard let record = record(row.recordId) else { continue }
            let tab = QueryTab(name: stateManager.nextTabName(), connectionId: record.id,
                               schemaName: record.effectiveDefaultSchema)
            let controller = delegate.openTab(tab, beside: delegate.frontmostWindowController)
            stateManager.useConnection(record.id, forTabId: tab.id, in: controller.session)
        }
    }

    @objc private func menuShowInFinder(_ sender: Any?) {
        let urls = targetRows().compactMap(\.path).map { URL(fileURLWithPath: $0) }
        let present = urls.filter { fileExists($0.path) }
        if !present.isEmpty {
            NSWorkspace.shared.activateFileViewerSelecting(present)
        } else if let folder = urls.first?.deletingLastPathComponent(), fileExists(folder.path) {
            NSWorkspace.shared.open(folder)
        } else {
            NSSound.beep()
        }
    }

    @objc private func menuCopyPath(_ sender: Any?) {
        let paths = targetRows().compactMap(\.path)
        guard !paths.isEmpty else { return }
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(paths.joined(separator: "\n"), forType: .string)
    }

    @objc private func menuSaveAsConnection(_ sender: Any?) {
        for row in targetRows() where !row.saved {
            if let id = row.recordId { stateManager.setSaved(true, id: id) }
        }
    }

    @objc private func menuRemoveFromConnections(_ sender: Any?) {
        for row in targetRows() where row.saved && row.kind == .database {
            if let id = row.recordId { stateManager.setSaved(false, id: id) }
        }
    }

    /// Remove from List. A not-saved file that no saved Session and no open
    /// tab uses is forgotten completely: its record goes too, after an alert
    /// that says so (`FilesListRule.forgetsRecord`).
    @objc private func menuRemoveFromList(_ sender: Any?) {
        let rows = targetRows().filter { $0.path != nil }
        guard !rows.isEmpty else { return }
        let sessionIds = Set(((try? PharosCore.loadSavedQueries()) ?? []).compactMap(\.connectionId))
        let tabIds = stateManager.connectionIdsInUse
        let forgotten = rows.filter { FilesListRule.forgetsRecord($0, sessionConnectionIds: sessionIds, tabConnectionIds: tabIds) }
        let remove = { [weak self] in
            RecentFileStore.shared.remove(paths: rows.compactMap(\.path))
            for row in forgotten { if let id = row.recordId { self?.stateManager.deleteConnection(id: id) } }
        }
        guard !forgotten.isEmpty, let window = view.window else { remove(); return }
        let alert = NSAlert()
        let text = Self.forgetAlert(rows: rows, forgotten: forgotten.count)
        alert.messageText = text.title
        alert.informativeText = text.message
        alert.addButton(withTitle: String(localized: "Remove"))
        alert.addButton(withTitle: String(localized: "Cancel"))
        alert.beginSheetModal(for: window) { response in
            if response == .alertFirstButtonReturn { remove() }
        }
    }

    static func forgetAlert(rows: [FilesListRule.Row], forgotten: Int) -> (title: String, message: String) {
        let title = rows.count == 1
            ? String(localized: "Remove “\(DisplayEscape.escapedTrimmed(rows[0].title))” from the list?")
            : String(localized: "Remove \(rows.count) files from the list?")
        let message = forgotten == 1 && rows.count == 1
            ? String(localized: "Pharos also forgets this file. Its query history and Results History workspaces stay, but they open without a connection. The file stays where it is.")
            : String(localized: "Pharos also forgets the database files that no Session or tab uses. Their query history and workspaces stay, but they open without a connection. The files stay where they are.")
        return (title, message)
    }
}

// MARK: - Table

extension FilesNavigatorVC: NSTableViewDataSource, NSTableViewDelegate {
    func numberOfRows(in tableView: NSTableView) -> Int { items.count }

    func tableView(_ tableView: NSTableView, isGroupRow row: Int) -> Bool {
        if case .header = items[row] { return true }
        return false
    }

    func tableView(_ tableView: NSTableView, shouldSelectRow row: Int) -> Bool {
        if case .header = items[row] { return false }
        return true
    }

    func tableView(_ tableView: NSTableView, heightOfRow row: Int) -> CGFloat {
        if case .header = items[row] { return 24 }
        return 38
    }

    func tableView(_ tableView: NSTableView, viewFor tableColumn: NSTableColumn?, row: Int) -> NSView? {
        switch items[row] {
        case .header(let section, let count):
            return headerCell(section, count: count)
        case .file(let file):
            return fileCell(file)
        }
    }

    private func headerCell(_ section: FilesListRule.Section, count: Int) -> NSView {
        let title: String
        switch section {
        case .open: title = String(localized: "Open")
        case .recent: title = String(localized: "Recent")
        case .older: title = String(localized: "Older")
        }
        let label = NSTextField(labelWithString: "\(title)  \(count)")
        label.font = .systemFont(ofSize: NSFont.smallSystemFontSize, weight: .semibold)
        label.textColor = .secondaryLabelColor
        let stack = NSStackView(views: [label])
        stack.orientation = .horizontal
        stack.edgeInsets = NSEdgeInsets(top: 0, left: 4, bottom: 0, right: 8)
        if section == .older {
            // A disclosure in words and a chevron: the section is collapsed by
            // default, and a click on the header opens or closes it.
            let open = olderExpanded || !filterText.isEmpty
            let chevron = NSImageView(image: NSImage(systemSymbolName: open ? "chevron.down" : "chevron.right",
                                                     accessibilityDescription: nil) ?? NSImage())
            chevron.symbolConfiguration = .init(pointSize: 9, weight: .semibold)
            chevron.contentTintColor = .secondaryLabelColor
            stack.insertArrangedSubview(chevron, at: 0)
            stack.setAccessibilityElement(true)
            stack.setAccessibilityRole(.disclosureTriangle)
            stack.setAccessibilityLabel("\(title), \(count)")
            stack.setAccessibilityValue(open ? 1 : 0)
            stack.toolTip = String(localized: "Files not opened in the last 60 days")
        }
        return stack
    }

    private func fileCell(_ row: FilesListRule.Row) -> NSView {
        let missing = row.path.map { !fileExists($0) } ?? false
        let icon = NSImageView()
        if row.kind == .memory {
            icon.image = ConnectionTile.image(kind: .memory, state: .connected, size: 24)
        } else if let path = row.path, !missing {
            icon.image = NSWorkspace.shared.icon(forFile: path)
        } else {
            let type = row.path.flatMap { UTType(filenameExtension: ($0 as NSString).pathExtension) } ?? .data
            icon.image = NSWorkspace.shared.icon(for: type)
        }
        icon.imageScaling = .scaleProportionallyUpOrDown
        icon.translatesAutoresizingMaskIntoConstraints = false
        icon.widthAnchor.constraint(equalToConstant: 24).isActive = true
        icon.heightAnchor.constraint(equalToConstant: 24).isActive = true
        if missing { icon.alphaValue = 0.45 }

        let title = NSTextField(labelWithString: DisplayEscape.escaped(row.title))
        title.font = .systemFont(ofSize: NSFont.systemFontSize)
        title.lineBreakMode = .byTruncatingMiddle
        let detail = NSTextField(labelWithString: Self.detail(of: row, missing: missing))
        detail.font = .systemFont(ofSize: NSFont.smallSystemFontSize)
        detail.textColor = .secondaryLabelColor
        detail.lineBreakMode = .byTruncatingMiddle
        for label in [title, detail] {
            label.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        }
        let text = NSStackView(views: [title, detail])
        text.orientation = .vertical
        text.alignment = .leading
        text.spacing = 0
        let stack = NSStackView(views: [icon, text])
        stack.orientation = .horizontal
        stack.spacing = 8
        stack.edgeInsets = NSEdgeInsets(top: 0, left: 4, bottom: 0, right: 8)
        stack.toolTip = row.path ?? row.title
        stack.setAccessibilityElement(true)
        stack.setAccessibilityRole(.cell)
        stack.setAccessibilityLabel("\(DisplayEscape.escaped(row.title)), \(Self.detail(of: row, missing: missing))")
        return stack
    }

    /// "~/Data · Connected · Saved", "~/Downloads · File not found", "In memory".
    static func detail(of row: FilesListRule.Row, missing: Bool) -> String {
        var parts: [String] = []
        if let folder = row.folder { parts.append(DisplayEscape.escaped(folder)) }
        else { parts.append(String(localized: "In memory")) }
        if missing { parts.append(String(localized: "File not found")) }
        else if row.isOpen { parts.append(String(localized: "Open")) }
        if row.saved && row.kind == .database { parts.append(String(localized: "Saved")) }
        return parts.joined(separator: " · ")
    }

    // Drag out: a file URL.
    func tableView(_ tableView: NSTableView, pasteboardWriterForRow row: Int) -> NSPasteboardWriting? {
        guard let path = self.row(at: row)?.path else { return nil }
        return URL(fileURLWithPath: path) as NSURL
    }

    // Drop in: files from Finder open, the way a drop on the Dock icon does.
    func tableView(_ tableView: NSTableView, validateDrop info: NSDraggingInfo, proposedRow row: Int,
                   proposedDropOperation dropOperation: NSTableView.DropOperation) -> NSDragOperation {
        guard info.draggingSource as? NSTableView !== tableView, !Self.fileURLs(info).isEmpty else { return [] }
        tableView.setDropRow(-1, dropOperation: .on)
        return .copy
    }

    func tableView(_ tableView: NSTableView, acceptDrop info: NSDraggingInfo, row: Int,
                   dropOperation: NSTableView.DropOperation) -> Bool {
        let urls = Self.fileURLs(info)
        guard !urls.isEmpty else { return false }
        NSApp.delegate?.application?(NSApp, open: urls)
        return true
    }

    private static func fileURLs(_ info: NSDraggingInfo) -> [URL] {
        (info.draggingPasteboard.readObjects(forClasses: [NSURL.self],
                                             options: [.urlReadingFileURLsOnly: true]) as? [URL]) ?? []
    }
}

// MARK: - Context menu

extension FilesNavigatorVC: NSMenuDelegate {
    func menuNeedsUpdate(_ menu: NSMenu) {
        menu.removeAllItems()
        let rows = targetRows()
        guard !rows.isEmpty else { return }
        func add(_ title: String, _ action: Selector) {
            let item = menu.addItem(withTitle: title, action: action, keyEquivalent: "")
            item.target = self
        }
        add(String(localized: "Open"), #selector(menuOpen(_:)))
        if rows.contains(where: { $0.recordId != nil }) {
            add(String(localized: "Open in New Tab"), #selector(menuOpenInNewTab(_:)))
        }
        if rows.contains(where: { $0.path != nil }) {
            menu.addItem(.separator())
            add(String(localized: "Show in Finder"), #selector(menuShowInFinder(_:)))
            add(String(localized: "Copy Path"), #selector(menuCopyPath(_:)))
        }
        let canSave = rows.contains { !$0.saved && $0.recordId != nil }
        let canUnsave = rows.contains { $0.saved && $0.kind == .database && $0.recordId != nil }
        if canSave || canUnsave { menu.addItem(.separator()) }
        if canSave { add(String(localized: "Save as Connection"), #selector(menuSaveAsConnection(_:))) }
        if canUnsave { add(String(localized: "Remove from Connections"), #selector(menuRemoveFromConnections(_:))) }
        if rows.contains(where: { $0.path != nil }) {
            menu.addItem(.separator())
            add(String(localized: "Remove from List"), #selector(menuRemoveFromList(_:)))
        }
    }
}
