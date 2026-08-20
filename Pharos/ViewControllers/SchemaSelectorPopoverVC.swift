import AppKit

/// Popover content for the editor's schema selector. A search field sits above a
/// scrollable list of schemas, so it scrolls naturally (unlike NSMenu, which jumps
/// in large increments). A pinned "All Schemas" row sits at the top; the active
/// schema shows a checkmark and the connection's default schema shows a
/// "default" badge in its own view — never text appended to the name, since
/// `★` and spaces are legal in a schema name and could otherwise imitate the
/// marker. Single-click commits a selection; the owner dismisses the
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

    /// Visible list height: one row per schema plus the pinned "All Schemas" row
    /// (each row is rowHeight + intercell spacing = 24pt), capped so long lists
    /// scroll instead of growing without bound. Fixed at load from the full schema
    /// count so the popover doesn't resize while the user is typing in the filter.
    private var listHeight: CGFloat {
        let rows = allSchemas.count + 1
        return min(CGFloat(rows) * 24 + 4, 220)
    }

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
            scrollView.heightAnchor.constraint(equalToConstant: listHeight),

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

    /// The default-schema marker, as a separate view rather than text appended
    /// to the name. `★` and spaces are legal in a schema name, so a schema
    /// called `foo ★ default` would otherwise render exactly like the real
    /// marker. A marker of app state must live where name content cannot
    /// reach it.
    fileprivate static func makeDefaultBadge() -> NSTextField {
        let badge = NSTextField(labelWithString: "default")
        badge.font = .systemFont(ofSize: 10, weight: .semibold)
        badge.textColor = .secondaryLabelColor
        badge.alignment = .right
        badge.setContentCompressionResistancePriority(.required, for: .horizontal)
        return badge
    }
}

/// Row cell for the schema list. Holds the default-schema badge as a stored
/// subview built once at cell-creation time, so a recycled cell never carries
/// state from the row it last displayed — only `isHidden` changes per row.
private final class SchemaRowCellView: NSTableCellView {
    let badge = SchemaSelectorPopoverVC.makeDefaultBadge()
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
        let cell = (tableView.makeView(withIdentifier: id, owner: self) as? SchemaRowCellView) ?? {
            let c = SchemaRowCellView()
            let tf = NSTextField(labelWithString: "")
            tf.translatesAutoresizingMaskIntoConstraints = false
            tf.font = .systemFont(ofSize: 12)
            tf.lineBreakMode = .byTruncatingTail
            let iv = NSImageView()
            iv.translatesAutoresizingMaskIntoConstraints = false
            c.addSubview(iv)
            c.addSubview(tf)
            c.badge.translatesAutoresizingMaskIntoConstraints = false
            c.addSubview(c.badge)
            c.imageView = iv
            c.textField = tf
            c.identifier = id
            NSLayoutConstraint.activate([
                iv.leadingAnchor.constraint(equalTo: c.leadingAnchor, constant: 2),
                iv.centerYAnchor.constraint(equalTo: c.centerYAnchor),
                iv.widthAnchor.constraint(equalToConstant: 14),
                tf.leadingAnchor.constraint(equalTo: iv.trailingAnchor, constant: 4),
                tf.centerYAnchor.constraint(equalTo: c.centerYAnchor),
                // Two independent caps on the name field's trailing edge: one
                // always active (against the container), one against the
                // badge's leading edge. AppKit excludes a constraint from
                // layout whenever the view it references is hidden, so when
                // the badge is hidden only the container cap applies and the
                // name field can use the full row width; when the badge is
                // shown, both apply and the tighter one (the badge) wins.
                tf.trailingAnchor.constraint(lessThanOrEqualTo: c.trailingAnchor, constant: -4),
                tf.trailingAnchor.constraint(
                    lessThanOrEqualTo: c.badge.leadingAnchor, constant: -4),
                c.badge.trailingAnchor.constraint(equalTo: c.trailingAnchor, constant: -4),
                c.badge.centerYAnchor.constraint(equalTo: c.centerYAnchor),
            ])
            return c
        }()

        let rawTitle: String
        let isActive: Bool
        let isDefault: Bool
        if row == 0 {
            rawTitle = "All Schemas"
            isActive = (activeSchema == nil)
            isDefault = false
        } else {
            let name = visibleSchemas[row - 1]
            rawTitle = name
            isActive = (activeSchema == name)
            isDefault = (name == defaultSchema)   // raw-name comparison — never the escaped/displayed text
        }
        let escapedTitle = DisplayEscape.escaped(rawTitle)
        cell.textField?.stringValue = escapedTitle
        cell.imageView?.image = isActive
            ? NSImage(systemSymbolName: "checkmark", accessibilityDescription: "selected")
            : nil
        // Set in both directions every time: a recycled cell must never keep
        // a badge left visible from the row it displayed before.
        cell.badge.isHidden = !isDefault
        // The tooltip may disclose the escaped name, but whether it also says
        // "default schema" is driven by `isDefault` (an app-state boolean from
        // the raw-name comparison above), never by concatenating marker text
        // onto the name itself — so a name that merely looks like the marker
        // still cannot make the tooltip claim default status.
        cell.toolTip = isDefault ? "\(escapedTitle) (default schema)" : escapedTitle
        return cell
    }
}
