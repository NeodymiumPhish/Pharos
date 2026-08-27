import AppKit

/// The vertical result-tabs panel docked at the right edge of an editor pane.
/// Pure view layer: it renders `[ResultTabRowModel]` and reports clicks through
/// closures. Result-tab state stays in ContentViewController, which pushes rows
/// in via `update(rows:activeId:)` — the same imperative-push pattern as
/// `ResultTabBar` and `syncVariablesPanel`.
///
/// No FFI imports here, deliberately: scripts/test-result-tabs-panel-vc.sh
/// compiles this file into a standalone test binary.
final class ResultTabsPanelVC: NSViewController, NSTableViewDataSource, NSTableViewDelegate {

    var onSelectRow: ((String) -> Void)?
    var onCloseRow: ((String) -> Void)?
    var onViewDetail: ((String) -> Void)?

    private(set) var rows: [ResultTabRowModel] = []
    private var activeId: String?

    private let headerLabel = NSTextField(labelWithString: "Results")
    private let emptyLabel = NSTextField(labelWithString: "No results")
    private let tableView = NSTableView()
    private let scrollView = NSScrollView()
    private static let headerHeight: CGFloat = 26
    private static let rowHeight: CGFloat = 24

    /// True while `update` rewrites the table selection, so the selection
    /// delegate can tell a programmatic move from a user click.
    private var isProgrammaticSelection = false

    // MARK: - Test seams

    var headerText: String { headerLabel.stringValue }
    var isEmptyLabelHidden: Bool { emptyLabel.isHidden }
    var numberOfRowsShown: Int { tableView.numberOfRows }
    var selectedRowIndex: Int { tableView.selectedRow }

    func simulateRowClick(at index: Int) {
        tableView.selectRowIndexes(IndexSet(integer: index), byExtendingSelection: false)
    }

    func simulateRowClose(at index: Int) {
        guard index >= 0, index < rows.count else { return }
        onCloseRow?(rows[index].id)
    }

    /// The realised cell for a row, so a test can click the control the user
    /// actually clicks rather than trusting the closure wiring by inspection.
    func cellForTesting(row: Int) -> ResultTabRowCell? {
        tableView.view(atColumn: 0, row: row, makeIfNecessary: true) as? ResultTabRowCell
    }

    // MARK: - View

    override func loadView() {
        let container = PanelBackground()
        container.wantsLayer = true
        self.view = container

        // Leading hairline so the panel edge reads cleanly against its neighbour.
        let edge = NSBox()
        edge.boxType = .separator
        edge.translatesAutoresizingMaskIntoConstraints = false

        headerLabel.font = .systemFont(ofSize: 11, weight: .semibold)
        headerLabel.textColor = .secondaryLabelColor
        headerLabel.translatesAutoresizingMaskIntoConstraints = false

        emptyLabel.font = .systemFont(ofSize: 12)
        emptyLabel.textColor = .tertiaryLabelColor
        emptyLabel.translatesAutoresizingMaskIntoConstraints = false

        let column = NSTableColumn(identifier: NSUserInterfaceItemIdentifier("result"))
        column.resizingMask = .autoresizingMask
        tableView.addTableColumn(column)
        tableView.headerView = nil
        tableView.rowHeight = Self.rowHeight
        tableView.style = .plain
        tableView.intercellSpacing = NSSize(width: 0, height: 0)
        tableView.allowsEmptySelection = true
        tableView.allowsMultipleSelection = false
        tableView.dataSource = self
        tableView.delegate = self
        tableView.menu = makeContextMenu()

        scrollView.documentView = tableView
        scrollView.hasVerticalScroller = true
        scrollView.drawsBackground = false
        scrollView.translatesAutoresizingMaskIntoConstraints = false

        container.addSubview(edge)
        container.addSubview(headerLabel)
        container.addSubview(scrollView)
        container.addSubview(emptyLabel)

        NSLayoutConstraint.activate([
            edge.leadingAnchor.constraint(equalTo: container.leadingAnchor),
            edge.topAnchor.constraint(equalTo: container.topAnchor),
            edge.bottomAnchor.constraint(equalTo: container.bottomAnchor),
            edge.widthAnchor.constraint(equalToConstant: 1),

            headerLabel.topAnchor.constraint(equalTo: container.topAnchor, constant: 6),
            headerLabel.leadingAnchor.constraint(equalTo: container.leadingAnchor, constant: 10),
            headerLabel.trailingAnchor.constraint(lessThanOrEqualTo: container.trailingAnchor, constant: -8),

            scrollView.topAnchor.constraint(equalTo: container.topAnchor, constant: Self.headerHeight),
            scrollView.leadingAnchor.constraint(equalTo: container.leadingAnchor, constant: 1),
            scrollView.trailingAnchor.constraint(equalTo: container.trailingAnchor),
            scrollView.bottomAnchor.constraint(equalTo: container.bottomAnchor),

            emptyLabel.centerXAnchor.constraint(equalTo: container.centerXAnchor),
            emptyLabel.topAnchor.constraint(equalTo: container.topAnchor, constant: Self.headerHeight + 12),
        ])
    }

