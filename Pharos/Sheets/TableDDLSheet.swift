import AppKit

/// Modal showing a table's reconstructed CREATE TABLE DDL at selectable detail
/// levels (sidebar), with copy-to-clipboard and an inline Clone Table action.
/// Modeled on QueryDetailSheet.
class TableDDLSheet: NSViewController {

    private let schema: String
    private let table: String
    private let ddl: TableDDL
    private var onClone: ((String, Bool) -> Void)?

    private let levels = DDLDetailLevel.allCases
    private var selectedLevel: DDLDetailLevel = .full

    private let sidebar = NSTableView()
    private let textView = NSTextView()
    private let cloneNameField = NSTextField()
    private let includeRowsCheckbox = NSButton(checkboxWithTitle: "Include table rows", target: nil, action: nil)
    private var cloneSection: NSView!

    init(schema: String, table: String, ddl: TableDDL, onClone: @escaping (String, Bool) -> Void) {
        self.schema = schema
        self.table = table
        self.ddl = ddl
        self.onClone = onClone
        super.init(nibName: nil, bundle: nil)
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) not implemented")
    }

    override func loadView() {
        let container = NSView(frame: NSRect(x: 0, y: 0, width: 660, height: 460))
        self.view = container

        // Title
        let titleLabel = NSTextField(labelWithString: "Table DDL")
        titleLabel.font = .systemFont(ofSize: 17, weight: .semibold)
        let subtitleLabel = NSTextField(labelWithString: "\(schema).\(table)")
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
        let copyButton = NSButton(title: "Copy DDL", target: self, action: #selector(copyDDL))
        copyButton.bezelStyle = .rounded
        let copyConfig = NSImage.SymbolConfiguration(pointSize: 11, weight: .medium)
        copyButton.image = NSImage(systemSymbolName: "doc.on.doc", accessibilityDescription: nil)?
            .withSymbolConfiguration(copyConfig)
        copyButton.imagePosition = .imageLeading

        let cloneToggle = NSButton(title: "Clone Table\u{2026}", target: self, action: #selector(toggleCloneSection))
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
        let doneButton = NSButton(title: "Done", target: self, action: #selector(dismissSheet))
        doneButton.keyEquivalent = "\u{1b}"
        doneButton.bezelStyle = .rounded
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
        cloneNameField.stringValue = "\(table)_copy"
        cloneNameField.widthAnchor.constraint(greaterThanOrEqualToConstant: 220).isActive = true
        includeRowsCheckbox.state = .off

        let cancelButton = NSButton(title: "Cancel", target: self, action: #selector(toggleCloneSection))
        let cloneButton = NSButton(title: "Clone", target: self, action: #selector(doClone))
        cloneButton.keyEquivalent = "\r"
        cloneButton.bezelStyle = .rounded
        let buttonStack = NSStackView(views: [cancelButton, cloneButton])
        buttonStack.spacing = 8

        let grid = NSGridView(views: [
            [nameLabel, cloneNameField],
            [NSGridCell.emptyContentView, includeRowsCheckbox],
            [NSGridCell.emptyContentView, buttonStack],
        ])
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

    @objc private func doClone() {
        let name = cloneNameField.stringValue.trimmingCharacters(in: .whitespaces)
        guard !name.isEmpty else { return }
        let include = includeRowsCheckbox.state == .on
        let callback = onClone
        dismiss(nil)
        callback?(name, include)
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
