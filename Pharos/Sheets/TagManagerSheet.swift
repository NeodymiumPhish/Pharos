import AppKit

// MARK: - TagManagerSheet

/// The grid's Add Tag… (`.add`) and Remove From Tag… (`.remove`) sheet: a list
/// of tags, and the chosen one's detail (`TagDetailVC`) beside it. The Tag
/// Manager WINDOW shows the same detail beside its Glass sidebar instead
/// (`TagManagerHostVC`); this sheet keeps its own compact list because it is
/// a task — choose the tag the selection joins, or tick the rules it leaves —
/// that ends with Save or Cancel.
///
/// Everything about editing lives in the detail, which owns the model. This
/// class owns only the list, the heading, and closing the sheet.
final class TagManagerSheet: NSViewController, NSTableViewDataSource, NSTableViewDelegate {

    /// The tag on show and every edit to it. Its model is the one truth; the
    /// list below reads `detail.model` and keeps no copy.
    let detail: TagDetailVC

    /// Told when this sheet closes itself.
    ///
    /// `dismiss(nil)` is always called as well, so the app's behaviour does not
    /// depend on whether anyone set this. It exists because `dismiss(nil)` is a
    /// NO-OP on a controller that was never presented, which leaves "did it
    /// close?" unobservable to the sheet's own harness — and that is exactly the
    /// question a failing save turns on.
    var onClose: (() -> Void)?
    /// Told after a save was written, just before `onClose`.
    var onSaved: (() -> Void)?

    // MARK: Controls

    let tableView = NSTableView()
    let newTagButton = NSButton()
    let deleteTagButton = NSButton()
    /// What the sheet is FOR, which is the one thing that differs between the
    /// entries.
    let titleLabel = NSTextField(labelWithString: "Tags")

    private var model: TagManagerModel { detail.model }

    // MARK: Construction

    init(model: TagManagerModel, committer: TagManagerCommitting,
         columns: [ColumnDef], loadedRows: [[String?]]) {
        detail = TagDetailVC(model: model, committer: committer,
                             columns: columns, loadedRows: loadedRows,
                             secondaryAction: .cancel)
        super.init(nibName: nil, bundle: nil)
        detail.onSaved = { [weak self] in
            self?.onSaved?()
            self?.closeSheet()
        }
        detail.onCancel = { [weak self] in self?.closeSheet() }
        detail.onTagChanged = { [weak self] index in self?.refreshRow(index) }
        detail.onAddTag = { [weak self] in self?.addTagTapped(nil) }
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) is not used") }

    // MARK: Layout

    override func loadView() {
        let root = NSView(frame: NSRect(x: 0, y: 0, width: 860, height: 560))

        titleLabel.stringValue = Self.title(for: model.mode)
        titleLabel.font = .systemFont(ofSize: 17, weight: .semibold)
        titleLabel.translatesAutoresizingMaskIntoConstraints = false

        buildSidebar()
        let sidebar = sidebarColumn()
        sidebar.translatesAutoresizingMaskIntoConstraints = false

        addChild(detail)
        let detailView = detail.view
        detailView.translatesAutoresizingMaskIntoConstraints = false

        root.addSubview(titleLabel)
        root.addSubview(sidebar)
        root.addSubview(detailView)
        NSLayoutConstraint.activate([
            titleLabel.topAnchor.constraint(equalTo: root.topAnchor, constant: 20),
            titleLabel.leadingAnchor.constraint(equalTo: root.leadingAnchor, constant: 20),
            titleLabel.trailingAnchor.constraint(lessThanOrEqualTo: root.trailingAnchor, constant: -20),

            sidebar.topAnchor.constraint(equalTo: titleLabel.bottomAnchor, constant: 12),
            sidebar.leadingAnchor.constraint(equalTo: root.leadingAnchor, constant: 20),
            sidebar.bottomAnchor.constraint(equalTo: root.bottomAnchor, constant: -20),
            sidebar.widthAnchor.constraint(equalToConstant: 240),

            detailView.topAnchor.constraint(equalTo: titleLabel.bottomAnchor, constant: 12),
            detailView.leadingAnchor.constraint(equalTo: sidebar.trailingAnchor, constant: 14),
            detailView.trailingAnchor.constraint(equalTo: root.trailingAnchor),
            detailView.bottomAnchor.constraint(equalTo: root.bottomAnchor),
        ])
        view = root
        detail.leadingKeyViews = [tableView, newTagButton, deleteTagButton]
    }

