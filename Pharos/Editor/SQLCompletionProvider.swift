import AppKit

/// Provides SQL autocomplete via a popover with a table of suggestions.
class SQLCompletionProvider: NSObject {

    struct Completion: Equatable {
        enum Kind {
            case keyword, function, snippet, schema, table, column, view
            /// A `{{name}}` query variable that exists.
            case variable
            /// The `{{` list's row that creates a variable with the typed name.
            case newVariable

            /// How the kind reads out. The row's icon is the only *visible*
            /// encoding of the kind, and an icon says nothing to VoiceOver —
            /// so this word goes into the symbol's accessibility description
            /// and into the row's label.
            var displayName: String {
                switch self {
                case .keyword: return "Keyword"
                case .function: return "Function"
                case .snippet: return "Snippet"
                case .schema: return "Schema"
                case .table: return "Table"
                case .column: return "Column"
                case .view: return "View"
                case .variable: return "Variable"
                case .newVariable: return "New Variable"
                }
            }
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

    // MARK: Query variables

    /// A query variable as the `{{` list shows it.
    struct VariableEntry: Equatable {
        let name: String
        /// One line of the value (`VariableValuePreview.snippet`).
        let preview: String
    }

    /// The app-wide query variables, in list order. The `{{` list offers these.
    var variables: [VariableEntry] = []

    /// Called after a `{{` row is accepted and `{{name}}` is written, with
    /// the name. The owner opens (or creates) that variable in the sidebar.
    var onVariableChosen: ((String) -> Void)?

    /// The `{{` token the list is completing; nil while it shows the SQL list.
    private var variableContext: VariableCompletion.Context?

    /// How much of a value preview a row shows. The row is one line, and the
    /// value is often a long comma-joined list.
    private static let variablePreviewLimit = 40

    /// Schema metadata for context-aware completions. Setters rebuild the
    /// catalog snapshot the resolver reads, so the per-keystroke path does
    /// no conversion.
    var schemas: [SchemaInfo] = [] {
        didSet { rebuildCatalog() }
    }
    var tables: [String: [TableInfo]] = [:] {
        didSet { rebuildCatalog() }
    }
    var columnsByTable: [String: [ColumnInfo]] = [:] {
        didSet { rebuildCatalog() }
    }

    /// Where an unqualified table is looked for first: the toolbar's schema,
    /// or the connection's default. nil means `public` alone.
    var currentSchema: String?

    /// Asked, with a schema name, to have that schema's tables and columns
    /// loaded (the metadata cache loads per schema, lazily). Called for the
    /// schemas the statement at the caret refers to.
    var onSchemaNeeded: ((String) -> Void)?

    private var catalog = CompletionResolver.Catalog()

    private func rebuildCatalog() {
        var built = CompletionResolver.Catalog()
        built.schemas = schemas.map(\.name)
        for (schema, list) in tables {
            built.tables[schema] = list.map { .init(name: $0.name, isView: $0.tableType == .view) }
        }
        for (key, list) in columnsByTable {
            built.columns[key] = list.map { .init(name: $0.name, type: $0.dataType, isPrimaryKey: $0.isPrimaryKey) }
        }
        catalog = built
    }

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

    // MARK: - Accessibility Text
    //
    // The popover never takes focus — key events stay with the text view so
    // typing keeps filtering the list — so VoiceOver never moves into the
    // table and never reads a row on its own. These strings are spoken to the
    // user instead, as announcements. They are pure functions so the test
    // harness can check the wording without a screen reader.

    /// A row, read as one phrase: "count, Function, aggregate". The detail is
    /// dropped when it only repeats the kind (a keyword's detail is
    /// "keyword"), which would otherwise be read out twice.
    static func rowLabel(for item: Completion) -> String {
        var parts = [DisplayEscape.escaped(item.label), item.kind.displayName]
        let detail = DisplayEscape.escaped(item.detail)
        if !detail.isEmpty, detail.caseInsensitiveCompare(item.kind.displayName) != .orderedSame {
            parts.append(detail)
        }
        return parts.joined(separator: ", ")
    }

    /// What is said when the list appears: how many there are, then the row
    /// that is already selected.
    static func announcementText(for item: Completion?, count: Int) -> String {
        let noun = count == 1 ? "completion" : "completions"
        guard let item else { return "\(count) \(noun)" }
        return "\(count) \(noun). \(DisplayEscape.escaped(item.label)), \(item.kind.displayName)"
    }

    /// What is said when the arrow keys move the selection.
    static func selectionAnnouncementText(for item: Completion) -> String {
        "\(DisplayEscape.escaped(item.label)), \(item.kind.displayName)"
    }

    private func announce(_ text: String) {
        guard !text.isEmpty else { return }
        let element: Any = NSApp?.mainWindow ?? textView ?? self
        NSAccessibility.post(
            element: element, notification: .announcementRequested,
            userInfo: [
                .announcement: text,
                .priority: NSAccessibilityPriorityLevel.high.rawValue,
            ]
        )
    }

