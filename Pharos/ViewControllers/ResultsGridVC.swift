import AppKit

/// Displays query results in an NSTableView.
class ResultsGridVC: NSViewController, NSTableViewDataSource, NSTableViewDelegate {

    private let tableView = NSTableView()
    private let scrollView = NSScrollView()
    private let statusBar = NSTextField(labelWithString: "")
    private let emptyLabel = NSTextField(labelWithString: "Run a query to see results")

    private var columns: [ColumnDef] = []
    private var rows: [[String: AnyCodable]] = []
    private var rowCount: Int = 0
    private var hasMore: Bool = false
    private var executionTimeMs: UInt64 = 0

    override func loadView() {
        let container = NSView(frame: NSRect(x: 0, y: 0, width: 600, height: 300))
        self.view = container

        // Status bar at top
        statusBar.translatesAutoresizingMaskIntoConstraints = false
        statusBar.font = .systemFont(ofSize: 11)
        statusBar.textColor = .secondaryLabelColor
        statusBar.isHidden = true

        // Table view
        tableView.dataSource = self
        tableView.delegate = self
        tableView.usesAlternatingRowBackgroundColors = true
        tableView.allowsMultipleSelection = true
        tableView.allowsColumnReordering = true
        tableView.allowsColumnResizing = true
        tableView.rowSizeStyle = .custom
        tableView.rowHeight = 22
        tableView.gridStyleMask = [.solidHorizontalGridLineMask, .solidVerticalGridLineMask]
        tableView.gridColor = .separatorColor
        tableView.intercellSpacing = NSSize(width: 8, height: 0)
        tableView.columnAutoresizingStyle = .noColumnAutoresizing

        scrollView.documentView = tableView
        scrollView.hasVerticalScroller = true
        scrollView.hasHorizontalScroller = true
        scrollView.autohidesScrollers = true
        scrollView.translatesAutoresizingMaskIntoConstraints = false
        scrollView.borderType = .noBorder

        // Empty state
        emptyLabel.translatesAutoresizingMaskIntoConstraints = false
        emptyLabel.textColor = .tertiaryLabelColor
        emptyLabel.font = .systemFont(ofSize: 13)
        emptyLabel.alignment = .center

        container.addSubview(statusBar)
        container.addSubview(scrollView)
        container.addSubview(emptyLabel)

        NSLayoutConstraint.activate([
            statusBar.topAnchor.constraint(equalTo: container.topAnchor, constant: 4),
            statusBar.leadingAnchor.constraint(equalTo: container.leadingAnchor, constant: 8),
            statusBar.trailingAnchor.constraint(equalTo: container.trailingAnchor, constant: -8),

            scrollView.topAnchor.constraint(equalTo: statusBar.bottomAnchor, constant: 4),
            scrollView.leadingAnchor.constraint(equalTo: container.leadingAnchor),
            scrollView.trailingAnchor.constraint(equalTo: container.trailingAnchor),
            scrollView.bottomAnchor.constraint(equalTo: container.bottomAnchor),

            emptyLabel.centerXAnchor.constraint(equalTo: container.centerXAnchor),
            emptyLabel.centerYAnchor.constraint(equalTo: container.centerYAnchor),
        ])
    }

    // MARK: - Public API

    func showResult(_ result: QueryResult) {
        self.columns = result.columns
        self.rows = result.rows
        self.rowCount = result.rowCount
        self.hasMore = result.hasMore
        self.executionTimeMs = result.executionTimeMs

        rebuildColumns()
        tableView.reloadData()
        emptyLabel.isHidden = true
        scrollView.isHidden = false
        statusBar.isHidden = false

        let timeStr = formatDuration(executionTimeMs)
        let moreStr = hasMore ? " (more available)" : ""
        statusBar.stringValue = "\(rowCount) row\(rowCount == 1 ? "" : "s") in \(timeStr)\(moreStr)"
    }

    func showExecuteResult(_ result: ExecuteResult) {
        clear()
        statusBar.isHidden = false
        let timeStr = formatDuration(result.executionTimeMs)
        statusBar.stringValue = "\(result.rowsAffected) row\(result.rowsAffected == 1 ? "" : "s") affected in \(timeStr)"
    }

    func showError(_ message: String) {
        clear()
        emptyLabel.stringValue = message
        emptyLabel.textColor = .systemRed
        emptyLabel.isHidden = false
    }

    func clear() {
        columns = []
        rows = []
        rowCount = 0
        hasMore = false
        executionTimeMs = 0

        // Remove all table columns
        while let col = tableView.tableColumns.last {
            tableView.removeTableColumn(col)
        }
        tableView.reloadData()
        emptyLabel.stringValue = "Run a query to see results"
        emptyLabel.textColor = .tertiaryLabelColor
        emptyLabel.isHidden = false
        scrollView.isHidden = true
        statusBar.isHidden = true
    }

    // MARK: - Column Setup

