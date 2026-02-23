import AppKit

/// Provides SQL autocomplete via a popover with a table of suggestions.
class SQLCompletionProvider: NSObject {

    struct Completion {
        enum Kind {
            case keyword, function, snippet, schema, table, column, view
        }
        let label: String
        let detail: String
        let insertText: String
        let kind: Kind
    }

    private let popover = NSPopover()
    private let tableView = NSTableView()
    private let scrollView = NSScrollView()
    private var completions: [Completion] = []
    private var filteredCompletions: [Completion] = []
    private weak var textView: SQLTextView?
    private var currentWord: String = ""
    private var wordRange: NSRange = NSRange(location: 0, length: 0)

    /// Schema metadata for context-aware completions.
    var schemas: [SchemaInfo] = []
    var tables: [String: [TableInfo]] = [:] // schemaName -> tables
    var columnsByTable: [String: [ColumnInfo]] = [:] // schema.table -> columns

    override init() {
        super.init()

        let column = NSTableColumn(identifier: NSUserInterfaceItemIdentifier("completion"))
        column.width = 300
        tableView.addTableColumn(column)
        tableView.headerView = nil
        tableView.dataSource = self
        tableView.delegate = self
        tableView.rowSizeStyle = .custom
        tableView.rowHeight = 24
        tableView.target = self
        tableView.doubleAction = #selector(acceptCompletion)
        tableView.action = #selector(tableClicked)

        scrollView.documentView = tableView
        scrollView.hasVerticalScroller = true
        scrollView.autohidesScrollers = true

        let contentVC = NSViewController()
        contentVC.view = scrollView
        contentVC.preferredContentSize = NSSize(width: 320, height: 200)

        popover.contentViewController = contentVC
        popover.behavior = .transient
        popover.animates = false
    }

    // MARK: - Show/Hide

    func attachTo(_ textView: SQLTextView) {
        self.textView = textView
    }

    func showCompletions(for textView: SQLTextView) {
        guard let word = currentWordBeforeCursor(in: textView) else {
            dismiss()
            return
        }
        self.currentWord = word.text
        self.wordRange = word.range

        // Build completions based on context
        let context = analyzeContext(textView: textView)
        completions = buildCompletions(context: context)
        filterCompletions()

        guard !filteredCompletions.isEmpty else {
            dismiss()
            return
        }

        tableView.reloadData()
        tableView.selectRowIndexes(IndexSet(integer: 0), byExtendingSelection: false)

        if !popover.isShown {
            let cursorRect = cursorScreenRect(in: textView)
            popover.show(relativeTo: cursorRect, of: textView, preferredEdge: .minY)
        }
    }

    func dismiss() {
        if popover.isShown {
            popover.close()
        }
    }

    var isShown: Bool { popover.isShown }

    // MARK: - Keyboard Navigation

    func moveUp() {
        let row = tableView.selectedRow
        if row > 0 {
            tableView.selectRowIndexes(IndexSet(integer: row - 1), byExtendingSelection: false)
            tableView.scrollRowToVisible(row - 1)
        }
    }

    func moveDown() {
        let row = tableView.selectedRow
        if row < filteredCompletions.count - 1 {
            tableView.selectRowIndexes(IndexSet(integer: row + 1), byExtendingSelection: false)
            tableView.scrollRowToVisible(row + 1)
        }
    }

    func acceptSelected() {
        acceptCompletion()
    }

    // MARK: - Context Analysis

    private enum CompletionContext {
        case general
        case afterDot(prefix: String) // schema.table or table.column
        case afterFrom
        case afterJoin
        case afterWhere
        case afterSelect
    }

    private func analyzeContext(textView: SQLTextView) -> CompletionContext {
        let text = textView.string as NSString
        let cursor = textView.selectedRange().location
        let beforeCursor = text.substring(to: cursor).lowercased()
        let trimmed = beforeCursor.trimmingCharacters(in: .whitespacesAndNewlines)

        // Check for dot completion
        if let dotMatch = trimmed.range(of: #"(\w+)\.\w*$"#, options: .regularExpression) {
            let prefix = String(trimmed[dotMatch].components(separatedBy: ".").first ?? "")
            return .afterDot(prefix: prefix)
        }

        // Check for keyword context
        let words = trimmed.components(separatedBy: .whitespacesAndNewlines).filter { !$0.isEmpty }
        if let lastKeyword = words.last(where: { SQLCompletionProvider.contextKeywords.contains($0) }) {
            switch lastKeyword {
            case "from", "into", "update", "table": return .afterFrom
            case "join": return .afterJoin
            case "where", "and", "or", "on": return .afterWhere
            case "select": return .afterSelect
            default: break
            }
        }

        return .general
    }

    private static let contextKeywords = Set(["select", "from", "where", "join", "into", "update", "table", "and", "or", "on"])

    // MARK: - Completion Building

