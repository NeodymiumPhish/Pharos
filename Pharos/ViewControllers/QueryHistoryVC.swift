import AppKit

class QueryHistoryVC: NSViewController, NSTableViewDataSource, NSTableViewDelegate {

    private let tableView = NSTableView()
    private let scrollView = NSScrollView()
    private let searchField = NSSearchField()

    private var entries: [QueryHistoryEntry] = []
    private var connectionFilter: String?

    override func loadView() {
        let container = NSView()
        self.view = container

        // Search field
        searchField.placeholderString = "Search history"
        searchField.translatesAutoresizingMaskIntoConstraints = false
        searchField.sendsWholeSearchString = false
        searchField.sendsSearchStringImmediately = true
        searchField.target = self
        searchField.action = #selector(searchChanged(_:))

        // Table columns
        let sqlCol = NSTableColumn(identifier: NSUserInterfaceItemIdentifier("sql"))
        sqlCol.title = "SQL"
        sqlCol.width = 200
        sqlCol.minWidth = 100

        let timeCol = NSTableColumn(identifier: NSUserInterfaceItemIdentifier("time"))
        timeCol.title = "Time"
        timeCol.width = 60
        timeCol.minWidth = 40

        let dateCol = NSTableColumn(identifier: NSUserInterfaceItemIdentifier("date"))
        dateCol.title = "Date"
        dateCol.width = 100
        dateCol.minWidth = 80

        tableView.addTableColumn(sqlCol)
        tableView.addTableColumn(timeCol)
        tableView.addTableColumn(dateCol)
        tableView.headerView = nil
        tableView.dataSource = self
        tableView.delegate = self
        tableView.rowSizeStyle = .custom
        tableView.rowHeight = 36
        tableView.usesAlternatingRowBackgroundColors = true
        tableView.doubleAction = #selector(doubleClickedRow(_:))
        tableView.target = self
        tableView.menu = buildContextMenu()

        scrollView.documentView = tableView
        scrollView.hasVerticalScroller = true
        scrollView.autohidesScrollers = true
        scrollView.translatesAutoresizingMaskIntoConstraints = false

        container.addSubview(searchField)
        container.addSubview(scrollView)

        NSLayoutConstraint.activate([
            searchField.topAnchor.constraint(equalTo: container.topAnchor, constant: 4),
            searchField.leadingAnchor.constraint(equalTo: container.leadingAnchor, constant: 8),
            searchField.trailingAnchor.constraint(equalTo: container.trailingAnchor, constant: -8),

            scrollView.topAnchor.constraint(equalTo: searchField.bottomAnchor, constant: 4),
            scrollView.leadingAnchor.constraint(equalTo: container.leadingAnchor),
            scrollView.trailingAnchor.constraint(equalTo: container.trailingAnchor),
            scrollView.bottomAnchor.constraint(equalTo: container.bottomAnchor),
        ])
    }

    // MARK: - Public API

    func reload(connectionId: String? = nil) {
        self.connectionFilter = connectionId
        do {
            let filter = QueryHistoryFilter(connectionId: connectionId, limit: 200)
            entries = try PharosCore.loadQueryHistory(filter: filter)
            tableView.reloadData()
        } catch {
            NSLog("Failed to load query history: \(error)")
        }
    }

    // MARK: - Actions

    @objc private func doubleClickedRow(_ sender: Any?) {
        let row = tableView.clickedRow
        guard row >= 0, row < entries.count else { return }
        let entry = entries[row]
        // TODO: Open SQL in editor tab
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(entry.sql, forType: .string)
    }

    @objc private func searchChanged(_ sender: NSSearchField) {
        let search = sender.stringValue.isEmpty ? nil : sender.stringValue
        do {
            let filter = QueryHistoryFilter(connectionId: connectionFilter, search: search, limit: 200)
            entries = try PharosCore.loadQueryHistory(filter: filter)
            tableView.reloadData()
        } catch {
            NSLog("Failed to search history: \(error)")
        }
    }

    @objc private func contextCopySQL(_ sender: Any?) {
        let row = tableView.clickedRow
        guard row >= 0, row < entries.count else { return }
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(entries[row].sql, forType: .string)
    }

    @objc private func contextDelete(_ sender: Any?) {
        let row = tableView.clickedRow
        guard row >= 0, row < entries.count else { return }
        do {
            _ = try PharosCore.deleteQueryHistoryEntry(id: entries[row].id)
            reload(connectionId: connectionFilter)
        } catch {
            NSLog("Failed to delete history entry: \(error)")
        }
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
        guard row < entries.count, let colId = tableColumn?.identifier else { return nil }
        let entry = entries[row]

        let cellId = NSUserInterfaceItemIdentifier("HistoryCell_\(colId.rawValue)")
        let cell: NSTableCellView
        if let existing = tableView.makeView(withIdentifier: cellId, owner: self) as? NSTableCellView {
            cell = existing
        } else {
            cell = NSTableCellView()
            cell.identifier = cellId
            let textField = NSTextField(labelWithString: "")
            textField.lineBreakMode = .byTruncatingTail
            textField.translatesAutoresizingMaskIntoConstraints = false
            cell.addSubview(textField)
            cell.textField = textField
            NSLayoutConstraint.activate([
                textField.leadingAnchor.constraint(equalTo: cell.leadingAnchor, constant: 4),
                textField.trailingAnchor.constraint(equalTo: cell.trailingAnchor, constant: -4),
                textField.centerYAnchor.constraint(equalTo: cell.centerYAnchor),
            ])
        }

        switch colId.rawValue {
        case "sql":
            // Show first line of SQL, truncated
            let firstLine = entry.sql.components(separatedBy: .newlines).first ?? entry.sql
            cell.textField?.stringValue = firstLine.trimmingCharacters(in: .whitespaces)
            cell.textField?.font = .monospacedSystemFont(ofSize: 11, weight: .regular)
            cell.textField?.textColor = .labelColor
        case "time":
            cell.textField?.stringValue = formatDuration(entry.executionTimeMs)
            cell.textField?.font = .systemFont(ofSize: 11)
            cell.textField?.textColor = .secondaryLabelColor
        case "date":
            cell.textField?.stringValue = formatDate(entry.executedAt)
            cell.textField?.font = .systemFont(ofSize: 11)
            cell.textField?.textColor = .secondaryLabelColor
        default:
            break
        }

        return cell
    }

    // MARK: - Formatting

    private func formatDuration(_ ms: Int64) -> String {
        if ms >= 1000 {
            return String(format: "%.1fs", Double(ms) / 1000)
        }
        return "\(ms)ms"
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

        menu.addItem(withTitle: "Copy SQL", action: #selector(contextCopySQL), keyEquivalent: "")
        menu.addItem(.separator())
        menu.addItem(withTitle: "Delete", action: #selector(contextDelete), keyEquivalent: "")
    }
}
