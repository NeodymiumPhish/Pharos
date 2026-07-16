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

// MARK: - Single-Line Cell View (Earlier-history disclosure row)

private class HistorySingleLineCell: NSTableCellView {
    let label = NSTextField(labelWithString: "")

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)

        label.lineBreakMode = .byTruncatingTail
        label.font = .systemFont(ofSize: 11)
        label.textColor = .secondaryLabelColor
        label.translatesAutoresizingMaskIntoConstraints = false

        addSubview(label)

        NSLayoutConstraint.activate([
            label.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 8),
            label.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -8),
            label.centerYAnchor.constraint(equalTo: centerYAnchor),
        ])
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) not implemented")
    }
}

// MARK: - Preview Row Cell View (bottom pane)

private class PreviewRowCell: NSTableCellView {
    let dot = NSView()
    let primaryLabel = NSTextField(labelWithString: "")
    let secondaryLabel = NSTextField(labelWithString: "")

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)

        dot.wantsLayer = true
        dot.layer?.cornerRadius = 4
        dot.translatesAutoresizingMaskIntoConstraints = false

        primaryLabel.lineBreakMode = .byTruncatingTail
        primaryLabel.font = .systemFont(ofSize: 12)
        primaryLabel.textColor = .labelColor
        primaryLabel.translatesAutoresizingMaskIntoConstraints = false
        primaryLabel.setContentHuggingPriority(.defaultLow, for: .horizontal)
        primaryLabel.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)

        secondaryLabel.lineBreakMode = .byTruncatingTail
        secondaryLabel.font = .systemFont(ofSize: 10)
        secondaryLabel.textColor = .secondaryLabelColor
        secondaryLabel.alignment = .right
        secondaryLabel.translatesAutoresizingMaskIntoConstraints = false
        secondaryLabel.setContentHuggingPriority(.required, for: .horizontal)

        addSubview(dot)
        addSubview(primaryLabel)
        addSubview(secondaryLabel)

        NSLayoutConstraint.activate([
            dot.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 8),
            dot.centerYAnchor.constraint(equalTo: centerYAnchor),
            dot.widthAnchor.constraint(equalToConstant: 8),
            dot.heightAnchor.constraint(equalToConstant: 8),

            primaryLabel.leadingAnchor.constraint(equalTo: dot.trailingAnchor, constant: 8),
            primaryLabel.centerYAnchor.constraint(equalTo: centerYAnchor),

            secondaryLabel.leadingAnchor.constraint(greaterThanOrEqualTo: primaryLabel.trailingAnchor, constant: 8),
            secondaryLabel.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -8),
            secondaryLabel.centerYAnchor.constraint(equalTo: centerYAnchor),
        ])
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) not implemented")
    }

    func setDotColor(_ color: NSColor) {
        dot.layer?.backgroundColor = color.cgColor
    }
}

// MARK: - QueryHistoryVC

class QueryHistoryVC: NSViewController, NSTableViewDataSource, NSTableViewDelegate {

    /// A row shown in the history list: a workspace summary, the "Earlier
    /// history" disclosure row, or a legacy (pre-workspace) query_history entry.
    private enum HistoryRow {
        case workspace(WorkspaceSummary)
        case earlierHeader(count: Int, expanded: Bool)
        case legacy(QueryHistoryEntry)
    }

    private let tableView = NSTableView()
    private let scrollView = NSScrollView()
    private let previewTable = NSTableView()
    private let previewScroll = NSScrollView()
    private let splitView = NSSplitView()

    private var rows: [HistoryRow] = []
    private var workspaces: [WorkspaceSummary] = []
    private var legacyEntries: [QueryHistoryEntry] = []
    private var earlierExpanded = false

    /// Results of the currently-selected workspace, shown in the bottom preview table.
    private var previewResults: [WorkspaceResultMeta] = []
    private var selectedWorkspaceId: String?

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
        tableView.action = #selector(singleClickedRow(_:))
        tableView.doubleAction = #selector(doubleClickedRow(_:))
        tableView.target = self
        tableView.menu = buildContextMenu()

