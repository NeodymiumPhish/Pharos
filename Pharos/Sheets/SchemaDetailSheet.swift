import AppKit

/// Reusable modal sheet for displaying schema detail data (indexes, constraints, functions)
/// in a table view. Presented via context menu from the schema browser.
class SchemaDetailSheet: NSViewController {

    enum DetailKind {
        case indexes(schema: String, table: String, items: [IndexInfo])
        case constraints(schema: String, table: String, items: [ConstraintInfo])
        case functions(schema: String, items: [FunctionInfo])
    }

    private let kind: DetailKind
    private let tableView = NSTableView()

    private init(kind: DetailKind) {
        self.kind = kind
        super.init(nibName: nil, bundle: nil)
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) not implemented")
    }

    // MARK: - Factory

    static func forIndexes(schema: String, table: String, items: [IndexInfo]) -> SchemaDetailSheet {
        SchemaDetailSheet(kind: .indexes(schema: schema, table: table, items: items))
    }

    static func forConstraints(schema: String, table: String, items: [ConstraintInfo]) -> SchemaDetailSheet {
        SchemaDetailSheet(kind: .constraints(schema: schema, table: table, items: items))
    }

    static func forFunctions(schema: String, items: [FunctionInfo]) -> SchemaDetailSheet {
        SchemaDetailSheet(kind: .functions(schema: schema, items: items))
    }

    // MARK: - View Lifecycle

    override func loadView() {
        let container = NSView(frame: NSRect(x: 0, y: 0, width: 620, height: 400))
        self.view = container

        // Title
        let titleLabel = NSTextField(labelWithString: sheetTitle)
        titleLabel.font = .systemFont(ofSize: 17, weight: .semibold)
        titleLabel.translatesAutoresizingMaskIntoConstraints = false

        // Table view
        setupColumns()
        tableView.dataSource = self
        tableView.delegate = self
        tableView.usesAlternatingRowBackgroundColors = true
        tableView.rowSizeStyle = .default
        tableView.columnAutoresizingStyle = .uniformColumnAutoresizingStyle

        let scrollView = NSScrollView()
        scrollView.documentView = tableView
        scrollView.hasVerticalScroller = true
        scrollView.autohidesScrollers = true
        scrollView.translatesAutoresizingMaskIntoConstraints = false

        // Close button
        let closeButton = NSButton(title: "Close", target: self, action: #selector(closeSheet))
        closeButton.keyEquivalent = "\u{1b}" // Escape
        closeButton.translatesAutoresizingMaskIntoConstraints = false

        // Empty state
        if rowCount == 0 {
            let emptyLabel = NSTextField(labelWithString: emptyMessage)
            emptyLabel.font = .systemFont(ofSize: 13)
            emptyLabel.textColor = .secondaryLabelColor
            emptyLabel.alignment = .center
            emptyLabel.translatesAutoresizingMaskIntoConstraints = false

            container.addSubview(titleLabel)
            container.addSubview(emptyLabel)
            container.addSubview(closeButton)

            NSLayoutConstraint.activate([
                titleLabel.topAnchor.constraint(equalTo: container.topAnchor, constant: 20),
                titleLabel.centerXAnchor.constraint(equalTo: container.centerXAnchor),

                emptyLabel.centerXAnchor.constraint(equalTo: container.centerXAnchor),
                emptyLabel.centerYAnchor.constraint(equalTo: container.centerYAnchor),

                closeButton.bottomAnchor.constraint(equalTo: container.bottomAnchor, constant: -16),
                closeButton.trailingAnchor.constraint(equalTo: container.trailingAnchor, constant: -20),
            ])
            return
        }

        container.addSubview(titleLabel)
        container.addSubview(scrollView)
        container.addSubview(closeButton)

        NSLayoutConstraint.activate([
            titleLabel.topAnchor.constraint(equalTo: container.topAnchor, constant: 20),
            titleLabel.centerXAnchor.constraint(equalTo: container.centerXAnchor),

            scrollView.topAnchor.constraint(equalTo: titleLabel.bottomAnchor, constant: 12),
            scrollView.leadingAnchor.constraint(equalTo: container.leadingAnchor, constant: 16),
            scrollView.trailingAnchor.constraint(equalTo: container.trailingAnchor, constant: -16),
            scrollView.bottomAnchor.constraint(equalTo: closeButton.topAnchor, constant: -12),

            closeButton.bottomAnchor.constraint(equalTo: container.bottomAnchor, constant: -16),
            closeButton.trailingAnchor.constraint(equalTo: container.trailingAnchor, constant: -20),
        ])
    }

    // MARK: - Actions

    @objc private func closeSheet() {
        dismiss(nil)
    }

    // MARK: - Column Setup

    private func setupColumns() {
        switch kind {
        case .indexes:
            addColumn("Name", width: 160)
            addColumn("Columns", width: 180)
            addColumn("Type", width: 80)
            addColumn("Unique", width: 60)
            addColumn("Primary", width: 60)

        case .constraints:
            addColumn("Name", width: 160)
            addColumn("Type", width: 100)
            addColumn("Columns", width: 150)
            addColumn("References", width: 180)

        case .functions:
            addColumn("Name", width: 150)
            addColumn("Arguments", width: 180)
            addColumn("Returns", width: 100)
            addColumn("Language", width: 80)
        }
    }

    private func addColumn(_ title: String, width: CGFloat) {
        let col = NSTableColumn(identifier: NSUserInterfaceItemIdentifier(title))
        col.title = title
        col.width = width
        col.minWidth = 40
        tableView.addTableColumn(col)
    }

    // MARK: - Helpers

    private var sheetTitle: String {
        switch kind {
        case .indexes(let schema, let table, _):
            return "Indexes — \(schema).\(table)"
        case .constraints(let schema, let table, _):
            return "Constraints — \(schema).\(table)"
        case .functions(let schema, _):
            return "Functions — \(schema)"
        }
    }

    private var rowCount: Int {
        switch kind {
        case .indexes(_, _, let items): return items.count
        case .constraints(_, _, let items): return items.count
        case .functions(_, let items): return items.count
        }
    }

    private var emptyMessage: String {
        switch kind {
        case .indexes: return "No indexes found."
        case .constraints: return "No constraints found."
        case .functions: return "No functions found."
        }
    }
}