    private func buildCompletions(context: CompletionContext) -> [Completion] {
        var result: [Completion] = []

        switch context {
        case .afterDot(let prefix):
            // Schema → tables, or table → columns
            if let schemaTables = tables[prefix] {
                for table in schemaTables {
                    let kind: Completion.Kind = table.tableType == .view ? .view : .table
                    result.append(Completion(label: table.name, detail: table.tableType.rawValue, insertText: table.name, kind: kind))
                }
            }
            // Check as table name
            for (key, cols) in columnsByTable {
                let tableName = key.components(separatedBy: ".").last ?? ""
                if tableName.lowercased() == prefix.lowercased() {
                    for col in cols {
                        let pk = col.isPrimaryKey ? " PK" : ""
                        result.append(Completion(label: col.name, detail: "\(col.dataType)\(pk)", insertText: col.name, kind: .column))
                    }
                }
            }

        case .afterFrom, .afterJoin:
            // Suggest tables and schemas
            for schema in schemas {
                result.append(Completion(label: schema.name, detail: "schema", insertText: schema.name, kind: .schema))
            }
            for (_, schemaTables) in tables {
                for table in schemaTables {
                    let kind: Completion.Kind = table.tableType == .view ? .view : .table
                    result.append(Completion(label: table.name, detail: table.tableType.rawValue, insertText: table.name, kind: kind))
                }
            }

        case .afterWhere, .afterSelect:
            // Suggest columns from all known tables + keywords
            for (_, cols) in columnsByTable {
                for col in cols {
                    result.append(Completion(label: col.name, detail: col.dataType, insertText: col.name, kind: .column))
                }
            }
            result.append(contentsOf: keywordCompletions)
            result.append(contentsOf: functionCompletions)

        case .general:
            result.append(contentsOf: keywordCompletions)
            result.append(contentsOf: functionCompletions)
            // Add schema/table names
            for schema in schemas {
                result.append(Completion(label: schema.name, detail: "schema", insertText: schema.name, kind: .schema))
            }
            for (_, schemaTables) in tables {
                for table in schemaTables {
                    let kind: Completion.Kind = table.tableType == .view ? .view : .table
                    result.append(Completion(label: table.name, detail: table.tableType.rawValue, insertText: table.name, kind: kind))
                }
            }
        }

        return result
    }

    private func filterCompletions() {
        if currentWord.isEmpty {
            filteredCompletions = completions
        } else {
            let lower = currentWord.lowercased()
            filteredCompletions = completions.filter { $0.label.lowercased().hasPrefix(lower) }
            // Also include contains-matches, sorted after prefix matches
            let containsMatches = completions.filter {
                !$0.label.lowercased().hasPrefix(lower) && $0.label.lowercased().contains(lower)
            }
            filteredCompletions.append(contentsOf: containsMatches)
        }
    }

    // MARK: - Text Helpers

    private struct WordInfo {
        let text: String
        let range: NSRange
    }

    private func currentWordBeforeCursor(in textView: NSTextView) -> WordInfo? {
        let text = textView.string as NSString
        let cursor = textView.selectedRange().location
        guard cursor > 0 else { return nil }

        var start = cursor
        while start > 0 {
            let char = text.character(at: start - 1)
            let scalar = UnicodeScalar(char)
            if scalar == nil || (!CharacterSet.alphanumerics.contains(scalar!) && scalar! != UnicodeScalar("_")) {
                break
            }
            start -= 1
        }

        let length = cursor - start
        if length == 0 { return nil }
        let range = NSRange(location: start, length: length)
        return WordInfo(text: text.substring(with: range), range: range)
    }

    private func cursorScreenRect(in textView: NSTextView) -> NSRect {
        guard let layoutManager = textView.layoutManager else {
            return NSRect(x: 0, y: 0, width: 1, height: 16)
        }
        let glyphIndex = layoutManager.glyphIndexForCharacter(at: textView.selectedRange().location)
        var lineRect = layoutManager.lineFragmentRect(forGlyphAt: max(0, glyphIndex), effectiveRange: nil)
        let location = layoutManager.location(forGlyphAt: max(0, glyphIndex))
        lineRect.origin.x += location.x + textView.textContainerInset.width
        lineRect.origin.y += textView.textContainerInset.height
        lineRect.size.width = 1
        return lineRect
    }

    @objc private func acceptCompletion() {
        let row = tableView.selectedRow
        guard row >= 0, row < filteredCompletions.count, let textView else { return }
        let completion = filteredCompletions[row]

        // Replace the current word with the completion
        textView.insertText(completion.insertText, replacementRange: wordRange)
        dismiss()
    }

    @objc private func tableClicked() {
        // Single click just selects
    }

    // MARK: - Static Data

    private var keywordCompletions: [Completion] {
        Self.sqlKeywords.map { Completion(label: $0, detail: "keyword", insertText: $0, kind: .keyword) }
    }

    private var functionCompletions: [Completion] {
        Self.sqlFunctions.map { Completion(label: $0, detail: "function", insertText: "\($0)()", kind: .function) }
    }

