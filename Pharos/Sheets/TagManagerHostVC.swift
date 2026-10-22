import AppKit

/// The Tag Manager window's content: one `TagManagerSheet` at a time, rebuilt
/// from the store after a save and when another window changes the tags while
/// this one has no edits of its own.
@MainActor
final class TagManagerHostVC: NSViewController {
    var closeWindow: (() -> Void)?
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

    init(tags: @escaping () -> [Tag], committer: TagManagerCommitting) {
        self.tags = tags
        self.committer = committer
        super.init(nibName: nil, bundle: nil)
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) not implemented") }
    private(set) var sheet: TagManagerSheet?
    private var columns: [ColumnDef] = []
    private var loadedRows: [[String?]] = []
    private var justSaved = false

    override func loadView() {
        view = NSView(frame: NSRect(x: 0, y: 0, width: 900, height: 600))
    }

    func setResults(columns: [ColumnDef], loadedRows: [[String?]]) {
        self.columns = columns
        self.loadedRows = loadedRows
    }

    /// Edits not yet saved.
    var hasEdits: Bool { !(sheet?.model.commits().isEmpty ?? true) }

    /// The tag selected in the sidebar, kept across a rebuild.
    var selectedTagId: String? {
        guard let sheet, sheet.tableView.selectedRow >= 0,
              sheet.tableView.selectedRow < sheet.model.visibleTagIndices.count else { return nil }
        return sheet.model.tags[sheet.model.visibleTagIndices[sheet.tableView.selectedRow]].id
    }

    /// A fresh sheet from the store, on `preselect` (or the tag selected now).
    func reseed(preselect: String? = nil) {
        let keep = preselect ?? selectedTagId
        if let old = sheet {
            old.view.removeFromSuperview()
            old.removeFromParent()
        }
        let model = TagManagerModel(tags: tags(), mode: .manage)
        let fresh = TagManagerSheet(model: model, committer: committer,
                                    columns: columns, loadedRows: loadedRows)
        fresh.onSaved = { [weak self] in self?.justSaved = true }
        fresh.onClose = { [weak self] in
            guard let self else { return }
            if self.justSaved {
                self.justSaved = false
                self.reseed()
            } else {
                self.closeWindow?()
            }
        }
        addChild(fresh)
        fresh.view.translatesAutoresizingMaskIntoConstraints = false
        view.addSubview(fresh.view)
        NSLayoutConstraint.activate([
            fresh.view.topAnchor.constraint(equalTo: view.safeAreaLayoutGuide.topAnchor),
            fresh.view.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            fresh.view.trailingAnchor.constraint(equalTo: view.trailingAnchor),
            fresh.view.bottomAnchor.constraint(equalTo: view.bottomAnchor),
        ])
        sheet = fresh
        if let keep { select(tagId: keep) }
    }

    /// Select a tag the way a click does (the sheet has no other entry point).
    func select(tagId: String) {
        guard let sheet, let modelIndex = sheet.model.tags.firstIndex(where: { $0.id == tagId }),
              let row = sheet.model.visibleTagIndices.firstIndex(of: modelIndex) else { return }
        sheet.tableView.selectRowIndexes(IndexSet(integer: row), byExtendingSelection: false)
        sheet.tableView.delegate?.tableViewSelectionDidChange?(
            Notification(name: NSTableView.selectionDidChangeNotification, object: sheet.tableView))
    }

    /// Another window (the grid's Add Tag…, an inspector delete) changed the
    /// tags: follow it unless this window has edits of its own, which a save
    /// will reconcile (a write on a tag that vanished reports itself).
    func storeChanged() {
        guard sheet != nil, !hasEdits else { return }
        reseed()
    }

    /// The window is closing: unsaved edits ask first.
    func confirmClose() -> Bool {
        guard hasEdits else { return true }
        return askDiscard()
    }
}
