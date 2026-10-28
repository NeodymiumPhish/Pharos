import AppKit
import os

// MARK: - TagDetailVC

/// One tag on show: its identity fields, its rules, the capture checklist (in
/// `.add`), Add Values… and Test a value (in `.manage`), and the action bar
/// that saves the lot. The Tag Manager window puts it beside its Glass
/// sidebar; the grid's Add Tag… and Remove From Tag… sheets
/// (`TagManagerSheet`) put it beside their tag list. Both hand it the tag to
/// show with `select(modelIndex:)` and are told what changed through the
/// callbacks below.
///
/// It holds no truth of its own. `TagManagerModel` decides what an edit means
/// and what a save would write; `TagRuleGridView` draws the rules; this class
/// is the wiring between them, plus the identity fields. Three rules govern
/// that wiring, and each is the kind an ordinary-looking edit would quietly
/// reverse:
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
/// The model is a STRUCT held here and mutated in place — this is its only
/// owner, so the list beside it reads `model` rather than keeping a copy.
/// Every callback this class hands out reaches back through `self` and reads
/// `self.model` at CALL time — none of them captures the model, or a tag out
/// of it, by value. A closure that captured `self.model` at render time would
/// go on editing a copy that Save never sees.
final class TagDetailVC: NSViewController, NSTextFieldDelegate {

    /// The button beside Save. The window's edits outlive one tag, so it
    /// reverts them; a sheet's are one task, so it cancels the task.
    enum SecondaryAction {
        case cancel
        case revert
    }

    // MARK: State

    /// Read-only to everyone else: every change goes through a mutating method
    /// on the model, from one of the actions below.
    private(set) var model: TagManagerModel
    private let committer: TagManagerCommitting
    let secondaryAction: SecondaryAction

    /// The result behind the manager, for the live match count. Both may be
    /// empty — the Tag Manager window can open with no result behind it at
    /// all — so nothing here may require them.
    private let columns: [ColumnDef]
    private let loadedRows: [[String?]]

    /// How the footer's count is worked out.
    ///
    /// Injectable so the stale-count guard can be tested. A test supplies a
    /// function that blocks on a semaphore it controls; production uses the real
    /// matcher. Racing the real one by timing would be a flaky test pretending
    /// to be a guarantee.
    var countMatches: (Tag, [ColumnDef], [[String?]]) -> (solid: Int, partial: Int)
        = TagRuleMatcher.matchCounts

    /// Bumped by every count started, so a slow background count that lands
    /// after a newer one is discarded instead of overwriting a fresher number.
    ///
    /// It guards a tag SWITCH as well as an edit: every count starts here, and
    /// the previous tag's number landing under the new tag's name would be a
    /// wrong number attached to the wrong tag, which is worse than a slow one.
    private var countGeneration = 0

    /// Mirrors `ResultsGridVC.matchAsyncThreshold`. Deliberately its own
    /// constant rather than a reference: this is a modal's responsiveness
    /// policy, not the grid's. Keep them in step by hand.
    private static let asyncCountThreshold = 5_000

    /// The rules TICKED for removal, across every tag — not only the one on
    /// screen.
    ///
    /// Held here rather than in the grid because the grid draws ONE tag: a
    /// `.remove` that spans two tags would lose the first tag's ticks the moment
    /// the analyst looked at the second. Seeded from the mode, and from then on
    /// the analyst's.
    private var tickedRuleIds: Set<String> = []

    /// The tag on show, by its index in `model.tags` — NOT its row in any
    /// list. The two differ the moment a tag is deleted, because the model
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

    // MARK: Callbacks

    /// A save was written. The sheet closes; the window reloads from the store.
    var onSaved: (() -> Void)?
    /// Cancel was pressed (`.cancel` only). Nothing was written.
    var onCancel: (() -> Void)?
    /// Revert was pressed (`.revert` only): the owner rebuilds from the store.
    var onRevert: (() -> Void)?
    /// What the tag at this model index looks like, or whether it has
    /// unsaved edits, may have changed: a rename, a recolour, a rule or
    /// condition added, removed or edited. The list beside this redraws that
    /// row. Called per keystroke, so it must stay cheap.
    var onTagChanged: ((Int) -> Void)?
    /// The empty state's New Tag button.
    var onAddTag: (() -> Void)?

    /// The views that come BEFORE this detail in the Tab order — the list
    /// beside it, and the sheet's own buttons. The loop runs through them,
    /// then this detail's controls, and back.
    var leadingKeyViews: [NSView] = [] {
        didSet { if isViewLoaded { rebuildKeyViewLoop() } }
    }

    // MARK: Controls
    //
    // Internal, like `TagRuleGridView.groups` and for the same reason: the
    // suites drive the REAL controls through their own target/action and
    // delegate wiring, and a view walk cannot tell the name field from the
    // note field.

