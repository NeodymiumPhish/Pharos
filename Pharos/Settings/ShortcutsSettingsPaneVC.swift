import AppKit

/// Settings ▸ Shortcuts. A read-only list of every key Pharos answers, with a
/// search field.
///
/// Read-only on purpose (user decision, 2026-09-19): macOS already lets
/// anyone rebind a menu command in System Settings ▸ Keyboard ▸ Keyboard
/// Shortcuts ▸ App Shortcuts, and a second rebinding mechanism inside the app
/// would fight it. The footer caption says so, because a list with no edit
/// control otherwise reads as an oversight.
///
/// A hand-built pane, not a `SettingsFormPaneVC`: it shows a table, not rows
/// of controls.
final class ShortcutsSettingsPaneVC: SettingsPaneVC, NSTableViewDataSource, NSTableViewDelegate {

    private let searchField = NSSearchField()
    private let tableView = NSTableView()
    private let scrollView = NSScrollView()
    private let emptyLabel = NSTextField(labelWithString: String(localized: "No shortcut matches."))

    private var allEntries: [ShortcutCatalog.Entry] = []
    private var shown: [ShortcutCatalog.Entry] = []

    private enum Column: String {
        case command, group, shortcut
    }

    override func loadView() {
        let root = SettingsPaneSurfaceView()
        root.translatesAutoresizingMaskIntoConstraints = false
        view = root

        searchField.placeholderString = String(localized: "Search shortcuts")
        searchField.translatesAutoresizingMaskIntoConstraints = false
        searchField.target = self
        searchField.action = #selector(searchChanged)
        searchField.sendsSearchStringImmediately = true
        searchField.setAccessibilityIdentifier("settings.shortcuts.search")

        for (id, title, width) in [
            (Column.command, String(localized: "Command"), CGFloat(260)),
            (Column.group, String(localized: "Menu"), CGFloat(140)),
            (Column.shortcut, String(localized: "Shortcut"), CGFloat(110)),
        ] {
            let column = NSTableColumn(identifier: NSUserInterfaceItemIdentifier(id.rawValue))
            column.title = title
            column.width = width
            column.minWidth = 60
            tableView.addTableColumn(column)
        }
        tableView.usesAlternatingRowBackgroundColors = true
        tableView.rowSizeStyle = .default
        tableView.allowsColumnSelection = false
        tableView.allowsMultipleSelection = false
        tableView.dataSource = self
        tableView.delegate = self
        tableView.setAccessibilityIdentifier("settings.shortcuts.table")
        tableView.setAccessibilityLabel(String(localized: "Keyboard shortcuts"))

        scrollView.documentView = tableView
        scrollView.hasVerticalScroller = true
        scrollView.borderType = .noBorder
        scrollView.drawsBackground = false
        scrollView.contentView.drawsBackground = false
        scrollView.translatesAutoresizingMaskIntoConstraints = false

        emptyLabel.textColor = .secondaryLabelColor
        emptyLabel.alignment = .center
        emptyLabel.isHidden = true
        emptyLabel.translatesAutoresizingMaskIntoConstraints = false

        let footer = NSTextField(wrappingLabelWithString: String(
            localized: "Shortcuts follow the macOS System Settings ▸ Keyboard ▸ Keyboard Shortcuts ▸ App Shortcuts list. Add an entry for Pharos there to change one."))
        footer.font = .systemFont(ofSize: SettingsMetrics.captionFontSize)
        footer.textColor = .secondaryLabelColor
        footer.translatesAutoresizingMaskIntoConstraints = false
        footer.setAccessibilityIdentifier("settings.shortcuts.footer")

        root.addSubview(searchField)
        root.addSubview(scrollView)
        root.addSubview(emptyLabel)
        root.addSubview(footer)

        let inset = SettingsMetrics.paneInsetH
        NSLayoutConstraint.activate([
            // The safe area, unlike every other pane: this one is a search
            // field above a table rather than a scroll view that insets
            // itself, so nothing else here would clear the toolbar.
            searchField.topAnchor.constraint(equalTo: root.safeAreaLayoutGuide.topAnchor,
                                             constant: SettingsMetrics.paneInsetTop),
            searchField.leadingAnchor.constraint(equalTo: root.leadingAnchor, constant: inset),
            searchField.trailingAnchor.constraint(equalTo: root.trailingAnchor, constant: -inset),

            scrollView.topAnchor.constraint(equalTo: searchField.bottomAnchor, constant: 10),
            scrollView.leadingAnchor.constraint(equalTo: root.leadingAnchor, constant: inset),
            scrollView.trailingAnchor.constraint(equalTo: root.trailingAnchor, constant: -inset),

            emptyLabel.centerXAnchor.constraint(equalTo: scrollView.centerXAnchor),
            emptyLabel.centerYAnchor.constraint(equalTo: scrollView.centerYAnchor),

            footer.topAnchor.constraint(equalTo: scrollView.bottomAnchor, constant: 8),
            footer.leadingAnchor.constraint(equalTo: root.leadingAnchor, constant: inset),
            footer.trailingAnchor.constraint(equalTo: root.trailingAnchor, constant: -inset),
            footer.bottomAnchor.constraint(equalTo: root.bottomAnchor, constant: -SettingsMetrics.paneInsetBottom),
        ])
    }

