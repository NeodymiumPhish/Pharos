import AppKit

// MARK: - TagSheet

/// "Add Tag": name a finding, pick the columns that define it, watch the live
/// count, save.
///
/// The model layer is `TagDraft` and the count is the real `TagTupleMatcher`,
/// so what the footer promises and what SQLite receives cannot drift apart.
/// This class owns layout and event wiring only.
final class TagSheet: NSViewController, NSTextFieldDelegate {

    /// Everything the sheet needs from the grid, resolved before it opens.
    struct Context {
        let columns: [ColumnDef]
        /// The selected rows' values as text, in column order. One tuple per row.
        let selectedRows: [[String?]]
        /// Every loaded row, for the live count.
        let loadedRows: [[String?]]
        let originConnection: String
        /// "public.certs", or "" when the result has no source table. Provenance
        /// only — an empty string never stops a tag being made.
        let originTable: String
        let existingTags: [Tag]
    }

    private let context: Context

    private let tagPopup = NSPopUpButton()
    private let nameField = NSTextField()
    private let colorControl = NSSegmentedControl()
    private let noteField = NSTextField()
    private let columnStack = NSStackView()
    private let countLabel = NSTextField(labelWithString: "")
    private let warningLabel = NSTextField(labelWithString: "")
    private let createButton = NSButton(title: "Create Tag", target: nil, action: nil)

    /// Checkbox per result column, in column order.
    private var checkboxes: [NSButton] = []

    /// nil = "New tag"; otherwise the tag the new tuples join.
    private var targetTagId: String?

    /// Bumped by every `refresh`, so a slow background count that lands after
    /// the analyst has ticked another box is discarded instead of overwriting
    /// a newer number.
    private var countGeneration = 0

    /// Mirrors `ResultsGridVC.matchAsyncThreshold`. Deliberately a second
    /// constant rather than a reference to that one: this is a modal's
    /// responsiveness policy, not the grid's, and a sheet should not reach into
    /// a view controller for a number. Keep them in step by hand.
    private static let asyncCountThreshold = 5_000

    init(context: Context) {
        self.context = context
        super.init(nibName: nil, bundle: nil)
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) is not used") }

    // MARK: Layout