    let nameField = NSTextField()
    let colorPicker = TagColorSwatchPicker()
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
    /// The checklist's fixed-height viewport.
    let captureScroll = NSScrollView()
    /// Add Values… under the Rules box (`.manage` only). The grid's own
    /// button of that name stays hidden: this one is the form's footer button.
    let addValuesButton = NSButton()
    /// "Test a value" (`.manage` only): a typed sample checked against the
    /// selected tag's rules (`TagSampleTest`), so a tag can be tried before any
    /// results exist.
    let sampleField = NSSearchField()
    /// The sample's result, shown as the Test row's caption.
    var sampleResultLabel: NSTextField { sampleRow.captionLabel }
    let saveButton = NSButton()
    let cancelButton = NSButton()
    let revertButton = NSButton()
    /// Why Save is unavailable, or what a save will do that cannot be undone.
    let statusLabel = NSTextField(labelWithString: "")
    /// How many loaded rows the selected tag matches, run through the real
    /// matcher.
    let countLabel = NSTextField(labelWithString: "")
    /// "This tag is broad." Never blocks — see `refreshCount`.
    let warningLabel = NSTextField(labelWithString: "")
    /// "No Tags" (with New Tag) or "No Tag Selected", in place of the form.
    let emptyState = EmptyStateView()

    /// The form, hidden whole when no tag is selected.
    private(set) var formScroll: NSScrollView!
    private var sampleRow: SettingsRow!
    private var nameRow: SettingsRow!
    private var colorRow: SettingsRow!
    private var noteRow: SettingsRow!

    // MARK: Construction

    init(model: TagManagerModel, committer: TagManagerCommitting,
         columns: [ColumnDef], loadedRows: [[String?]],
         secondaryAction: SecondaryAction) {
        self.model = model
        self.committer = committer
        self.columns = columns
        self.loadedRows = loadedRows
        self.secondaryAction = secondaryAction
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
        // The furniture's grey ground: the group boxes' plates are drawn in a
        // colour that equals the window background in Light mode, so they
        // need this surface to be seen at all (`SettingsMetrics.paneSurfaceColor`).
        let root = SettingsPaneSurfaceView(frame: NSRect(x: 0, y: 0, width: 640, height: 560))

        buildIdentityControls()
        buildCaptureList()
        buildSample()
        buildActionControls()

        var sections: [NSView] = [section(String(localized: "Tag", comment: "Tag Manager: the identity section's header."),
                                          rows: [nameRow, colorRow, noteRow])]

        // The checklist sits ABOVE the rules, because it is what the analyst
        // came here to decide: in `.add` the rules below are the tag's existing
        // ones, and the new rule is being built up here. Built only in `.add`:
        // a hidden row would still draw its separator in the box.
        var ruleRows: [NSView] = []
        if model.capture != nil { ruleRows.append(captureRow()) }
        ruleRows.append(padded(grid, vertical: 10))
        let footer: NSView? = model.mode == .manage ? SettingsFooterButtonRow(buttons: [addValuesButton]) : nil
        sections.append(section(String(localized: "Rules", comment: "Tag Manager: the rules section's header."),
                                rows: ruleRows, footer: footer))
        if model.mode == .manage {
            sections.append(section(nil, rows: [sampleRow]))
        }

        let scroll = SettingsFormScroll.makePane(sections: sections)
        formScroll = scroll
        root.addSubview(scroll)

        emptyState.translatesAutoresizingMaskIntoConstraints = false
        emptyState.isHidden = true
        root.addSubview(emptyState)

        let separator = NSBox()
        separator.boxType = .separator
        separator.translatesAutoresizingMaskIntoConstraints = false
        root.addSubview(separator)

        let actionBar = buildActionBar()
        root.addSubview(actionBar)

        NSLayoutConstraint.activate([
            // The window's top, not the safe area: the form's scroll view
            // insets itself under the toolbar (`SettingsFormScroll`), and
            // pinning to the safe area as well would inset it twice.
            scroll.topAnchor.constraint(equalTo: root.topAnchor),
            scroll.leadingAnchor.constraint(equalTo: root.leadingAnchor),
            scroll.trailingAnchor.constraint(equalTo: root.trailingAnchor),
            scroll.bottomAnchor.constraint(equalTo: separator.topAnchor),

            // Not a scroll view, so it keeps clear of the toolbar itself
            // (lessons, 2026-09-16).
            emptyState.topAnchor.constraint(equalTo: root.safeAreaLayoutGuide.topAnchor),
            emptyState.leadingAnchor.constraint(equalTo: root.leadingAnchor),
            emptyState.trailingAnchor.constraint(equalTo: root.trailingAnchor),
            emptyState.bottomAnchor.constraint(equalTo: separator.topAnchor),

            separator.leadingAnchor.constraint(equalTo: root.leadingAnchor),
            separator.trailingAnchor.constraint(equalTo: root.trailingAnchor),
            separator.bottomAnchor.constraint(equalTo: actionBar.topAnchor, constant: -Self.actionBarInsetTop),

            actionBar.leadingAnchor.constraint(equalTo: root.leadingAnchor, constant: SettingsMetrics.paneInsetH),
            actionBar.trailingAnchor.constraint(equalTo: root.trailingAnchor, constant: -SettingsMetrics.paneInsetH),
            actionBar.bottomAnchor.constraint(equalTo: root.bottomAnchor, constant: -Self.actionBarInsetBottom),
        ])
        view = root
    }

