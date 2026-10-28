import AppKit

/// The sidebar of a manager window (Variables, Tags, Connections): one
/// source-list row per record, filtered by the toolbar's filter field. The
/// glass comes from the split view item (`ManagerSplitViewController`); the
/// table is transparent so it shows through, and the selection is the
/// system's own pill (a plain `NSTableRowView`).
///
/// The owner passes ALL its records to `setItems(_:)` every time they change
/// and this view does the rest: the filter, keeping the selection by id, the
/// "No Matches" row. It never moves keyboard focus, so an owner can call
/// `setItems` on every keystroke in a detail field.
@MainActor
final class ManagerSidebarVC: NSViewController, NSTableViewDataSource, NSTableViewDelegate, NSMenuDelegate {

    // MARK: Callbacks

    /// The USER picked a row (nil: the user cleared the selection). Never
    /// called for `selectedId = …`, `setItems` or a filter change.
    var onSelect: ((String?) -> Void)?
    /// Delete (⌫ or ⌦, alone or with ⌘), Edit ▸ Delete, or the context
    /// menu's Delete. The ids are the rows to delete; the owner confirms if
    /// it wants to, deletes, and calls `setItems`. No Delete item is offered
    /// while this is nil.
    var onDelete: (([String]) -> Void)?
    /// The context menu's Duplicate. The item is offered only while this is
    /// set.
    var onDuplicate: ((String) -> Void)?
    /// A row was dragged to a new place. `to` is the gap it was dropped in,
    /// counted before the move — the convention of
    /// `Array.move(fromOffsets:toOffset:)` and SwiftUI's `onMove`, so an
    /// owner can pass both straight on. Dragging is offered only while this
    /// is set AND the filter is empty: in a filtered list a drop position
    /// does not name a place in the whole list.
    var onMove: ((_ from: Int, _ to: Int) -> Void)? {
        didSet { if isViewLoaded { updateDragRegistration() } }
    }

    // MARK: State

    let tableView = ManagerSidebarTableView()
    private let scrollView = NSScrollView()
    private let listAccessibilityLabel: String

    /// Every record, in the owner's order.
    private(set) var items: [ManagerSidebarItem] = []
    /// The rows on show: `items` minus what the filter hides.
    private(set) var shownItems: [ManagerSidebarItem] = []

    /// Matched case- and diacritic-insensitively against each row's title
    /// and subtitle (`ManagerSidebarItem.matches`).
    var filterText: String = "" {
        didSet {
            guard filterText != oldValue else { return }
            reloadShown(scrollToSelection: true)
        }
    }

    /// True while a filter is hiding rows (or could be): reordering is off.
    var isFiltering: Bool { !filterText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }

    /// True when the filter matches nothing and the one row on show says so.
    var isShowingNoMatches: Bool { isFiltering && shownItems.isEmpty }

    /// The record the user is working on. It survives a filter that hides
    /// its row — the row is selected again when the filter brings it back —
    /// and is cleared by `setItems` when the record is gone. Setting it
    /// selects the row without calling `onSelect` and without taking focus;
    /// an id that is not among the items selects nothing.
    var selectedId: String? {
        get { keptId }
        set {
            keptId = newValue.flatMap { id in items.contains { $0.id == id } ? id : nil }
            guard isViewLoaded else { return }
            syncTableSelection(scroll: true)
        }
    }

    private var keptId: String?
    /// Set while code, not the user, changes the table's selection, so
    /// `tableViewSelectionDidChange` does not report it.
    private var isProgrammaticSelection = false

    private static let rowDragType = NSPasteboard.PasteboardType("com.pharos.manager-sidebar.row")

    // MARK: Life cycle

    /// - Parameter accessibilityLabel: what VoiceOver calls the list, such
    ///   as "Variables".
    init(accessibilityLabel: String) {
        listAccessibilityLabel = accessibilityLabel
        super.init(nibName: nil, bundle: nil)
    }

    required init?(coder: NSCoder) { fatalError("ManagerSidebarVC is built in code") }