    override func viewDidLoad() {
        super.viewDidLoad()
        reloadFromSettings()
    }

    /// The catalogue is read from the LIVE menu bar every time the pane is
    /// shown, so an item added to a menu appears here with no second list to
    /// maintain.
    override func reloadFromSettings() {
        allEntries = ShortcutCatalog.all(menuBar: NSApp.mainMenu)
        applyFilter()
    }

    @objc private func searchChanged() { applyFilter() }

    private func applyFilter() {
        shown = ShortcutCatalog.filter(allEntries, query: searchField.stringValue)
        emptyLabel.isHidden = !shown.isEmpty
        tableView.reloadData()
    }

    // MARK: - Table

    func numberOfRows(in tableView: NSTableView) -> Int { shown.count }

    func tableView(_ tableView: NSTableView, viewFor tableColumn: NSTableColumn?, row: Int) -> NSView? {
        guard let tableColumn, let column = Column(rawValue: tableColumn.identifier.rawValue),
              shown.indices.contains(row) else { return nil }
        let entry = shown[row]
        let identifier = NSUserInterfaceItemIdentifier("shortcut.\(column.rawValue)")
        let cell = tableView.makeView(withIdentifier: identifier, owner: nil) as? NSTableCellView
            ?? Self.makeCell(identifier: identifier, monospaced: column == .shortcut)
        switch column {
        case .command: cell.textField?.stringValue = entry.command
        case .group: cell.textField?.stringValue = entry.group
        case .shortcut: cell.textField?.stringValue = entry.shortcut
        }
        return cell
    }

    /// The list is read-only, so nothing is selectable: a selection would
    /// promise an action the pane does not have.
    func tableView(_ tableView: NSTableView, shouldSelectRow row: Int) -> Bool { false }

    private static func makeCell(identifier: NSUserInterfaceItemIdentifier, monospaced: Bool) -> NSTableCellView {
        let cell = NSTableCellView()
        cell.identifier = identifier
        let label = NSTextField(labelWithString: "")
        label.lineBreakMode = .byTruncatingTail
        label.font = monospaced
            ? .monospacedSystemFont(ofSize: SettingsMetrics.titleFontSize, weight: .regular)
            : .systemFont(ofSize: SettingsMetrics.titleFontSize)
        label.translatesAutoresizingMaskIntoConstraints = false
        cell.addSubview(label)
        cell.textField = label
        NSLayoutConstraint.activate([
            label.leadingAnchor.constraint(equalTo: cell.leadingAnchor, constant: 2),
            label.trailingAnchor.constraint(equalTo: cell.trailingAnchor, constant: -2),
            label.centerYAnchor.constraint(equalTo: cell.centerYAnchor),
        ])
        return cell
    }
}
