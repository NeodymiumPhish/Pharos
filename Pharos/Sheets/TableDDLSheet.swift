import AppKit

/// The one line the clone section says about a shape the copy cannot simply
/// reproduce. Pure, so the wording is pinned by the suite rather than read
/// off a screenshot.
enum CloneShapeNote {
    /// Nil when there is nothing to warn about — an ordinary table, or a
    /// parent whose only consequence is the row-scope choice, which the radio
    /// labels already state.
    static func text(for shape: TableShape) -> String? {
        var sentences: [String] = []

        // A partitioned copy is created with no partitions, so PostgreSQL
        // answers any row with "no partition of relation found for row".
        if let key = shape.partitionBy {
            sentences.append(
                "Partitioned by \(key). The copy keeps the partition key and is created "
                + "with no partitions, so it cannot take rows."
            )
        }

        // LIKE copies every inherited column, so the copy is complete — but
        // it stands alone. Saying so is the point: the alternative would
        // change what the source tree returns.
        if !shape.inheritsFrom.isEmpty {
            // Per-part escaping: see DisplayEscape.escapedQualified's doc comment.
            let parents = shape.inheritsFrom
                .map { DisplayEscape.escapedQualified(schema: $0.schema, table: $0.table) }
                .joined(separator: ", ")
            let tree = shape.inheritsFrom.count == 1 ? "inheritance tree" : "inheritance trees"
            sentences.append(
                "The copy will be a standalone table, not part of \(parents)'s \(tree)."
            )
        }

        return sentences.isEmpty ? nil : sentences.joined(separator: " ")
    }
}

/// What the alert says after a clone succeeds. Pure, for the same reason
/// `CloneShapeNote` is.
enum CloneOutcomeText {
    /// `rowsCopied` is nil when the structure alone was cloned.
    /// `partitionBy` is the source's partition clause, which the copy now
    /// carries — and which comes with no partitions, so the copy holds
    /// nothing until one is attached. The core refuses rows in that case, so
    /// the two arguments are never both present.
    static func message(rowsCopied: Int64?, partitionBy: String?) -> String {
        if let rows = rowsCopied {
            return "Table cloned with \(CountedNounText.phrase(Int(rows), "row"))."
        }
        if let key = partitionBy {
            return "Table structure cloned. The copy is partitioned by \(key) "
                + "and has no partitions yet, so it holds no rows."
        }
        return "Table structure cloned."
    }
}

/// Modal showing a table's reconstructed CREATE TABLE DDL at selectable detail
/// levels (sidebar), with copy-to-clipboard and an inline Clone Table action.
/// Modeled on QueryDetailSheet.
class TableDDLSheet: NSViewController {

    private let schema: String
    private let table: String
    private let ddl: TableDDL
    private var onClone: ((String, Bool, CloneRowScope) -> Void)?

    private let levels = DDLDetailLevel.allCases
    private var selectedLevel: DDLDetailLevel = .columns

    private let sidebar = NSTableView()
    private let textView = TableDDLSheet.makeDisclosingTextView()
    private let cloneNameField = NSTextField()
    private let includeRowsCheckbox = NSButton(checkboxWithTitle: "Include table rows", target: nil, action: nil)
    /// Shown only when the source has descendants: without it "include rows"
    /// would mean two very different amounts of data under one name.
    private var scopeRadios: [CloneRowScope: NSButton] = [:]
    private var scopeStack: NSStackView?
    private var cloneSection: NSView!
    // Stored, not local to `loadView`, so `viewWillAppear` can reach them.
    private let copyButton = NSButton()
    private let cloneToggle = NSButton()
    private let doneButton = NSButton()
    private let cloneCancelButton = NSButton()
    private let cloneButton = NSButton()