    override func viewDidLoad() {
        super.viewDidLoad()
        tableView.reloadData()
        // The first tag, not nothing: a detail pane standing empty beside a
        // full list reads as a fault.
        select(modelIndex: model.visibleTagIndices.first)
    }

    override func viewWillAppear() {
        super.viewWillAppear()
        view.window?.initialFirstResponder = detail.nameField
    }

    private func buildSidebar() {
        let column = NSTableColumn(identifier: .init("tag"))
        tableView.addTableColumn(column)
        tableView.headerView = nil
        tableView.rowHeight = 22
        tableView.dataSource = self
        tableView.delegate = self
        tableView.allowsEmptySelection = true
        tableView.allowsMultipleSelection = false

        newTagButton.title = "New Tag"
        newTagButton.bezelStyle = .rounded
        newTagButton.setButtonType(.momentaryPushIn)
        newTagButton.target = self
        newTagButton.action = #selector(addTagTapped)
        newTagButton.setAccessibilityLabel("Make a new tag")

        deleteTagButton.image = NSImage(systemSymbolName: "trash",
                                        accessibilityDescription: "Delete this tag")
        deleteTagButton.bezelStyle = .rounded
        deleteTagButton.setButtonType(.momentaryPushIn)
        deleteTagButton.target = self
        deleteTagButton.action = #selector(deleteTagTapped)
        deleteTagButton.hasDestructiveAction = true
        deleteTagButton.setAccessibilityLabel("Delete the selected tag")
        deleteTagButton.setContentHuggingPriority(.required, for: .horizontal)
    }

    private func sidebarColumn() -> NSView {
        let scroll = NSScrollView()
        scroll.hasVerticalScroller = true
        scroll.borderType = .bezelBorder
        scroll.documentView = tableView

        let buttons = NSStackView(views: [newTagButton, TagRuleGridView.slack(),
                                          deleteTagButton])
        buttons.orientation = .horizontal
        buttons.alignment = .centerY
        buttons.spacing = 6

        let column = NSStackView(views: [scroll, buttons])
        column.orientation = .vertical
        column.alignment = .leading
        column.spacing = 8
        column.spanArrangedSubviewsFullWidth()
        return column
    }

    /// What the sheet is FOR, in its heading.
    ///
    /// One modal with several jobs, and the heading is the first thing that
    /// says which. `.add` states the ROW COUNT because that number is the
    /// analyst's only check that the sheet caught the selection they made — an
    /// off-by-one selection is silent everywhere else.
    private static func title(for mode: TagManagerModel.Mode) -> String {
        switch mode {
        case .manage:
            return "Tags"
        case .add(let capture):
            // The SELECTED ROWS, not the draft rules. The heading answers "did
            // the sheet catch the selection I made", which must not change as
            // boxes are ticked — a heading that read "0 rows" until the first
            // tick would answer a different question than it appears to.
            let rows = capture.selectedRows.count
            return rows == 1 ? "Add to Tag — 1 row" : "Add to Tag — \(rows) rows"
        case .remove:
            return "Remove from Tag"
        }
    }

    // MARK: Selection

    /// Show one tag, by its MODEL index, or nothing at all.
    ///
    /// The detail is told BEFORE the table's selection moves, so the selection
    /// notification that follows resolves to the same index and stops there
    /// rather than redrawing a second time.
    private func select(modelIndex: Int?) {
        detail.select(modelIndex: modelIndex)
        if let shown = detail.selectedTagIndex, let row = model.visibleTagIndices.firstIndex(of: shown) {
            tableView.selectRowIndexes(IndexSet(integer: row), byExtendingSelection: false)
        } else {
            tableView.deselectAll(nil)
        }
        deleteTagButton.isEnabled = detail.selectedTagIndex != nil
    }

    /// Redraw ONE list row, for an edit that changed what it says — a rename,
    /// or a rule added or removed. A whole `reloadData` per keystroke would be
    /// a table rebuild per character.
    private func refreshRow(_ modelIndex: Int) {
        guard let row = model.visibleTagIndices.firstIndex(of: modelIndex) else { return }
        tableView.reloadData(forRowIndexes: IndexSet(integer: row),
                             columnIndexes: IndexSet(integersIn: 0..<max(tableView.numberOfColumns, 1)))
    }

    // MARK: Tag actions

    @objc private func addTagTapped(_ sender: Any?) {
        let index = detail.addTag()
        tableView.reloadData()
        select(modelIndex: index)
        view.window?.makeFirstResponder(detail.nameField)
    }

