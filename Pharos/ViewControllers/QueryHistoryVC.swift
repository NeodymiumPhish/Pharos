import AppKit

extension Notification.Name {
    static let openHistoryEntry = Notification.Name("PharosOpenHistoryEntry")
    static let queryHistoryDidChange = Notification.Name("PharosQueryHistoryDidChange")
    /// Posted after a result is associated with a workspace (workspace list needs refresh).
    static let workspaceHistoryDidChange = Notification.Name("PharosWorkspaceHistoryDidChange")
    /// Posted to request reopening a full workspace into a live editor tab.
    static let openWorkspace = Notification.Name("PharosOpenWorkspace")
}

// MARK: - Two-Line Cell View

private class HistoryTwoLineCell: NSTableCellView {
    let primaryLabel = NSTextField(labelWithString: "")
    let secondaryLabel = NSTextField(labelWithString: "")

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)

        primaryLabel.lineBreakMode = .byTruncatingTail
        primaryLabel.font = .systemFont(ofSize: 12)
        primaryLabel.textColor = .labelColor
        primaryLabel.translatesAutoresizingMaskIntoConstraints = false

        secondaryLabel.lineBreakMode = .byTruncatingTail
        secondaryLabel.font = .systemFont(ofSize: 10)
        secondaryLabel.textColor = .secondaryLabelColor
        secondaryLabel.translatesAutoresizingMaskIntoConstraints = false

        addSubview(primaryLabel)
        addSubview(secondaryLabel)

        NSLayoutConstraint.activate([
            primaryLabel.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 8),
            primaryLabel.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -8),
            primaryLabel.topAnchor.constraint(equalTo: topAnchor, constant: 6),

            secondaryLabel.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 8),
            secondaryLabel.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -8),
            secondaryLabel.topAnchor.constraint(equalTo: primaryLabel.bottomAnchor, constant: 1),
        ])
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) not implemented")
    }
}

// MARK: - QueryHistoryVC

class QueryHistoryVC: NSViewController, NSTableViewDataSource, NSTableViewDelegate {

    private let tableView = NSTableView()
    private let scrollView = NSScrollView()

    private var entries: [QueryHistoryEntry] = []
    private var connectionFilter: String?
    private var filterText: String?

    /// Called when the table selection changes; passes the number of selected rows.
    var onSelectionChanged: ((Int) -> Void)?

    override func loadView() {
        let container = NSView()
        self.view = container

        // Single column for two-line cells
        let col = NSTableColumn(identifier: NSUserInterfaceItemIdentifier("entry"))
        col.title = ""
        tableView.addTableColumn(col)

        tableView.headerView = nil
        tableView.dataSource = self
        tableView.delegate = self
        tableView.rowSizeStyle = .custom
        tableView.rowHeight = 40
        tableView.usesAlternatingRowBackgroundColors = true
        tableView.allowsMultipleSelection = true
        tableView.doubleAction = #selector(doubleClickedRow(_:))
        tableView.target = self
        tableView.menu = buildContextMenu()

        scrollView.documentView = tableView
        scrollView.hasVerticalScroller = true
        scrollView.autohidesScrollers = true
        scrollView.translatesAutoresizingMaskIntoConstraints = false

        container.addSubview(scrollView)

        NSLayoutConstraint.activate([
            scrollView.topAnchor.constraint(equalTo: container.topAnchor),
            scrollView.leadingAnchor.constraint(equalTo: container.leadingAnchor),
            scrollView.trailingAnchor.constraint(equalTo: container.trailingAnchor),
            scrollView.bottomAnchor.constraint(equalTo: container.bottomAnchor),
        ])

        // Auto-reload when a query finishes executing
        NotificationCenter.default.addObserver(
            self, selector: #selector(historyDidChange),
            name: .queryHistoryDidChange, object: nil
        )
    }

    @objc private func historyDidChange() {
        requery()
    }

    // MARK: - Public API

    func reload(connectionId: String? = nil) {
        self.connectionFilter = connectionId
        requery()
    }

    // MARK: - Filter API (called by SidebarViewController)