    private func announceSelectedRow() {
        let row = tableView.selectedRow
        guard row >= 0, row < filteredCompletions.count else { return }
        announce(Self.selectionAnnouncementText(for: filteredCompletions[row]))
    }

    /// Test seam: PharosTests/CompletionAccessibilityTests.swift drives
    /// `tableView(_:viewFor:row:)` directly against a stub table. Production
    /// code never calls this.
    func setFilteredCompletionsForTesting(_ items: [Completion]) {
        filteredCompletions = items
    }

    /// Test seam: the rows the list shows, in order.
    var visibleCompletionsForTesting: [Completion] { filteredCompletions }

    /// Room for the overlay scroller at a row's trailing edge.
    static let detailTrailingInset: CGFloat = 18

    // MARK: - Show/Hide

    func attachTo(_ textView: SQLTextView) {
        self.textView = textView
    }

    func showCompletions(for textView: SQLTextView) {
        let text = textView.string as NSString
        let cursor = min(textView.selectedRange().location, text.length)

        // Inside a `{{` token the list is the variable list, whatever the SQL
        // context around it.
        if let context = VariableCompletion.context(in: text, caret: cursor) {
            variableContext = context
            filteredCompletions = variableCompletions(for: context)
            present(in: textView)
            return
        }

        // The caret left the token (a space, a brace, a deleted `{{`): the
        // variable list closes rather than turning into the SQL list.
        let wasVariableList = variableContext != nil && popover.isShown
        variableContext = nil
        if wasVariableList {
            dismiss()
            return
        }

        // What the statement around the caret expects, and the rows for it.
        let scope = SQLStatementScope.analyze(textView.string, caret: cursor)
        let typedLength = (scope.typed as NSString).length
        currentWord = scope.typed
        wordRange = NSRange(location: cursor - typedLength, length: typedLength)

        let env = CompletionResolver.Environment(catalog: catalog, currentSchema: currentSchema, variables: variables)
        for schema in CompletionResolver.referencedSchemas(scope, in: env) {
            onSchemaNeeded?(schema)
        }
        completions = CompletionResolver.rows(for: scope, in: env)
        filterCompletions()
        present(in: textView)
    }

    /// Show `filteredCompletions` with the first row selected, or close the
    /// list when there is nothing to show.
    private func present(in textView: SQLTextView) {
        guard !filteredCompletions.isEmpty else {
            dismiss()
            return
        }

        tableView.reloadData()
        tableView.selectRowIndexes(IndexSet(integer: 0), byExtendingSelection: false)
        tableView.scrollRowToVisible(0)

        if !popover.isShown {
            let cursorRect = cursorScreenRect(in: textView)
            popover.show(relativeTo: cursorRect, of: textView, preferredEdge: .maxY)
            // Keep text view as first responder so key events route through it
            textView.window?.makeFirstResponder(textView)
            // Nothing else tells a screen-reader user the list arrived: the
            // popover never takes focus, so no focus change is reported.
            announce(Self.announcementText(
                for: filteredCompletions.first, count: filteredCompletions.count))
        }
    }

    /// The `{{` list's rows: `VariableCompletion.items` as completions.
    private func variableCompletions(for context: VariableCompletion.Context) -> [Completion] {
        // Last definition wins, as it does when the query runs.
        var previews: [String: String] = [:]
        for variable in variables { previews[variable.name] = variable.preview }

        let items = VariableCompletion.items(names: variables.map(\.name), typed: context.typed)
        return items.prefix(max(1, maximumItems)).map { item in
            if item.isNew {
                return Completion(label: item.name, detail: "new variable", insertText: item.name, kind: .newVariable)
            }
            var preview = previews[item.name] ?? ""
            if preview.count > Self.variablePreviewLimit {
                preview = String(preview.prefix(Self.variablePreviewLimit)) + "…"
            }
            return Completion(label: item.name, detail: preview, insertText: item.name, kind: .variable)
        }
    }

    func dismiss() {
        variableContext = nil
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
            announceSelectedRow()
        }
    }

    func moveDown() {
        let row = tableView.selectedRow
        if row < filteredCompletions.count - 1 {
            tableView.selectRowIndexes(IndexSet(integer: row + 1), byExtendingSelection: false)
            tableView.scrollRowToVisible(row + 1)
            announceSelectedRow()
        }
    }

    func acceptSelected() {
        acceptCompletion()
    }

    /// Hard cap on the result count. The popover only renders a handful of
    /// rows at once; producing thousands of matches just to sort and dedupe
    /// is wasted work on databases with very large schemas.
    ///
    /// Settings ▸ Editor ▸ Completion ▸ Maximum suggestions. 200 is the
    /// figure this was hard-coded to before the setting existed.
    var maximumItems: Int = 200

    /// The case a KEYWORD takes as it is inserted. Settings ▸ Editor.
    /// `.upper` is what the keyword list has always produced.
    var keywordCase: KeywordCase = .upper

