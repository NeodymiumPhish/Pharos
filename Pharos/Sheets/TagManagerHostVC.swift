import AppKit

/// The Tag Manager window's content: the shared manager shell
/// (`ManagerSplitViewController`) with every tag in its Glass sidebar and the
/// chosen one's `TagDetailVC` beside it. **+** in the toolbar makes a tag; the
/// toolbar's filter field narrows the sidebar; Delete (or the row's context
/// menu) deletes one. Save writes every tag's edits at once and Revert drops
/// them all — the model spans the window, not one tag.
///
/// The detail is rebuilt from the store after a save, on Revert, and when
/// another window changes the tags while this one has no edits of its own.
@MainActor
final class TagManagerHostVC: NSViewController {
    /// Injected (the store in the app, a fake in the harness), so this
    /// controller needs neither the core nor a window to be tested.
    private let tags: () -> [Tag]
    private let committer: TagManagerCommitting
    /// The close question; replaceable in the harness, where no alert can run.
    var askDiscard: () -> Bool = {
        let alert = NSAlert()
        alert.messageText = String(localized: "Discard your changes to tags?")
        alert.informativeText = String(localized: "The changes you made in the Tag Manager have not been saved.")
        alert.addButton(withTitle: String(localized: "Discard"))
        alert.addButton(withTitle: String(localized: "Cancel"))
        return alert.runModal() == .alertFirstButtonReturn
    }

    let sidebar = ManagerSidebarVC(accessibilityLabel: String(localized: "Tags", comment: "Tag Manager: the sidebar list's VoiceOver name."))
    let toolbar = ManagerToolbarController(identifier: "PharosTagManagerToolbar",
                                           addLabel: String(localized: "New Tag", comment: "Tag Manager: make a new tag."))
    let split: ManagerSplitViewController
    /// The detail on show. Replaced whole by `reseed`.
    private(set) var detail: TagDetailVC

    private var columns: [ColumnDef] = []
    private var loadedRows: [[String?]] = []
    /// False until the first `reseed`: before it, the detail is a placeholder
    /// with no tags, and the store's changes have nothing to follow.
    private var isSeeded = false

    /// The narrowest the detail may get: the window's 760 pt minimum less the
    /// sidebar's 220.
    static let detailMinimum: CGFloat = 540

    init(tags: @escaping () -> [Tag], committer: TagManagerCommitting) {
        self.tags = tags
        self.committer = committer
        let placeholder = TagDetailVC(model: TagManagerModel(tags: [], mode: .manage), committer: committer,
                                      columns: [], loadedRows: [], secondaryAction: .revert)
        detail = placeholder
        split = ManagerSplitViewController(sidebar: sidebar, detail: placeholder,
                                           autosaveName: "PharosTagManagerSplit",
                                           detailMinimum: Self.detailMinimum)
        super.init(nibName: nil, bundle: nil)
        split.toolbarController = toolbar
        toolbar.onAdd = { [weak self] in self?.addTag() }
        sidebar.onSelect = { [weak self] id in self?.sidebarSelected(id) }
        sidebar.onDelete = { [weak self] ids in self?.deleteTags(ids) }
        wire(placeholder)
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) not implemented") }

    override func loadView() {
        view = NSView(frame: NSRect(x: 0, y: 0, width: 900, height: 600))
        // A child, pinned to every edge. Measured against the split view as
        // the window's own content controller: the same glass sidebar, the
        // same titlebar backgrounds, the same safe areas.
        addChild(split)
        split.view.translatesAutoresizingMaskIntoConstraints = false
        view.addSubview(split.view)
        NSLayoutConstraint.activate([
            split.view.topAnchor.constraint(equalTo: view.topAnchor),
            split.view.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            split.view.trailingAnchor.constraint(equalTo: view.trailingAnchor),
            split.view.bottomAnchor.constraint(equalTo: view.bottomAnchor),
        ])
    }

    override func viewWillAppear() {
        super.viewWillAppear()
        if let window = view.window { split.installToolbarIfNeeded(on: window) }
    }

    func setResults(columns: [ColumnDef], loadedRows: [[String?]]) {
        self.columns = columns
        self.loadedRows = loadedRows
    }

    /// Edits not yet saved.
    var hasEdits: Bool { isSeeded && detail.hasEdits }

    /// The tag selected in the sidebar, kept across a rebuild. Nil for a tag
    /// made this session, which has no id yet.
    var selectedTagId: String? {
        guard let index = detail.selectedTagIndex, detail.model.tags.indices.contains(index) else { return nil }
        return detail.model.tags[index].id
    }

    /// A fresh detail from the store, on `preselect` (or the tag selected
    /// now, or the first).
    func reseed(preselect: String? = nil) {
        let keep = preselect ?? selectedTagId
        let model = TagManagerModel(tags: tags(), mode: .manage)
        let fresh = TagDetailVC(model: model, committer: committer,
                                columns: columns, loadedRows: loadedRows,
                                secondaryAction: .revert)
        wire(fresh)
        detail = fresh
        isSeeded = true
        split.setDetail(fresh)
        reloadSidebar()
        let index = keep.flatMap { id in model.tags.firstIndex { $0.id == id } }
            .flatMap { model.visibleTagIndices.contains($0) ? $0 : nil }
        show(modelIndex: index ?? model.visibleTagIndices.first)
        // After `setDetail`, which recalculates the window's key view loop
        // from the view tree and so drops the detail's own chain.
        fresh.rebuildKeyViewLoop()
    }