    private static let sqlKeywords = [
        "SELECT", "FROM", "WHERE", "AND", "OR", "NOT", "IN", "LIKE", "ILIKE",
        "BETWEEN", "IS", "NULL", "TRUE", "FALSE",
        "ORDER", "BY", "ASC", "DESC", "NULLS", "FIRST", "LAST",
        "GROUP", "HAVING", "LIMIT", "OFFSET",
        "JOIN", "INNER", "LEFT", "RIGHT", "FULL", "OUTER", "CROSS", "ON",
        "UNION", "ALL", "INTERSECT", "EXCEPT",
        "INSERT", "INTO", "VALUES", "DEFAULT",
        "UPDATE", "SET", "DELETE",
        "CREATE", "TABLE", "INDEX", "VIEW", "SCHEMA",
        "ALTER", "ADD", "DROP", "COLUMN", "CONSTRAINT",
        "PRIMARY", "KEY", "FOREIGN", "REFERENCES", "UNIQUE", "CHECK",
        "CASCADE", "RESTRICT",
        "AS", "DISTINCT", "CASE", "WHEN", "THEN", "ELSE", "END",
        "EXISTS", "ANY", "WITH", "RECURSIVE", "RETURNING",
        "BEGIN", "COMMIT", "ROLLBACK",
        "EXPLAIN", "ANALYZE",
    ]

    private static let sqlFunctions = [
        "count", "sum", "avg", "min", "max", "array_agg", "string_agg",
        "length", "lower", "upper", "trim", "substring", "concat", "replace",
        "now", "current_date", "current_timestamp", "date_trunc", "extract",
        "abs", "ceil", "floor", "round", "random",
        "json_build_object", "jsonb_build_object", "json_agg", "jsonb_agg",
        "coalesce", "nullif", "greatest", "least", "generate_series",
        "row_number", "rank", "dense_rank", "lag", "lead",
    ]
}

// MARK: - NSTableViewDataSource

extension SQLCompletionProvider: NSTableViewDataSource {
    func numberOfRows(in tableView: NSTableView) -> Int {
        filteredCompletions.count
    }
}

// MARK: - NSTableViewDelegate

extension SQLCompletionProvider: NSTableViewDelegate {
    func tableView(_ tableView: NSTableView, viewFor tableColumn: NSTableColumn?, row: Int) -> NSView? {
        guard row < filteredCompletions.count else { return nil }
        let item = filteredCompletions[row]

        let cellId = NSUserInterfaceItemIdentifier("CompletionCell")
        let cell: NSTableCellView
        if let existing = tableView.makeView(withIdentifier: cellId, owner: self) as? NSTableCellView {
            cell = existing
        } else {
            cell = NSTableCellView()
            cell.identifier = cellId

            let iconView = NSImageView()
            iconView.translatesAutoresizingMaskIntoConstraints = false
            let label = NSTextField(labelWithString: "")
            label.translatesAutoresizingMaskIntoConstraints = false
            label.font = .monospacedSystemFont(ofSize: 12, weight: .regular)
            let detail = NSTextField(labelWithString: "")
            detail.translatesAutoresizingMaskIntoConstraints = false
            detail.font = .systemFont(ofSize: 10)
            detail.textColor = .secondaryLabelColor
            detail.tag = 100

            cell.addSubview(iconView)
            cell.addSubview(label)
            cell.addSubview(detail)
            cell.imageView = iconView
            cell.textField = label

            NSLayoutConstraint.activate([
                iconView.leadingAnchor.constraint(equalTo: cell.leadingAnchor, constant: 4),
                iconView.centerYAnchor.constraint(equalTo: cell.centerYAnchor),
                iconView.widthAnchor.constraint(equalToConstant: 16),
                iconView.heightAnchor.constraint(equalToConstant: 16),

                label.leadingAnchor.constraint(equalTo: iconView.trailingAnchor, constant: 4),
                label.centerYAnchor.constraint(equalTo: cell.centerYAnchor),

                detail.trailingAnchor.constraint(equalTo: cell.trailingAnchor, constant: -4),
                detail.centerYAnchor.constraint(equalTo: cell.centerYAnchor),
            ])
        }

        cell.textField?.stringValue = item.label

        let detailField = cell.viewWithTag(100) as? NSTextField
        detailField?.stringValue = item.detail

        let iconName: String
        switch item.kind {
        case .keyword: iconName = "textformat"
        case .function: iconName = "function"
        case .snippet: iconName = "text.document"
        case .schema: iconName = "folder"
        case .table: iconName = "tablecells"
        case .column: iconName = "line.3.horizontal"
        case .view: iconName = "eye"
        }
        cell.imageView?.image = NSImage(systemSymbolName: iconName, accessibilityDescription: nil)
        cell.imageView?.contentTintColor = .secondaryLabelColor

        return cell
    }
}