        scrollView.documentView = tableView
        scrollView.hasVerticalScroller = true
        scrollView.autohidesScrollers = true
        scrollView.translatesAutoresizingMaskIntoConstraints = false

        // Bottom preview pane: shows the selected workspace's results.
        let previewCol = NSTableColumn(identifier: NSUserInterfaceItemIdentifier("preview"))
        previewCol.title = ""
        previewTable.addTableColumn(previewCol)

        previewTable.headerView = nil
        previewTable.dataSource = self
        previewTable.delegate = self
        previewTable.rowSizeStyle = .custom
        previewTable.rowHeight = 34
        previewTable.usesAlternatingRowBackgroundColors = true
        previewTable.allowsMultipleSelection = false
        previewTable.doubleAction = #selector(previewDoubleClicked(_:))
        previewTable.target = self
        previewTable.menu = buildPreviewContextMenu()

        previewScroll.documentView = previewTable
        previewScroll.hasVerticalScroller = true
        previewScroll.autohidesScrollers = true
        previewScroll.translatesAutoresizingMaskIntoConstraints = false

        splitView.isVertical = false // stacks top/bottom
        splitView.dividerStyle = .thin
        splitView.translatesAutoresizingMaskIntoConstraints = false
        splitView.addArrangedSubview(scrollView)
        splitView.addArrangedSubview(previewScroll)
        splitView.setHoldingPriority(.defaultLow - 1, forSubviewAt: 1)
        // Remembers the divider position (preview pane height) across launches.
        splitView.autosaveName = "PharosHistoryPreviewSplit"

        container.addSubview(splitView)

        NSLayoutConstraint.activate([
            splitView.topAnchor.constraint(equalTo: container.topAnchor),
            splitView.leadingAnchor.constraint(equalTo: container.leadingAnchor),
            splitView.trailingAnchor.constraint(equalTo: container.trailingAnchor),
            splitView.bottomAnchor.constraint(equalTo: container.bottomAnchor),
        ])