    func applyFilter(_ text: String) {
        filterText = text
        requery()
    }

    func clearFilter() {
        filterText = nil
        requery()
    }

    // MARK: - Batch Delete

    /// Delete the currently selected history entries with confirmation.
    func deleteSelectedEntries() {
        let selectedRows = tableView.selectedRowIndexes
        guard !selectedRows.isEmpty else { return }
        let ids = selectedRows.map { entries[$0].id }

        let alert = NSAlert()
        alert.messageText = "Delete \(ids.count) history item\(ids.count == 1 ? "" : "s")?"
        alert.informativeText = "This action cannot be undone."
        alert.alertStyle = .warning
        alert.addButton(withTitle: "Delete")
        alert.addButton(withTitle: "Cancel")

        guard let window = view.window else { return }
        alert.beginSheetModal(for: window) { [weak self] response in
            guard response == .alertFirstButtonReturn else { return }
            do {
                _ = try PharosCore.batchDeleteQueryHistory(ids: ids)
                self?.reload(connectionId: self?.connectionFilter)
            } catch {
                NSLog("Failed to batch delete history entries: \(error)")
            }
        }
    }

    // MARK: - Query

    /// Generation counter to discard out-of-order requery results. Each
    /// requery captures the current generation; only the result whose
    /// generation matches the latest at completion time is applied. Prevents
    /// stale rows winning a race when the user types quickly.
    private var requeryGeneration: UInt64 = 0

    private func requery() {
        requeryGeneration &+= 1
        let generation = requeryGeneration
        let search = (filterText?.isEmpty ?? true) ? nil : filterText
        let filter = QueryHistoryFilter(connectionId: connectionFilter, search: search, limit: 200)
        // Hop the FFI roundtrip (SQLite IO + JSON decode of up to 200 rows)
        // off the main thread so typing in the sidebar filter — which can fire
        // this several times a second — never stalls the UI.
        Task.detached(priority: .userInitiated) { [weak self] in
            let loaded: [QueryHistoryEntry]
            do {
                loaded = try PharosCore.loadQueryHistory(filter: filter)
            } catch {
                NSLog("Failed to load query history: \(error)")
                return
            }
            await MainActor.run {
                guard let self, generation == self.requeryGeneration else { return }
                // Skip reload if the result set is identical to what we already
                // show. Comparing the id list is cheap (<=200 entries) and
                // avoids redoing the cell tree work — preserves selection and
                // scroll position on harmless requeries (e.g. queryHistoryDidChange
                // posted but the new entry doesn't pass the current filter).
                let oldIds = self.entries.map { $0.id }
                let newIds = loaded.map { $0.id }
                guard oldIds != newIds else {
                    self.entries = loaded
                    return
                }
                self.entries = loaded
                self.tableView.reloadData()
            }
        }
    }

    // MARK: - Actions

    @objc private func doubleClickedRow(_: Any?) {
        let row = tableView.clickedRow
        guard row >= 0, row < entries.count else { return }
        let entry = entries[row]
        NotificationCenter.default.post(
            name: .openHistoryEntry,
            object: nil,
            userInfo: ["entry": entry]
        )
    }

    @objc private func contextCopySQL(_: Any?) {
        let row = tableView.clickedRow
        guard row >= 0, row < entries.count else { return }
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(entries[row].sql, forType: .string)
    }

    @objc private func contextDelete(_: Any?) {
        let row = tableView.clickedRow
        guard row >= 0, row < entries.count else { return }
        do {
            _ = try PharosCore.deleteQueryHistoryEntry(id: entries[row].id)
            reload(connectionId: connectionFilter)
        } catch {
            NSLog("Failed to delete history entry: \(error)")
        }
    }

    /// Context-menu action used when more than one row is selected — routes
    /// through the confirmed batch-delete flow already used by the
    /// Backspace/Delete keypath.
    @objc private func contextDeleteSelected(_: Any?) {
        deleteSelectedEntries()
    }

    private func buildContextMenu() -> NSMenu {
        let menu = NSMenu()
        menu.delegate = self
        return menu
    }