    init(schema: String, table: String, ddl: TableDDL, onClone: @escaping (String, Bool, CloneRowScope) -> Void) {
        self.schema = schema
        self.table = table
        self.ddl = ddl
        self.onClone = onClone
        super.init(nibName: nil, bundle: nil)
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) not implemented")
    }

    /// The DDL view with the disclosing layout manager, so an invisible scalar
    /// smuggled into an identifier is visible before the reader copies the DDL
    /// and runs it somewhere else. Copy DDL still copies the raw bytes.
    ///
    /// Builds its own TextKit stack for the same reason `VariableValueTextView`
    /// does: `NSTextView()` alone leaves storage, layout manager and container
    /// nil, and then silently drops every assignment to `string`.
    private static func makeDisclosingTextView() -> NSTextView {
        let storage = NSTextStorage()
        let layoutManager = FoldingLayoutManager(foldState: FoldState())
        storage.addLayoutManager(layoutManager)
        let container = NSTextContainer()
        container.widthTracksTextView = false
        container.heightTracksTextView = false
        layoutManager.addTextContainer(container)
        return NSTextView(frame: .zero, textContainer: container)
    }

    override func loadView() {
        let container = NSView(frame: NSRect(x: 0, y: 0, width: 660, height: 460))
        self.view = container

        // Title
        let titleLabel = NSTextField(labelWithString: "Table DDL")
        titleLabel.font = .systemFont(ofSize: 17, weight: .semibold)
        // Display-only: schema/table are server-derived. The clone action and
        // the DDL request keep using the raw stored strings.
        // Per-part escaping: see DisplayEscape.escapedQualified's doc comment.
        let subtitleLabel = NSTextField(labelWithString: DisplayEscape.escapedQualified(schema: schema, table: table))
        subtitleLabel.font = .systemFont(ofSize: 12)
        subtitleLabel.textColor = .secondaryLabelColor

        // Sidebar (detail levels)
        sidebar.headerView = nil
        sidebar.rowHeight = 24
        let col = NSTableColumn(identifier: NSUserInterfaceItemIdentifier("level"))
        col.width = 150
        sidebar.addTableColumn(col)
        sidebar.delegate = self
        sidebar.dataSource = self
        sidebar.selectionHighlightStyle = .regular
        let sidebarScroll = NSScrollView()
        sidebarScroll.documentView = sidebar
        sidebarScroll.hasVerticalScroller = true
        sidebarScroll.borderType = .bezelBorder
        sidebarScroll.translatesAutoresizingMaskIntoConstraints = false
        sidebarScroll.widthAnchor.constraint(equalToConstant: 170).isActive = true

        // DDL text view (read-only, monospaced, horizontally scrollable)
        let textScroll = NSScrollView()
        textScroll.hasVerticalScroller = true
        textScroll.hasHorizontalScroller = true
        textScroll.borderType = .bezelBorder
        textScroll.drawsBackground = true
        textView.isEditable = false
        textView.isSelectable = true
        textView.font = .monospacedSystemFont(ofSize: 12, weight: .regular)
        textView.textContainerInset = NSSize(width: 8, height: 8)
        textView.isVerticallyResizable = true
        textView.isHorizontallyResizable = true
        textView.autoresizingMask = [.width, .height]
        textView.maxSize = NSSize(width: CGFloat.greatestFiniteMagnitude, height: CGFloat.greatestFiniteMagnitude)
        textView.textContainer?.widthTracksTextView = false
        textView.textContainer?.containerSize = NSSize(width: CGFloat.greatestFiniteMagnitude,
                                                       height: CGFloat.greatestFiniteMagnitude)
        textView.backgroundColor = .textBackgroundColor
        textView.string = selectedLevel.ddl(from: ddl)
        textScroll.documentView = textView
        textScroll.translatesAutoresizingMaskIntoConstraints = false

        let paneRow = NSStackView(views: [sidebarScroll, textScroll])
        paneRow.orientation = .horizontal
        paneRow.spacing = 8
        paneRow.distribution = .fill

        // Action row: Copy DDL (left) — spacer — Clone Table (right)
        copyButton.title = "Copy DDL"
        copyButton.target = self
        copyButton.action = #selector(copyDDL)
        copyButton.bezelStyle = .rounded
        let copyConfig = NSImage.SymbolConfiguration(pointSize: 11, weight: .medium)
        copyButton.image = NSImage(systemSymbolName: "doc.on.doc", accessibilityDescription: "Copy")?
            .withSymbolConfiguration(copyConfig)
        copyButton.imagePosition = .imageLeading

        cloneToggle.title = "Clone Table\u{2026}"
        cloneToggle.target = self
        cloneToggle.action = #selector(toggleCloneSection)
        cloneToggle.bezelStyle = .rounded

        let spacer = NSView()
        spacer.setContentHuggingPriority(.defaultLow, for: .horizontal)
        let actionRow = NSStackView(views: [copyButton, spacer, cloneToggle])
        actionRow.orientation = .horizontal
        actionRow.spacing = 8

        // Clone section (hidden until Clone Table clicked)
        cloneSection = buildCloneSection()
        cloneSection.isHidden = true

        // Done
        doneButton.title = "Done"
        doneButton.target = self
        doneButton.action = #selector(dismissSheet)
        doneButton.keyEquivalent = "\u{1b}"
        doneButton.bezelStyle = .rounded
        doneButton.setAccessibilityIdentifier("sheet.tableddl.cancel")
        let doneRow = NSStackView(views: [doneButton])
        doneRow.orientation = .horizontal

        let mainStack = NSStackView(views: [titleLabel, subtitleLabel, paneRow, actionRow, cloneSection, doneRow])
        mainStack.orientation = .vertical
        mainStack.alignment = .leading
        mainStack.spacing = 12
        mainStack.edgeInsets = NSEdgeInsets(top: 20, left: 20, bottom: 20, right: 20)
        mainStack.setCustomSpacing(4, after: titleLabel)
        mainStack.translatesAutoresizingMaskIntoConstraints = false
        container.addSubview(mainStack)

        NSLayoutConstraint.activate([
            mainStack.topAnchor.constraint(equalTo: container.topAnchor),
            mainStack.leadingAnchor.constraint(equalTo: container.leadingAnchor),
            mainStack.trailingAnchor.constraint(equalTo: container.trailingAnchor),
            mainStack.bottomAnchor.constraint(equalTo: container.bottomAnchor),
            paneRow.leadingAnchor.constraint(equalTo: mainStack.leadingAnchor, constant: 20),
            paneRow.trailingAnchor.constraint(equalTo: mainStack.trailingAnchor, constant: -20),
            paneRow.heightAnchor.constraint(greaterThanOrEqualToConstant: 280),
            actionRow.leadingAnchor.constraint(equalTo: mainStack.leadingAnchor, constant: 20),
            actionRow.trailingAnchor.constraint(equalTo: mainStack.trailingAnchor, constant: -20),
            doneRow.trailingAnchor.constraint(equalTo: mainStack.trailingAnchor, constant: -20),
        ])

        // Select the default level.
        if let idx = levels.firstIndex(of: selectedLevel) {
            sidebar.selectRowIndexes(IndexSet(integer: idx), byExtendingSelection: false)
        }
    }

    private func buildCloneSection() -> NSView {
        let nameLabel = NSTextField(labelWithString: "New table name:")
        nameLabel.font = .systemFont(ofSize: 13)
        nameLabel.alignment = .right
        cloneNameField.placeholderString = "table_name"
        cloneNameField.delegate = self
        // The default is seeded from a server-derived name, and the sanitising
        // delegate fires only on edits — sanitise the seed itself so the field
        // never HOLDS a deceptive name, not even before the first keystroke.
        cloneNameField.stringValue = AuthoredLabelSanitizer.sanitized("\(table)_copy")
        cloneNameField.widthAnchor.constraint(greaterThanOrEqualToConstant: 220).isActive = true
        includeRowsCheckbox.state = .off
        includeRowsCheckbox.target = self
        includeRowsCheckbox.action = #selector(includeRowsChanged)
        includeRowsCheckbox.setAccessibilityIdentifier("sheet.tableddl.includeRows")

        // A partitioned copy has no partitions, so PostgreSQL refuses every
        // row. The core refuses it too; disabling it here means the analyst
        // never asks for something that can only fail.
        if ddl.shape.isPartitionedParent {
            includeRowsCheckbox.isEnabled = false
        }

        var rows: [[NSView]] = [[nameLabel, cloneNameField]]

        if let note = CloneShapeNote.text(for: ddl.shape) {
            let noteLabel = NSTextField(labelWithString: note)
            noteLabel.font = .systemFont(ofSize: 11)
            noteLabel.textColor = .secondaryLabelColor
            noteLabel.lineBreakMode = .byWordWrapping
            noteLabel.maximumNumberOfLines = 3
            noteLabel.cell?.wraps = true
            noteLabel.preferredMaxLayoutWidth = 320
            noteLabel.setAccessibilityIdentifier("sheet.tableddl.shapeNote")
            rows.append([NSGridCell.emptyContentView, noteLabel])
        }

        rows.append([NSGridCell.emptyContentView, includeRowsCheckbox])

        // The scope only exists when there IS a tree below this table. On an
        // ordinary table both radios would mean the same thing, and a choice
        // with one answer is noise.
        if ddl.shape.hasChildTables {
            let stack = NSStackView(views: CloneRowScope.allCases.map { scope in
                let radio = NSButton(radioButtonWithTitle: scope.title, target: self,
                                     action: #selector(rowScopeChanged))
                radio.state = scope == .ownRows ? .on : .off
                radio.setAccessibilityIdentifier("sheet.tableddl.rowScope.\(scope.rawValue)")
                scopeRadios[scope] = radio
                return radio
            })
            stack.orientation = .vertical
            stack.alignment = .leading
            stack.spacing = 4
            scopeStack = stack
            rows.append([NSGridCell.emptyContentView, stack])
        }
        // Enabled only while rows are being copied at all.
        updateScopeEnablement()

        cloneCancelButton.title = "Cancel"
        cloneCancelButton.target = self
        cloneCancelButton.action = #selector(toggleCloneSection)
        cloneButton.title = "Clone"
        cloneButton.target = self
        cloneButton.action = #selector(doClone)
        cloneButton.keyEquivalent = "\r"
        cloneButton.bezelStyle = .rounded
        cloneButton.setAccessibilityIdentifier("sheet.tableddl.default")
        let buttonStack = NSStackView(views: [cloneCancelButton, cloneButton])
        buttonStack.spacing = 8

        rows.append([NSGridCell.emptyContentView, buttonStack])
        let grid = NSGridView(views: rows)
        grid.column(at: 0).xPlacement = .trailing
        grid.rowSpacing = 8
        grid.columnSpacing = 8
        grid.translatesAutoresizingMaskIntoConstraints = false

        let separator = NSBox()
        separator.boxType = .separator
        separator.translatesAutoresizingMaskIntoConstraints = false

        let section = NSView()
        section.translatesAutoresizingMaskIntoConstraints = false
        section.addSubview(separator)
        section.addSubview(grid)
        NSLayoutConstraint.activate([
            separator.topAnchor.constraint(equalTo: section.topAnchor),
            separator.leadingAnchor.constraint(equalTo: section.leadingAnchor, constant: 20),
            separator.trailingAnchor.constraint(equalTo: section.trailingAnchor, constant: -20),
            grid.topAnchor.constraint(equalTo: separator.bottomAnchor, constant: 12),
            grid.leadingAnchor.constraint(equalTo: section.leadingAnchor, constant: 20),
            grid.trailingAnchor.constraint(lessThanOrEqualTo: section.trailingAnchor, constant: -20),
            grid.bottomAnchor.constraint(equalTo: section.bottomAnchor),
        ])
        return section
    }

    // MARK: - Key View Loop

    override func viewWillAppear() {
        super.viewWillAppear()
        // No editable field is visible at open — the clone section starts
        // hidden — so the first button is the initial responder.
        view.window?.initialFirstResponder = copyButton
        // NOT true: that recalculates the window's key view loop from the
        // view hierarchy — repeatedly, not just once, as testing against a
        // live build showed — which silently discards the explicit chain
        // below (including the clone section's grid) the first time
        // anything triggers it.
        view.window?.autorecalculatesKeyViewLoop = false
        sidebar.nextKeyView = copyButton
        copyButton.nextKeyView = cloneToggle
        cloneToggle.nextKeyView = doneButton
        doneButton.nextKeyView = sidebar
        // Explicit, because these controls sit in NSGridView rows: AppKit's
        // automatic key view loop follows the grid's own subview order,
        // which does not match the row-by-row reading order the clone
        // section is laid out in.
        cloneNameField.nextKeyView = includeRowsCheckbox
        // The radios sit between the checkbox and the buttons in reading
        // order; the grid's own subview order does not, which is why this
        // chain is explicit.
        var afterCheckbox: NSView = cloneCancelButton
        if let radios = scopeStack?.views as? [NSButton], let first = radios.first {
            for (a, b) in zip(radios, radios.dropFirst()) { a.nextKeyView = b }
            radios.last?.nextKeyView = cloneCancelButton
            afterCheckbox = first
        }
        includeRowsCheckbox.nextKeyView = afterCheckbox
        cloneCancelButton.nextKeyView = cloneButton
        cloneButton.nextKeyView = doneButton
    }

    // MARK: - Actions

    @objc private func copyDDL() {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(textView.string, forType: .string)
        if let button = view.findSubview(ofType: NSButton.self, where: { $0.title == "Copy DDL" }) {
            button.title = "Copied!"
            DispatchQueue.main.asyncAfter(deadline: .now() + 1.5) {
                button.title = "Copy DDL"
            }
        }
    }

    @objc private func toggleCloneSection() {
        cloneSection.isHidden.toggle()
    }

    @objc private func includeRowsChanged() {
        updateScopeEnablement()
    }

    /// Radios in one superview sharing a target/action are a group already;
    /// this exists so the selection can be read back and asserted.
    @objc private func rowScopeChanged() {}

    /// The scope is a choice about rows, so it follows the checkbox.
    private func updateScopeEnablement() {
        let on = includeRowsCheckbox.state == .on && includeRowsCheckbox.isEnabled
        for radio in scopeRadios.values { radio.isEnabled = on }
    }

    /// The selected scope, or the safe one when there are no radios — an
    /// ordinary table has nothing below it, so `ONLY` and no `ONLY` read the
    /// same rows.
    var selectedRowScope: CloneRowScope {
        scopeRadios.first(where: { $0.value.state == .on })?.key ?? .ownRows
    }

    @objc private func doClone() {
        // Sanitised again here, after controlTextDidChange has already done it
        // per keystroke: this is the only line that reaches the clone action,
        // so a future path that sets the field without an edit notification
        // cannot get a deceptive name past it. Sanitising BEFORE trimming
        // matters — an unusual space folds to a plain one, which the trim
        // then takes.
        let name = AuthoredLabelSanitizer.sanitized(cloneNameField.stringValue)
            .trimmingCharacters(in: .whitespaces)
        guard !name.isEmpty else { return }
        let include = includeRowsCheckbox.state == .on && includeRowsCheckbox.isEnabled
        let scope = selectedRowScope
        let callback = onClone
        dismiss(nil)
        callback?(name, include, scope)
    }

    @objc private func dismissSheet() {
        dismiss(nil)
    }
}