// MARK: - NSTableViewDataSource & Delegate

extension SchemaDetailSheet: NSTableViewDataSource, NSTableViewDelegate {

    func numberOfRows(in tableView: NSTableView) -> Int {
        rowCount
    }

    func tableView(_ tableView: NSTableView, viewFor tableColumn: NSTableColumn?, row: Int) -> NSView? {
        guard let columnId = tableColumn?.identifier.rawValue else { return nil }

        let cellId = NSUserInterfaceItemIdentifier("DetailCell_\(columnId)")
        let cell: NSTextField
        if let existing = tableView.makeView(withIdentifier: cellId, owner: self) as? NSTextField {
            cell = existing
        } else {
            cell = NSTextField(labelWithString: "")
            cell.identifier = cellId
            cell.lineBreakMode = .byTruncatingTail
            cell.font = .systemFont(ofSize: 12)
        }

        cell.stringValue = cellValue(column: columnId, row: row)
        return cell
    }

    private func cellValue(column: String, row: Int) -> String {
        switch kind {
        case .indexes(_, _, let items):
            let item = items[row]
            switch column {
            case "Name": return item.name
            case "Columns": return item.columns.joined(separator: ", ")
            case "Type": return item.indexType
            case "Unique": return item.isUnique ? "Yes" : "No"
            case "Primary": return item.isPrimary ? "Yes" : "No"
            default: return ""
            }

        case .constraints(_, _, let items):
            let item = items[row]
            switch column {
            case "Name": return item.name
            case "Type": return item.constraintType
            case "Columns": return item.columns.joined(separator: ", ")
            case "References":
                if let ref = item.referencedTable {
                    let cols = item.referencedColumns?.joined(separator: ", ") ?? ""
                    return "\(ref)(\(cols))"
                }
                return item.checkClause ?? ""
            default: return ""
            }

        case .functions(_, let items):
            let item = items[row]
            switch column {
            case "Name": return item.name
            case "Arguments": return item.argumentTypes
            case "Returns": return item.returnType
            case "Language": return item.language
            default: return ""
            }
        }
    }
}