        // Auto-reload when a query finishes executing or a result is
        // associated with a workspace.
        NotificationCenter.default.addObserver(
            self, selector: #selector(historyDidChange),
            name: .queryHistoryDidChange, object: nil
        )
        NotificationCenter.default.addObserver(
            self, selector: #selector(historyDidChange),
            name: .workspaceHistoryDidChange, object: nil
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
    //
    // Only legacy rows are deletable through this path today; workspace
    // rename/duplicate/delete lands in Phase 6.

    /// Delete the currently selected legacy history entries with confirmation.
    func deleteSelectedEntries() {
        let selectedRows = tableView.selectedRowIndexes
        let ids: [String] = selectedRows.compactMap { idx -> String? in
            guard idx < rows.count, case let .legacy(entry) = rows[idx] else { return nil }
            return entry.id
        }
        guard !ids.isEmpty else { return }

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
        let connectionId = connectionFilter
        // Hop the FFI roundtrip (SQLite IO + JSON decode) off the main thread
        // so typing in the sidebar filter — which can fire this several times
        // a second — never stalls the UI.
        Task.detached(priority: .userInitiated) { [weak self] in
            let ws: [WorkspaceSummary]
            let legacy: [QueryHistoryEntry]
            do {
                ws = try PharosCore.loadWorkspaces(filter: .init(search: search, limit: 200, offset: 0))
                legacy = try PharosCore.loadQueryHistory(
                    filter: QueryHistoryFilter(connectionId: connectionId, search: search, limit: 200, onlyLegacy: true)
                )
            } catch {
                NSLog("Failed to load workspace history: \(error)")
                return
            }
            await MainActor.run {
                guard let self, generation == self.requeryGeneration else { return }
                self.workspaces = ws
                self.legacyEntries = legacy
                self.rebuildRows()
                self.tableView.reloadData()
                self.resyncSelectionToPreviewedWorkspace()
            }
        }
    }

    /// reloadData() doesn't remap selectedRowIndexes to the same row identity
    /// — the workspace list can reorder (last_activity_at DESC) on every
    /// requery. Re-find the previewed workspace's new row and re-select it so
    /// the highlighted row and the preview pane stay in sync; if it's gone
    /// (filtered out or deleted), clear the preview instead of leaving it
    /// pointing at whatever row now occupies the old index.
    private func resyncSelectionToPreviewedWorkspace() {
        guard let workspaceId = selectedWorkspaceId else { return }
        if let idx = rows.firstIndex(where: {
            if case .workspace(let w) = $0 { return w.id == workspaceId }
            return false
        }) {
            if tableView.selectedRowIndexes != IndexSet(integer: idx) {
                tableView.selectRowIndexes(IndexSet(integer: idx), byExtendingSelection: false)
            }
        } else {
            clearPreview()
        }
    }

    /// Rebuild the flat `rows` list: workspaces first, then (when there are
    /// any legacy rows) an "Earlier history" disclosure row, then the legacy
    /// entries themselves when expanded.
    private func rebuildRows() {
        var out: [HistoryRow] = workspaces.map { .workspace($0) }
        if !legacyEntries.isEmpty {
            out.append(.earlierHeader(count: legacyEntries.count, expanded: earlierExpanded))
            if earlierExpanded {
                out.append(contentsOf: legacyEntries.map { .legacy($0) })
            }
        }
        rows = out
    }

    // MARK: - Actions

    /// Single-click handler: toggles the "Earlier history" disclosure row.
    /// Row selection itself (workspace preview, arrow-key nav) is handled by
    /// `tableViewSelectionDidChange` / `tableView(_:shouldSelectRow:)` — the
    /// header row is never selectable, so this is the only path that expands
    /// or collapses it.
    @objc private func singleClickedRow(_: Any?) {
        let row = tableView.clickedRow
        guard row >= 0, row < rows.count, case .earlierHeader = rows[row] else { return }
        earlierExpanded.toggle()
        rebuildRows()
        tableView.reloadData()
    }

    @objc private func doubleClickedRow(_: Any?) {
        let row = tableView.clickedRow
        guard row >= 0, row < rows.count else { return }
        switch rows[row] {
        case .legacy(let entry):
            NotificationCenter.default.post(
                name: .openHistoryEntry,
                object: nil,
                userInfo: ["entry": entry]
            )
        case .workspace(let w):
            NotificationCenter.default.post(
                name: .openWorkspace,
                object: nil,
                userInfo: ["workspaceId": w.id]
            )
        case .earlierHeader:
            break
        }
    }

    @objc private func previewDoubleClicked(_: Any?) {
        let row = previewTable.clickedRow
        guard row >= 0, row < previewResults.count, let workspaceId = selectedWorkspaceId else { return }
        NotificationCenter.default.post(
            name: .openWorkspace,
            object: nil,
            userInfo: ["workspaceId": workspaceId, "focusResultId": previewResults[row].id]
        )
    }

    @objc private func contextCopySQL(_: Any?) {
        let row = tableView.clickedRow
        guard row >= 0, row < rows.count, case let .legacy(entry) = rows[row] else { return }
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(entry.sql, forType: .string)
    }

    @objc private func contextDelete(_: Any?) {
        let row = tableView.clickedRow
        guard row >= 0, row < rows.count, case let .legacy(entry) = rows[row] else { return }
        do {
            _ = try PharosCore.deleteQueryHistoryEntry(id: entry.id)
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

    // MARK: - Workspace Context-Menu Actions

    private func rowAt(_ index: Int) -> HistoryRow? {
        guard index >= 0, index < rows.count else { return nil }
        return rows[index]
    }

    @objc private func contextRenameWorkspace(_: Any?) {
        guard case .workspace(let w)? = rowAt(tableView.clickedRow) else { return }
        let alert = NSAlert()
        alert.messageText = "Rename Workspace"
        let field = NSTextField(string: w.name)
        field.frame = NSRect(x: 0, y: 0, width: 240, height: 24)
        alert.accessoryView = field
        alert.addButton(withTitle: "Rename")
        alert.addButton(withTitle: "Cancel")
        guard let win = view.window else { return }
        alert.window.initialFirstResponder = field
        alert.beginSheetModal(for: win) { [weak self] resp in
            guard resp == .alertFirstButtonReturn else { return }
            let newName = field.stringValue.trimmingCharacters(in: .whitespaces)
            guard !newName.isEmpty, newName != w.name else { return }
            _ = try? PharosCore.renameWorkspace(id: w.id, name: newName)
            self?.requery()
        }
    }

    @objc private func contextDuplicateWorkspace(_: Any?) {
        guard case .workspace(let w)? = rowAt(tableView.clickedRow) else { return }
        _ = try? PharosCore.duplicateWorkspace(id: w.id)
        requery()
    }

    @objc private func contextDeleteWorkspace(_: Any?) {
        guard case .workspace(let w)? = rowAt(tableView.clickedRow) else { return }

        let alert = NSAlert()
        alert.messageText = "Delete workspace \"\(w.name)\"?"
        alert.informativeText = "This permanently deletes the workspace and all its saved results."
        alert.alertStyle = .warning
        alert.addButton(withTitle: "Delete")
        alert.addButton(withTitle: "Cancel")

        guard let window = view.window else { return }
        alert.beginSheetModal(for: window) { [weak self] response in
            guard response == .alertFirstButtonReturn else { return }
            if self?.selectedWorkspaceId == w.id { self?.clearPreview() }
            _ = try? PharosCore.deleteWorkspace(id: w.id)
            self?.requery()
        }
    }

    /// Context-menu action for a multi-row selection that's entirely
    /// workspace rows — mirrors `deleteSelectedEntries()`'s confirmation flow.
    @objc private func contextDeleteSelectedWorkspaces(_: Any?) {
        let ids: [String] = tableView.selectedRowIndexes.compactMap { idx -> String? in
            guard case .workspace(let w)? = rowAt(idx) else { return nil }
            return w.id
        }
        guard !ids.isEmpty else { return }

        let alert = NSAlert()
        alert.messageText = "Delete \(ids.count) workspace\(ids.count == 1 ? "" : "s")?"
        alert.informativeText = "This action cannot be undone."
        alert.alertStyle = .warning
        alert.addButton(withTitle: "Delete")
        alert.addButton(withTitle: "Cancel")

        guard let window = view.window else { return }
        alert.beginSheetModal(for: window) { [weak self] response in
            guard response == .alertFirstButtonReturn else { return }
            for id in ids {
                _ = try? PharosCore.deleteWorkspace(id: id)
            }
            if let selectedWorkspaceId = self?.selectedWorkspaceId, ids.contains(selectedWorkspaceId) {
                self?.clearPreview()
            }
            self?.requery()
        }
    }

    // MARK: - Preview-Table Context-Menu Actions

    @objc private func contextDeletePreviewResult(_: Any?) {
        let row = previewTable.clickedRow
        guard row >= 0, row < previewResults.count else { return }
        _ = try? PharosCore.deleteWorkspaceResult(id: previewResults[row].id)
        requery()
        if let wsId = selectedWorkspaceId { showPreview(for: wsId) }
    }

    @objc private func contextCopyPreviewSQL(_: Any?) {
        let row = previewTable.clickedRow
        guard row >= 0, row < previewResults.count else { return }
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(previewResults[row].sql, forType: .string)
    }

    private func buildContextMenu() -> NSMenu {
        let menu = NSMenu()
        menu.delegate = self
        return menu
    }

    private func buildPreviewContextMenu() -> NSMenu {
        let menu = NSMenu()
        menu.delegate = self
        return menu
    }

    // MARK: - NSTableViewDataSource

    func numberOfRows(in tableView: NSTableView) -> Int {
        if tableView === previewTable {
            return previewResults.count
        }
        return rows.count
    }

    // MARK: - NSTableViewDelegate

    func tableView(_ tableView: NSTableView, viewFor tableColumn: NSTableColumn?, row: Int) -> NSView? {
        if tableView === previewTable {
            return previewCell(for: row)
        }

        guard row < rows.count else { return nil }
        switch rows[row] {
        case .workspace(let w):
            return workspaceCell(for: w)
        case .earlierHeader(let count, let expanded):
            return earlierHeaderCell(count: count, expanded: expanded)
        case .legacy(let entry):
            return legacyCell(for: entry)
        }
    }

    func tableView(_ tableView: NSTableView, shouldSelectRow row: Int) -> Bool {
        guard tableView === self.tableView, row < rows.count else { return true }
        // The disclosure row toggles via click/action, not selection — keeps
        // arrow-key navigation from spuriously expanding/collapsing it.
        if case .earlierHeader = rows[row] { return false }
        return true
    }

    func tableView(_ tableView: NSTableView, heightOfRow row: Int) -> CGFloat {
        if tableView === previewTable {
            return 34
        }
        guard row < rows.count else { return 40 }
        if case .earlierHeader = rows[row] {
            return 22
        }
        return 40
    }

    private func workspaceCell(for w: WorkspaceSummary) -> NSView {
        let cellId = NSUserInterfaceItemIdentifier("HistoryTwoLine")
        let cell: HistoryTwoLineCell
        if let existing = tableView.makeView(withIdentifier: cellId, owner: self) as? HistoryTwoLineCell {
            cell = existing
        } else {
            cell = HistoryTwoLineCell()
            cell.identifier = cellId
        }

        cell.primaryLabel.stringValue = "📊 \(w.name)"
        let queryWord = w.queryCount == 1 ? "query" : "queries"
        cell.secondaryLabel.stringValue = "\(w.queryCount) \(queryWord) · \(formatDate(w.lastActivityAt)) · \(w.connectionName)"
        return cell
    }

    private func earlierHeaderCell(count: Int, expanded: Bool) -> NSView {
        let cellId = NSUserInterfaceItemIdentifier("EarlierHeader")
        let cell: HistorySingleLineCell
        if let existing = tableView.makeView(withIdentifier: cellId, owner: self) as? HistorySingleLineCell {
            cell = existing
        } else {
            cell = HistorySingleLineCell()
            cell.identifier = cellId
        }

        cell.label.stringValue = "\(expanded ? "▾" : "▸") Earlier history (\(count))"
        return cell
    }

    private func legacyCell(for entry: QueryHistoryEntry) -> NSView {
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
            colText = ""
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

    private func previewCell(for row: Int) -> NSView {
        let cellId = NSUserInterfaceItemIdentifier("PreviewRow")
        let cell: PreviewRowCell
        if let existing = previewTable.makeView(withIdentifier: cellId, owner: self) as? PreviewRowCell {
            cell = existing
        } else {
            cell = PreviewRowCell()
            cell.identifier = cellId
        }

        guard row < previewResults.count else { return cell }
        let meta = previewResults[row]

        let colorIndex = (meta.colorIndex ?? 0) % ResultTab.palette.count
        cell.setDotColor(ResultTab.palette[colorIndex])

        if let label = meta.customLabel, !label.isEmpty {
            cell.primaryLabel.stringValue = label
        } else {
            let firstLine = meta.sql.components(separatedBy: .newlines).first ?? meta.sql
            cell.primaryLabel.stringValue = firstLine.trimmingCharacters(in: .whitespaces)
        }

        if meta.hasResults, let count = meta.rowCount {
            cell.secondaryLabel.textColor = .secondaryLabelColor
            cell.secondaryLabel.stringValue = "\(formatRowCount(Int64(count))) row\(count == 1 ? "" : "s")"
        } else {
            cell.secondaryLabel.textColor = .tertiaryLabelColor
            cell.secondaryLabel.stringValue = "SQL only"
        }

        return cell
    }

    func tableViewSelectionDidChange(_ notification: Notification) {
        guard let changed = notification.object as? NSTableView, changed === tableView else {
            return // Preview-table selection doesn't drive the sidebar or the preview itself.
        }
        onSelectionChanged?(tableView.selectedRowIndexes.count)

        let selected = tableView.selectedRowIndexes
        guard selected.count == 1, let row = selected.first, row < rows.count else {
            clearPreview()
            return
        }

        switch rows[row] {
        case .earlierHeader:
            // Unreachable: shouldSelectRow(_:) refuses selection on this row.
            break
        case .workspace(let w):
            selectedWorkspaceId = w.id
            showPreview(for: w.id)
        case .legacy:
            clearPreview()
        }
    }

    private func clearPreview() {
        selectedWorkspaceId = nil
        previewResults = []
        previewTable.reloadData()
    }

    private func showPreview(for workspaceId: String) {
        Task.detached(priority: .userInitiated) { [weak self] in
            let detail = try? PharosCore.loadWorkspace(id: workspaceId)
            await MainActor.run {
                // Discard a stale response if the selection moved on before this returned.
                guard let self, self.selectedWorkspaceId == workspaceId else { return }
                self.previewResults = detail?.results ?? []
                self.previewTable.reloadData()
            }
        }
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
        if menu === previewTable.menu {
            updatePreviewMenu(menu)
        } else {
            updateMainMenu(menu)
        }
    }

    private func updateMainMenu(_ menu: NSMenu) {
        let row = tableView.clickedRow
        guard row >= 0, row < rows.count else { return }

        // Right-clicking a row that's already part of a multi-row selection
        // should operate on the whole selection. AppKit replaces the selection
        // when right-clicking outside it, so by the time this fires the
        // selection already reflects what the click targets.
        let selectedRows = tableView.selectedRowIndexes
        if selectedRows.count > 1 && selectedRows.contains(row) {
            let allLegacy = selectedRows.allSatisfy { idx in
                idx < rows.count && isLegacyRow(idx)
            }
            if allLegacy {
                menu.addItem(
                    withTitle: "Delete \(selectedRows.count) Items",
                    action: #selector(contextDeleteSelected),
                    keyEquivalent: ""
                )
                return
            }
            let allWorkspace = selectedRows.allSatisfy { idx in
                idx < rows.count && isWorkspaceRow(idx)
            }
            if allWorkspace {
                menu.addItem(
                    withTitle: "Delete \(selectedRows.count) Workspaces",
                    action: #selector(contextDeleteSelectedWorkspaces),
                    keyEquivalent: ""
                )
                return
            }
            // Mixed selection: no menu.
            return
        }

        switch rows[row] {
        case .workspace:
            menu.addItem(withTitle: "Rename…", action: #selector(contextRenameWorkspace), keyEquivalent: "")
            menu.addItem(withTitle: "Duplicate", action: #selector(contextDuplicateWorkspace), keyEquivalent: "")
            menu.addItem(.separator())
            menu.addItem(withTitle: "Delete", action: #selector(contextDeleteWorkspace), keyEquivalent: "")
        case .legacy:
            menu.addItem(withTitle: "Copy SQL", action: #selector(contextCopySQL), keyEquivalent: "")
            menu.addItem(.separator())
            menu.addItem(withTitle: "Delete", action: #selector(contextDelete), keyEquivalent: "")
        case .earlierHeader:
            break // No menu on the disclosure row.
        }
    }

    private func updatePreviewMenu(_ menu: NSMenu) {
        let row = previewTable.clickedRow
        guard row >= 0, row < previewResults.count else { return }
        menu.addItem(withTitle: "Delete this result", action: #selector(contextDeletePreviewResult), keyEquivalent: "")
        menu.addItem(withTitle: "Copy SQL", action: #selector(contextCopyPreviewSQL), keyEquivalent: "")
    }

    private func isLegacyRow(_ index: Int) -> Bool {
        if case .legacy = rows[index] { return true }
        return false
    }

    private func isWorkspaceRow(_ index: Int) -> Bool {
        if case .workspace = rows[index] { return true }
        return false
    }
}