// MARK: - Sidebar data source / delegate

extension TableDDLSheet: NSTableViewDataSource, NSTableViewDelegate {
    func numberOfRows(in tableView: NSTableView) -> Int { levels.count }

    func tableView(_ tableView: NSTableView, viewFor tableColumn: NSTableColumn?, row: Int) -> NSView? {
        let id = NSUserInterfaceItemIdentifier("levelCell")
        let cell: NSTableCellView
        if let reused = tableView.makeView(withIdentifier: id, owner: self) as? NSTableCellView {
            cell = reused
        } else {
            cell = NSTableCellView()
            let tf = NSTextField(labelWithString: "")
            tf.translatesAutoresizingMaskIntoConstraints = false
            cell.addSubview(tf)
            cell.textField = tf
            cell.identifier = id
            NSLayoutConstraint.activate([
                tf.leadingAnchor.constraint(equalTo: cell.leadingAnchor, constant: 6),
                tf.trailingAnchor.constraint(equalTo: cell.trailingAnchor, constant: -6),
                tf.centerYAnchor.constraint(equalTo: cell.centerYAnchor),
            ])
        }
        cell.textField?.stringValue = levels[row].title
        return cell
    }

    func tableViewSelectionDidChange(_ notification: Notification) {
        let row = sidebar.selectedRow
        guard row >= 0, row < levels.count else { return }
        selectedLevel = levels[row]
        textView.string = selectedLevel.ddl(from: ddl)
    }
}

// MARK: - View Finder Helper

private extension NSView {
    func findSubview<T: NSView>(ofType type: T.Type, where predicate: (T) -> Bool) -> T? {
        for sub in subviews {
            if let match = sub as? T, predicate(match) { return match }
            if let found = sub.findSubview(ofType: type, where: predicate) { return found }
        }
        return nil
    }
}

// MARK: - Clone-name sanitising

extension TableDDLSheet: NSTextFieldDelegate {
    // A clone name is an authored label that becomes an identifier: it is
    // sanitised as it changes by the shared authored-label mechanism, so the
    // field never holds a name that reads as something it is not.
    func controlTextDidChange(_ obj: Notification) {
        guard (obj.object as? NSTextField) === cloneNameField else { return }
        cloneNameField.sanitizeAsAuthoredLabel()
    }
}