    /// Delete the selected tag, with no confirmation alert — see
    /// `TagDetailVC.deleteTag(at:)` for why.
    @objc private func deleteTagTapped(_ sender: Any?) {
        guard let index = detail.selectedTagIndex else { return }
        let removedRow = tableView.selectedRow
        detail.deleteTag(at: index)
        tableView.reloadData()
        // "Stay put": the next tag slides into the removed row and inherits the
        // selection; removing the last falls back one. Deleting down the list
        // therefore walks downwards instead of jumping to the top.
        let survivors = model.visibleTagIndices
        let nextRow = TagPalette.selectionAfterRemoval(removedRow: removedRow,
                                                       newCount: survivors.count)
        let next = nextRow.flatMap { survivors.indices.contains($0) ? survivors[$0] : nil }
        select(modelIndex: next)
    }

    private func closeSheet() {
        dismiss(nil)
        onClose?()
    }

    // MARK: NSTableViewDataSource / Delegate

    func numberOfRows(in tableView: NSTableView) -> Int { model.visibleTagIndices.count }

    func tableView(_ tableView: NSTableView, viewFor tableColumn: NSTableColumn?,
                   row: Int) -> NSView? {
        let visible = model.visibleTagIndices
        guard visible.indices.contains(row), model.tags.indices.contains(visible[row])
        else { return nil }
        let tag = model.tags[visible[row]]
        let identifier = NSUserInterfaceItemIdentifier("TagManagerRow")
        let cell = tableView.makeView(withIdentifier: identifier, owner: self)
            as? NSTableCellView ?? Self.makeRowCell(identifier)
        cell.imageView?.image = TagPalette.swatch(colorIndex: tag.colorIndex)
        // TRIMMED then ESCAPED (`TagDetailVC.displayName`), unlike the editable
        // name field: this row is drawn in the app's own voice and is what the
        // analyst reads before pressing Delete, and nothing reads it back — so
        // a trailing space typed a moment ago and about to be trimmed at Save
        // has no business appearing here as a mid-word `<U+0020>`.
        //
        // The count is the EDITED one, rules added this session included. Every
        // other surface here shows the edit in progress, and a list saying
        // "2 rules" beside a grid drawing three would have the two disagree
        // about the same tag while the analyst looks at both.
        let count = tag.rules.count
        let name = TagDetailVC.displayName(tag.name)
        cell.textField?.stringValue = "\(name) — \(CountedNounText.phrase(count, "rule"))"
        // The full name, because the label truncates: two tags whose names
        // differ only past the cut would otherwise read identically. ESCAPED,
        // like the label, and set on the LABEL as well as the cell, because the
        // label covers most of the row and answers the tooltip question for
        // itself. ALWAYS set, never only when the text is cut off: whether it
        // is cut off depends on the pane width at that moment.
        cell.toolTip = name
        cell.textField?.toolTip = name
        return cell
    }

    private static func makeRowCell(_ identifier: NSUserInterfaceItemIdentifier)
        -> NSTableCellView {
        let cell = NSTableCellView()
        cell.identifier = identifier
        let image = NSImageView()
        image.translatesAutoresizingMaskIntoConstraints = false
        let text = NSTextField(labelWithString: "")
        text.lineBreakMode = .byTruncatingTail
        text.translatesAutoresizingMaskIntoConstraints = false
        cell.addSubview(image)
        cell.addSubview(text)
        cell.imageView = image
        cell.textField = text
        NSLayoutConstraint.activate([
            image.leadingAnchor.constraint(equalTo: cell.leadingAnchor, constant: 4),
            image.centerYAnchor.constraint(equalTo: cell.centerYAnchor),
            image.widthAnchor.constraint(equalToConstant: 12),
            image.heightAnchor.constraint(equalToConstant: 12),
            text.leadingAnchor.constraint(equalTo: image.trailingAnchor, constant: 6),
            text.trailingAnchor.constraint(equalTo: cell.trailingAnchor, constant: -4),
            text.centerYAnchor.constraint(equalTo: cell.centerYAnchor),
        ])
        return cell
    }

    /// Idempotent on purpose: a programmatic selection raises this too, and a
    /// second pass over the same row must not re-render the grid under a field
    /// somebody is typing in.
    func tableViewSelectionDidChange(_ notification: Notification) {
        let visible = model.visibleTagIndices
        let row = tableView.selectedRow
        let resolved: Int? = visible.indices.contains(row) ? visible[row] : nil
        guard resolved != detail.selectedTagIndex else { return }
        detail.select(modelIndex: resolved)
        deleteTagButton.isEnabled = resolved != nil
    }
}