    override func loadView() {
        view = NSView()
        view.translatesAutoresizingMaskIntoConstraints = false

        let column = NSTableColumn(identifier: NSUserInterfaceItemIdentifier("item"))
        column.resizingMask = .autoresizingMask
        tableView.addTableColumn(column)
        tableView.headerView = nil
        tableView.style = .sourceList
        // `.default` follows System Settings ▸ Appearance ▸ Sidebar icon
        // size; the cell reads the effective style for its type sizes.
        tableView.rowSizeStyle = .default
        // A filter that matches nothing leaves no row to select, and the
        // user may clear the selection by clicking below the rows.
        tableView.allowsEmptySelection = true
        tableView.allowsMultipleSelection = false
        tableView.allowsTypeSelect = true
        tableView.usesAutomaticRowHeights = false
        tableView.backgroundColor = .clear
        tableView.dataSource = self
        tableView.delegate = self
        tableView.setDraggingSourceOperationMask(.move, forLocal: true)
        tableView.setAccessibilityIdentifier("manager.sidebar")
        tableView.setAccessibilityLabel(listAccessibilityLabel)
        tableView.deleteHandler = { [weak self] in self?.deleteSelectedRows() ?? false }
        tableView.canDelete = { [weak self] in self?.selectedShownIds.isEmpty == false && self?.onDelete != nil }

        let menu = NSMenu()
        menu.delegate = self
        tableView.menu = menu

        scrollView.documentView = tableView
        scrollView.drawsBackground = false
        scrollView.contentView.drawsBackground = false
        scrollView.borderType = .noBorder
        scrollView.hasVerticalScroller = true
        scrollView.hasHorizontalScroller = false
        // As in SettingsSidebarVC: the scroll view supplies the titlebar
        // inset itself, so the rows scroll under the toolbar and the
        // sidebar's titlebar separator appears only once they do.
        scrollView.automaticallyAdjustsContentInsets = true
        scrollView.translatesAutoresizingMaskIntoConstraints = false
        view.addSubview(scrollView)
        NSLayoutConstraint.activate([
            scrollView.topAnchor.constraint(equalTo: view.topAnchor),
            scrollView.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            scrollView.trailingAnchor.constraint(equalTo: view.trailingAnchor),
            scrollView.bottomAnchor.constraint(equalTo: view.bottomAnchor),
        ])
        updateDragRegistration()
    }

    override func viewDidLoad() {
        super.viewDidLoad()
        reloadShown(scrollToSelection: true)
    }

    // MARK: Items

    /// Show these records — all of them; the filter is applied here. The
    /// selected record stays selected if its id is still present, and
    /// `selectedId` becomes nil if it is not (no `onSelect`: the owner
    /// removed it, so the owner decides what the detail shows next).
    func setItems(_ newItems: [ManagerSidebarItem]) {
        items = newItems
        if let keptId, !newItems.contains(where: { $0.id == keptId }) { self.keptId = nil }
        reloadShown(scrollToSelection: false)
    }

    private func reloadShown(scrollToSelection: Bool) {
        let previousIds = shownItems.map(\.id)
        shownItems = isFiltering ? items.filter { $0.matches(filterText) } : items
        guard isViewLoaded else { return }

        isProgrammaticSelection = true
        defer { isProgrammaticSelection = false }
        // An empty list, before and after, also goes the full way: the
        // "No Matches" row may be coming or going.
        let sameRows = !shownItems.isEmpty && shownItems.map(\.id) == previousIds
            && tableView.numberOfRows == shownItems.count
        if sameRows {
            // Same records in the same places: refresh the cells in place, so
            // a rename typed in the detail does not rebuild the list under
            // the user's pointer.
            let all = IndexSet(integersIn: 0..<shownItems.count)
            tableView.reloadData(forRowIndexes: all, columnIndexes: IndexSet(integer: 0))
            tableView.noteHeightOfRows(withIndexesChanged: all)
        } else {
            tableView.reloadData()
        }
        syncTableSelection(scroll: scrollToSelection)
    }

    /// Put the table's selection on `keptId`'s row, or on nothing when that
    /// row is not on show.
    private func syncTableSelection(scroll: Bool) {
        let wasProgrammatic = isProgrammaticSelection
        isProgrammaticSelection = true
        defer { isProgrammaticSelection = wasProgrammatic }
        if let keptId, let row = shownItems.firstIndex(where: { $0.id == keptId }) {
            if tableView.selectedRowIndexes != IndexSet(integer: row) {
                tableView.selectRowIndexes(IndexSet(integer: row), byExtendingSelection: false)
            }
            if scroll { tableView.scrollRowToVisible(row) }
        } else if !tableView.selectedRowIndexes.isEmpty {
            tableView.deselectAll(nil)
        }
    }

