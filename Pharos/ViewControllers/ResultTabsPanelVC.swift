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

    /// The panel's scroll offset, so a test can prove an unchanged push does not
    /// move it. The debounce tick pushes identical rows while the user types, and
    /// a reload there would yank the list back to the active row.
    var scrollOffsetY: CGFloat { scrollView.contentView.bounds.origin.y }

    /// The visible content width the rows must fill, so a test can prove a cell
    /// tracks the panel across a resize rather than asserting a magic number.
    /// Not the panel's own width: the scroll view is inset 1pt for the leading
    /// hairline, and a visible scroller takes its width from this too.
    var clipWidth: CGFloat { scrollView.contentView.bounds.width }

    func simulateRowClick(at index: Int) {
        tableView.selectRowIndexes(IndexSet(integer: index), byExtendingSelection: false)
    }

    /// Empty the selection the way a Command-click on the highlighted row — or a
    /// click in the empty space below the last row — does. A test cannot produce
    /// that gesture: NSTableView decides it inside `mouseDown`'s own tracking
    /// loop, which needs a real event queue and an on-screen window. This drives
    /// the same table API that gesture ends at, and deliberately does NOT set
    /// `isProgrammaticSelection`, so the delegate sees it as the user's move.
    func simulateDeselectAll() {
        tableView.deselectAll(nil)
    }

    /// Scroll the list the way a user's trackpad would, so a test can put the
    /// panel somewhere a reload would drag it away from.
    func simulateScroll(toY y: CGFloat) {
        scrollView.contentView.scroll(to: NSPoint(x: 0, y: y))
        scrollView.reflectScrolledClipView(scrollView.contentView)
    }

    /// The realised cell for a row, so a test can click the control the user
    /// actually clicks rather than trusting the closure wiring by inspection.
    func cellForTesting(row: Int) -> ResultTabRowCell? {
        tableView.view(atColumn: 0, row: row, makeIfNecessary: true) as? ResultTabRowCell
    }

    /// Build the row menu the way a right-click does, so a test can prove
    /// opening it has no side effects. `clickedRow` is what AppKit sets on a
    /// real right-click and is not settable from a test.
    func simulateRightClickMenu(at index: Int) -> NSMenu {
        let menu = NSMenu()
        buildRowMenu(for: index, into: menu)
        return menu
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
        // Kept, deliberately, even though `viewDidLayout` now sets the width
        // explicitly. Autoresizing is the mechanism measured to work in every
        // reproducible condition; the explicit set covers the environment where
        // it apparently does not. Turning it off — with `[]` and
        // `.noColumnAutoresizing` — would leave only the unproven mechanism and
        // make any layout path that skips `viewDidLayout` strictly worse. There
        // is no fight: both want the same value, and the assignment is guarded.
        // The mask deliberately omits `.userResizingMask`: there is no header,
        // so there is no divider to drag, and the width is not the user's to set.
        column.resizingMask = .autoresizingMask
        tableView.addTableColumn(column)
        tableView.headerView = nil
        tableView.rowHeight = Self.rowHeight
        tableView.style = .plain
        tableView.intercellSpacing = NSSize(width: 0, height: 0)
        // Stays true. An empty selection IS a meaningful state here: `activeId`
        // is nil whenever this panel's editor tab holds no result, and the panel
        // must be able to say "nothing is on screen" rather than highlight a row
        // the grid is not showing. With this false, AppKit refuses the
        // `deselectAll` in `update` and re-selects a row of its own after a
        // reload, which would make the highlight lie. The user CAN empty the
        // selection by hand (Command-click, or a click below the last row); that
        // is repaired by the unconditional reconcile in `update`, not by
        // forbidding the state.
        tableView.allowsEmptySelection = true
        tableView.allowsMultipleSelection = false
        tableView.dataSource = self
        tableView.delegate = self
        tableView.menu = makeContextMenu()

        scrollView.documentView = tableView
        scrollView.hasVerticalScroller = true
        // Legacy (always-visible) scrollers reserve their 17pt from the clip
        // view whether or not the list overflows. Left at the default `false`,
        // that made every row stop 18pt short of the panel's edge — and the
        // close button 24pt short — even with three rows in a 300pt panel.
        // Overlay scrollers float over the content and are unaffected.
        scrollView.autohidesScrollers = true
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
            // Bounded like the header above: "No results" fits the 160pt minimum
            // panel width, but longer copy would silently overflow the panel.
            emptyLabel.leadingAnchor.constraint(greaterThanOrEqualTo: container.leadingAnchor, constant: 8),
            emptyLabel.trailingAnchor.constraint(lessThanOrEqualTo: container.trailingAnchor, constant: -8),
        ])
    }

    // MARK: - Layout

    /// Pin the single column to the visible content width.
    ///
    /// Honest note on why this is here. The reported symptom is a row whose
    /// selection highlight fills the panel while its contents — dot, label,
    /// counts, close button — sit in the leftmost part of the row, with a gap
    /// beyond the counts. A row's highlight is drawn by its ROW view, which
    /// always spans the table, while the contents live in the CELL view, whose
    /// width is the column's. So the symptom says the column was narrower than
    /// the clip view on the user's machine.
    ///
    /// I could not reproduce that. With `resizingMask = .autoresizingMask` the
    /// column tracked the clip view in every condition I could build: frames set
    /// from a parent's `viewDidLayout`, deferred passes, coalesced drag steps,
    /// both scroller styles, with and without overflow, and — checked
    /// specifically — resizes with no `update`/`reloadData` in between, holding
    /// the same cell instance throughout.
    ///
    /// This is therefore insurance, not a demonstrated repair: it makes the
    /// invariant explicit and cheap to hold instead of relying on AppKit's
    /// implicit autoresizing, which evidently behaves differently somewhere. The
    /// guard keeps it idempotent, so it cannot fight the autoresizing that is
    /// already doing the job, and cannot loop.
    override func viewDidLayout() {
        super.viewDidLayout()
        guard let column = tableView.tableColumns.first else { return }
        let width = scrollView.contentView.bounds.width
        if abs(column.width - width) > 0.5 { column.width = width }
    }

    // MARK: - Input

    /// Everything `update` renders, as one `Equatable` value. Compared whole, so
    /// a parameter added to `update` in future has to be added here too rather
    /// than being silently left out of the no-op guard.
    private struct Pushed: Equatable {
        let rows: [ResultTabRowModel]
        let activeId: String?
    }

    /// What was last rendered, so an unchanged push can be skipped. `nil` until
    /// the first push, which must always render however empty it is.
    private var lastPushed: Pushed?

    /// Render a push. Rows arrive already ordered (creation order, same as the
    /// horizontal bar); `activeId` is the row this panel's own editor tab holds
    /// as its result, and is nil only when that tab has no result at all.
    ///
    /// Three separate concerns, deliberately gated separately rather than all
    /// behind one no-op guard:
    ///
    /// - **Reload** only when `rows` changed. ContentViewController re-pushes on
    ///   every result-tab change AND on the 250 ms re-resolve tick that fires
    ///   while the user types; reloading there would yank a user who had
    ///   scrolled down to an older result back to the active row.
    /// - **Reconcile the selection every time**, unconditionally. The user can
    ///   empty the selection themselves (Command-click the highlighted row, or
    ///   click the empty space below the last row); the delegate reports nothing
    ///   for an empty selection, so controller state does not move and every
    ///   later push is identical. Gating the selection on "something changed"
    ///   therefore lost the highlight for good — and in the default vertical
    ///   mode this panel is the only surface saying which result the grid shows.
    ///   `selectRowIndexes`/`deselectAll` do not scroll, so this costs nothing.
    /// - **Scroll** only when `activeId` moved, or when the reload already
    ///   disturbed the list. Never on an identical push.
    func update(rows: [ResultTabRowModel], activeId: String?) {
        let previous = lastPushed
        lastPushed = Pushed(rows: rows, activeId: activeId)
        // `previous` is nil until the first push, which must render in full
        // however empty it is — an Optional comparison against a non-Optional
        // reports "changed" for it, which is exactly what the first push wants.
        let rowsChanged = previous?.rows != rows
        let activeIdChanged = previous == nil || previous?.activeId != activeId

        self.rows = rows
        self.activeId = activeId

        // The whole body is wrapped: `reloadData` can drop a selection that no
        // longer has a row, and the reconcile below moves it on purpose. Either
        // one firing `onSelectRow` would re-enter the controller and, from an
        // unfocused pane, switch the active editor tab and swap the grid.
        isProgrammaticSelection = true
        defer { isProgrammaticSelection = false }

        // Header text and the empty placeholder are functions of `rows` alone.
        if rowsChanged {
            headerLabel.stringValue = rows.isEmpty ? "Results" : "Results · \(rows.count)"
            emptyLabel.isHidden = !rows.isEmpty
        }
        // Reload on an activeId change too, not just a rows change. A cell's
        // close button is shown by `configure(model:isActive:)`, which runs
        // ONLY from `viewFor` — so without a reload the outgoing row keeps its
        // `isActive` and its ✕ while the incoming row never gets one. Moving
        // the table's selection below repaints the highlight but cannot fix
        // that. This does not reopen the scroll-fight: the 250 ms re-resolve
        // tick pushes identical rows AND an identical activeId, so it still
        // reloads nothing, and `scrollRowToVisible` stays separately guarded.
        if rowsChanged || activeIdChanged {
            tableView.reloadData()
        }

        guard let activeId, let idx = rows.firstIndex(where: { $0.id == activeId }) else {
            // No active result — say so honestly rather than leaving a stale
            // highlight. This is why `allowsEmptySelection` stays true.
            if tableView.selectedRow != -1 { tableView.deselectAll(nil) }
            return
        }
        if tableView.selectedRow != idx {
            tableView.selectRowIndexes(IndexSet(integer: idx), byExtendingSelection: false)
        }
        if rowsChanged || activeIdChanged {
            tableView.scrollRowToVisible(idx)
        }
    }

    // MARK: - NSTableViewDataSource / Delegate

    func numberOfRows(in tableView: NSTableView) -> Int { rows.count }

    func tableView(_ tableView: NSTableView, viewFor tableColumn: NSTableColumn?, row: Int) -> NSView? {
        let identifier = NSUserInterfaceItemIdentifier("ResultTabRowCell")
        let cell: ResultTabRowCell
        if let existing = tableView.makeView(withIdentifier: identifier, owner: nil) as? ResultTabRowCell {
            cell = existing
        } else {
            cell = ResultTabRowCell(frame: .zero)
            cell.identifier = identifier
            // Set once per cell, not per configure: the closure never varies,
            // because the row's id arrives as its parameter from the cell at
            // click time.
            cell.onClose = { [weak self] id in self?.onCloseRow?(id) }
        }
        let model = rows[row]
        cell.configure(model: model, isActive: model.id == activeId)
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
        buildRowMenu(for: tableView.clickedRow, into: menu)
    }

    /// Deliberately does NOT select the row it builds the menu for, which is a
    /// divergence from `ResultTabBar.rightMouseDown` — that one calls its
    /// `onSelectTab` before popping the menu up. The bar is a single surface
    /// belonging to the one active editor tab, so selecting there costs nothing;
    /// this panel exists once per pane, and selecting from it can switch which
    /// editor tab is active, focus that pane and swap the results grid. Reading
    /// a row's SQL should not change what the grid shows, and both items below
    /// carry their own row id, so pre-selecting buys the menu nothing.
    private func buildRowMenu(for row: Int, into menu: NSMenu) {
        guard row >= 0, row < rows.count else { return }
        let id = rows[row].id

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