    override func loadView() {
        let root = NSView(frame: NSRect(x: 0, y: 0, width: 460, height: 520))

        let title = NSTextField(labelWithString:
            context.selectedRows.count > 1
                ? "Add Tag — \(context.selectedRows.count) rows"
                : "Add Tag")
        title.font = .systemFont(ofSize: 17, weight: .semibold)

        tagPopup.addItem(withTitle: "New tag")
        for tag in context.existingTags {
            // Escaped for DISPLAY only. The tag this popup selects is carried by
            // `representedObject` (the id) on the next line, never by the title,
            // so escaping cannot pick the wrong tag.
            tagPopup.addItem(withTitle: DisplayEscape.escaped(tag.name))
            tagPopup.lastItem?.representedObject = tag.id
            tagPopup.lastItem?.image = TagPalette.swatch(colorIndex: tag.colorIndex)
        }
        tagPopup.target = self
        tagPopup.action = #selector(tagChoiceChanged)

        nameField.placeholderString = "Case name"
        // Delegate for `controlTextDidChange` below: a name is sanitised as it
        // is typed or pasted, so the field never holds one that reads as
        // something else.
        nameField.delegate = self

        // A segmented control rather than six buttons: one control, one
        // selectedSegment, and the keyboard reaches it for free.
        colorControl.segmentCount = TagPalette.colors.count
        colorControl.trackingMode = .selectOne
        for index in TagPalette.colors.indices {
            colorControl.setImage(TagPalette.swatch(colorIndex: index), forSegment: index)
            colorControl.setWidth(30, forSegment: index)
        }
        colorControl.selectedSegment = context.existingTags.count % TagPalette.colors.count

        noteField.placeholderString = "Note (optional)"

        columnStack.orientation = .vertical
        columnStack.alignment = .width
        columnStack.spacing = 4
        buildColumnRows()

        let scroll = NSScrollView()
        scroll.hasVerticalScroller = true
        scroll.drawsBackground = false
        scroll.documentView = columnStack
        columnStack.translatesAutoresizingMaskIntoConstraints = false

        countLabel.font = .systemFont(ofSize: 11)
        countLabel.textColor = .secondaryLabelColor
        warningLabel.font = .systemFont(ofSize: 11)
        warningLabel.textColor = .systemOrange

        let cancel = NSButton(title: "Cancel", target: self, action: #selector(cancel))
        cancel.keyEquivalent = "\u{1b}"
        createButton.target = self
        createButton.action = #selector(save)
        createButton.keyEquivalent = "\r"

        let form = NSStackView(views: [
            title,
            labelled("Tag", tagPopup),
            labelled("Name", nameField),
            labelled("Colour", colorControl),
            labelled("Note", noteField),
            NSTextField(labelWithString: "Capture from columns"),
            scroll,
            countLabel,
            warningLabel,
            NSStackView(views: [cancel, createButton]),
        ])
        form.orientation = .vertical
        form.alignment = .width
        form.spacing = 10
        form.translatesAutoresizingMaskIntoConstraints = false
        root.addSubview(form)
        NSLayoutConstraint.activate([
            form.topAnchor.constraint(equalTo: root.topAnchor, constant: 20),
            form.leadingAnchor.constraint(equalTo: root.leadingAnchor, constant: 20),
            form.trailingAnchor.constraint(equalTo: root.trailingAnchor, constant: -20),
            form.bottomAnchor.constraint(equalTo: root.bottomAnchor, constant: -20),
            scroll.heightAnchor.constraint(equalToConstant: 200),
            columnStack.widthAnchor.constraint(equalTo: scroll.widthAnchor),
        ])
        view = root
    }

    override func viewDidLoad() {
        super.viewDidLoad()
        refresh()
    }

    /// Focus the name field once the sheet is on screen.
    ///
    /// NOT in `viewDidLoad`: `view.window` is still nil there, so the
    /// assignment silently does nothing — proved by test, not assumed. By
    /// `viewDidAppear` the sheet is attached and `makeFirstResponder` takes.
    override func viewDidAppear() {
        super.viewDidAppear()
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

    /// One row per result column: a checkbox, the family, and how many distinct
    /// values the SELECTION would contribute. The count is what tells an analyst
    /// that a column is constant across the selection and therefore a wide
    /// capture.
    private func buildColumnRows() {
        for (index, column) in context.columns.enumerated() {
            // The column name is data: a SELECT alias comes straight from the
            // query, and this checkbox is what the analyst reads to decide which
            // column a tag captures from. Escaped for DISPLAY only — the column
            // this box selects is carried by `box.tag` (the index) below, so the
            // capture cannot follow the rendered title.
            let box = NSButton(checkboxWithTitle: DisplayEscape.escaped(column.name),
                               target: self, action: #selector(columnToggled))
            box.tag = index
            checkboxes.append(box)

            let family = TagValueNormalizer.family(forDataType: column.dataType)
            let familyLabel = NSTextField(labelWithString: family)
            familyLabel.font = .monospacedSystemFont(ofSize: 10, weight: .regular)
            familyLabel.textColor = .tertiaryLabelColor

            let distinct = Set(context.selectedRows.compactMap {
                index < $0.count ? $0[index] : nil
            }).count
            let countText = NSTextField(labelWithString:
                "\(distinct) value\(distinct == 1 ? "" : "s")")
            countText.font = .systemFont(ofSize: 10)
            countText.textColor = .tertiaryLabelColor

            let row = NSStackView(views: [box, familyLabel, countText])
            row.orientation = .horizontal
            row.spacing = 8
            columnStack.addArrangedSubview(row)
        }
    }

    // MARK: State

    private var checkedColumns: [Int] {
        checkboxes.filter { $0.state == .on }.map { $0.tag }
    }

    private var draftTuples: [NewTagTuple] {
        TagDraft.tuples(selectedRows: context.selectedRows, columns: context.columns,
                        checkedColumns: checkedColumns,
                        originConnection: context.originConnection,
                        originTable: context.originTable)
    }

    @objc private func columnToggled() { refresh() }

    /// A tag name is sanitised AS IT CHANGES, not at save.
    ///
    /// The name is a label this app then draws in its own voice — the grid row
    /// tooltip, the Inspector, the removal sheet's group header, the delete
    /// confirmation — so a bidi override in it makes every one of those read as
    /// something the tag is not. Cleaning it here rather than on the way to the
    /// store is what lets the analyst SEE the name they are committing to;
    /// storing a name the field never displayed would be its own kind of lie.
    ///
    /// The note is deliberately left alone. It gates nothing and names no
    /// value, it has one display site which is the Inspector, and that label
    /// legitimately holds prose across several lines — the sanitiser folds a
    /// newline to a space, which would destroy a paragraph break an analyst
    /// meant. Its exposure is a display concern, not an input one.
    func controlTextDidChange(_ obj: Notification) {
        guard (obj.object as? NSTextField) === nameField else { return }
        nameField.sanitizeAsTagName()
    }

    @objc private func tagChoiceChanged() {
        targetTagId = tagPopup.selectedItem?.representedObject as? String
        // "Add to existing" disables the identity fields: the tuples join a tag
        // that already has a name, a colour and a note.
        let isNew = targetTagId == nil
        nameField.isEnabled = isNew
        colorControl.isEnabled = isNew
        noteField.isEnabled = isNew
        createButton.title = isNew ? "Create Tag" : "Add to Tag"
        refresh()
    }

    /// The live count, run through the REAL matcher on every toggle. Below the
    /// threshold it runs synchronously, the same cost class as the matcher the
    /// grid runs anyway; above it, the count moves to a background queue
    /// exactly as `ResultsGridVC.matchAsyncThreshold` does for the grid's own
    /// match, so a large loaded set cannot drop a frame on every checkbox
    /// click.
    private func refresh() {
        let tuples = draftTuples
        createButton.isEnabled = !tuples.isEmpty
        guard !tuples.isEmpty else {
            countLabel.stringValue = "Select at least one column."
            warningLabel.stringValue = ""
            return
        }

        countGeneration += 1
        let generation = countGeneration
        let columns = context.columns
        let rows = context.loadedRows
        let previewTag = TagDraft.previewTag(tuples: tuples)

        guard rows.count > Self.asyncCountThreshold else {
            show(matched: TagTupleMatcher.matchCount(tag: previewTag,
                                                     columns: columns, rows: rows),
                 loaded: rows.count)
            return
        }

        // Above the threshold the count leaves the main thread, exactly as the
        // grid's own match does. The label says so meanwhile rather than
        // showing a stale number from the previous tick.
        countLabel.stringValue = "Counting…"
        warningLabel.stringValue = ""
        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            let matched = TagTupleMatcher.matchCount(tag: previewTag,
                                                     columns: columns, rows: rows)
            DispatchQueue.main.async {
                MainActor.assumeIsolated {
                    guard let self, self.countGeneration == generation else { return }
                    self.show(matched: matched, loaded: rows.count)
                }
            }
        }
    }

    /// The footer, from a finished count.
    private func show(matched: Int, loaded: Int) {
        countLabel.stringValue = "Matches \(matched) of \(loaded) loaded rows."
        // The warning never blocks: a deliberately broad temporary tag is a
        // legitimate tool, and only the analyst knows which this is.
        warningLabel.stringValue = TagDraft.isBroad(matched: matched, loaded: loaded)
            ? "This tag is broad."
            : ""
    }

    // MARK: Actions

    @objc private func cancel() { dismiss(nil) }

    @objc private func save() {
        let tuples = draftTuples
        guard !tuples.isEmpty else { return }
        do {
            if let targetTagId {
                try TagStore.shared.addTuples(
                    AddTagTuples(tagId: targetTagId, tuples: tuples))
            } else {
                // `.whitespacesAndNewlines`, not `.whitespaces`: pasted text
                // carries a trailing newline, which `.whitespaces` leaves in
                // place. That is the note's case — the NAME reaches this line
                // with its newlines already folded to spaces — and both are
                // trimmed the one way. `TagManageSheet` trims the same way.
                //
                // Sanitised again here, after `controlTextDidChange` has
                // already done it per keystroke: this is the only line that
                // reaches the store, so a future path that sets the field
                // without an edit notification cannot get a deceptive name
                // past it. Sanitising BEFORE trimming matters — an unusual
                // space folds to a plain one, which the trim then takes.
                let name = TagNameSanitizer.sanitized(nameField.stringValue)
                    .trimmingCharacters(in: .whitespacesAndNewlines)
                let note = noteField.stringValue.trimmingCharacters(in: .whitespacesAndNewlines)
                try TagStore.shared.createTag(CreateTag(
                    name: name.isEmpty ? "Untitled tag" : name,
                    colorIndex: max(0, colorControl.selectedSegment),
                    note: note.isEmpty ? nil : note,
                    tuples: tuples))
            }
            dismiss(nil)
        } catch {
            NSLog("Tag save failed: \(error)")
            let alert = NSAlert()
            alert.messageText = "Could not save the tag"
            alert.informativeText = "\(error)"
            alert.addButton(withTitle: "OK")
            guard let window = view.window else { return }
            alert.beginSheetModal(for: window)
        }
    }
}
