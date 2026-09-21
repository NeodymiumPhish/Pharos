import AppKit

/// The sidebar of the Settings window: one source-list row per pane, a
/// tinted symbol badge and the pane's title. The glass comes from the split
/// view item; the table is transparent so it shows through.
final class SettingsSidebarVC: NSViewController, NSTableViewDataSource, NSTableViewDelegate {

    /// Called for a USER selection only, never for `select(_:)`.
    var onSelect: ((SettingsPaneID) -> Void)?

    let tableView = NSTableView()
    private let scrollView = NSScrollView()
    private let allSpecs = SettingsPaneRegistry.all
    /// The rows on show. Equal to `allSpecs` unless a search is filtering.
    private var specs = SettingsPaneRegistry.all
    /// The matched row per pane, shown as a second line while filtering.
    private var subtitles: [SettingsPaneID: String] = [:]
    private var isProgrammaticSelection = false

    override func loadView() {
        view = NSView()
        view.translatesAutoresizingMaskIntoConstraints = false

        let column = NSTableColumn(identifier: NSUserInterfaceItemIdentifier("pane"))
        column.resizingMask = .autoresizingMask
        tableView.addTableColumn(column)
        tableView.headerView = nil
        tableView.style = .sourceList
        tableView.rowSizeStyle = .custom
        tableView.rowHeight = Self.singleLineRowHeight
        // A search that matches nothing shows no rows, and a table that
        // refuses an empty selection would force-select row 0 of an empty
        // list.
        tableView.allowsEmptySelection = true
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
        // See SettingsFormScroll: the scroll view supplies the titlebar inset
        // itself, so the rows scroll under the toolbar and the sidebar's
        // titlebar separator appears only once they do.
        scrollView.automaticallyAdjustsContentInsets = true
        scrollView.translatesAutoresizingMaskIntoConstraints = false
        view.addSubview(scrollView)
        NSLayoutConstraint.activate([
            scrollView.topAnchor.constraint(equalTo: view.topAnchor),
            scrollView.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            scrollView.trailingAnchor.constraint(equalTo: view.trailingAnchor),
            scrollView.bottomAnchor.constraint(equalTo: view.bottomAnchor),
        ])
    }

    override func viewDidLoad() {
        super.viewDidLoad()
        tableView.reloadData()
    }

    // MARK: - Filtering

    /// Show only these panes, each with the setting that matched, or pass nil
    /// to show all 16 again.
    ///
    /// Wrapped in `isProgrammaticSelection`: `reloadData` moves rows, which
    /// fires `tableViewSelectionDidChange`, and without the guard filtering
    /// would navigate the user to a pane they never clicked.
    func setFilter(_ hits: [SettingsSearchIndex.Hit]?, keeping current: SettingsPaneID?) {
        isProgrammaticSelection = true
        defer { isProgrammaticSelection = false }

        if let hits {
            let order = hits.map(\.paneId)
            specs = allSpecs.filter { order.contains($0.id.rawValue) }
                .sorted { a, b in
                    (order.firstIndex(of: a.id.rawValue) ?? 0) < (order.firstIndex(of: b.id.rawValue) ?? 0)
                }
            subtitles = [:]
            for hit in hits {
                guard let id = SettingsPaneID(rawValue: hit.paneId), let subtitle = hit.subtitle else { continue }
                subtitles[id] = subtitle
            }
        } else {
            specs = allSpecs
            subtitles = [:]
        }
        tableView.reloadData()

        // Keep the pane the user is looking at selected if it survived the
        // filter; otherwise select nothing rather than jump somewhere.
        if let current, let row = specs.firstIndex(where: { $0.id == current }) {
            tableView.selectRowIndexes(IndexSet(integer: row), byExtendingSelection: false)
            tableView.scrollRowToVisible(row)
        } else {
            tableView.deselectAll(nil)
        }
    }

    /// The first pane a filtered list offers, for ↩ in the search field.
    var firstShownPane: SettingsPaneID? { specs.first?.id }

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

    /// A row's height. Two lines while a search is naming the matched
    /// setting under the pane's name, one otherwise.
    static let singleLineRowHeight: CGFloat = 28
    static let twoLineRowHeight: CGFloat = 42

    func tableView(_ tableView: NSTableView, heightOfRow row: Int) -> CGFloat {
        guard specs.indices.contains(row), subtitles[specs[row].id] != nil else {
            return Self.singleLineRowHeight
        }
        return Self.twoLineRowHeight
    }

    func numberOfRows(in tableView: NSTableView) -> Int { specs.count }

    func tableView(_ tableView: NSTableView, viewFor tableColumn: NSTableColumn?, row: Int) -> NSView? {
        let spec = specs[row]
        let identifier = NSUserInterfaceItemIdentifier("settings.sidebar.cell")
        let cell = tableView.makeView(withIdentifier: identifier, owner: nil) as? SettingsSidebarCell
            ?? SettingsSidebarCell(identifier: identifier)
        cell.configure(spec, subtitle: subtitles[spec.id])
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
    /// The setting that matched, while a search is filtering. Hidden
    /// otherwise, which closes the row back up to one line.
    private let subtitleLabel = NSTextField(labelWithString: "")
    private let textStack = NSStackView()

    init(identifier: NSUserInterfaceItemIdentifier) {
        super.init(frame: .zero)
        self.identifier = identifier
        badge.translatesAutoresizingMaskIntoConstraints = false
        label.font = .systemFont(ofSize: SettingsMetrics.titleFontSize)
        label.lineBreakMode = .byTruncatingTail
        label.translatesAutoresizingMaskIntoConstraints = false

        subtitleLabel.font = .systemFont(ofSize: SettingsMetrics.captionFontSize)
        subtitleLabel.textColor = .secondaryLabelColor
        subtitleLabel.lineBreakMode = .byTruncatingTail
        subtitleLabel.translatesAutoresizingMaskIntoConstraints = false

        textStack.orientation = .vertical
        textStack.alignment = .leading
        textStack.spacing = 1
        textStack.translatesAutoresizingMaskIntoConstraints = false
        textStack.addArrangedSubview(label)
        textStack.addArrangedSubview(subtitleLabel)

        addSubview(badge)
        addSubview(textStack)
        textField = label
        NSLayoutConstraint.activate([
            badge.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 2),
            badge.centerYAnchor.constraint(equalTo: centerYAnchor),
            badge.widthAnchor.constraint(equalToConstant: SettingsMetrics.rowIconSize),
            badge.heightAnchor.constraint(equalToConstant: SettingsMetrics.rowIconSize),
            textStack.leadingAnchor.constraint(equalTo: badge.trailingAnchor, constant: 8),
            textStack.centerYAnchor.constraint(equalTo: centerYAnchor),
            textStack.trailingAnchor.constraint(lessThanOrEqualTo: trailingAnchor, constant: -4),
        ])
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) not implemented")
    }

    func configure(_ spec: SettingsPaneSpec, subtitle: String? = nil) {
        badge.symbolName = spec.symbol
        badge.tint = spec.tint
        label.stringValue = spec.title
        subtitleLabel.stringValue = subtitle ?? ""
        subtitleLabel.isHidden = (subtitle ?? "").isEmpty
        // The identifier goes on the LABEL as well as the cell: AppKit does
        // not carry a cell view's or a row view's accessibility identifier
        // into the AXCell / AXRow it publishes, and the label is the element
        // an AX script can actually find (measured 2026-09-19).
        setAccessibilityIdentifier(spec.id.rowIdentifier)
        label.setAccessibilityIdentifier(spec.id.rowIdentifier)
        label.setAccessibilityLabel(spec.title)
    }
}