    private var buttonRow: NSStackView?
    private static let buttonRowSpacing: CGFloat = 8

    /// The two wrapping labels are told their width after each pass. A
    /// wrapping label with no preferred width reports ONE long line — so it
    /// either holds the pane open at that width or, yielding, is cut to one
    /// line. Given its width, it reports the height of the lines it needs; a
    /// change invalidates it and schedules the next pass (the `SettingsRow`
    /// pattern).
    override func viewDidLayout() {
        super.viewDidLayout()
        Self.wrap(captureCaption, at: captureCaption.frame.width)
        // The status line wraps in what the two buttons leave it, not at its
        // own frame — that frame is whatever its last text needed.
        if let buttonRow {
            let secondary: NSButton = secondaryAction == .cancel ? cancelButton : revertButton
            let available = buttonRow.frame.width - secondary.frame.width - saveButton.frame.width
                - Self.buttonRowSpacing * 3
            Self.wrap(statusLabel, at: available)
        }
    }

    private static func wrap(_ label: NSTextField, at width: CGFloat) {
        guard width > 0, abs(label.preferredMaxLayoutWidth - width) > 0.5 else { return }
        label.preferredMaxLayoutWidth = width
    }

    /// The action bar's insets: the Connection Manager's, so the managers'
    /// Save buttons sit in the same place.
    private static let actionBarInsetTop: CGFloat = 14
    private static let actionBarInsetBottom: CGFloat = 16

    override func viewWillAppear() {
        super.viewWillAppear()
        // NOT true: that recalculates the window's key view loop from the
        // view hierarchy — repeatedly, not just once, as testing against a
        // live build showed — which silently discards an explicit chain the
        // first time anything triggers it.
        view.window?.autorecalculatesKeyViewLoop = false
        rebuildKeyViewLoop()
    }

    /// The whole Tab order, by hand: the views before this detail, the
    /// identity form, every rule's controls in screen order (family, operator,
    /// value, upper bound, remove, …, Add Condition), Add Rule, Add Values…,
    /// Test a value, then the action bar. Rebuilt after every render of the
    /// rules, which replaces their views — automatic recalculation stays off
    /// (see above), so without this Tab in a rule field went nowhere and
    /// selected the field's own text. Controls that cannot take focus (a
    /// hidden upper bound; a pop-up without Full Keyboard Access) are skipped
    /// by AppKit's `nextValidKeyView`.
    func rebuildKeyViewLoop() {
        let secondary: NSButton = secondaryAction == .cancel ? cancelButton : revertButton
        let chain: [NSView] = leadingKeyViews + [nameField, colorPicker, noteField]
            + grid.keyViews + [addValuesButton, sampleField, secondary, saveButton]
        for (view, next) in zip(chain, chain.dropFirst() + [chain[0]]) { view.nextKeyView = next }
    }

    /// A header (optional), a group box of `rows`, and an optional footer row,
    /// spaced as the Settings window spaces them.
    private func section(_ title: String?, rows: [NSView], footer: NSView? = nil) -> NSView {
        var parts: [NSView] = []
        if let title { parts.append(SettingsSectionHeader.make(title)) }
        parts.append(SettingsGroupBox(title: title, rows: rows))
        if let footer { parts.append(footer) }
        let stack = NSStackView(views: parts)
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = SettingsMetrics.headerToBoxGap
        stack.translatesAutoresizingMaskIntoConstraints = false
        stack.spanArrangedSubviewsFullWidth()
        return stack
    }