    private func wire(_ detail: TagDetailVC) {
        detail.leadingKeyViews = [sidebar.tableView]
        detail.onTagChanged = { [weak self] index in self?.refreshSidebarItem(index) }
        detail.onAddTag = { [weak self] in self?.addTag() }
        // The window stays open after a save, on a fresh detail built from
        // the store; Revert rebuilds the same way and writes nothing.
        detail.onSaved = { [weak self] in self?.reseed() }
        detail.onRevert = { [weak self] in self?.reseed() }
    }

    // MARK: Sidebar

    /// The id a sidebar row goes by: the tag's own, or — for a tag made this
    /// session, which has none yet — its place in the model, which never
    /// moves while this detail lives (the model marks a deleted tag rather
    /// than removing it).
    static func sidebarId(for tag: EditableTag, at index: Int) -> String {
        tag.id ?? "new-\(index)"
    }

    /// One sidebar row: the colour swatch, the name (escaped and trimmed, as
    /// every surface but the field draws it), the EDITED rule count, and the
    /// unsaved dot from the same diff Save writes.
    static func sidebarItem(for tag: EditableTag, at index: Int, in model: TagManagerModel) -> ManagerSidebarItem {
        let name = TagDetailVC.displayName(tag.name)
        return ManagerSidebarItem(
            id: sidebarId(for: tag, at: index),
            title: name.isEmpty ? String(localized: "Untitled Tag", comment: "Tag Manager: a tag with no name yet.") : name,
            subtitle: CountedNounText.phrase(tag.rules.count, "rule"),
            badge: .swatch(TagPalette.color(at: tag.colorIndex)),
            trailing: model.hasEdits(tagAt: index) ? [.unsavedDot] : [])
    }

    /// Every visible tag, in model order. The sidebar keeps the selection by
    /// id and refreshes rows in place when the ids are unchanged.
    private func reloadSidebar() {
        let model = detail.model
        sidebar.setItems(model.visibleTagIndices.map { index in
            Self.sidebarItem(for: model.tags[index], at: index, in: model)
        })
    }

    /// Redraw the one row an edit changed (its name, colour, rule count or
    /// unsaved dot). Per keystroke, so only that row's diff is worked out.
    private func refreshSidebarItem(_ index: Int) {
        let model = detail.model
        guard model.tags.indices.contains(index) else { return }
        let id = Self.sidebarId(for: model.tags[index], at: index)
        var items = sidebar.items
        guard let position = items.firstIndex(where: { $0.id == id }) else { return reloadSidebar() }
        items[position] = Self.sidebarItem(for: model.tags[index], at: index, in: model)
        sidebar.setItems(items)
    }

    /// The model index a sidebar id names, if that tag is still visible.
    private func modelIndex(forSidebarId id: String) -> Int? {
        let model = detail.model
        return model.visibleTagIndices.first { Self.sidebarId(for: model.tags[$0], at: $0) == id }
    }

    /// Show `index` in the detail and select its row, without telling anyone
    /// it was the user.
    private func show(modelIndex index: Int?) {
        detail.select(modelIndex: index)
        sidebar.selectedId = index.map { Self.sidebarId(for: detail.model.tags[$0], at: $0) }
    }

    private func sidebarSelected(_ id: String?) {
        let index = id.flatMap(modelIndex(forSidebarId:))
        guard index != detail.selectedTagIndex else { return }
        detail.select(modelIndex: index)
    }

    /// Select a tag the way a click does.
    func select(tagId: String) {
        guard let index = detail.model.tags.firstIndex(where: { $0.id == tagId }),
              detail.model.visibleTagIndices.contains(index) else { return }
        show(modelIndex: index)
    }

    // MARK: Tag actions

    /// + in the toolbar, or the empty state's New Tag.
    func addTag() {
        let index = detail.addTag()
        reloadSidebar()
        show(modelIndex: index)
        view.window?.makeFirstResponder(detail.nameField)
    }

    /// Delete key or the context menu. The same model step as the sheet's
    /// trash button — marked, not written, and no alert: the footer says what
    /// Save would destroy, and Revert takes it back. When the tag on show
    /// goes, the selection "stays put": the next tag slides into its row.
    func deleteTags(_ ids: [String]) {
        for id in ids {
            let model = detail.model
            guard let index = modelIndex(forSidebarId: id) else { continue }
            let removedRow = model.visibleTagIndices.firstIndex(of: index) ?? 0
            let wasShown = index == detail.selectedTagIndex
            detail.deleteTag(at: index)
            reloadSidebar()
            guard wasShown else { continue }
            let survivors = detail.model.visibleTagIndices
            let nextRow = TagPalette.selectionAfterRemoval(removedRow: removedRow, newCount: survivors.count)
            show(modelIndex: nextRow.flatMap { survivors.indices.contains($0) ? survivors[$0] : nil })
        }
    }

    // MARK: Store and window

    /// Another window (the grid's Add Tag…, an inspector delete) changed the
    /// tags: follow it unless this window has edits of its own, which a save
    /// will reconcile (a write on a tag that vanished reports itself). A form
    /// with edits is left alone (lessons, 2026-09-16).
    func storeChanged() {
        guard isSeeded, !hasEdits else { return }
        reseed()
    }

    /// The window is closing: unsaved edits ask first.
    func confirmClose() -> Bool {
        guard hasEdits else { return true }
        return askDiscard()
    }
}