    private func rebuildColumns() {
        // Remove existing columns
        while let col = tableView.tableColumns.last {
            tableView.removeTableColumn(col)
        }

        // Row number column
        let rowNumCol = NSTableColumn(identifier: NSUserInterfaceItemIdentifier("__rownum__"))
        rowNumCol.title = "#"
        rowNumCol.width = 40
        rowNumCol.minWidth = 30
        rowNumCol.maxWidth = 60
        tableView.addTableColumn(rowNumCol)

        // Data columns
        for colDef in columns {
            let col = NSTableColumn(identifier: NSUserInterfaceItemIdentifier(colDef.name))
            col.title = colDef.name
            col.width = estimateColumnWidth(colDef)
            col.minWidth = 50
            col.maxWidth = 600

            // Header with type subtitle
            let headerCell = NSTableHeaderCell()
            headerCell.stringValue = "\(colDef.name)\n\(colDef.dataType)"
            headerCell.font = .systemFont(ofSize: 11, weight: .medium)
            col.headerCell = headerCell
            col.headerCell.stringValue = colDef.name

            tableView.addTableColumn(col)
        }
    }

    private func estimateColumnWidth(_ col: ColumnDef) -> CGFloat {
        let nameWidth = CGFloat(col.name.count) * 8 + 20
        let typeWidth: CGFloat
        switch col.dataType.lowercased() {
        case "boolean", "bool": typeWidth = 60
        case "integer", "int", "int4", "smallint", "int2": typeWidth = 80
        case "bigint", "int8": typeWidth = 100
        case "uuid": typeWidth = 260
        case "timestamp", "timestamptz": typeWidth = 180
        case "date": typeWidth = 100
        default: typeWidth = 150
        }
        return max(nameWidth, typeWidth)
    }

    // MARK: - NSTableViewDataSource

    func numberOfRows(in tableView: NSTableView) -> Int {
        rows.count
    }

    // MARK: - NSTableViewDelegate

    func tableView(_ tableView: NSTableView, viewFor tableColumn: NSTableColumn?, row: Int) -> NSView? {
        guard let colId = tableColumn?.identifier, row < rows.count else { return nil }

        let cellId = NSUserInterfaceItemIdentifier("ResultCell_\(colId.rawValue)")
        let cell: NSTableCellView

        if let existing = tableView.makeView(withIdentifier: cellId, owner: self) as? NSTableCellView {
            cell = existing
        } else {
            cell = NSTableCellView()
            cell.identifier = cellId
            let textField = NSTextField(labelWithString: "")
            textField.lineBreakMode = .byTruncatingTail
            textField.font = .monospacedSystemFont(ofSize: 12, weight: .regular)
            textField.translatesAutoresizingMaskIntoConstraints = false
            cell.addSubview(textField)
            cell.textField = textField
            NSLayoutConstraint.activate([
                textField.leadingAnchor.constraint(equalTo: cell.leadingAnchor, constant: 2),
                textField.trailingAnchor.constraint(equalTo: cell.trailingAnchor, constant: -2),
                textField.centerYAnchor.constraint(equalTo: cell.centerYAnchor),
            ])
        }

        if colId.rawValue == "__rownum__" {
            cell.textField?.stringValue = "\(row + 1)"
            cell.textField?.textColor = .tertiaryLabelColor
            cell.textField?.font = .monospacedDigitSystemFont(ofSize: 11, weight: .regular)
        } else {
            let rowData = rows[row]
            if let value = rowData[colId.rawValue] {
                if value.isNull {
                    cell.textField?.stringValue = "NULL"
                    cell.textField?.textColor = .tertiaryLabelColor
                    cell.textField?.font = .monospacedSystemFont(ofSize: 12, weight: .regular)
                } else {
                    cell.textField?.stringValue = value.displayString
                    cell.textField?.textColor = .labelColor
                    cell.textField?.font = .monospacedSystemFont(ofSize: 12, weight: .regular)
                }
            } else {
                cell.textField?.stringValue = ""
                cell.textField?.textColor = .labelColor
            }
        }

        return cell
    }

    // MARK: - Copy Support

    @objc func copy(_ sender: Any?) {
        let selectedRows = tableView.selectedRowIndexes
        guard !selectedRows.isEmpty else { return }

        var lines: [String] = []
        let colIds = tableView.tableColumns.compactMap { col -> String? in
            let id = col.identifier.rawValue
            return id == "__rownum__" ? nil : id
        }

        for row in selectedRows {
            guard row < rows.count else { continue }
            let rowData = rows[row]
            let values = colIds.map { rowData[$0]?.displayString ?? "" }
            lines.append(values.joined(separator: "\t"))
        }

        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(lines.joined(separator: "\n"), forType: .string)
    }

    // MARK: - Formatting

    private func formatDuration(_ ms: UInt64) -> String {
        if ms >= 1000 {
            return String(format: "%.1fs", Double(ms) / 1000)
        }
        return "\(ms)ms"
    }
}
