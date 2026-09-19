import AppKit

/// The sidebar of the Settings window: one source-list row per pane, a
/// tinted symbol badge and the pane's title. The glass comes from the split
/// view item; the table is transparent so it shows through.
final class SettingsSidebarVC: NSViewController, NSTableViewDataSource, NSTableViewDelegate {

    /// Called for a USER selection only, never for `select(_:)`.
    var onSelect: ((SettingsPaneID) -> Void)?

    let tableView = NSTableView()
    private let scrollView = NSScrollView()
    private let specs = SettingsPaneRegistry.all
    private var isProgrammaticSelection = false

    override func loadView() {
        view = NSView()
        view.translatesAutoresizingMaskIntoConstraints = false

        let column = NSTableColumn(identifier: NSUserInterfaceItemIdentifier("pane"))
        column.resizingMask = .autoresizingMask
        tableView.addTableColumn(column)
        tableView.headerView = nil
        tableView.style = .sourceList
        tableView.rowSizeStyle = .default
        tableView.rowHeight = 28
        tableView.allowsEmptySelection = false
        tableView.allowsMultipleSelection = false
        tableView.usesAutomaticRowHeights = false
        tableView.backgroundColor = .clear
        tableView.dataSource = self
        tableView.delegate = self
        tableView.setAccessibilityIdentifier("settings.sidebar")
        tableView.setAccessibilityLabel(String(localized: "Settings panes"))

        scrollView.documentView = tableView
        scrollView.drawsBackground = false
        scrollView.contentView.drawsBackground = false
        scrollView.borderType = .noBorder
        scrollView.hasVerticalScroller = true
        scrollView.hasHorizontalScroller = false
        scrollView.automaticallyAdjustsContentInsets = false
        scrollView.contentInsets = NSEdgeInsets(top: 0, left: 0, bottom: 0, right: 0)
        scrollView.translatesAutoresizingMaskIntoConstraints = false
        view.addSubview(scrollView)
        NSLayoutConstraint.activate([
            scrollView.topAnchor.constraint(equalTo: view.safeAreaLayoutGuide.topAnchor, constant: 8),
            scrollView.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            scrollView.trailingAnchor.constraint(equalTo: view.trailingAnchor),
            scrollView.bottomAnchor.constraint(equalTo: view.bottomAnchor),
        ])
    }

    override func viewDidLoad() {
        super.viewDidLoad()
        tableView.reloadData()
    }

    // MARK: - Selection

    var selectedPane: SettingsPaneID? {
        let row = tableView.selectedRow
        return specs.indices.contains(row) ? specs[row].id : nil
    }

    /// Select a row without reporting it as the user's choice.
    func select(_ id: SettingsPaneID) {
        guard let row = specs.firstIndex(where: { $0.id == id }) else { return }
        guard tableView.selectedRow != row else { return }
        isProgrammaticSelection = true
        tableView.selectRowIndexes(IndexSet(integer: row), byExtendingSelection: false)
        tableView.scrollRowToVisible(row)
        isProgrammaticSelection = false
    }

    func tableViewSelectionDidChange(_ notification: Notification) {
        guard !isProgrammaticSelection, let id = selectedPane else { return }
        onSelect?(id)
    }

    // MARK: - Data

    func numberOfRows(in tableView: NSTableView) -> Int { specs.count }

    func tableView(_ tableView: NSTableView, viewFor tableColumn: NSTableColumn?, row: Int) -> NSView? {
        let spec = specs[row]
        let identifier = NSUserInterfaceItemIdentifier("settings.sidebar.cell")
        let cell = tableView.makeView(withIdentifier: identifier, owner: nil) as? SettingsSidebarCell
            ?? SettingsSidebarCell(identifier: identifier)
        cell.configure(spec)
        return cell
    }

    func tableView(_ tableView: NSTableView, rowViewForRow row: Int) -> NSTableRowView? {
        let rowView = NSTableRowView()
        rowView.setAccessibilityIdentifier(specs[row].id.rowIdentifier)
        rowView.setAccessibilityLabel(specs[row].title)
        return rowView
    }
}

/// Badge + title. The badge is drawn (see `SettingsSymbolBadge`), so the tint
/// survives selection and vibrancy.
final class SettingsSidebarCell: NSTableCellView {

    private let badge = SettingsSymbolBadge(symbolName: "gearshape", tint: .systemGray)
    private let label = NSTextField(labelWithString: "")

    init(identifier: NSUserInterfaceItemIdentifier) {
        super.init(frame: .zero)
        self.identifier = identifier
        badge.translatesAutoresizingMaskIntoConstraints = false
        label.font = .systemFont(ofSize: SettingsMetrics.titleFontSize)
        label.lineBreakMode = .byTruncatingTail
        label.translatesAutoresizingMaskIntoConstraints = false
        addSubview(badge)
        addSubview(label)
        textField = label
        NSLayoutConstraint.activate([
            badge.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 2),
            badge.centerYAnchor.constraint(equalTo: centerYAnchor),
            badge.widthAnchor.constraint(equalToConstant: SettingsMetrics.rowIconSize),
            badge.heightAnchor.constraint(equalToConstant: SettingsMetrics.rowIconSize),
            label.leadingAnchor.constraint(equalTo: badge.trailingAnchor, constant: 8),
            label.centerYAnchor.constraint(equalTo: centerYAnchor),
            label.trailingAnchor.constraint(lessThanOrEqualTo: trailingAnchor, constant: -4),
        ])
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) not implemented")
    }

    func configure(_ spec: SettingsPaneSpec) {
        badge.symbolName = spec.symbol
        badge.tint = spec.tint
        label.stringValue = spec.title
        // The identifier goes on the LABEL as well as the cell: AppKit does
        // not carry a cell view's or a row view's accessibility identifier
        // into the AXCell / AXRow it publishes, and the label is the element
        // an AX script can actually find (measured 2026-09-19).
        setAccessibilityIdentifier(spec.id.rowIdentifier)
        label.setAccessibilityIdentifier(spec.id.rowIdentifier)
        label.setAccessibilityLabel(spec.title)
    }
}