    /// The ids of the rows selected AND on show.
    private var selectedShownIds: [String] {
        tableView.selectedRowIndexes.compactMap { shownItems.indices.contains($0) ? shownItems[$0].id : nil }
    }

    // MARK: Delete, Duplicate

    /// Returns false when there is nothing to delete, so the key falls
    /// through to the table (and its beep).
    @discardableResult
    func deleteSelectedRows() -> Bool {
        let ids = selectedShownIds
        guard !ids.isEmpty, let onDelete else { return false }
        onDelete(ids)
        return true
    }

    func menuNeedsUpdate(_ menu: NSMenu) {
        populateContextMenu(menu, forRow: tableView.clickedRow)
    }

    /// The context menu for `row`: Duplicate (when `onDuplicate` is set) and
    /// Delete (when `onDelete` is set). Empty — so no menu appears — below
    /// the rows and on the "No Matches" row. Split out of `menuNeedsUpdate`
    /// because `clickedRow` cannot be set from a test.
    func populateContextMenu(_ menu: NSMenu, forRow row: Int) {
        menu.removeAllItems()
        guard !isShowingNoMatches, shownItems.indices.contains(row) else { return }
        let id = shownItems[row].id
        if onDuplicate != nil {
            let item = NSMenuItem(title: String(localized: "Duplicate"),
                                  action: #selector(duplicateFromMenu(_:)), keyEquivalent: "")
            item.target = self
            item.representedObject = id
            menu.addItem(item)
        }
        if onDelete != nil {
            if !menu.items.isEmpty { menu.addItem(.separator()) }
            let item = NSMenuItem(title: String(localized: "Delete"),
                                  action: #selector(deleteFromMenu(_:)), keyEquivalent: "")
            item.target = self
            item.representedObject = id
            menu.addItem(item)
        }
    }

    @objc private func duplicateFromMenu(_ sender: NSMenuItem) {
        guard let id = sender.representedObject as? String else { return }
        onDuplicate?(id)
    }

    /// The CLICKED row, which need not be the selected one — the context
    /// menu acts on what was right-clicked, as in Finder.
    @objc private func deleteFromMenu(_ sender: NSMenuItem) {
        guard let id = sender.representedObject as? String else { return }
        onDelete?([id])
    }

    // MARK: Reorder

    /// True while a drag may move a row.
    var canReorder: Bool { onMove != nil && !isFiltering }

    private func updateDragRegistration() {
        if onMove != nil {
            tableView.registerForDraggedTypes([Self.rowDragType])
        } else {
            tableView.unregisterDraggedTypes()
        }
    }

    func tableView(_ tableView: NSTableView, pasteboardWriterForRow row: Int) -> NSPasteboardWriting? {
        guard canReorder, shownItems.indices.contains(row) else { return nil }
        let item = NSPasteboardItem()
        item.setString(String(row), forType: Self.rowDragType)
        return item
    }

    func tableView(_ tableView: NSTableView, validateDrop info: NSDraggingInfo, proposedRow row: Int,
                   proposedDropOperation dropOperation: NSTableView.DropOperation) -> NSDragOperation {
        guard canReorder, (info.draggingSource as? NSTableView) === tableView else { return [] }
        // Between rows only: dropping ON a row would mean "into", and a
        // flat list has no into.
        if dropOperation == .on { tableView.setDropRow(row, dropOperation: .above) }
        return .move
    }

    func tableView(_ tableView: NSTableView, acceptDrop info: NSDraggingInfo, row: Int,
                   dropOperation: NSTableView.DropOperation) -> Bool {
        guard let text = info.draggingPasteboard.pasteboardItems?.first?.string(forType: Self.rowDragType),
              let from = Int(text) else { return false }
        return performMove(from: from, to: row)
    }

    /// Reports a move to `onMove`, unless it is refused (filtering, no
    /// handler, out of range) or would leave the row where it is.
    @discardableResult
    func performMove(from: Int, to: Int) -> Bool {
        guard canReorder, let onMove, items.indices.contains(from), (0...items.count).contains(to),
              to != from, to != from + 1 else { return false }
        onMove(from, to)
        return true
    }

    // MARK: Selection

    func tableViewSelectionDidChange(_ notification: Notification) {
        guard !isProgrammaticSelection else { return }
        let id = selectedShownIds.first
        keptId = id
        onSelect?(id)
    }

    func tableView(_ tableView: NSTableView, shouldSelectRow row: Int) -> Bool {
        !isShowingNoMatches
    }

    func tableView(_ tableView: NSTableView, typeSelectStringFor tableColumn: NSTableColumn?, row: Int) -> String? {
        guard !isShowingNoMatches, shownItems.indices.contains(row) else { return nil }
        return shownItems[row].typeSelectText
    }

    // MARK: Data

    func numberOfRows(in tableView: NSTableView) -> Int {
        isShowingNoMatches ? 1 : shownItems.count
    }

    func tableView(_ tableView: NSTableView, heightOfRow row: Int) -> CGFloat {
        let hasSubtitle = !isShowingNoMatches && shownItems.indices.contains(row)
            && !(shownItems[row].subtitle ?? "").isEmpty
        return ManagerSidebarCell.rowHeight(base: tableView.rowHeight, style: tableView.effectiveRowSizeStyle,
                                            hasSubtitle: hasSubtitle)
    }

    func tableView(_ tableView: NSTableView, viewFor tableColumn: NSTableColumn?, row: Int) -> NSView? {
        if isShowingNoMatches {
            return tableView.makeView(withIdentifier: ManagerNoMatchesCell.identifier, owner: nil)
                ?? ManagerNoMatchesCell()
        }
        let cell = tableView.makeView(withIdentifier: ManagerSidebarCell.identifier, owner: nil)
            as? ManagerSidebarCell ?? ManagerSidebarCell()
        cell.configure(shownItems[row])
        return cell
    }

    func tableView(_ tableView: NSTableView, rowViewForRow row: Int) -> NSTableRowView? {
        let rowView = NSTableRowView()
        if !isShowingNoMatches, shownItems.indices.contains(row) {
            rowView.setAccessibilityLabel(shownItems[row].title)
        }
        return rowView
    }
}

// MARK: - Table

/// The sidebar's table: Delete and Edit ▸ Delete go to the owner.
final class ManagerSidebarTableView: NSTableView {

    /// Returns true when it deleted something.
    var deleteHandler: (() -> Bool)?
    /// Whether Edit ▸ Delete is enabled.
    var canDelete: (() -> Bool)?

    override func keyDown(with event: NSEvent) {
        if Self.isDeleteKey(event), deleteHandler?() == true { return }
        super.keyDown(with: event)
    }

    /// ⌫ (Delete) or ⌦ (Forward Delete), alone or with ⌘ — Finder's
    /// Move to Trash chord.
    static func isDeleteKey(_ event: NSEvent) -> Bool {
        guard event.type == .keyDown,
              let scalar = event.charactersIgnoringModifiers?.unicodeScalars.first else { return false }
        let modifiers = event.modifierFlags.intersection(.deviceIndependentFlagsMask)
            .subtracting([.function, .numericPad, .capsLock])
        guard modifiers.isEmpty || modifiers == .command else { return false }
        return scalar.value == 0x7F || scalar.value == 0x08 || scalar.value == UInt32(NSDeleteFunctionKey)
    }

    /// Edit ▸ Delete.
    @objc func delete(_ sender: Any?) {
        _ = deleteHandler?()
    }

    override func validateUserInterfaceItem(_ item: NSValidatedUserInterfaceItem) -> Bool {
        if item.action == #selector(delete(_:)) { return canDelete?() ?? false }
        return super.validateUserInterfaceItem(item)
    }
}

// MARK: - No Matches

/// The one row a filter that matches nothing leaves: "No Matches", centred.
final class ManagerNoMatchesCell: NSTableCellView {

    static let identifier = NSUserInterfaceItemIdentifier("manager.sidebar.noMatches")

    init() {
        super.init(frame: .zero)
        identifier = Self.identifier
        let label = NSTextField(labelWithString: String(localized: "No Matches"))
        label.textColor = .secondaryLabelColor
        label.alignment = .center
        label.lineBreakMode = .byTruncatingTail
        label.translatesAutoresizingMaskIntoConstraints = false
        label.setAccessibilityIdentifier("manager.sidebar.noMatches")
        addSubview(label)
        textField = label
        NSLayoutConstraint.activate([
            label.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 4),
            label.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -4),
            label.centerYAnchor.constraint(equalTo: centerYAnchor),
        ])
    }

    required init?(coder: NSCoder) { fatalError("ManagerNoMatchesCell is built in code") }

    var message: String { textField?.stringValue ?? "" }
}