    // MARK: - Input

    /// Full reload. Rows arrive already ordered (creation order, same as the
    /// horizontal bar); `activeId` nil means no row in this panel is the live
    /// grid's result (an unfocused pane).
    func update(rows: [ResultTabRowModel], activeId: String?) {
        self.rows = rows
        self.activeId = activeId

        headerLabel.stringValue = rows.isEmpty ? "Results" : "Results · \(rows.count)"
        emptyLabel.isHidden = !rows.isEmpty

        isProgrammaticSelection = true
        tableView.reloadData()
        if let activeId, let idx = rows.firstIndex(where: { $0.id == activeId }) {
            tableView.selectRowIndexes(IndexSet(integer: idx), byExtendingSelection: false)
            tableView.scrollRowToVisible(idx)
        } else {
            tableView.deselectAll(nil)
        }
        isProgrammaticSelection = false
    }

    // MARK: - NSTableViewDataSource / Delegate

    func numberOfRows(in tableView: NSTableView) -> Int { rows.count }

    func tableView(_ tableView: NSTableView, viewFor tableColumn: NSTableColumn?, row: Int) -> NSView? {
        let identifier = NSUserInterfaceItemIdentifier("ResultTabRowCell")
        let cell = tableView.makeView(withIdentifier: identifier, owner: nil) as? ResultTabRowCell
            ?? {
                let c = ResultTabRowCell(frame: .zero)
                c.identifier = identifier
                return c
            }()
        let model = rows[row]
        cell.configure(model: model, isActive: model.id == activeId)
        cell.onClose = { [weak self] id in self?.onCloseRow?(id) }
        return cell
    }

    func tableViewSelectionDidChange(_ notification: Notification) {
        guard !isProgrammaticSelection else { return }
        let idx = tableView.selectedRow
        guard idx >= 0, idx < rows.count else { return }
        onSelectRow?(rows[idx].id)
    }

    // MARK: - Context menu

    private func makeContextMenu() -> NSMenu {
        let menu = NSMenu()
        menu.delegate = self
        return menu
    }
}

extension ResultTabsPanelVC: NSMenuDelegate {
    func menuNeedsUpdate(_ menu: NSMenu) {
        menu.removeAllItems()
        let row = tableView.clickedRow
        guard row >= 0, row < rows.count else { return }
        let id = rows[row].id

        // Right-click also selects, matching the horizontal bar's behaviour.
        onSelectRow?(id)

        let detail = NSMenuItem(title: "View SQL Query", action: #selector(menuViewDetail(_:)), keyEquivalent: "")
        detail.target = self
        detail.representedObject = id
        menu.addItem(detail)

        let close = NSMenuItem(title: "Close", action: #selector(menuClose(_:)), keyEquivalent: "")
        close.target = self
        close.representedObject = id
        menu.addItem(close)
    }

    @objc private func menuViewDetail(_ sender: NSMenuItem) {
        guard let id = sender.representedObject as? String else { return }
        onViewDetail?(id)
    }

    @objc private func menuClose(_ sender: NSMenuItem) {
        guard let id = sender.representedObject as? String else { return }
        onCloseRow?(id)
    }
}

/// Same background as the variables panel's, which keeps its own copy private
/// to that file. Resolves the colour in `updateLayer` so a change of
/// appearance re-resolves it; a `CGColor` assigned once never would.
private final class PanelBackground: NSView {
    override var wantsUpdateLayer: Bool { true }
    override func updateLayer() {
        layer?.backgroundColor = NSColor.controlBackgroundColor.cgColor
    }
}