    // MARK: - NSTableViewDataSource

    func numberOfRows(in tableView: NSTableView) -> Int {
        entries.count
    }

    // MARK: - NSTableViewDelegate

    func tableView(_ tableView: NSTableView, viewFor tableColumn: NSTableColumn?, row: Int) -> NSView? {
        guard row < entries.count else { return nil }
        let entry = entries[row]

        let cellId = NSUserInterfaceItemIdentifier("HistoryTwoLine")
        let cell: HistoryTwoLineCell
        if let existing = tableView.makeView(withIdentifier: cellId, owner: self) as? HistoryTwoLineCell {
            cell = existing
        } else {
            cell = HistoryTwoLineCell()
            cell.identifier = cellId
        }

        // Line 1: "6 Columns - users" or "SELECT ..." fallback
        let colText: String
        if let count = entry.columnCount {
            colText = "\(count) Column\(count == 1 ? "" : "s")"
        } else {
            colText = nil ?? ""
        }
        let tableText = entry.tableNames ?? ""

        if !colText.isEmpty && !tableText.isEmpty {
            cell.primaryLabel.stringValue = "\(colText) – \(tableText)"
        } else if !tableText.isEmpty {
            cell.primaryLabel.stringValue = tableText
        } else if !colText.isEmpty {
            cell.primaryLabel.stringValue = colText
        } else {
            // Fallback: first line of SQL
            let firstLine = entry.sql.components(separatedBy: .newlines).first ?? entry.sql
            cell.primaryLabel.stringValue = firstLine.trimmingCharacters(in: .whitespaces)
        }

        // Line 2: "1,000 Rows - 1h ago"
        let rowText: String
        if let count = entry.rowCount {
            rowText = "\(formatRowCount(count)) Row\(count == 1 ? "" : "s")"
        } else {
            rowText = ""
        }
        let dateText = formatDate(entry.executedAt)

        let connName = entry.connectionName
        if !rowText.isEmpty {
            cell.secondaryLabel.stringValue = "\(rowText) – \(dateText) – \(connName)"
        } else {
            cell.secondaryLabel.stringValue = "\(dateText) – \(connName)"
        }

        return cell
    }

    func tableViewSelectionDidChange(_ notification: Notification) {
        onSelectionChanged?(tableView.selectedRowIndexes.count)
    }

    // MARK: - Formatting

    private func formatRowCount(_ count: Int64) -> String {
        let formatter = NumberFormatter()
        formatter.numberStyle = .decimal
        formatter.groupingSeparator = ","
        return formatter.string(from: NSNumber(value: count)) ?? "\(count)"
    }

    private func formatDate(_ iso: String) -> String {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        guard let date = formatter.date(from: iso) ?? ISO8601DateFormatter().date(from: iso) else {
            return iso
        }

        let relative = RelativeDateTimeFormatter()
        relative.unitsStyle = .abbreviated
        return relative.localizedString(for: date, relativeTo: Date())
    }
}

// MARK: - NSMenuDelegate

extension QueryHistoryVC: NSMenuDelegate {
    func menuNeedsUpdate(_ menu: NSMenu) {
        menu.removeAllItems()
        let row = tableView.clickedRow
        guard row >= 0, row < entries.count else { return }

        // Right-clicking a row that's already part of a multi-row selection
        // should operate on the whole selection. AppKit replaces the selection
        // when right-clicking outside it, so by the time this fires the
        // selection already reflects what the click targets.
        let selectedRows = tableView.selectedRowIndexes
        if selectedRows.count > 1 && selectedRows.contains(row) {
            menu.addItem(
                withTitle: "Delete \(selectedRows.count) Items",
                action: #selector(contextDeleteSelected),
                keyEquivalent: ""
            )
            return
        }

        menu.addItem(withTitle: "Copy SQL", action: #selector(contextCopySQL), keyEquivalent: "")
        menu.addItem(.separator())
        menu.addItem(withTitle: "Delete", action: #selector(contextDelete), keyEquivalent: "")
    }
}