    /// `content` inset as a row's content is, for a box row that is not a
    /// `SettingsRow`.
    private func padded(_ content: NSView, vertical: CGFloat) -> NSView {
        let row = NSView()
        row.translatesAutoresizingMaskIntoConstraints = false
        content.translatesAutoresizingMaskIntoConstraints = false
        row.addSubview(content)
        NSLayoutConstraint.activate([
            content.leadingAnchor.constraint(equalTo: row.leadingAnchor, constant: SettingsMetrics.rowInsetH),
            content.trailingAnchor.constraint(equalTo: row.trailingAnchor, constant: -SettingsMetrics.rowInsetH),
            content.topAnchor.constraint(equalTo: row.topAnchor, constant: vertical),
            content.bottomAnchor.constraint(equalTo: row.bottomAnchor, constant: -vertical),
        ])
        return row
    }

    private static let fieldWidth: CGFloat = 260

    private func buildIdentityControls() {
        nameField.placeholderString = "Case name"
        // Delegate, not target/action: `controlTextDidChange` fires per
        // keystroke, so the name is sanitised as it is typed and the model
        // never holds a name the field is not showing.
        nameField.delegate = self
        nameField.setAccessibilityLabel("Tag name")
        nameField.setAccessibilityIdentifier("tags.detail.name")
        nameField.translatesAutoresizingMaskIntoConstraints = false
        nameField.widthAnchor.constraint(equalToConstant: Self.fieldWidth).isActive = true

        colorPicker.target = self
        colorPicker.action = #selector(colorChanged)
        colorPicker.setAccessibilityLabel("Tag colour")
        colorPicker.setAccessibilityIdentifier("tags.detail.colour")

        noteField.placeholderString = "Note (optional)"
        noteField.delegate = self
        // A note is prose and may be several lines. `stringValue` round-trips
        // whatever is stored either way; this is only about showing it.
        noteField.usesSingleLineMode = false
        noteField.cell?.wraps = true
        noteField.maximumNumberOfLines = 3
        noteField.preferredMaxLayoutWidth = Self.fieldWidth
        noteField.setAccessibilityLabel("Tag note")
        noteField.setAccessibilityIdentifier("tags.detail.note")
        // The note is prose, the one free-text field here that is not SQL or
        // an identifier, so Writing Tools apply here — and the affordance
        // shows so the user can find them. Every SQL view keeps
        // `writingToolsBehavior = .none`.
        noteField.allowsWritingTools = true
        noteField.allowsWritingToolsAffordance = true
        noteField.translatesAutoresizingMaskIntoConstraints = false
        noteField.widthAnchor.constraint(equalToConstant: Self.fieldWidth).isActive = true

        let noteControl = NSStackView(views: [noteBadge, noteField])
        noteBadge.link(to: noteField)
        noteControl.orientation = .horizontal
        noteControl.alignment = .centerY
        noteControl.spacing = 6
        noteControl.translatesAutoresizingMaskIntoConstraints = false

        nameRow = SettingsRow(title: String(localized: "Name", comment: "Tag Manager: the tag's name."),
                              control: nameField)
        colorRow = SettingsRow(title: String(localized: "Colour", comment: "Tag Manager: the tag's colour."),
                               control: colorPicker)
        noteRow = SettingsRow(title: String(localized: "Note", comment: "Tag Manager: the tag's note."),
                              control: noteControl)
    }

    /// The capture checklist and its caption.
    ///
    /// The checklist SCROLLS inside a fixed height, and that is the whole point
    /// of the scroll view: a 60-column result would otherwise draw sixty rows
    /// and push the rules grid out of sight. A fixed height means the two
    /// cannot compete for space at all, whatever the result's shape.
    private func buildCaptureList() {
        captureCaption.font = .preferredFont(forTextStyle: .caption1)
        captureCaption.textColor = .secondaryLabelColor
        captureCaption.lineBreakMode = .byWordWrapping
        captureCaption.maximumNumberOfLines = 0
        captureCaption.cell?.wraps = true
        captureCaption.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)

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

