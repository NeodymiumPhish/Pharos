import AppKit

// MARK: - TagManageSheet

/// "Manage Tags…": rename, recolour, edit the note, or delete a tag.
///
/// Single pane: the tag list on top, the selected tag's fields below, an
/// explicit Save. Changing the list selection without saving discards edits —
/// deliberate simplicity; the fields always mirror the selected tag.
///
/// Every write goes through `TagStore`, which reloads and posts `didChange`,
/// so every open grid recolours on Save without this sheet telling anyone.
final class TagManageSheet: NSViewController,
                            NSTableViewDataSource, NSTableViewDelegate,
                            NSTextFieldDelegate {

    private var tags: [Tag] = []
    private let preselectTagId: String?

    private let tableView = NSTableView()
    private let nameField = NSTextField()
    private let colorControl = NSSegmentedControl()
    private let noteField = NSTextField()
    private let saveButton = NSButton(title: "Save Changes", target: nil, action: nil)
    private let deleteButton = NSButton(title: "Delete Tag…", target: nil, action: nil)
    private let emptyLabel = NSTextField(labelWithString: "No tags yet.")

    init(preselect: String? = nil) {
        self.preselectTagId = preselect
        super.init(nibName: nil, bundle: nil)
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) is not used") }

    // MARK: Layout

    override func loadView() {
        let root = NSView(frame: NSRect(x: 0, y: 0, width: 520, height: 440))

        let title = NSTextField(labelWithString: "Manage Tags")
        title.font = .systemFont(ofSize: 17, weight: .semibold)

        let column = NSTableColumn(identifier: .init("tag"))
        tableView.addTableColumn(column)
        tableView.headerView = nil
        tableView.rowHeight = 22
        tableView.dataSource = self
        tableView.delegate = self
        tableView.allowsEmptySelection = true
        tableView.allowsMultipleSelection = false

        let scroll = NSScrollView()
        scroll.hasVerticalScroller = true
        scroll.borderType = .bezelBorder
        scroll.documentView = tableView

        colorControl.segmentCount = TagPalette.colors.count
        colorControl.trackingMode = .selectOne
        for index in TagPalette.colors.indices {
            colorControl.setImage(TagPalette.swatch(colorIndex: index), forSegment: index)
            colorControl.setWidth(30, forSegment: index)
        }

        nameField.placeholderString = "Case name"
        // Delegate, not target/action: `controlTextDidChange` fires per
        // keystroke, so the name is sanitised as it is typed and Save enables
        // the moment the name becomes non-empty.
        nameField.delegate = self
        noteField.placeholderString = "Note (optional)"

        saveButton.target = self
        saveButton.action = #selector(saveChanges)
        // Save is the DEFAULT button, not Done: the fields have no action of
        // their own, so Return in the name field resolves to whatever holds
        // "\r" — and a Return that closed the sheet would silently discard the
        // edit the analyst had just typed.
        saveButton.keyEquivalent = "\r"

        deleteButton.target = self
        deleteButton.action = #selector(deleteSelected)
        deleteButton.hasDestructiveAction = true

        let done = NSButton(title: "Done", target: self, action: #selector(dismissSheet))
        done.keyEquivalent = "\u{1b}"

        emptyLabel.textColor = .secondaryLabelColor
        emptyLabel.translatesAutoresizingMaskIntoConstraints = false

        let spacer = NSView()
        spacer.setContentHuggingPriority(.init(1), for: .horizontal)
        spacer.setContentCompressionResistancePriority(.init(1), for: .horizontal)
        let buttonRow = NSStackView(views: [deleteButton, spacer, saveButton, done])
        buttonRow.orientation = .horizontal
        buttonRow.spacing = 8

        let form = NSStackView(views: [
            title,
            scroll,
            labelled("Name", nameField),
            labelled("Colour", colorControl),
            labelled("Note", noteField),
            buttonRow,
        ])
        form.orientation = .vertical
        form.alignment = .width
        form.spacing = 10
        form.translatesAutoresizingMaskIntoConstraints = false
        root.addSubview(form)
        // Added after `form`, so it draws OVER the empty table rather than
        // under it.
        root.addSubview(emptyLabel)
        NSLayoutConstraint.activate([
            form.topAnchor.constraint(equalTo: root.topAnchor, constant: 20),
            form.leadingAnchor.constraint(equalTo: root.leadingAnchor, constant: 20),
            form.trailingAnchor.constraint(equalTo: root.trailingAnchor, constant: -20),
            form.bottomAnchor.constraint(equalTo: root.bottomAnchor, constant: -20),
            scroll.heightAnchor.constraint(equalToConstant: 180),
            emptyLabel.centerXAnchor.constraint(equalTo: scroll.centerXAnchor),
            emptyLabel.centerYAnchor.constraint(equalTo: scroll.centerYAnchor),
        ])
        view = root
    }

    override func viewDidLoad() {
        super.viewDidLoad()
        reloadTags(selecting: preselectTagId)
    }

    /// Focus the name field once the sheet is on screen, matching `TagSheet`.
    ///
    /// NOT in `viewDidLoad`: `view.window` is still nil there, so the
    /// assignment silently does nothing. With no tag selected there is nothing
    /// to focus — every field is disabled in that state.
    override func viewDidAppear() {
        super.viewDidAppear()
        guard selectedTag != nil else { return }
        view.window?.makeFirstResponder(nameField)
    }

    private func labelled(_ text: String, _ control: NSView) -> NSStackView {
        let label = NSTextField(labelWithString: text)
        label.alignment = .right
        label.textColor = .secondaryLabelColor
        label.widthAnchor.constraint(equalToConstant: 60).isActive = true
        let row = NSStackView(views: [label, control])
        row.orientation = .horizontal
        row.spacing = 8
        return row
    }

    // MARK: State

    private var selectedTag: Tag? {
        let row = tableView.selectedRow
        guard row >= 0, row < tags.count else { return nil }
        return tags[row]
    }

    /// Reload from the store and choose the selection.
    ///
    /// `id` lands on that tag when it still exists. `removedRow` is the row a
    /// just-deleted tag held, resolved by `TagPalette.selectionAfterRemoval`.
    /// Passing NEITHER means "no tag in particular" — the sheet then keeps a
    /// valid selection or falls to the first tag, which is the surprising part
    /// worth stating: `nil` is not "select nothing".
    ///
    /// `loadTagsIfNeeded` first because a failed write EVICTS the store's cache
    /// (`reloadTagsOrEvict` sets `tagsLoaded = false`), and the only other
    /// caller is `AppStateManager` at startup. Without this the whole app would
    /// believe it had no tags until relaunch: this list empty, the menu items
    /// disabled, `presentTagManageSheet` beeping. This is the recovery path.
    private func reloadTags(selecting id: String? = nil, afterRemoving removedRow: Int? = nil) {
        try? TagStore.shared.loadTagsIfNeeded()
        tags = TagStore.shared.tags
        tableView.reloadData()
        emptyLabel.isHidden = !tags.isEmpty
        if let id, let row = tags.firstIndex(where: { $0.id == id }) {
            select(row: row)
        } else if let removedRow {
            select(row: TagPalette.selectionAfterRemoval(removedRow: removedRow,
                                                        newCount: tags.count))
        } else if !tags.isEmpty && selectedTag == nil {
            // `selectedTag`, NOT `tableView.selectedRow < 0`: the old test
            // assumed `reloadData()` clips a now-invalid index, which AppKit
            // does not promise. This asks the question that actually matters —
            // "does the selection resolve to a tag?" — so a surviving
            // out-of-range index is repaired rather than left drawn over
            // disabled fields.
            select(row: 0)
        }
        populateFields()
    }

    /// Select one row, or clear the selection when there is no row to take.
    private func select(row: Int?) {
        guard let row, row >= 0, row < tags.count else {
            tableView.deselectAll(nil)
            return
        }
        tableView.selectRowIndexes(IndexSet(integer: row), byExtendingSelection: false)
    }

    private func populateFields() {
        if let tag = selectedTag {
            // SANITISED, not escaped: `saveChanges` reads this field back and
            // writes it to the store, so an escaped value would be saved as
            // its token text the first time the analyst pressed Save. The
            // read-only list row in `viewFor` is where the escaping belongs.
            //
            // A tag stored before the name rule existed can still hold a bidi
            // override, and this field is where it would be read and re-saved.
            // Cleaning it on the way IN means the field and the store agree
            // about everything except the characters that were only ever there
            // to deceive — and any later Save takes them out of the store too.
            nameField.stringValue = TagNameSanitizer.sanitized(tag.name)
            colorControl.selectedSegment = TagPalette.normalizedColorIndex(tag.colorIndex) ?? -1
            noteField.stringValue = tag.note ?? ""
        } else {
            nameField.stringValue = ""
            colorControl.selectedSegment = -1
            noteField.stringValue = ""
        }
        let hasSelection = selectedTag != nil
        nameField.isEnabled = hasSelection
        colorControl.isEnabled = hasSelection
        noteField.isEnabled = hasSelection
        deleteButton.isEnabled = hasSelection
        updateSaveButton()
    }

    private func updateSaveButton() {
        saveButton.isEnabled = selectedTag != nil
            && !nameField.stringValue.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    /// Sanitise the name AS IT CHANGES, then re-read it for the Save button.
    ///
    /// In that order: a name of nothing but bidi overrides sanitises away to
    /// an empty string, and Save must be disabled for it exactly as it is for
    /// a name the analyst cleared by hand.
    ///
    /// The rename path needs this as much as the Add Tag sheet does — it is
    /// the other place a tag name is authored, and a rename is where a tag
    /// that already carries trust can be given a name that reads as something
    /// else. The note is deliberately not sanitised; see `TagSheet`.
    func controlTextDidChange(_ obj: Notification) {
        if (obj.object as? NSTextField) === nameField { nameField.sanitizeAsTagName() }
        updateSaveButton()
    }

    // MARK: Actions

    @objc private func saveChanges() {
        guard let tag = selectedTag else { return }
        // Sanitised again on the only line that reaches the store, after
        // `controlTextDidChange` has already done it per keystroke, so a path
        // that sets the field without raising an edit notification cannot get
        // a deceptive name past it. Before the trim: an unusual space folds to
        // a plain one, which the trim then takes.
        let name = TagNameSanitizer.sanitized(nameField.stringValue)
            .trimmingCharacters(in: .whitespacesAndNewlines)
        guard !name.isEmpty else { return }

        // Send the colour only when the user actually moved the control.
        // A stored index can be out of the palette's range, and `populateFields`
        // shows it WRAPPED — so writing the wrapped value back would silently
        // change the tag's stored colour on a save that only renamed it.
        let chosen = colorControl.selectedSegment
        let colorChanged = chosen >= 0 && chosen != TagPalette.normalizedColorIndex(tag.colorIndex)

        // The note is ALWAYS sent: Rust's update_tag treats nil as
        // "unchanged" (COALESCE), so clearing a note requires "".
        let update = UpdateTag(
            id: tag.id,
            name: name,
            colorIndex: colorChanged ? chosen : nil,
            note: noteField.stringValue.trimmingCharacters(in: .whitespacesAndNewlines))
        do {
            // `update_tag` runs `UPDATE … WHERE id = ?1` and returns Ok(None)
            // for an id that is gone — no error crosses the FFI. Without this
            // guard, saving into a tag deleted elsewhere would report success
            // and leave the analyst believing the edit landed.
            guard try TagStore.shared.updateTag(update) != nil else {
                presentError(title: "That tag no longer exists",
                             message: "It was deleted elsewhere. The list has been refreshed.")
                reloadTags()
                return
            }
            reloadTags(selecting: tag.id)
        } catch {
            NSLog("Tag update failed: \(error)")
            presentError(title: "Could not save the tag", message: "\(error)")
            reloadTags(selecting: tag.id)
        }
    }

    @objc private func deleteSelected() {
        guard let tag = selectedTag, let window = view.window else { return }
        // Read the row BEFORE the write: afterwards the list has re-sorted
        // itself around the gap and this index no longer names the tag.
        let removedRow = tableView.selectedRow
        // Shared with the Inspector's per-tag "Remove Tag…", which offers the
        // same destructive action: one wording, one plural rule, one test.
        let text = TagInspectorModel.deleteConfirmation(
            name: tag.name, tupleCount: tag.tuples.count)
        let alert = NSAlert()
        alert.messageText = text.title
        alert.informativeText = text.body
        alert.alertStyle = .critical
        alert.addButton(withTitle: "Delete Tag")
        alert.addButton(withTitle: "Cancel")
        alert.buttons.first?.hasDestructiveAction = true
        // Cancel takes Return, not Delete. This sheet has just taught the
        // analyst that Return means Save; letting the same key confirm a
        // permanent, global delete (ON DELETE CASCADE takes every tuple) would
        // trade on that habit. `TagRemovalSheet` defaults to Cancel for the
        // same reason.
        alert.buttons.first?.keyEquivalent = ""
        alert.buttons.last?.keyEquivalent = "\r"
        alert.beginSheetModal(for: window) { [weak self] response in
            guard response == .alertFirstButtonReturn, let self else { return }
            do {
                try TagStore.shared.deleteTag(id: tag.id)
                self.reloadTags(afterRemoving: removedRow)
            } catch {
                NSLog("Tag delete failed: \(error)")
                // Deferred by a turn: this runs inside the confirmation
                // alert's completion handler, and AppKit tears a sheet down
                // ASYNCHRONOUSLY, so presenting in the same turn can be
                // dropped — leaving only the NSLog and a sheet that looks like
                // it did nothing (tasks/lessons.md, 2026-08-06). The lesson
                // prescribes an INJECTED closure so a test can control the
                // timing; there is no harness that reaches this class, so a
                // plain hop is the honest equivalent here.
                DispatchQueue.main.async {
                    self.presentError(title: "Could not delete the tag", message: "\(error)")
                }
                self.reloadTags(selecting: tag.id)
            }
        }
    }

    @objc private func dismissSheet() { dismiss(nil) }

    // No `cancelOperation` override: `done` holds "\u{1b}", and a button's key
    // equivalent is resolved before the responder chain sees the key, so the
    // override could never run.

    private func presentError(title: String, message: String) {
        guard let window = view.window else { return }
        let alert = NSAlert()
        alert.messageText = title
        alert.informativeText = message
        alert.addButton(withTitle: "OK")
        alert.beginSheetModal(for: window)
    }

    // MARK: NSTableViewDataSource / Delegate

    func numberOfRows(in tableView: NSTableView) -> Int { tags.count }

    func tableView(_ tableView: NSTableView, viewFor tableColumn: NSTableColumn?,
                   row: Int) -> NSView? {
        guard row < tags.count else { return nil }
        let tag = tags[row]
        let identifier = NSUserInterfaceItemIdentifier("TagManageRow")
        let cell = tableView.makeView(withIdentifier: identifier, owner: self)
            as? NSTableCellView ?? {
                let fresh = NSTableCellView()
                fresh.identifier = identifier
                let image = NSImageView()
                image.translatesAutoresizingMaskIntoConstraints = false
                let text = NSTextField(labelWithString: "")
                text.lineBreakMode = .byTruncatingTail
                text.translatesAutoresizingMaskIntoConstraints = false
                fresh.addSubview(image)
                fresh.addSubview(text)
                fresh.imageView = image
                fresh.textField = text
                NSLayoutConstraint.activate([
                    image.leadingAnchor.constraint(equalTo: fresh.leadingAnchor, constant: 4),
                    image.centerYAnchor.constraint(equalTo: fresh.centerYAnchor),
                    image.widthAnchor.constraint(equalToConstant: 12),
                    image.heightAnchor.constraint(equalToConstant: 12),
                    text.leadingAnchor.constraint(equalTo: image.trailingAnchor, constant: 6),
                    text.trailingAnchor.constraint(equalTo: fresh.trailingAnchor, constant: -4),
                    text.centerYAnchor.constraint(equalTo: fresh.centerYAnchor),
                ])
                return fresh
            }()
        cell.imageView?.image = TagPalette.swatch(colorIndex: tag.colorIndex)
        let count = tag.tuples.count
        // DISPLAY only, and still needed after the name rule: a tag stored
        // before it exists can hold a bidi override, and this list row is what
        // the analyst reads before pressing Delete. The EDITABLE `nameField` in
        // `populateFields` is deliberately NOT escaped but SANITISED — that
        // field is read back by `saveChanges`, so escaping it would write the
        // token text into the store on any save.
        cell.textField?.stringValue =
            "\(DisplayEscape.escaped(tag.name)) — \(count) tuple\(count == 1 ? "" : "s")"
        return cell
    }

    func tableViewSelectionDidChange(_ notification: Notification) {
        populateFields()
    }
}
