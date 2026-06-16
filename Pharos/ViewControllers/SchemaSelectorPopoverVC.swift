import AppKit

/// Popover content for the editor's schema selector. A search field sits above a
/// scrollable list of schemas, so it scrolls naturally (unlike NSMenu, which jumps
/// in large increments). A pinned "All Schemas" row sits at the top; the active
/// schema shows a checkmark and the connection's default schema shows a
/// "★ default" badge. Single-click commits a selection; the owner dismisses the
/// popover. Self-contained — knows nothing about EditorPaneVC.
final class SchemaSelectorPopoverVC: NSViewController {

    /// Fired when a schema row is clicked. `nil` means "All Schemas".
    var onSelectSchema: ((String?) -> Void)?
    /// Fired when "Set as Default Schema" is clicked.
    var onSetDefault: (() -> Void)?

    private let allSchemas: [String]
    private let activeSchema: String?
    private let defaultSchema: String?

    private var visibleSchemas: [String]

    private let searchField = NSSearchField()
    private let scrollView = NSScrollView()
    private let tableView = NSTableView()

    init(schemas: [String], activeSchema: String?, defaultSchema: String?) {
        self.allSchemas = schemas
        self.activeSchema = activeSchema
        self.defaultSchema = defaultSchema
        self.visibleSchemas = schemas
        super.init(nibName: nil, bundle: nil)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) not used") }

    override func loadView() {
        let container = NSView()
        container.translatesAutoresizingMaskIntoConstraints = false
        self.view = container

        // Search field — live filtering via controlTextDidChange.
        searchField.translatesAutoresizingMaskIntoConstraints = false
        searchField.placeholderString = "Filter schemas\u{2026}"
        searchField.controlSize = .small
        searchField.font = .systemFont(ofSize: 12)
        searchField.delegate = self
        container.addSubview(searchField)

        // Table inside a scroll view — natural scrolling.
        let column = NSTableColumn(identifier: NSUserInterfaceItemIdentifier("schema"))
        column.resizingMask = .autoresizingMask
        tableView.addTableColumn(column)
        tableView.headerView = nil
        tableView.rowSizeStyle = .custom
        tableView.rowHeight = 22
        tableView.intercellSpacing = NSSize(width: 0, height: 2)
        tableView.selectionHighlightStyle = .regular
        tableView.backgroundColor = .clear
        tableView.dataSource = self
        tableView.delegate = self
        tableView.target = self
        tableView.action = #selector(rowClicked)

        scrollView.documentView = tableView
        scrollView.hasVerticalScroller = true
        scrollView.drawsBackground = false
        scrollView.borderType = .noBorder
        scrollView.translatesAutoresizingMaskIntoConstraints = false
        container.addSubview(scrollView)

        let setDefaultButton = NSButton(
            title: "Set as Default Schema", target: self, action: #selector(setDefaultClicked))
        setDefaultButton.translatesAutoresizingMaskIntoConstraints = false
        setDefaultButton.bezelStyle = .rounded
        setDefaultButton.controlSize = .small
        setDefaultButton.font = .systemFont(ofSize: 12)
        container.addSubview(setDefaultButton)

        NSLayoutConstraint.activate([
            container.widthAnchor.constraint(equalToConstant: 240),

            searchField.topAnchor.constraint(equalTo: container.topAnchor, constant: 8),
            searchField.leadingAnchor.constraint(equalTo: container.leadingAnchor, constant: 8),
            searchField.trailingAnchor.constraint(equalTo: container.trailingAnchor, constant: -8),

            scrollView.topAnchor.constraint(equalTo: searchField.bottomAnchor, constant: 6),
            scrollView.leadingAnchor.constraint(equalTo: container.leadingAnchor, constant: 8),
            scrollView.trailingAnchor.constraint(equalTo: container.trailingAnchor, constant: -8),
            scrollView.heightAnchor.constraint(equalToConstant: 220),

            setDefaultButton.topAnchor.constraint(equalTo: scrollView.bottomAnchor, constant: 6),
            setDefaultButton.leadingAnchor.constraint(equalTo: container.leadingAnchor, constant: 8),
            setDefaultButton.trailingAnchor.constraint(equalTo: container.trailingAnchor, constant: -8),
            setDefaultButton.bottomAnchor.constraint(equalTo: container.bottomAnchor, constant: -8),
        ])
    }

    override func viewDidAppear() {
        super.viewDidAppear()
        view.window?.makeFirstResponder(searchField)
    }

    @objc private func rowClicked() {
        let row = tableView.clickedRow
        guard row >= 0 else { return }
        if row == 0 {
            onSelectSchema?(nil)            // "All Schemas"
        } else {
            let idx = row - 1
            guard idx < visibleSchemas.count else { return }   // stale-index guard
            onSelectSchema?(visibleSchemas[idx])
        }
    }

    @objc private func setDefaultClicked() {
        onSetDefault?()
    }
}

extension SchemaSelectorPopoverVC: NSSearchFieldDelegate {
    func controlTextDidChange(_ obj: Notification) {
        visibleSchemas = SchemaListFilter.filter(allSchemas, query: searchField.stringValue)
        tableView.reloadData()
    }
}

extension SchemaSelectorPopoverVC: NSTableViewDataSource, NSTableViewDelegate {
    func numberOfRows(in tableView: NSTableView) -> Int {
        visibleSchemas.count + 1   // +1 for the pinned "All Schemas" row
    }

    func tableView(_ tableView: NSTableView, viewFor tableColumn: NSTableColumn?, row: Int) -> NSView? {
        let id = NSUserInterfaceItemIdentifier("schemaRow")
        let cell = (tableView.makeView(withIdentifier: id, owner: self) as? NSTableCellView) ?? {
            let c = NSTableCellView()
            let tf = NSTextField(labelWithString: "")
            tf.translatesAutoresizingMaskIntoConstraints = false
            tf.font = .systemFont(ofSize: 12)
            tf.lineBreakMode = .byTruncatingTail
            let iv = NSImageView()
            iv.translatesAutoresizingMaskIntoConstraints = false
            c.addSubview(iv)
            c.addSubview(tf)
            c.imageView = iv
            c.textField = tf
            c.identifier = id
            NSLayoutConstraint.activate([
                iv.leadingAnchor.constraint(equalTo: c.leadingAnchor, constant: 2),
                iv.centerYAnchor.constraint(equalTo: c.centerYAnchor),
                iv.widthAnchor.constraint(equalToConstant: 14),
                tf.leadingAnchor.constraint(equalTo: iv.trailingAnchor, constant: 4),
                tf.trailingAnchor.constraint(equalTo: c.trailingAnchor, constant: -4),
                tf.centerYAnchor.constraint(equalTo: c.centerYAnchor),
            ])
            return c
        }()

        let title: String
        let isActive: Bool
        if row == 0 {
            title = "All Schemas"
            isActive = (activeSchema == nil)
        } else {
            let name = visibleSchemas[row - 1]
            title = (name == defaultSchema) ? "\(name)  \u{2605} default" : name
            isActive = (activeSchema == name)
        }
        cell.textField?.stringValue = title
        cell.imageView?.image = isActive
            ? NSImage(systemSymbolName: "checkmark", accessibilityDescription: "selected")
            : nil
        cell.toolTip = title
        return cell
    }
}