        captureList.onToggle = { [weak self] index, checked in
            self?.captureColumnToggled(index, checked)
        }
        renderCaptureList()
    }

    /// How tall the checklist is, whatever the result's width in columns.
    private static let captureListHeight: CGFloat = 118

    /// The caption over the checklist, as one box row.
    private func captureRow() -> NSView {
        let stack = NSStackView(views: [captureCaption, captureScroll])
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = 6
        stack.spanArrangedSubviewsFullWidth()
        return padded(stack, vertical: 10)
    }

    private func buildSample() {
        sampleField.placeholderString = String(localized: "Test a value — an address, a number, text…")
        sampleField.sendsSearchStringImmediately = true
        sampleField.target = self
        sampleField.action = #selector(sampleChanged(_:))
        sampleField.setAccessibilityLabel(String(localized: "Test a value"))
        sampleField.setAccessibilityIdentifier("tags.sample.field")
        sampleField.translatesAutoresizingMaskIntoConstraints = false
        sampleField.widthAnchor.constraint(equalToConstant: Self.fieldWidth).isActive = true
        sampleRow = SettingsRow(title: String(localized: "Test a value"), control: sampleField)

        addValuesButton.title = String(localized: "Add Values…")
        addValuesButton.target = self
        addValuesButton.action = #selector(addValuesTapped)
        addValuesButton.setAccessibilityLabel(String(localized: "Add rules from a list of values"))
        addValuesButton.toolTip = String(localized: "Paste or type values, one per line: each becomes a rule.")
    }

    private func buildActionControls() {
        countLabel.font = .preferredFont(forTextStyle: .caption1)
        countLabel.textColor = .secondaryLabelColor
        countLabel.lineBreakMode = .byTruncatingTail
        countLabel.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        warningLabel.font = .preferredFont(forTextStyle: .caption1)
        warningLabel.textColor = .systemOrange

        statusLabel.font = .preferredFont(forTextStyle: .caption1)
        statusLabel.textColor = .secondaryLabelColor
        statusLabel.lineBreakMode = .byWordWrapping
        statusLabel.maximumNumberOfLines = 0
        statusLabel.cell?.wraps = true
        statusLabel.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)

        saveButton.title = "Save"
        saveButton.bezelStyle = .rounded
        saveButton.setButtonType(.momentaryPushIn)
        saveButton.target = self
        saveButton.action = #selector(saveTapped)
        // Save is the DEFAULT button: the fields have no action of their own, so
        // Return resolves to whatever holds "\r" — and a Return that CLOSED the
        // sheet would silently discard the edit just typed.
        saveButton.keyEquivalent = "\r"
        saveButton.setAccessibilityIdentifier("sheet.tagmanager.default")
        saveButton.setContentCompressionResistancePriority(.required, for: .horizontal)

        cancelButton.title = "Cancel"
        cancelButton.bezelStyle = .rounded
        cancelButton.setButtonType(.momentaryPushIn)
        cancelButton.target = self
        cancelButton.action = #selector(cancelTapped)
        cancelButton.keyEquivalent = "\u{1b}"
        cancelButton.setAccessibilityIdentifier("sheet.tagmanager.cancel")
        cancelButton.setContentCompressionResistancePriority(.required, for: .horizontal)

        revertButton.title = String(localized: "Revert", comment: "Tag Manager: discard every unsaved edit.")
        revertButton.bezelStyle = .rounded
        revertButton.setButtonType(.momentaryPushIn)
        revertButton.target = self
        revertButton.action = #selector(revertTapped)
        revertButton.setAccessibilityIdentifier("tags.manager.revert")
        revertButton.setContentCompressionResistancePriority(.required, for: .horizontal)
    }

    /// The count over the status line and the two buttons, outside the scroll
    /// view: an action the user must reach to finish the task must never be
    /// something they have to find by scrolling.
    private func buildActionBar() -> NSView {
        // The count sits ABOVE the status line rather than beside it: the two
        // answer different questions — "what does this tag reach" and "what will
        // Save do" — and one crowded row would make either easy to miss.
        let countRow = NSStackView(views: [countLabel, warningLabel, TagRuleGridView.slack()])
        countRow.orientation = .horizontal
        countRow.alignment = .centerY
        countRow.spacing = 8

        let secondary: NSButton = secondaryAction == .cancel ? cancelButton : revertButton
        let buttonRow = NSStackView(views: [statusLabel, TagRuleGridView.slack(), secondary, saveButton])
        buttonRow.orientation = .horizontal
        buttonRow.alignment = .centerY
        buttonRow.spacing = Self.buttonRowSpacing
        self.buttonRow = buttonRow

        let bar = NSStackView(views: [countRow, buttonRow])
        bar.orientation = .vertical
        bar.alignment = .leading
        bar.spacing = 8
        bar.translatesAutoresizingMaskIntoConstraints = false
        bar.spanArrangedSubviewsFullWidth()
        return bar
    }

    // MARK: Selection

    /// Show one tag, by its MODEL index, or nothing at all. Always redraws,
    /// even for the tag already on show: the owner calls this after a tag is
    /// added or deleted, when the list of tags around it changed.
    func select(modelIndex: Int?) {
        _ = view
        let resolved = modelIndex.flatMap { index in
            model.tags.indices.contains(index) && !model.isDeleted(tagAt: index) ? index : nil
        }
        selectedTagIndex = resolved
        refreshIdentity()
        renderGrid()
        refreshFooter()
        // A tag SWITCH starts a count like any other change, and bumps the
        // generation like any other — a count of the previous tag landing under
        // this one's name would be a wrong number, not a slow one.
        refreshCount()
    }

    /// The tag on show, or nil.
    private var selectedTag: EditableTag? {
        guard let index = selectedTagIndex, model.tags.indices.contains(index) else { return nil }
        return model.tags[index]
    }

    /// Edits not yet saved, the model's AND the mode's (a `.remove` tick, an
    /// `.add` draft joining a tag).
    var hasEdits: Bool { !model.commits().isEmpty || hasModeWork }

    // MARK: Tag actions — called by the list beside this detail

    /// Make a new tag and show it. Returns its model index.
    @discardableResult
    func addTag() -> Int {
        // A name, not an empty field: an unnamed tag blocks Save, and a new tag
        // that arrives already blocking reads as a fault rather than as an
        // invitation to type.
        model.addTag(name: "New Tag",
                     colorIndex: TagPalette.normalizedColorIndex(model.tags.count) ?? 0)
        let index = model.tags.count - 1
        select(modelIndex: index)
        return index
    }

    /// Mark the tag at `index` deleted. No confirmation alert, deliberately:
    /// nothing is deleted yet. The tag is MARKED, the footer says what a save
    /// would destroy, and Cancel (or Revert) discards the whole thing — so an
    /// alert here would be asking the analyst to confirm something that has
    /// not happened. The confirmation that matters is Save, which is explicit
    /// and which states the count first.
    ///
    /// The owner picks what to show next and calls `select(modelIndex:)`;
    /// this redraws only what the delete itself changes.
    func deleteTag(at index: Int) {
        model.deleteTag(at: index)
        if index == selectedTagIndex {
            selectedTagIndex = nil
            select(modelIndex: nil)
        } else {
            refreshFooter()
        }
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
            colorPicker.selectedIndex = TagPalette.normalizedColorIndex(tag.colorIndex) ?? -1
            noteField.stringValue = tag.note
            noteBadge.update(for: tag.note)
        } else {
            nameField.stringValue = ""
            colorPicker.selectedIndex = -1
            noteField.stringValue = ""
            noteBadge.update(for: "")
        }
        let hasTag = selectedTag != nil
        nameField.isEnabled = hasTag
        nameField.isEditable = hasTag
        noteField.isEnabled = hasTag
        noteField.isEditable = hasTag
        colorPicker.isEnabled = hasTag
        formScroll.isHidden = !hasTag
        if hasTag {
            emptyState.isHidden = true
        } else if model.visibleTagIndices.isEmpty {
            emptyState.show(
                symbol: "tag",
                title: String(localized: "No Tags", comment: "Tag Manager: the empty state's title."),
                message: String(localized: "A tag marks the rows whose values match its rules — an address, a CIDR range, a number, a date.",
                                comment: "Tag Manager: the empty state's message."),
                actionTitle: String(localized: "New Tag", comment: "Tag Manager: make a new tag."),
                action: { [weak self] in self?.onAddTag?() })
        } else {
            emptyState.show(
                symbol: "tag",
                title: String(localized: "No Tag Selected", comment: "Tag Manager: tags exist, none is selected."),
                message: String(localized: "Select a tag to edit it."))
        }
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
        rebuildKeyViewLoop()
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

    // MARK: The live count
    //
    // Below `asyncCountThreshold` the count runs synchronously, which is the
    // same cost class as the match the grid runs anyway; above it the count
    // moves to a background queue exactly as `ResultsGridVC.matchAsyncThreshold`
    // does for the grid's own match, so a large loaded set cannot drop a frame
    // on every edit; and `countGeneration` discards a slow count that lands
    // after a newer one rather than letting it overwrite a fresher number.
    //
    // This count is per SELECTED TAG, so a tag switch starts a count too — and
    // every switch goes through `select`. A stale count from the previous tag
    // would land under the new tag's name, which is a wrong number attached to
    // the wrong tag: worse than a slow one.

    @objc private func sampleChanged(_ sender: Any?) { refreshSample() }

    /// The sample's result against the selected tag's rules as they are now,
    /// edits included.
    func refreshSample() {
        guard let index = selectedTagIndex else { setSampleResult("", matched: false); return }
        let sample = sampleField.stringValue
        let results = TagSampleTest.evaluate(sample, rules: model.tags[index].rules.map(\.conditions))
        setSampleResult(TagSampleTest.summary(results, sample: sample),
                        matched: results.contains(where: \.isMatch))
        // And on the rules themselves: a match is drawn on its rule's box.
        if sample.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            grid.showSampleMarks(nil)
        } else {
            var marks: [Int: TagRuleGridView.SampleMark] = [:]
            for result in results {
                if result.isMatch { marks[result.ordinal - 1] = .match }
                else if result.matched > 0 { marks[result.ordinal - 1] = .partial(matched: result.matched, total: result.total) }
            }
            grid.showSampleMarks(marks)
        }
    }

    /// The Test row's caption. Its colour is set AFTER the text: the row's
    /// caption setter leaves the colour alone.
    private func setSampleResult(_ text: String, matched: Bool) {
        sampleRow.caption = text
        sampleRow.captionLabel.textColor = matched ? .systemGreen : .secondaryLabelColor
    }

    private func refreshCount() {
        refreshSample()
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
            // window can open with no result behind it at all.
            countLabel.stringValue =
                "No rows are loaded here, so there is nothing to count against."
            warningLabel.stringValue = ""
            return
        }

        let preview = previewTag(for: tag)
        let columns = self.columns
        let count = countMatches

        guard rows.count > Self.asyncCountThreshold else {
            let counts = count(preview, columns, rows)
            show(solid: counts.solid, partial: counts.partial, loaded: rows.count)
            return
        }

        countLabel.stringValue = "Counting…"
        warningLabel.stringValue = ""
        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            let counts = count(preview, columns, rows)
            DispatchQueue.main.async {
                MainActor.assumeIsolated {
                    guard let self, self.countGeneration == generation else { return }
                    self.show(solid: counts.solid, partial: counts.partial, loaded: rows.count)
                }
            }
        }
    }

    /// The footer, from a finished count.
    ///
    /// `solid` is what the tag CLAIMS — one whole rule present in the row —
    /// and is the number that falls when a rule tightens. `partial` is what
    /// the tag merely TOUCHES: rows a rule is halfway satisfied against, which
    /// tint in the grid too but are not claimed. Stating only `solid` would
    /// leave the analyst seeing more colour in the grid than the footer
    /// accounts for, so the partial count is said alongside it — but dropped
    /// entirely when there are none, so the common case reads as one plain
    /// sentence rather than a trailing "0 partial." that means nothing.
    private func show(solid: Int, partial: Int, loaded: Int) {
        var text = "Matches \(solid) of \(loaded) loaded rows."
        if partial > 0 {
            text += " \(partial) partial."
        }
        countLabel.stringValue = text
        // The warning never blocks Save, and nothing below it may start to: a
        // deliberately broad temporary tag is a legitimate tool, and only the
        // analyst knows which this is.
        //
        // Fed solid + partial, not solid alone: "This tag is broad" warns
        // about how much of the grid will light up, and a value common enough
        // to touch — without claiming — hundreds of rows dashed IS broad.
        warningLabel.stringValue = TagDraft.isBroad(matched: solid + partial, loaded: loaded)
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
        revertButton.isEnabled = hasEdits
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
        // joins is chosen by a LIST SELECTION — which looks like navigation,
        // not like a decision. This is the line that makes it one.
        if !model.draftRules.isEmpty, let index = selectedTagIndex {
            let rules = model.draftRules.count
            // "one per selected row" only when that is literally true. Two rows
            // whose captured values normalise the same collapse into ONE rule —
            // `TagDraft` does that so the live count is honest — so the count
            // and the row count can legitimately differ, and the clause must not
            // claim otherwise.
            let perRow = rules > 1 && rules == model.capture?.selectedRows.count
            notices.append("Saving adds \(CountedNounText.phrase(rules, "rule")) to "
                + "\(tagName(index))\(perRow ? ", one per selected row" : "").")
        }
        statusLabel.stringValue = notices.joined(separator: " ")
        statusLabel.textColor = notices.isEmpty ? .secondaryLabelColor : .systemOrange
    }

    /// The rules a save would remove because they are TICKED.
    ///
    /// Read from this view's own set, which the boxes drive — never from
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

    /// Work this view carries that the MODEL cannot see: the draft of `.add`,
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
    /// The first three questions are this view's own — the model cannot see a
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
    /// the analyst can act on rather than a fact about the form.
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
        let escaped = Self.displayName(name)
        return escaped.isEmpty ? "the unnamed tag" : "\u{201C}\(escaped)\u{201D}"
    }

    /// One tag's name as the manager draws it anywhere but the field itself:
    /// a list row, its tooltip, and every sentence naming a tag in the footer
    /// or an alert. TRIMMED, then escaped — not the raw name, which is
    /// `TagManagerModel.committedName`'s edge-space disclosure bug this method
    /// exists to fix (a name typed as `Test ` mid-word must not read
    /// `Test<U+0020>` before the analyst has even finished the word), and not
    /// `committedName(name)` either, despite that being the form the store
    /// will actually receive.
    ///
    /// `committedName` SANITISES before it trims, and sanitising does not
    /// disclose a hostile scalar — it REMOVES one, same as the name field
    /// does per keystroke. Piping every stored name through it here would
    /// make a bidi override in a name typed this session invisible, which is
    /// correct (the field already denied it entry, so there is nothing left
    /// to show), but it would ALSO make one in a name stored before that
    /// field rule existed invisible — silently, with no `<U+XXXX>` marking
    /// where it stood.
    ///
    /// The trim-then-escape order is `DisplayEscape.escapedTrimmed`'s. See
    /// that function's doc for why the order discloses a hostile scalar
    /// instead of swallowing it.
    static func displayName(_ name: String) -> String {
        DisplayEscape.escapedTrimmed(name)
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
        onTagChanged?(index)
        refreshFooter()
    }

    @objc private func colorChanged(_ sender: Any?) {
        guard let index = selectedTagIndex, colorPicker.selectedIndex >= 0 else { return }
        model.recolour(tagAt: index, to: colorPicker.selectedIndex)
        onTagChanged?(index)
        refreshFooter()
    }

    // MARK: Rule and condition actions
    //
    // Every one of these closures reaches back through `self` and reads
    // `self.model` at CALL time. None captures the model, or a tag out of it, by
    // value — a closure that did would edit a copy Save never sees.

    private func gridCallbacks() -> TagRuleGridView.Callbacks {
        // `addValues` stays nil: the grid's own Add Values… button is hidden,
        // and the form's footer button (`addValuesButton`) takes its place.
        TagRuleGridView.Callbacks(
            addRule: { [weak self] in self?.addRule() },
            removeRule: { [weak self] in self?.removeRule($0) },
            addCondition: { [weak self] in self?.addCondition(toRule: $0) },
            removeCondition: { [weak self] in self?.removeCondition($1, fromRule: $0) },
            changedCondition: { [weak self] in self?.changedCondition($0, $1, $2) },
            invalidCondition: { [weak self] in self?.invalidCondition($0, $1, $2) },
            changedSelection: { [weak self] in self?.changedSelection($0) })
    }

    @objc private func addValuesTapped(_ sender: Any?) { presentAddValues() }

    /// Add Values…: a sheet over this view's window; the lines it accepts
    /// become one rule each on the selected tag (`TagValueImport`).
    func presentAddValues() {
        guard let index = selectedTagIndex else { return }
        let existing = model.tags[index].rules.map(\.conditions)
        let sheet = TagAddValuesSheet(existing: existing) { [weak self] conditions in
            self?.addRules(conditions)
        }
        presentAsSheet(sheet)
    }

    /// One rule per condition on the selected tag, then one re-render.
    func addRules(_ conditions: [TagCondition]) {
        guard let index = selectedTagIndex, !conditions.isEmpty else { return }
        for condition in conditions { model.addRule(toTagAt: index, conditions: [condition]) }
        structuralChange(tagAt: index)
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
        onTagChanged?(index)
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
        // The list's unsaved dot follows a value edit too.
        onTagChanged?(index)
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
    /// this view knows about.
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
            Log.ui.error("Tag manager save failed: \(error.localizedDescription, privacy: .public)")
            // The view STAYS UP, with every edit where it was: a save that
            // failed halfway is the one moment the analyst most needs their
            // work still in front of them.
            // `localizedDescription`, not interpolation. Every error that
            // reaches here is a `LocalizedError` — `TagCommitError` from the
            // save loop, `PharosCoreError` from the FFI under it — and
            // interpolating one of those prints the SWIFT CASE, so the analyst
            // would read `rustError("connection refused")` instead of the
            // sentence the error was given.
            statusLabel.stringValue = "Could not save: "
                + DisplayEscape.escapedMultiline(error.localizedDescription)
            statusLabel.textColor = .systemRed
            presentFailure(error)
            return
        }
        onSaved?()
    }

    @objc private func cancelTapped(_ sender: Any?) { onCancel?() }

    @objc private func revertTapped(_ sender: Any?) { onRevert?() }

    // No `cancelOperation` override: `cancelButton` holds "\u{1b}", and a
    // button's key equivalent is resolved before the responder chain sees the
    // key, so the override could never run.

    private func presentFailure(_ error: Error) {
        // Before building anything: with no window there is nothing to hang the
        // alert from, and the label above is the whole report.
        guard let window = view.window else { return }
        let alert = NSAlert()
        alert.messageText = "Could not save the tags"
        // Same reason as the status line above: the sentence the error carries,
        // not the Swift case that carries it.
        alert.informativeText = DisplayEscape.escapedMultiline(error.localizedDescription)
        alert.addButton(withTitle: "OK")
        alert.beginSheetModal(for: window)
    }
}

// MARK: - FlippedView

/// A document view that starts at the TOP. An unflipped `NSScrollView`
/// document pins its content to the bottom, so a short list would sit at the
/// foot of the pane and grow upwards.
private final class FlippedView: NSView {
    override var isFlipped: Bool { true }
}