    private func filterCompletions() {
        let cap = max(1, maximumItems)
        var seen = Set<String>()
        var out: [Completion] = []
        out.reserveCapacity(min(cap, 200))

        // Dedupe on what would be inserted, not on the label: `id` of two
        // tables in scope inserts as `u.id` and `o.id`, and both belong.
        func take(_ c: Completion) -> Bool {
            guard seen.insert(c.insertText).inserted else { return false }
            out.append(c)
            return out.count >= cap
        }

        if currentWord.isEmpty {
            for c in completions where take(c) { break }
        } else {
            let lower = currentWord.lowercased()
            // Pass 1: prefix matches (higher relevance).
            for c in completions where c.label.lowercased().hasPrefix(lower) {
                if take(c) { break }
            }
            // Pass 2: contains matches.
            if out.count < cap {
                for c in completions where c.label.lowercased().contains(lower) {
                    if take(c) { break }
                }
            }
            // Pass 3: initials — `uci` finds `user_created_id`.
            if out.count < cap {
                for c in completions where Self.initials(of: c.label).hasPrefix(lower) {
                    if take(c) { break }
                }
            }
        }
        filteredCompletions = out
    }

    /// The first letter of each `_`-separated word, lower-cased.
    static func initials(of label: String) -> String {
        label.split(separator: "_").compactMap { $0.first?.lowercased() }.joined()
    }

    // MARK: - Text Helpers

    private func cursorScreenRect(in textView: NSTextView) -> NSRect {
        guard let layoutManager = textView.layoutManager else {
            return NSRect(x: 0, y: 0, width: 1, height: 16)
        }
        let textLength = (textView.string as NSString).length
        // Clamp to valid character range (cursor can be at end of text)
        let charIndex = min(textView.selectedRange().location, max(0, textLength - 1))
        let glyphIndex = layoutManager.glyphIndexForCharacter(at: charIndex)
        let lineRect = layoutManager.lineFragmentRect(forGlyphAt: glyphIndex, effectiveRange: nil)
        let glyphLocation = layoutManager.location(forGlyphAt: glyphIndex)
        let origin = textView.textContainerOrigin
        return NSRect(
            x: lineRect.origin.x + glyphLocation.x + origin.x,
            y: lineRect.origin.y + origin.y,
            width: 1,
            height: lineRect.height
        )
    }

    @objc private func acceptCompletion() {
        let row = tableView.selectedRow
        guard row >= 0, row < filteredCompletions.count, let textView else { return }
        let completion = filteredCompletions[row]

        if variableContext != nil {
            acceptVariable(completion, in: textView)
            return
        }

        // A KEYWORD takes the case the user asked for; everything else — a
        // schema, a table, a column, a function — keeps the name the database
        // gave it, because that name is not ours to re-case.
        let insertText = completion.kind == .keyword
            ? KeywordCasing.applied(completion.insertText, case: keywordCase, typed: currentWord)
            : completion.insertText

        // Replace the current word with the completion
        textView.insertText(insertText, replacementRange: wordRange)
        dismiss()
    }

    /// Write `{{name}}` over the token, put the caret after it, and report
    /// the name.
    private func acceptVariable(_ completion: Completion, in textView: SQLTextView) {
        // Read the token again: the caret can move without an edit (the
        // arrow keys), so the context from the last keystroke can be stale.
        let text = textView.string as NSString
        let cursor = min(textView.selectedRange().location, text.length)
        guard let context = VariableCompletion.context(in: text, caret: cursor) else {
            dismiss()
            return
        }
        let name = completion.insertText
        textView.insertText(name + "}}", replacementRange: context.replaceRange)
        dismiss()
        onVariableChosen?(name)
    }

    @objc private func tableClicked() {
        // Single click just selects
    }


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

                // Clear of the overlay scroller, which draws over the cell's
                // trailing edge: at -4 the type sat behind the scroll bar.
                detail.trailingAnchor.constraint(equalTo: cell.trailingAnchor, constant: -Self.detailTrailingInset),
                detail.centerYAnchor.constraint(equalTo: cell.centerYAnchor),
            ])
        }

        cell.textField?.stringValue = DisplayEscape.escaped(item.label)

        let detailField = cell.viewWithTag(100) as? NSTextField
        detailField?.stringValue = DisplayEscape.escaped(item.detail)

        // Read the row as one unit — "count, Function, aggregate" — instead of
        // letting VoiceOver walk the label and the detail as separate pieces
        // of text with a nameless icon between them.
        cell.setAccessibilityLabel(Self.rowLabel(for: item))

        let iconName: String
        switch item.kind {
        case .keyword: iconName = "textformat"
        case .function: iconName = "function"
        case .snippet: iconName = "text.document"
        case .schema: iconName = "folder"
        case .table: iconName = "tablecells"
        case .column: iconName = "line.3.horizontal"
        case .view: iconName = "eye"
        case .variable: iconName = "curlybraces"
        case .newVariable: iconName = "plus.circle"
        }
        cell.imageView?.image = NSImage(
            systemSymbolName: iconName, accessibilityDescription: item.kind.displayName)
        cell.imageView?.contentTintColor = .secondaryLabelColor

        return cell
    }
}
