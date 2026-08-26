import AppKit

// MARK: - TagManagerSheet

/// The Tag Manager: a sidebar of tags, the identity fields for the selected
/// one, its rules, and one explicit Save.
///
/// It holds no truth of its own. `TagManagerModel` decides what an edit means
/// and what a save would write; `TagRuleGridView` draws the rules; this class is
/// the wiring between them, plus the sidebar and the identity fields. Three
/// rules govern that wiring, and each is the kind an ordinary-looking edit would
/// quietly reverse:
///
/// 1. **The grid is re-rendered only on a STRUCTURAL change** — a rule or
///    condition added or removed, or the selected tag changed. `render` rebuilds
///    every row from scratch, so it destroys the field the analyst is typing in,
///    and focus does not survive it. `changedCondition` fires per KEYSTROKE, so
///    re-rendering there would make the value field unusable. A value edit
///    changes nothing structural anyway: the row already shows what was typed,
///    owns its own error line, and shows or hides its own upper-bound field.
/// 2. **The NAME field is sanitised as it is typed; the NOTE field is not.** A
///    tag name is an authored label this app then draws in its own voice — the
///    sidebar, the row tooltip, the Inspector — so a bidi override in it makes
///    every one of those surfaces read as something the tag is not. A note is
///    prose, is legitimately multi-line, and is EDITED here rather than
///    rendered: escaping it would save the escape tokens, and sanitising it
///    would destroy a note that quotes the hostile text the analyst is hunting.
///    It carries a `HostileTextBadge` instead, so what is invisible is disclosed
///    rather than removed.
/// 3. **Edits commit on Save, never per keystroke.** `TagStore.reloadTags` posts
///    a global change that rebuilds every open grid's match, so a per-keystroke
///    write would rebuild the app's grids on every character typed.
///
/// The model is a STRUCT held here and mutated in place. Every callback this
/// class hands out reaches back through `self` and reads `self.model` at CALL
/// time — none of them captures the model, or a tag out of it, by value. A
/// closure that captured `self.model` at render time would go on editing a copy
/// that Save never sees.
final class TagManagerSheet: NSViewController,
                             NSTableViewDataSource, NSTableViewDelegate,
                             NSTextFieldDelegate {

    // MARK: State

    /// Read-only to everyone else: every change goes through a mutating method
    /// on the model, from one of the actions below.
    private(set) var model: TagManagerModel
    private let committer: TagManagerCommitting

    /// The result behind the manager, for the live match count. Both may be
    /// empty — the "Manage Tags…" entry has no result behind it at all — so
    /// nothing here may require them.
    private let columns: [ColumnDef]
    private let loadedRows: [[String?]]

    /// How the footer's count is worked out.
    ///
    /// Injectable so the stale-count guard can be tested. A test supplies a
    /// function that blocks on a semaphore it controls; production uses the real
    /// matcher. Racing the real one by timing would be a flaky test pretending
    /// to be a guarantee.
    var countMatches: (Tag, [ColumnDef], [[String?]]) -> Int = TagRuleMatcher.matchCount

    /// Bumped by every count started, so a slow background count that lands
    /// after a newer one is discarded instead of overwriting a fresher number.
    ///
    /// Lifted from `TagSheet.countGeneration`, together with the threshold and
    /// the background hop below — the sheet this one replaces. It guards a tag
    /// SWITCH as well as an edit, which `TagSheet` never had to: every count
    /// starts here, and the previous tag's number landing under the new tag's
    /// name would be a wrong number attached to the wrong tag, which is worse
    /// than a slow one.
    private var countGeneration = 0

    /// Mirrors `TagSheet.asyncCountThreshold`, which mirrors
    /// `ResultsGridVC.matchAsyncThreshold`. Deliberately its own constant rather
    /// than a reference: this is a modal's responsiveness policy, not the
    /// grid's. Keep them in step by hand.
    private static let asyncCountThreshold = 5_000

    /// The rules TICKED for removal, across every tag — not only the one on
    /// screen.
    ///
    /// Held here rather than in the grid because the grid draws ONE tag: a
    /// `.remove` that spans two tags would lose the first tag's ticks the moment
    /// the analyst looked at the second. Seeded from the mode, and from then on
    /// the analyst's, which is the whole point of assertion 7.
    private var tickedRuleIds: Set<String> = []

    /// The tag on show, by its index in `model.tags` — NOT its row in the
    /// sidebar. The two differ the moment a tag is deleted, because the model
    /// marks a deleted tag rather than removing it, so that indices held across
    /// a run loop keep their meaning.
    private(set) var selectedTagIndex: Int?

    /// What the analyst has typed that the condition editor refused, by (rule,
    /// condition) of the SELECTED tag.
    ///
    /// Cleared on every render: the rows are rebuilt there and each starts with
    /// no error drawn, so a refusal remembered across a render would be a
    /// refusal nothing on screen is showing.
    private var refusals: [ConditionRef: TagConditionEditor.Invalid] = [:]

    private struct ConditionRef: Hashable {
        let rule: Int
        let condition: Int
    }

    /// Told when this sheet closes itself.
    ///
    /// `dismiss(nil)` is always called as well, so the app's behaviour does not
    /// depend on whether anyone set this. It exists because `dismiss(nil)` is a
    /// NO-OP on a controller that was never presented, which leaves "did it
    /// close?" unobservable to the sheet's own harness — and that is exactly the
    /// question a failing save turns on.
    var onClose: (() -> Void)?

    // MARK: Controls
    //
    // Internal, like `TagRuleGridView.groups` and for the same reason: the suite
    // drives the REAL controls through their own target/action and delegate
    // wiring, and a view walk cannot tell the name field from the note field.

    let tableView = NSTableView()
    let nameField = NSTextField()
    let colorControl = NSSegmentedControl()
    let noteField = NSTextField()
    /// Says an invisible character is in the note. The note itself is never
    /// altered — see rule 2 above.
    let noteBadge = HostileTextBadge()
    let grid = TagRuleGridView()
    /// The capture checklist, drawn in `.add` only. Empty in every other mode.
    let captureList = TagCaptureListView()
    /// What the checklist is asking, and — with several rows selected — what
    /// ticking a box will produce.
    let captureCaption = NSTextField(labelWithString: "")
    let newTagButton = NSButton()
    let deleteTagButton = NSButton()
    let saveButton = NSButton()
    let cancelButton = NSButton()
    /// Why Save is unavailable, or what a save will do that cannot be undone.
    let statusLabel = NSTextField(labelWithString: "")
    let emptyLabel = NSTextField(labelWithString: "No tags yet. Add one to start.")
    /// What the sheet is FOR, which is the one thing that differs between the
    /// three entries.
    let titleLabel = NSTextField(labelWithString: "Tags")
    /// How many loaded rows the selected tag matches, run through the real
    /// matcher.
    let countLabel = NSTextField(labelWithString: "")
    /// "This tag is broad." Never blocks — see `refreshCount`.
    let warningLabel = NSTextField(labelWithString: "")

    /// The identity form and the rules, hidden together when no tag is
    /// selected. An `NSStackView` detaches a hidden arranged subview, so an
    /// empty sidebar leaves no phantom tag drawn beside it.
    private let identityStack = NSStackView()
    /// Internal, unlike the stacks around it: the suite MEASURES the two
    /// viewports against each other, because "the checklist scrolls instead of
    /// squeezing the rules" is a claim about heights and nothing else can
    /// check it.
    let gridScroll = NSScrollView()
    /// The caption and the checklist together, hidden whole in `.manage` and
    /// `.remove` — an `NSStackView` detaches a hidden arranged subview, so those
    /// modes lose the space as well as the rows.
    private let captureBox = NSStackView()
    let captureScroll = NSScrollView()

    // MARK: Construction

    init(model: TagManagerModel, committer: TagManagerCommitting,
         columns: [ColumnDef], loadedRows: [[String?]]) {
        self.model = model
        self.committer = committer
        self.columns = columns
        self.loadedRows = loadedRows
        // Seeded from the mode, then owned by the analyst. Nothing reads the
        // mode's set again: the boxes on screen are the promise, and a second
        // reader of the original set is exactly how a delete comes to disagree
        // with what was ticked.
        if case .remove(let ruleIds) = model.mode { self.tickedRuleIds = ruleIds }
        super.init(nibName: nil, bundle: nil)
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) is not used") }

    // MARK: Layout

    override func loadView() {
        let root = NSView(frame: NSRect(x: 0, y: 0, width: 860, height: 560))

        titleLabel.stringValue = Self.title(for: model.mode)
        titleLabel.font = .systemFont(ofSize: 17, weight: .semibold)

        buildSidebar()
        buildIdentity()
        buildCaptureList()
        buildGrid()
        buildFooterControls()

        let columnsRow = NSStackView(views: [sidebarColumn(), detailColumn()])
        columnsRow.orientation = .horizontal
        columnsRow.alignment = .top
        columnsRow.spacing = 14

        let footerRow = NSStackView(views: [statusLabel, TagRuleGridView.slack(),
                                            cancelButton, saveButton])
        footerRow.orientation = .horizontal
        footerRow.alignment = .centerY
        footerRow.spacing = 8

        // The count sits ABOVE the status line rather than beside it: the two
        // answer different questions — "what does this tag reach" and "what will
        // Save do" — and one crowded row would make either easy to miss.
        let countRow = NSStackView(views: [countLabel, warningLabel,
                                           TagRuleGridView.slack()])
        countRow.orientation = .horizontal
        countRow.alignment = .centerY
        countRow.spacing = 8

        let form = NSStackView(views: [titleLabel, columnsRow, countRow, footerRow])
        form.orientation = .vertical
        // `.leading` plus the span, never `.width`: an NSStackView silently
        // discards `.width` as an alignment — see NSStackView+SpanFullWidth.
        form.alignment = .leading
        form.spacing = 12
        form.spanArrangedSubviewsFullWidth()
        form.translatesAutoresizingMaskIntoConstraints = false
        root.addSubview(form)
        NSLayoutConstraint.activate([
            form.topAnchor.constraint(equalTo: root.topAnchor, constant: 20),
            form.leadingAnchor.constraint(equalTo: root.leadingAnchor, constant: 20),
            form.trailingAnchor.constraint(equalTo: root.trailingAnchor, constant: -20),
            form.bottomAnchor.constraint(equalTo: root.bottomAnchor, constant: -20),
        ])
        view = root
    }

    override func viewDidLoad() {
        super.viewDidLoad()
        tableView.reloadData()
        // The first tag, not nothing: a detail pane standing empty beside a
        // full sidebar reads as a fault, and every field in it would be greyed
        // with no explanation.
        select(modelIndex: model.visibleTagIndices.first)
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

        emptyLabel.textColor = .secondaryLabelColor
        emptyLabel.lineBreakMode = .byWordWrapping
        emptyLabel.maximumNumberOfLines = 0
        emptyLabel.cell?.wraps = true
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
        column.setContentHuggingPriority(.defaultHigh, for: .horizontal)
        column.widthAnchor.constraint(equalToConstant: 240).isActive = true
        return column
    }

    private func buildIdentity() {
        nameField.placeholderString = "Case name"
        // Delegate, not target/action: `controlTextDidChange` fires per
        // keystroke, so the name is sanitised as it is typed and the model
        // never holds a name the field is not showing.
        nameField.delegate = self
        nameField.setAccessibilityLabel("Tag name")

        colorControl.segmentCount = TagPalette.colors.count
        colorControl.trackingMode = .selectOne
        for index in TagPalette.colors.indices {
            colorControl.setImage(TagPalette.swatch(colorIndex: index), forSegment: index)
            colorControl.setWidth(30, forSegment: index)
        }
        colorControl.target = self
        colorControl.action = #selector(colorChanged)
        colorControl.setAccessibilityLabel("Tag colour")

        noteField.placeholderString = "Note (optional)"
        noteField.delegate = self
        // A note is prose and may be several lines. `stringValue` round-trips
        // whatever is stored either way; this is only about showing it.
        noteField.usesSingleLineMode = false
        noteField.cell?.wraps = true
        noteField.maximumNumberOfLines = 3
        noteField.setAccessibilityLabel("Tag note")

        let noteRow = NSStackView(views: [noteField, noteBadge])
        noteRow.orientation = .horizontal
        noteRow.alignment = .centerY
        noteRow.spacing = 6

        identityStack.orientation = .vertical
        identityStack.alignment = .leading
        identityStack.spacing = 8
        identityStack.addArrangedSubview(labelled("Name", nameField))
        identityStack.addArrangedSubview(labelled("Colour", colorControl))
        identityStack.addArrangedSubview(labelled("Note", noteRow))
        identityStack.spanArrangedSubviewsFullWidth()
    }

    /// The capture checklist and its caption.
    ///
    /// The checklist SCROLLS inside a fixed height, and that is the whole point
    /// of the scroll view: a 60-column result would otherwise draw sixty rows
    /// and push the rules grid off the bottom of the sheet. A fixed height means
    /// the two cannot compete for space at all — the grid keeps its own
    /// `>= 220`, whatever the result's shape.
    private func buildCaptureList() {
        captureCaption.font = .preferredFont(forTextStyle: .caption1)
        captureCaption.textColor = .secondaryLabelColor
        captureCaption.lineBreakMode = .byWordWrapping
        captureCaption.maximumNumberOfLines = 0
        captureCaption.cell?.wraps = true

        captureScroll.hasVerticalScroller = true
        captureScroll.drawsBackground = false
        captureScroll.borderType = .bezelBorder

        let document = FlippedView()
        document.translatesAutoresizingMaskIntoConstraints = false
        captureList.translatesAutoresizingMaskIntoConstraints = false
        document.addSubview(captureList)
        captureScroll.documentView = document
        NSLayoutConstraint.activate([
            document.leadingAnchor.constraint(equalTo: captureScroll.contentView.leadingAnchor),
            document.trailingAnchor.constraint(equalTo: captureScroll.contentView.trailingAnchor),
            document.topAnchor.constraint(equalTo: captureScroll.contentView.topAnchor),
            // Inset on both sides, so a row's checkbox does not sit against the
            // scroll view's border and a value has room before the scroller.
            captureList.leadingAnchor.constraint(equalTo: document.leadingAnchor, constant: 8),
            captureList.trailingAnchor.constraint(equalTo: document.trailingAnchor, constant: -8),
            captureList.topAnchor.constraint(equalTo: document.topAnchor, constant: 6),
            captureList.bottomAnchor.constraint(equalTo: document.bottomAnchor, constant: -6),
            captureScroll.heightAnchor.constraint(equalToConstant: Self.captureListHeight),
        ])

        captureBox.orientation = .vertical
        captureBox.alignment = .leading
        captureBox.spacing = 6
        captureBox.addArrangedSubview(captureCaption)
        captureBox.addArrangedSubview(captureScroll)
        captureBox.spanArrangedSubviewsFullWidth()
        // Only `.add` captures anything. A checklist in the other two modes
        // would be asking a question they are not there to answer.
        captureBox.isHidden = model.capture == nil

        captureList.onToggle = { [weak self] index, checked in
            self?.captureColumnToggled(index, checked)
        }
        renderCaptureList()
    }

    /// How tall the checklist is, whatever the result's width in columns.
    private static let captureListHeight: CGFloat = 118

    private func buildGrid() {
        gridScroll.hasVerticalScroller = true
        gridScroll.drawsBackground = false
        gridScroll.borderType = .noBorder

        let document = FlippedView()
        document.translatesAutoresizingMaskIntoConstraints = false
        grid.translatesAutoresizingMaskIntoConstraints = false
        document.addSubview(grid)
        gridScroll.documentView = document
        NSLayoutConstraint.activate([
            document.leadingAnchor.constraint(equalTo: gridScroll.contentView.leadingAnchor),
            document.trailingAnchor.constraint(equalTo: gridScroll.contentView.trailingAnchor),
            document.topAnchor.constraint(equalTo: gridScroll.contentView.topAnchor),
            grid.leadingAnchor.constraint(equalTo: document.leadingAnchor),
            grid.trailingAnchor.constraint(equalTo: document.trailingAnchor),
            grid.topAnchor.constraint(equalTo: document.topAnchor),
            grid.bottomAnchor.constraint(equalTo: document.bottomAnchor),
        ])
    }

    private func detailColumn() -> NSView {
        // The checklist sits ABOVE the rules, because it is what the analyst
        // came here to decide: in `.add` the rules below are the tag's existing
        // ones, and the new rule is being built up here.
        let column = NSStackView(views: [emptyLabel, identityStack, captureBox, gridScroll])
        column.orientation = .vertical
        column.alignment = .leading
        column.spacing = 12
        column.spanArrangedSubviewsFullWidth()
        gridScroll.heightAnchor.constraint(greaterThanOrEqualToConstant: 220).isActive = true
        return column
    }

    /// What the sheet is FOR, in its heading.
    ///
    /// One modal with three jobs, and the heading is the first thing that says
    /// which. `.add` states the ROW COUNT because that number is the analyst's
    /// only check that the sheet caught the selection they made — an off-by-one
    /// selection is silent everywhere else.
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

    private func buildFooterControls() {
        countLabel.font = .preferredFont(forTextStyle: .caption1)
        countLabel.textColor = .secondaryLabelColor
        warningLabel.font = .preferredFont(forTextStyle: .caption1)
        warningLabel.textColor = .systemOrange

        statusLabel.font = .preferredFont(forTextStyle: .caption1)
        statusLabel.textColor = .secondaryLabelColor
        statusLabel.lineBreakMode = .byWordWrapping
        statusLabel.maximumNumberOfLines = 0
        statusLabel.cell?.wraps = true

        saveButton.title = "Save"
        saveButton.bezelStyle = .rounded
        saveButton.setButtonType(.momentaryPushIn)
        saveButton.target = self
        saveButton.action = #selector(saveTapped)
        // Save is the DEFAULT button: the fields have no action of their own, so
        // Return resolves to whatever holds "\r" — and a Return that CLOSED the
        // sheet would silently discard the edit just typed.
        saveButton.keyEquivalent = "\r"

        cancelButton.title = "Cancel"
        cancelButton.bezelStyle = .rounded
        cancelButton.setButtonType(.momentaryPushIn)
        cancelButton.target = self
        cancelButton.action = #selector(cancelTapped)
        cancelButton.keyEquivalent = "\u{1b}"
    }

    private func labelled(_ text: String, _ control: NSView) -> NSStackView {
        let label = NSTextField(labelWithString: text)
        label.alignment = .right
        label.textColor = .secondaryLabelColor
        label.widthAnchor.constraint(equalToConstant: 60).isActive = true
        let row = NSStackView(views: [label, control])
        row.orientation = .horizontal
        row.alignment = .centerY
        row.spacing = 8
        return row
    }

    // MARK: Selection

    /// Show one tag, by its MODEL index, or nothing at all.
    ///
    /// `selectedTagIndex` is set BEFORE the table's selection is moved, so the
    /// selection notification that follows resolves to the same index and stops
    /// there rather than refreshing a second time.
    private func select(modelIndex: Int?) {
        let resolved = modelIndex.flatMap { model.tags.indices.contains($0) ? $0 : nil }
        selectedTagIndex = resolved
        if let resolved, let row = model.visibleTagIndices.firstIndex(of: resolved) {
            tableView.selectRowIndexes(IndexSet(integer: row), byExtendingSelection: false)
        } else {
            selectedTagIndex = nil
            tableView.deselectAll(nil)
        }
        refreshIdentity()
        renderGrid()
        refreshFooter()
        refreshCount()
    }

    /// The tag on show, or nil.
    private var selectedTag: EditableTag? {
        guard let index = selectedTagIndex, model.tags.indices.contains(index) else { return nil }
        return model.tags[index]
    }

    // MARK: Refreshing
    //
    // Split by what CHANGED, not done wholesale, because one of the four is
    // destructive: `renderGrid` rebuilds every condition row, including the one
    // the analyst is typing in.

    private func refreshIdentity() {
        if let tag = selectedTag {
            // SANITISED, not escaped: this field is read back on every
            // keystroke and its text becomes the tag's name, so an escaped
            // value would be stored as its token text. A tag stored before the
            // name rule existed can still hold an override, and this is where
            // it would be read and re-saved — cleaning it on the way IN means
            // the field and the store agree about everything except the
            // characters that were only ever there to deceive.
            //
            // The MODEL is deliberately left alone here. A tag the analyst never
            // touches produces no commit at all, so nothing is rewritten behind
            // their back; the sanitised text reaches the model the moment they
            // type into the field.
            nameField.stringValue = AuthoredLabelSanitizer.sanitized(tag.name)
            colorControl.selectedSegment = TagPalette.normalizedColorIndex(tag.colorIndex) ?? -1
            noteField.stringValue = tag.note
            noteBadge.update(for: tag.note)
        } else {
            nameField.stringValue = ""
            colorControl.selectedSegment = -1
            noteField.stringValue = ""
            noteBadge.update(for: "")
        }
        let hasTag = selectedTag != nil
        nameField.isEnabled = hasTag
        nameField.isEditable = hasTag
        noteField.isEnabled = hasTag
        noteField.isEditable = hasTag
        colorControl.isEnabled = hasTag
        deleteTagButton.isEnabled = hasTag
        identityStack.isHidden = !hasTag
        gridScroll.isHidden = !hasTag
        emptyLabel.isHidden = hasTag
        emptyLabel.stringValue = model.tags.isEmpty || model.visibleTagIndices.isEmpty
            ? "No tags yet. Add one to start."
            : "Select a tag to edit it."
    }

    /// Rebuild every rule and condition row from the model.
    ///
    /// Called ONLY on a structural change — a rule or condition added or
    /// removed, or the selected tag changed. Never from `changedCondition`: see
    /// rule 1 on the class.
    private func renderGrid() {
        refusals = [:]
        let tag = selectedTag
            ?? EditableTag(id: nil, name: "", colorIndex: 0, note: "", rules: [])
        // nil in every mode but `.remove`: nothing else is choosing rules, and
        // the empty set would still draw a column of boxes.
        let selection: Set<String>?
        if case .remove = model.mode { selection = tickedRuleIds } else { selection = nil }
        grid.render(tag, callbacks: gridCallbacks(), selection: selection)
    }

    /// Draw the capture checklist, and say what it is asking.
    ///
    /// Called ONCE, from `buildCaptureList`. The rows never change afterwards:
    /// the capture is fixed at the moment the sheet opens, and each box carries
    /// its own state, so a tick has nothing structural to rebuild. Re-rendering
    /// on a tick would destroy the very box that was just clicked.
    private func renderCaptureList() {
        captureList.render(model.capture, checked: model.checkedCaptureColumns)
        guard let capture = model.capture else {
            captureCaption.stringValue = ""
            return
        }
        let rows = capture.selectedRows.count
        // With several rows the checklist is describing a SET, and the two
        // things that are then easy to get wrong are both said here: a value is
        // only shown when every selected row shares it, and ticking makes one
        // rule per row rather than one rule holding everything.
        captureCaption.stringValue = rows > 1
            ? "Tick the values this tag captures. A value is shown where all "
                + "\(rows) rows share it, otherwise a count. Ticking makes one "
                + "rule per selected row."
            : "Tick the values this tag captures."
    }

    /// A capture box was ticked or unticked.
    ///
    /// The model is MUTATED, never rebuilt: an analyst who renamed a tag a
    /// moment ago would lose the rename to a rebuild. Everything downstream —
    /// the footer, the live count, and what a save writes — reads
    /// `model.draftRules` at call time, so all three follow one tick.
    private func captureColumnToggled(_ index: Int, _ checked: Bool) {
        guard model.setCaptureColumn(index, checked: checked) else { return }
        refreshFooter()
        // The whole point of the checklist: ticking one more column narrows the
        // tag, and the analyst must see that immediately — including when it
        // narrows the tag to nothing.
        refreshCount()
    }

    /// A tick changed. The grid reports the ticked rules of the tag ON SCREEN,
    /// so the other tags' ticks are carried across unread — a `.remove` can span
    /// two tags, and switching between them must not silently untick the first.
    private func changedSelection(_ onScreen: Set<String>) {
        let drawn = Set(grid.groups.compactMap(\.ruleId))
        tickedRuleIds.subtract(drawn)
        tickedRuleIds.formUnion(onScreen)
        refreshFooter()
    }

    /// Redraw ONE sidebar row, for an edit that changed what it says — a
    /// rename, a recolour, or a rule added or removed. A whole `reloadData` per
    /// keystroke would be a table rebuild per character.
    private func refreshSidebarRow(_ modelIndex: Int) {
        guard let row = model.visibleTagIndices.firstIndex(of: modelIndex) else { return }
        tableView.reloadData(forRowIndexes: IndexSet(integer: row),
                             columnIndexes: IndexSet(integersIn: 0..<max(tableView.numberOfColumns, 1)))
    }

    // MARK: The live count
    //
    // Lifted wholesale from `TagSheet.refresh` and `TagSheet.show` — the sheet
    // this one replaces, whose count this is. The threshold, the background hop
    // and the generation guard are its reasoning, not new reasoning: below
    // `asyncCountThreshold` the count runs synchronously, which is the same cost
    // class as the match the grid runs anyway; above it the count moves to a
    // background queue exactly as `ResultsGridVC.matchAsyncThreshold` does for
    // the grid's own match, so a large loaded set cannot drop a frame on every
    // edit; and `countGeneration` discards a slow count that lands after a newer
    // one rather than letting it overwrite a fresher number.
    //
    // One thing IS new. This count is per SELECTED TAG, which `TagSheet`'s never
    // was, so a tag switch starts a count too — and every switch goes through
    // `select` or `tableViewSelectionDidChange`, both of which come here. A
    // stale count from the previous tag would land under the new tag's name,
    // which is a wrong number attached to the wrong tag: worse than a slow one.

    /// Count the selected tag against the loaded rows, and say so.
    private func refreshCount() {
        // Bumped even on the paths that return early, so a count already in
        // flight is invalidated by a switch to a tag that has nothing to count.
        countGeneration += 1
        let generation = countGeneration

        guard let tag = selectedTag else {
            countLabel.stringValue = ""
            warningLabel.stringValue = ""
            return
        }
        let rows = loadedRows
        guard !rows.isEmpty else {
            // NOT "Matches 0 of 0 loaded rows": that reads as a statement about
            // the TAG, made from having nothing to compare it against. The
            // "Manage Tags…" entry has no result behind it at all.
            countLabel.stringValue =
                "No rows are loaded here, so there is nothing to count against."
            warningLabel.stringValue = ""
            return
        }

        let preview = previewTag(for: tag)
        let columns = self.columns
        let count = countMatches

        guard rows.count > Self.asyncCountThreshold else {
            show(matched: count(preview, columns, rows), loaded: rows.count)
            return
        }

        countLabel.stringValue = "Counting…"
        warningLabel.stringValue = ""
        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            let matched = count(preview, columns, rows)
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
        // The warning never blocks Save, and nothing below it may start to: a
        // deliberately broad temporary tag is a legitimate tool, and only the
        // analyst knows which this is.
        warningLabel.stringValue = TagDraft.isBroad(matched: matched, loaded: loaded)
            ? "This tag is broad."
            : ""
    }

    /// The tag the count is run against: the one on screen as it is being
    /// edited, plus — in `.add` — the draft that is about to join it.
    ///
    /// The draft is INCLUDED on purpose. The analyst is about to add those rules
    /// to this tag, so the honest answer to "what will this tag reach" is the
    /// answer after the add; a count of the tag without them would be a number
    /// for a tag that is about to stop existing.
    private func previewTag(for tag: EditableTag) -> Tag {
        var rules: [NewTagRule] = tag.rules.compactMap { rule in
            guard let key = RuleKey.encode(rule.conditions.map {
                RuleConditionKey(kind: $0.kind, family: $0.family,
                                 value: $0.value, operand2: $0.operand2)
            }) else { return nil }
            // Origins are provenance and take no part in matching, so the
            // preview leaves them empty rather than inventing them.
            return NewTagRule(conditions: rule.conditions, tupleKey: key,
                              originConnection: "", originTable: "")
        }
        rules.append(contentsOf: model.draftRules)
        return TagDraft.previewTag(tuples: rules)
    }

    private func refreshFooter() {
        let commits = model.commits()
        if let reason = blockingReason(commits) {
            statusLabel.stringValue = reason
            statusLabel.textColor = .secondaryLabelColor
            saveButton.isEnabled = false
            return
        }
        saveButton.isEnabled = true
        // Nothing here CONFIRMS any of this: none of it has happened yet, and
        // Cancel still discards the lot. What it must not do is happen silently,
        // so everything a save would do that the analyst cannot see on screen is
        // stated before they press the button.
        var notices: [String] = []
        let doomed = commits.filter { if case .deleteTag = $0 { return true } else { return false } }
        if !doomed.isEmpty {
            notices.append(doomed.count == 1
                ? "Saving deletes 1 tag and every rule in it."
                : "Saving deletes \(doomed.count) tags and every rule in them.")
        }
        let ticked = pendingDeletions.count
        if ticked > 0 {
            notices.append(ticked == 1
                ? "Saving removes 1 rule from its tag."
                : "Saving removes \(ticked) rules from their tags.")
        }
        // Said in `.add` even though nothing is wrong, because the tag the draft
        // joins is chosen by a SIDEBAR SELECTION — which looks like navigation,
        // not like a decision. This is the line that makes it one.
        if !model.draftRules.isEmpty, let index = selectedTagIndex {
            let rules = model.draftRules.count
            // "one per selected row" only when that is literally true. Two rows
            // whose captured values normalise the same collapse into ONE rule —
            // `TagDraft` does that so the live count is honest — so the count
            // and the row count can legitimately differ, and the clause must not
            // claim otherwise.
            let perRow = rules > 1 && rules == model.capture?.selectedRows.count
            notices.append("Saving adds \(rules) rule\(rules == 1 ? "" : "s") to "
                + "\(tagName(index))\(perRow ? ", one per selected row" : "").")
        }
        statusLabel.stringValue = notices.joined(separator: " ")
        statusLabel.textColor = notices.isEmpty ? .secondaryLabelColor : .systemOrange
    }

    /// The rules a save would remove because they are TICKED.
    ///
    /// Read from the sheet's own set, which the boxes drive — never from
    /// `Mode.remove`'s ids, which are only ever the STARTING position. Narrowed
    /// to rules that still exist and are not already going with their tag, so
    /// nothing is named twice.
    private var pendingDeletions: [String] {
        guard case .remove = model.mode, !tickedRuleIds.isEmpty else { return [] }
        let live = Set(model.tags.indices
            .filter { !model.isDeleted(tagAt: $0) }
            .flatMap { model.tags[$0].rules.compactMap(\.id) })
        // Sorted, so what is written is the same list twice running.
        return tickedRuleIds.intersection(live).sorted()
    }

    /// Work this sheet carries that the MODEL cannot see: the draft of `.add`,
    /// and the ticks of `.remove`.
    ///
    /// Without it `saveBlocker` answers `.noChanges` for a sheet whose entire
    /// purpose is a change — a `.remove` where nothing but boxes was touched
    /// would offer a dead Save button and say "Nothing has changed yet."
    private var hasModeWork: Bool {
        if !model.draftRules.isEmpty { return selectedTagIndex != nil }
        return !pendingDeletions.isEmpty
    }

    // MARK: What stops a save

    /// Why Save is unavailable, in words, or nil when it is available.
    ///
    /// The first three questions are the sheet's own — the model cannot see a
    /// refusal that lives in a field, and it deliberately says nothing about
    /// names. Each is asked of what would actually be WRITTEN rather than of the
    /// tags on screen, so a blank a foreign writer left in the store cannot make
    /// its tag permanently unsaveable. That is the same rule
    /// `TagManagerModel.saveBlocker` applies to an already-empty rule, and for
    /// the same reason.
    private func blockingReason(_ commits: [TagManagerCommit]) -> String? {
        if let refusal = refusals.values.compactMap({ $0 }).first {
            return refusalText(refusal)
        }
        if commits.contains(where: Self.writesANamelessTag) {
            return "A tag has no name yet. Every tag needs one."
        }
        if commits.contains(where: Self.writesABlankCondition) {
            return blankConditionText()
        }
        guard let blocker = model.saveBlocker() else { return nil }
        // The model cannot see the draft or the ticks, so its "nothing has
        // changed" is only ever true of the tags. Every other blocker still
        // holds: an empty rule or a duplicate one would still be written.
        if case .noChanges = blocker, hasModeWork { return nil }
        return blockerText(blocker)
    }

    private static func writesANamelessTag(_ commit: TagManagerCommit) -> Bool {
        switch commit {
        case .create(let create): return isBlank(create.name)
        // `commits()` always carries a name on an update; a nil one here would
        // mean "leave the name alone", which cannot be blank.
        case .update(let update): return update.name.map(isBlank) ?? false
        default: return false
        }
    }

    private static func writesABlankCondition(_ commit: TagManagerCommit) -> Bool {
        switch commit {
        case .create(let create): return create.rules.contains { hasBlankCondition($0.conditions) }
        case .addRules(let add): return add.rules.contains { hasBlankCondition($0.conditions) }
        case .updateRule(let update): return hasBlankCondition(update.conditions)
        default: return false
        }
    }

    /// A condition nobody has typed a value into.
    ///
    /// It must never be written. An `exact` condition of "" would be looked up
    /// in the value index like any other, so it would match every empty cell in
    /// every result — a tag that looks like it is watching one thing while
    /// matching hundreds.
    private static func hasBlankCondition(_ conditions: [TagCondition]) -> Bool {
        conditions.contains { isBlank($0.display) || isBlank($0.value) }
    }

    private static func isBlank(_ text: String) -> Bool {
        text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    /// Name the first blank condition on screen, so the message is something
    /// the analyst can act on rather than a fact about the sheet.
    private func blankConditionText() -> String {
        for (tagIndex, tag) in model.tags.enumerated() where !model.isDeleted(tagAt: tagIndex) {
            for (ruleIndex, rule) in tag.rules.enumerated()
            where Self.hasBlankCondition(rule.conditions) {
                return "Rule \(ruleIndex + 1) of \(quoted(tag.name)) has a condition "
                    + "with no value yet."
            }
        }
        return "A condition has no value yet."
    }

    private func blockerText(_ blocker: TagManagerModel.SaveBlocker) -> String {
        switch blocker {
        case .noChanges:
            return "Nothing has changed yet."
        case .emptyRule(let tagIndex, let ruleIndex):
            return "Rule \(ruleIndex + 1) of \(tagName(tagIndex)) has no conditions. "
                + "A rule with none would match nothing."
        case .duplicateRule(let tagIndex, let ruleIndex):
            return "Rule \(ruleIndex + 1) of \(tagName(tagIndex)) says the same thing as "
                + "another rule of that tag. Delete one of them."
        }
    }

    private func refusalText(_ invalid: TagConditionEditor.Invalid) -> String {
        switch invalid {
        case .emptyValue: return "A condition has no value yet."
        case .emptySecondOperand: return "A range condition has no upper bound yet."
        case .unparseable(let why), .wrongOperator(let why): return why
        }
    }

    /// One tag's name, ready to put in a sentence this app is speaking. Escaped,
    /// because a stored name can predate the name rule.
    private func tagName(_ index: Int) -> String {
        guard model.tags.indices.contains(index) else { return "that tag" }
        return quoted(model.tags[index].name)
    }

    private func quoted(_ name: String) -> String {
        let escaped = DisplayEscape.escaped(name)
        return escaped.isEmpty ? "the unnamed tag" : "\u{201C}\(escaped)\u{201D}"
    }

    // MARK: Identity edits

    /// Per keystroke, for BOTH fields — and the two are treated differently on
    /// purpose. See rule 2 on the class.
    func controlTextDidChange(_ obj: Notification) {
        guard let index = selectedTagIndex else { return }
        let field = obj.object as? NSTextField
        if field === nameField {
            nameField.sanitizeAsAuthoredLabel()
            model.rename(tagAt: index, to: nameField.stringValue)
            refreshSidebarRow(index)
        } else if field === noteField {
            // Never sanitised, never escaped. This field is read back and
            // stored, so escaping would save the escape tokens; and a note
            // legitimately quotes the hostile text the analyst is hunting, so
            // sanitising would destroy the record. The badge discloses instead.
            model.note(tagAt: index, to: noteField.stringValue)
            noteBadge.update(for: noteField.stringValue)
        } else {
            return
        }
        refreshFooter()
    }

    @objc private func colorChanged(_ sender: Any?) {
        guard let index = selectedTagIndex, colorControl.selectedSegment >= 0 else { return }
        model.recolour(tagAt: index, to: colorControl.selectedSegment)
        refreshSidebarRow(index)
        refreshFooter()
    }

    // MARK: Tag actions

    @objc private func addTagTapped(_ sender: Any?) {
        // A name, not an empty field: an unnamed tag blocks Save, and a new tag
        // that arrives already blocking reads as a fault rather than as an
        // invitation to type.
        model.addTag(name: "New Tag",
                     colorIndex: TagPalette.normalizedColorIndex(model.tags.count) ?? 0)
        tableView.reloadData()
        select(modelIndex: model.tags.count - 1)
        view.window?.makeFirstResponder(nameField)
    }

    /// Delete the selected tag, with no confirmation alert.
    ///
    /// Deliberate: nothing is deleted yet. The tag is MARKED, the footer says
    /// what a save would destroy, and Cancel discards the whole thing — so an
    /// alert here would be asking the analyst to confirm something that has not
    /// happened. The confirmation that matters is Save, which is explicit and
    /// which states the count first.
    @objc private func deleteTagTapped(_ sender: Any?) {
        guard let index = selectedTagIndex else { return }
        let removedRow = tableView.selectedRow
        model.deleteTag(at: index)
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

    // MARK: Rule and condition actions
    //
    // Every one of these closures reaches back through `self` and reads
    // `self.model` at CALL time. None captures the model, or a tag out of it, by
    // value — a closure that did would edit a copy Save never sees.

    private func gridCallbacks() -> TagRuleGridView.Callbacks {
        TagRuleGridView.Callbacks(
            addRule: { [weak self] in self?.addRule() },
            removeRule: { [weak self] in self?.removeRule($0) },
            addCondition: { [weak self] in self?.addCondition(toRule: $0) },
            removeCondition: { [weak self] in self?.removeCondition($1, fromRule: $0) },
            changedCondition: { [weak self] in self?.changedCondition($0, $1, $2) },
            invalidCondition: { [weak self] in self?.invalidCondition($0, $1, $2) },
            changedSelection: { [weak self] in self?.changedSelection($0) })
    }

    /// A condition with nothing in it yet.
    ///
    /// No value is invented: a fabricated one would be a rule the analyst never
    /// wrote, and it would match rows. The blank blocks Save until it is filled
    /// in, and the footer says so.
    private static func blankCondition() -> TagCondition {
        TagCondition(family: TagValueNormalizer.textFamily, kind: .exact,
                     value: "", display: "")
    }

    private func addRule() {
        guard let index = selectedTagIndex else { return }
        model.addRule(toTagAt: index, conditions: [Self.blankCondition()])
        structuralChange(tagAt: index)
    }

    private func removeRule(_ ruleIndex: Int) {
        guard let index = selectedTagIndex else { return }
        model.removeRule(at: ruleIndex, fromTagAt: index)
        structuralChange(tagAt: index)
    }

    private func addCondition(toRule ruleIndex: Int) {
        guard let index = selectedTagIndex else { return }
        model.addCondition(Self.blankCondition(), toRuleAt: ruleIndex, inTagAt: index)
        structuralChange(tagAt: index)
    }

    private func removeCondition(_ conditionIndex: Int, fromRule ruleIndex: Int) {
        guard let index = selectedTagIndex else { return }
        model.removeCondition(at: conditionIndex, fromRuleAt: ruleIndex, inTagAt: index)
        structuralChange(tagAt: index)
    }

    /// A rule or condition was added or removed: the rows on screen no longer
    /// match the model, and every index after the change has moved. This is the
    /// ONLY thing that re-renders the grid.
    private func structuralChange(tagAt index: Int) {
        renderGrid()
        refreshSidebarRow(index)
        refreshFooter()
        refreshCount()
    }

    /// A value was typed. NOT structural: the row already shows what was typed,
    /// owns its own error line, and shows or hides its own upper-bound field —
    /// and re-rendering would destroy the very field being typed in.
    private func changedCondition(_ ruleIndex: Int, _ conditionIndex: Int,
                                  _ condition: TagCondition) {
        guard let index = selectedTagIndex else { return }
        model.replaceCondition(at: conditionIndex, inRuleAt: ruleIndex,
                               ofTagAt: index, with: condition)
        refusals[ConditionRef(rule: ruleIndex, condition: conditionIndex)] = nil
        refreshFooter()
        // A value edit changes nothing structural, but it is exactly the thing
        // that changes what the tag REACHES.
        refreshCount()
    }

    /// The editor refused what was typed. The ROW draws the message beside the
    /// field itself; this only has to stop the save.
    private func invalidCondition(_ ruleIndex: Int, _ conditionIndex: Int,
                                  _ invalid: TagConditionEditor.Invalid?) {
        refusals[ConditionRef(rule: ruleIndex, condition: conditionIndex)] = invalid
        refreshFooter()
    }

    // MARK: Saving

    /// Everything a save would write: what the model derived, plus the work only
    /// this sheet knows about.
    ///
    /// In `.remove`, the analyst's OTHER edits are committed too — a rename they
    /// made on the way past goes with the deletion. The alternative is to
    /// discard it silently, which is worse: they typed it, they can see it, and
    /// nothing on screen says it will be thrown away. The footer states the
    /// removal explicitly, so neither half of the save is a surprise.
    private func commitsToWrite() -> [TagManagerCommit] {
        let commits = model.commits()
        // The ticked deletions go FIRST, for the reason `commits()` puts its own
        // deletes first: a rule about to be deleted may hold the very key an
        // edited rule is moving onto, and the unique index would refuse the
        // update otherwise.
        let doomed = pendingDeletions
        let withDeletions = doomed.isEmpty ? commits : [.deleteRules(doomed)] + commits
        guard !model.draftRules.isEmpty, let index = selectedTagIndex else {
            return withDeletions
        }
        return withDraft(model.draftRules, into: withDeletions, joiningTagAt: index)
    }

    /// The draft rules folded into the command that writes the tag they join.
    ///
    /// Two shapes, because a tag that does not exist yet has no id to name. An
    /// existing tag takes one more `.addRules`; a tag made this session must
    /// take the draft INSIDE its own `.create`.
    ///
    /// Which `.create`: `commits()` emits them in tag order, so the target's
    /// place among them is the number of new, undeleted tags before it.
    ///
    /// The draft rules pass through UNCHANGED, `originConnection` and
    /// `originTable` included. That is the whole reason the draft travels on the
    /// mode rather than through `EditableRule`: `TagManagerModel` writes empty
    /// origins for an authored rule, correctly, because an authored rule came
    /// from nobody's result — and a captured finding that lost its origin on the
    /// way in would have lost where it was seen, permanently.
    private func withDraft(_ draft: [NewTagRule], into commits: [TagManagerCommit],
                           joiningTagAt index: Int) -> [TagManagerCommit] {
        guard model.tags.indices.contains(index), !model.isDeleted(tagAt: index)
        else { return commits }
        if let id = model.tags[index].id {
            return commits + [.addRules(AddTagRules(tagId: id, rules: draft))]
        }
        let ordinal = model.tags.indices.filter {
            $0 < index && model.tags[$0].id == nil && !model.isDeleted(tagAt: $0)
        }.count
        var seen = -1
        return commits.map { commit in
            guard case .create(var create) = commit else { return commit }
            seen += 1
            guard seen == ordinal else { return commit }
            create.rules += draft
            return .create(create)
        }
    }

    @objc private func saveTapped(_ sender: Any?) {
        // The disabled button is the guard the analyst meets; this is the guard
        // behind it, for the Return key and for anything that enables the button
        // without going through the footer.
        //
        // Asked of `model.commits()`, not of everything below: those checks
        // refuse what the analyst AUTHORED here — a nameless tag, a condition
        // with no value typed into it. A draft rule captured from a real row is
        // neither, and a cell that happened to be empty must not make a finding
        // permanently unsaveable through a field that is not on screen.
        guard blockingReason(model.commits()) == nil else { return }
        let commits = commitsToWrite()
        do {
            try committer.apply(commits)
        } catch {
            NSLog("Tag manager save failed: \(error)")
            // The sheet STAYS UP, with every edit where it was: a save that
            // failed halfway is the one moment the analyst most needs their
            // work still in front of them.
            statusLabel.stringValue = "Could not save: "
                + DisplayEscape.escapedMultiline("\(error)")
            statusLabel.textColor = .systemRed
            presentFailure(error)
            return
        }
        closeSheet()
    }

    @objc private func cancelTapped(_ sender: Any?) { closeSheet() }

    // No `cancelOperation` override: `cancelButton` holds "\u{1b}", and a
    // button's key equivalent is resolved before the responder chain sees the
    // key, so the override could never run.

    private func closeSheet() {
        dismiss(nil)
        onClose?()
    }

    private func presentFailure(_ error: Error) {
        // Before building anything: with no window there is nothing to hang the
        // alert from, and the label above is the whole report.
        guard let window = view.window else { return }
        let alert = NSAlert()
        alert.messageText = "Could not save the tags"
        alert.informativeText = DisplayEscape.escapedMultiline("\(error)")
        alert.addButton(withTitle: "OK")
        alert.beginSheetModal(for: window)
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
        // ESCAPED, unlike the editable name field above: this row is drawn in
        // the app's own voice and is what the analyst reads before pressing
        // Delete, and nothing reads it back.
        //
        // The count is the EDITED one, rules added this session included. Every
        // other surface in this sheet shows the edit in progress, and a sidebar
        // saying "2 rules" beside a grid drawing three would have the two
        // disagree about the same tag while the analyst looks at both.
        let count = tag.rules.count
        cell.textField?.stringValue =
            "\(DisplayEscape.escaped(tag.name)) — \(count) rule\(count == 1 ? "" : "s")"
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
        guard resolved != selectedTagIndex else { return }
        selectedTagIndex = resolved
        refreshIdentity()
        renderGrid()
        refreshFooter()
        // A tag SWITCH starts a count like any other change, and bumps the
        // generation like any other — a count of the previous tag landing under
        // this one's name would be a wrong number, not a slow one.
        refreshCount()
    }
}

// MARK: - FlippedView

/// A document view that starts at the TOP. An unflipped `NSScrollView`
/// document pins its content to the bottom, so a short list of rules would sit
/// at the foot of the pane and grow upwards.
private final class FlippedView: NSView {
    override var isFlipped: Bool { true }
}
