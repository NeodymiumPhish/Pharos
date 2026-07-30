import AppKit

/// The variables panel's detail level: everything about one variable. The list
/// level is read-only, so this is the only place a name, type, or value is
/// edited. Edits apply live (as the panel has always behaved) — there is no
/// save/cancel model, and therefore no way to lose work by navigating back.
///
/// The name field is the one deliberate exception to "live": see the note at
/// `controlTextDidChange` and `commitNameIfValid` for why. Every other
/// control here — the type popup, the value editor, the Bool choice — still
/// writes straight through to `variable` and fires `onChange` on every
/// change, exactly as the class comment above describes. The name alone
/// defers its write to a handful of explicit "settle" points, because it is
/// the one field with a uniqueness constraint another row can violate one
/// keystroke at a time.
final class VariableDetailVC: NSViewController {

    /// Fired with the updated variable on every value/type edit, and on a
    /// name edit only at a settle point — see the class comment above and
    /// `commitNameIfValid` for why the name field alone is not "every
    /// keystroke."
    var onChange: ((QueryVariable) -> Void)?
    var onDelete: (() -> Void)?
    /// Back chevron or Escape.
    var onBack: (() -> Void)?

    private(set) var variable: QueryVariable

    private let nameField = NSTextField()
    private let typePopup = NSPopUpButton()
    // `VariableValueTextView()` — the parameterless convenience init builds its
    // own TextKit stack. Do NOT use `init(frame:textContainer:)` with a nil
    // container: it leaves textStorage/layoutManager/textContainer all nil and
    // the view then silently discards every assignment to `string`.
    private let valueTextView = VariableValueTextView()
    private let scrollView = NSScrollView()
    private let captionLabel = NSTextField(labelWithString: "")
    /// Stands in for `editorContainer`/`captionLabel` when `variable.type ==
    /// .bool` — a free-text editor is the wrong control for a value that is
    /// only ever one of three things. Segments are `True` / `False` / `NULL`,
    /// in that fixed order (index 0 / 1 / 2), matching `boolSegmentIndex(for:)`
    /// below.
    private let valueChoiceControl = NSSegmentedControl(
        labels: ["True", "False", "NULL"], trackingMode: .selectOne, target: nil, action: nil)
    /// Plain, size-less wrapper that takes `editorContainer`'s place in
    /// `body`'s arranged-subview list. `valueChoiceControl` itself carries a
    /// fixed intrinsic size (an `NSContentSizeLayoutConstraint` at the same
    /// priority NSStackView uses for its own arranged-subview edge ties) —
    /// measured directly: putting the control straight into the stack and
    /// only tuning its hugging priority still leaves `hasAmbiguousLayout`
    /// true, because the tie is over horizontal *position*, not size, and no
    /// hugging value fixes that. Wrapping it — the same trick
    /// `editorContainer` already uses for the text editor — sidesteps the
    /// problem instead of fighting it: the wrapper has no intrinsic size of
    /// its own, so it stretches to fill the leftover space exactly as
    /// `editorContainer` does, unambiguously, and the control sits inside it
    /// at its natural size, positioned by ordinary constraints.
    private let valueChoiceContainer = NSView()
    /// Duplicate-name note, hidden unless this variable shares its name with
    /// another row. Sits directly under the header so it reads as a comment on
    /// the name field above it.
    private let duplicationLabel = NSTextField(labelWithString: "")
    private let editorContainer = EditorBackgroundView()
    /// `NSTextView` has no native placeholder, unlike `nameField`'s
    /// `placeholderString` above — the old, single-line value field had one
    /// ("value"), and the spec calls for keeping it, so this stands in:
    /// shown only while the value editor is empty, positioned to align with
    /// where typed text would actually start (see `viewDidLayout`).
    private let valuePlaceholderLabel = NSTextField(labelWithString: "value")
    private var gutter: LineNumberGutter?

    init(variable: QueryVariable) {
        self.variable = variable
        super.init(nibName: nil, bundle: nil)
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) not implemented")
    }

    // MARK: - View

    override func loadView() {
        let container = NSView()
        self.view = container

        // Header — back · name · type · delete. Mirrors a list row's
        // name-leading / type-trailing layout so the two levels rhyme.
        let backButton = NSButton()
        backButton.image = NSImage(
            systemSymbolName: "chevron.left", accessibilityDescription: "Back to variables"
        )?.withSymbolConfiguration(NSImage.SymbolConfiguration(pointSize: 11, weight: .semibold))
        backButton.bezelStyle = .recessed
        backButton.isBordered = false
        backButton.contentTintColor = .controlAccentColor
        backButton.toolTip = "Back to variables"
        backButton.target = self
        backButton.action = #selector(backTapped)

        nameField.placeholderString = "name"
        nameField.stringValue = variable.name
        nameField.font = .monospacedSystemFont(ofSize: 11, weight: .regular)
        nameField.textColor = .systemIndigo
        nameField.isBordered = false
        nameField.drawsBackground = false
        nameField.focusRingType = .none
        nameField.delegate = self

        for type in VariableType.allCases { typePopup.addItem(withTitle: type.displayName) }
        if let index = VariableType.allCases.firstIndex(of: variable.type) {
            typePopup.selectItem(at: index)
        }
        typePopup.controlSize = .small
        typePopup.font = .systemFont(ofSize: 10)
        typePopup.isBordered = false
        // Kept out of the key-view loop so Tab moves name → value without
        // stranding focus on a popup between the two text controls.
        typePopup.refusesFirstResponder = true
        typePopup.target = self
        typePopup.action = #selector(typeChanged)

        valueChoiceControl.controlSize = .small
        valueChoiceControl.font = .systemFont(ofSize: 10)
        // Kept out of the key-view loop for the same reason as `typePopup`
        // just above: Tab should move name → value editor without landing on
        // a popup/segmented control in between. This matters even more here,
        // since when the type is `.bool` this control IS the value editor —
        // without `refusesFirstResponder` it would be the one place Tab could
        // strand focus with no text control to land on.
        valueChoiceControl.refusesFirstResponder = true
        valueChoiceControl.target = self
        valueChoiceControl.action = #selector(valueChoiceChanged)

        valueChoiceControl.translatesAutoresizingMaskIntoConstraints = false
        valueChoiceContainer.translatesAutoresizingMaskIntoConstraints = false
        valueChoiceContainer.addSubview(valueChoiceControl)
        NSLayoutConstraint.activate([
            valueChoiceControl.topAnchor.constraint(equalTo: valueChoiceContainer.topAnchor),
            valueChoiceControl.leadingAnchor.constraint(equalTo: valueChoiceContainer.leadingAnchor),
            valueChoiceControl.trailingAnchor.constraint(
                lessThanOrEqualTo: valueChoiceContainer.trailingAnchor),
        ])

        let deleteButton = NSButton()
        deleteButton.image = NSImage(systemSymbolName: "trash", accessibilityDescription: "Delete variable")
        deleteButton.bezelStyle = .recessed
        deleteButton.isBordered = false
        deleteButton.controlSize = .small
        deleteButton.contentTintColor = .tertiaryLabelColor
        deleteButton.toolTip = "Delete variable"
        deleteButton.target = self
        deleteButton.action = #selector(deleteTapped)

        let header = NSStackView(views: [backButton, nameField, typePopup, deleteButton])
        header.orientation = .horizontal
        header.spacing = 6
        header.alignment = .centerY
        header.distribution = .fill
        nameField.setContentHuggingPriority(.defaultLow, for: .horizontal)
        nameField.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        header.translatesAutoresizingMaskIntoConstraints = false

        // A layer-backed 1pt view, not `NSBox(boxType: .separator)` — the
        // form the plan originally specified here. Corrected understanding
        // (see the note at `VariableListView`'s own row hairlines, which hit
        // the identical situation): an `NSBox` separator DOES honour an
        // explicit `heightAnchor.constraint(equalToConstant: 1)` and reports
        // no ambiguity — it is only an *unconstrained* separator box, with no
        // intrinsic height of its own, that measures 5pt. A now-stale claim
        // once stood here — that even a constrained `NSBox` still measured
        // 5pt in this specific view, with the mechanism "unresolved" — which
        // does not survive that corrected story and was not independently
        // re-verified in this file specifically. A layer-backed view is kept
        // here regardless: it cannot acquire a height by accident, since
        // nothing but the one explicit constraint below can influence it,
        // and the harness asserts the 1pt result either way.
        let headerSeparator = HairlineView()
        headerSeparator.wantsLayer = true
        headerSeparator.translatesAutoresizingMaskIntoConstraints = false
        headerSeparator.heightAnchor.constraint(equalToConstant: 1).isActive = true

        // Value editor: text view + the app's line-number gutter, laid out by
        // frames inside `editorContainer` exactly as QueryEditorVC does it.
        scrollView.hasVerticalScroller = true
        scrollView.hasHorizontalScroller = true
        scrollView.autohidesScrollers = true
        scrollView.borderType = .noBorder
        scrollView.drawsBackground = false

        valueTextView.string = variable.value
        valueTextView.isVerticallyResizable = true
        valueTextView.isHorizontallyResizable = true
        valueTextView.autoresizingMask = []
        valueTextView.minSize = NSSize(width: 0, height: 0)
        valueTextView.maxSize = NSSize(
            width: CGFloat.greatestFiniteMagnitude, height: CGFloat.greatestFiniteMagnitude)
        // No wrapping: a long single-line value scrolls sideways instead of
        // reflowing, so an ID list stays one entry per line.
        valueTextView.textContainer?.widthTracksTextView = false
        valueTextView.textContainer?.containerSize = NSSize(
            width: CGFloat.greatestFiniteMagnitude, height: CGFloat.greatestFiniteMagnitude)
        valueTextView.delegate = self
        valueTextView.onBacktab = { [weak self] in
            guard let self else { return }
            self.view.window?.makeFirstResponder(self.nameField)
        }
        // Routed through `attemptBack()`, not `onBack` directly: Escape here
        // is a fourth path off this screen, and without this it bypassed the
        // collision refusal entirely (a colliding name field could still be
        // showing when this fires — the value editor has its own focus,
        // independent of the name field's).
        valueTextView.onCancel = { [weak self] in self?.attemptBack() }
        scrollView.documentView = valueTextView

        nameField.nextKeyView = valueTextView

        let gutterView = LineNumberGutter(textView: valueTextView, scrollView: scrollView)
        gutterView.onWidthChange = { [weak self] in self?.view.needsLayout = true }
        gutter = gutterView

        valuePlaceholderLabel.font = valueTextView.font
        valuePlaceholderLabel.textColor = .tertiaryLabelColor
        valuePlaceholderLabel.isSelectable = false
        // A label, not the editor, so it must not intercept clicks meant to
        // focus the (empty) text view underneath it.
        valuePlaceholderLabel.isEnabled = false

        editorContainer.wantsLayer = true
        editorContainer.translatesAutoresizingMaskIntoConstraints = false
        editorContainer.addSubview(gutterView)
        editorContainer.addSubview(scrollView)
        editorContainer.addSubview(valuePlaceholderLabel)

        captionLabel.font = .systemFont(ofSize: 9)
        captionLabel.textColor = .tertiaryLabelColor
        captionLabel.stringValue = VariableValuePreview.caption(for: variable.value)

        duplicationLabel.font = .systemFont(ofSize: 9)
        duplicationLabel.textColor = .secondaryLabelColor
        duplicationLabel.lineBreakMode = .byWordWrapping
        duplicationLabel.maximumNumberOfLines = 2
        duplicationLabel.isHidden = true

        // A vertical stack rather than pinned constraints, because the
        // duplication note is usually absent and a stack collapses hidden
        // arranged subviews instead of leaving a gap where it would have been.
        // `editorContainer` hugs loosely so it absorbs the remaining height.
        // `valueChoiceContainer` sits last, after `captionLabel`: it and
        // `editorContainer`/`captionLabel` are never visible at the same
        // time (see `applyValueControlVisibility`), so its position doesn't
        // create any visual overlap, and appending it here leaves the
        // existing three arranged-subview indices the test harness already
        // relies on (`duplicationLabel`@0, `editorContainer`@1,
        // `captionLabel`@2) untouched.
        let body = NSStackView(views: [duplicationLabel, editorContainer, captionLabel, valueChoiceContainer])
        body.orientation = .vertical
        body.alignment = .width
        body.spacing = 5
        body.translatesAutoresizingMaskIntoConstraints = false
        editorContainer.setContentHuggingPriority(.defaultLow, for: .vertical)
        // Same reason, same mechanism: a plain, size-less wrapper absorbs
        // the leftover height unambiguously when it's the only visible
        // arranged subview (the Bool case, absent a duplication note).
        valueChoiceContainer.setContentHuggingPriority(.defaultLow, for: .vertical)

        // Measured directly: switching types hides whichever of
        // `editorContainer` / `valueChoiceContainer` isn't current, and a
        // *hidden*, size-less `NSView` (neither one has an intrinsic content
        // size) sitting next to a sibling that IS absorbing the stack's
        // leftover space comes back `hasAmbiguousLayout == true` — reproduced
        // in isolation with a two-view stack with no other differences, so
        // this is an NSStackView/NSView interaction, not something specific
        // to either view here. It renders at zero size with no visual or
        // hit-testing consequence either way, but a lowest-priority
        // zero-size fallback on both gives the hidden one something
        // determinate to resolve to instead of nothing, which resolves it —
        // confirmed by removing either pair below and watching the
        // corresponding "no ambiguous layout" assertion fail.
        for view in [editorContainer, valueChoiceContainer] {
            let fallbackWidth = view.widthAnchor.constraint(equalToConstant: 0)
            let fallbackHeight = view.heightAnchor.constraint(equalToConstant: 0)
            fallbackWidth.priority = NSLayoutConstraint.Priority(rawValue: 1)
            fallbackHeight.priority = NSLayoutConstraint.Priority(rawValue: 1)
            NSLayoutConstraint.activate([fallbackWidth, fallbackHeight])
        }

        container.addSubview(header)
        container.addSubview(headerSeparator)
        container.addSubview(body)

        NSLayoutConstraint.activate([
            header.topAnchor.constraint(equalTo: container.topAnchor, constant: 6),
            header.leadingAnchor.constraint(equalTo: container.leadingAnchor, constant: 8),
            header.trailingAnchor.constraint(equalTo: container.trailingAnchor, constant: -8),

            headerSeparator.topAnchor.constraint(equalTo: header.bottomAnchor, constant: 6),
            headerSeparator.leadingAnchor.constraint(equalTo: container.leadingAnchor),
            headerSeparator.trailingAnchor.constraint(equalTo: container.trailingAnchor),

            body.topAnchor.constraint(equalTo: headerSeparator.bottomAnchor, constant: 8),
            body.leadingAnchor.constraint(equalTo: container.leadingAnchor, constant: 10),
            body.trailingAnchor.constraint(equalTo: container.trailingAnchor, constant: -10),
            body.bottomAnchor.constraint(equalTo: container.bottomAnchor, constant: -8),
        ])

        applyValueControlVisibility()
    }

    override func viewDidLayout() {
        super.viewDidLayout()
        // 1 pt inset keeps the gutter and text inside the container's border.
        let bounds = editorContainer.bounds
        let gutterWidth = gutter?.desiredWidth ?? 0
        let height = max(0, bounds.height - 2)
        gutter?.frame = NSRect(x: 1, y: 1, width: gutterWidth, height: height)
        scrollView.frame = NSRect(
            x: 1 + gutterWidth, y: 1,
            width: max(0, bounds.width - gutterWidth - 2), height: height
        )

        // Aligned with where the first line of typed text would actually
        // start: `editorContainer` is not flipped, so its visual top is the
        // larger y, and `valueTextView.textContainerInset` (2, 4) is what
        // pushes real text 2pt right / 4pt down from that same corner.
        let placeholderHeight = valuePlaceholderLabel.intrinsicContentSize.height
        valuePlaceholderLabel.frame = NSRect(
            x: scrollView.frame.minX + 2,
            y: scrollView.frame.maxY - 4 - placeholderHeight,
            width: max(0, scrollView.frame.width - 4),
            height: placeholderHeight
        )
    }

    /// Shown only while the value editor is empty — never at the same time
    /// as real content, and never while `variable.type == .bool` (the
    /// choice control has no notion of "empty" the way free text does).
    private func updateValuePlaceholderVisibility() {
        valuePlaceholderLabel.isHidden = variable.type == .bool || !valueTextView.string.isEmpty
    }

    /// Sibling variables' trimmed, non-empty names (this variable's own name
    /// excluded) — supplied by the panel, since this VC cannot see its own
    /// siblings. Read only from `controlTextDidChange` to decide whether a
    /// typed name may be committed; refreshed by the panel whenever the list
    /// changes underneath (see `QueryVariablesPanelVC.refreshDetailState`).
    var otherNames: Set<String> = []

    /// Whether `nameField`'s current *displayed* text collides with
    /// `otherNames` right now. Live and ephemeral — set the moment a typed
    /// name collides, cleared the moment it doesn't — and independent of
    /// `lastRowState.duplication`, which reflects only the committed model
    /// and can still be `.shadowed` for a duplicate pair loaded from a saved
    /// query that predates this refusal rule.
    private var isNameCollision = false

    /// The state `setState` was last given, cached so `updateDuplicationDisplay`
    /// can fall back to it (the `.shadowed` legacy note) once a live
    /// collision clears.
    private var lastRowState: VariableSubstitutor.RowState?

    // MARK: - API

    /// Move focus to the name field — used right after `+` creates a variable.
    func focusNameField() {
        view.window?.makeFirstResponder(nameField)
    }

    /// Apply the state the panel resolved for this variable: red for a value
    /// that cannot render, and (for legacy duplicate data only — see
    /// `updateDuplicationDisplay`) a note about an inert `.shadowed` row.
    ///
    /// It comes from the same `rowStates` pass the list uses, so the two
    /// levels cannot contradict each other.
    func setState(_ state: VariableSubstitutor.RowState?) {
        lastRowState = state
        updateNameFieldColor()
        updateDuplicationDisplay()
    }

    // MARK: - Actions

    @objc private func backTapped() { attemptBack() }
    @objc private func deleteTapped() { onDelete?() }

    @objc private func typeChanged() {
        // A type change is a settle point (see `commitNameIfValid`): the user
        // has moved on to a different control, so whatever the name field
        // currently shows either commits now or never will via this
        // interaction.
        commitNameIfValid()
        let index = typePopup.indexOfSelectedItem
        guard index >= 0, index < VariableType.allCases.count else { return }
        variable.type = VariableType.allCases[index]
        applyValueControlVisibility()
        onChange?(variable)
    }

    @objc private func valueChoiceChanged() {
        let index = valueChoiceControl.selectedSegment
        // trackingMode is .selectOne, so a real click always lands on a segment.
        guard index >= 0, index < VariableSubstitutor.BoolChoice.allCases.count else { return }
        variable.value = VariableSubstitutor.BoolChoice.allCases[index].rawValue
        onChange?(variable)
    }

    /// Escape with neither text control focused (e.g. straight after the slide).
    override func cancelOperation(_ sender: Any?) { attemptBack() }

    // MARK: - Name collision refusal

    /// Tints the name field red for either signal that can cause it — a live
    /// typed collision takes priority since it means an edit is actively
    /// being refused right now; otherwise falls back to the committed
    /// `problem` `setState` reported — and reverts to the normal indigo when
    /// neither applies.
    private func updateNameFieldColor() {
        if isNameCollision {
            nameField.textColor = .systemRed
            nameField.toolTip = Self.collisionMessage(for: collidingName)
        } else {
            let problem = lastRowState?.problem
            nameField.textColor = problem == nil ? .systemIndigo : .systemRed
            nameField.toolTip = problem?.message
        }
    }

    /// The trimmed text currently in the name field — used to name the
    /// variable in the collision message.
    private var collidingName: String {
        nameField.stringValue.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    /// Reads as an instruction, not just an observation: while colliding, the
    /// name field also blocks leaving this screen (see `attemptBack`), so the
    /// message has to tell the user what to do about it, not merely name the
    /// problem.
    private static func collisionMessage(for name: String) -> String {
        "A variable named \(name.debugDescription) already exists. Choose a different name."
    }

    /// Renders `duplicationLabel`'s content. A live typed collision takes
    /// priority over the committed `.shadowed` note — it is more urgent, since
    /// it is blocking an edit right now, whereas `.shadowed` merely describes
    /// an already-saved row that has always been inert. `.overriding` no
    /// longer renders anything at all: the only way to type your way into
    /// becoming the "winning" half of a duplicate is now refused before it
    /// ever reaches the model, so the note that used to call that out is
    /// unreachable for anything the user can create here — only a duplicate
    /// pair loaded from a saved query that predates this rule can still
    /// surface `.shadowed`.
    ///
    /// Forces an immediate relayout after changing `duplicationLabel.isHidden`
    /// rather than leaving `body`'s stack to catch up on some later, unrelated
    /// pass: that lag is exactly what let the value editor (and its cursor)
    /// sit in the wrong place until the user's next keystroke happened to
    /// trigger layout.
    private func updateDuplicationDisplay() {
        if isNameCollision {
            duplicationLabel.stringValue = Self.collisionMessage(for: collidingName)
            duplicationLabel.textColor = .systemRed
            duplicationLabel.isHidden = false
        } else if lastRowState?.duplication == .shadowed {
            duplicationLabel.stringValue = "Redefined below — this row has no effect."
            duplicationLabel.textColor = .secondaryLabelColor
            duplicationLabel.isHidden = false
        } else {
            duplicationLabel.stringValue = ""
            duplicationLabel.isHidden = true
        }
        view.needsLayout = true
        view.layoutSubtreeIfNeeded()
    }

    /// The single entry point for every path off this screen: the back
    /// button, Escape via `cancelOperation` with no text control focused,
    /// Escape while the name field specifically has focus (the delegate
    /// below), and Escape while the value editor has focus
    /// (`valueTextView.onCancel`, wired to this rather than `onBack`
    /// directly). While the field's displayed text collides with another
    /// variable's name, leaving is refused outright — kept from the previous
    /// fix; see `commitNameIfValid` for the deeper problem that fix alone
    /// didn't close. Otherwise, this is a settle point: commit whatever the
    /// field currently shows before actually leaving.
    ///
    /// (History, for whoever finds `git blame` pointing here: this used to
    /// *revert* the field to the variable's last valid name instead of
    /// refusing to leave. That looked safe — a colliding name was never
    /// written to the model — but it mangled input the refusal was never
    /// meant to touch: renaming an existing "seed_list" by typing a second
    /// "seed_list" walks the field through "s", "se", …, "seed_lis" on the
    /// way there, and a revert right after the final, colliding keystroke
    /// committed "seed_lis" — a name the user never typed. Refusing instead
    /// of reverting fixed *that* symptom, but not the underlying cause: see
    /// `commitNameIfValid` for why the real fix is one level up.)
    private func attemptBack() {
        guard !isNameCollision else {
            view.window?.makeFirstResponder(nameField)
            return
        }
        commitNameIfValid()
        onBack?()
    }

    /// Commits whatever the name field currently displays to `variable.name`
    /// — but only here, at a deliberate "settle" point, never as a direct
    /// side effect of a keystroke. `controlTextDidChange` below updates the
    /// live collision signal (red tint, inline message) on every keystroke,
    /// but does not write through to the model or fire `onChange` itself.
    ///
    /// This is the fix one level up from simply refusing to leave while
    /// colliding. Every *individual* prefix typed on the way to a colliding
    /// name is, on its own, unique — typing "seed_list" against an existing
    /// "seed_list" passes through "s", "se", …, "seed_lis", none of which
    /// collide. Committing per keystroke (as every other control in this
    /// view does, and as this one used to) means each of those prefixes
    /// really was written to the model and really did fire `onChange` before
    /// the final, colliding keystroke was ever reached — so any path that
    /// doesn't go through `attemptBack` (switching tabs mid-edit is the one
    /// that was actually hit) leaves the variable renamed to whatever prefix
    /// was typed last, with no collision ever having been visibly refused.
    /// Refusing to leave via `attemptBack` closes that one door; it does not
    /// stop the leak, because the leak already happened by the time
    /// `attemptBack` runs.
    ///
    /// Deferring the write to a handful of explicit settle points — this,
    /// Enter, losing first responder, a type change (see
    /// `controlTextDidEndEditing` and `typeChanged`), and dismissal the VC
    /// cannot refuse (see `settleForDismissal`) — means there is nothing
    /// intermediate to commit in the first place: mid-typing, the model
    /// still has whatever name the variable had before this edit began,
    /// through every door, known or not.
    ///
    /// Guards against firing a no-op `onChange` when a settle point is
    /// reached without the name actually having changed (e.g. back pressed
    /// right after opening the detail level), and against firing twice for
    /// the same edit when more than one settle signal fires for it — Enter
    /// typically also ends editing, so both call this, but the second call
    /// finds `typed == variable.name` already and does nothing.
    /// Commits the *trimmed* field content, not the raw one. Every collision
    /// rule trims — `otherNames(excluding:)` and this file's own
    /// `controlTextDidChange` both trim before comparing, and
    /// `VariableSubstitutor.rowStates` keys its duplicate-detection on the
    /// stored name as-is — so an untrimmed commit could put a name into the
    /// model that no rule downstream agrees is the same as its trimmed self.
    /// Measured consequence of not trimming here: typing `"ip "` committed a
    /// row no `{{token}}` could ever reference (the trailing space makes it
    /// a different string), which showed healthy (indigo, no badge, since
    /// `rowStates` cannot flag a collision the model itself doesn't contain)
    /// and then refused the *correct* name `"ip"` on another row as a
    /// duplicate — because by then two rows really did share the same
    /// trimmed name, just spelled differently in storage — blocking exit
    /// with no way to tell why. Trimming here also closes a second gap: a
    /// name of three spaces is non-empty by `String.isEmpty`, so it used to
    /// survive `dismissDetail`'s abandoned-row prune as a junk row; trimmed,
    /// it commits as `""` and prunes normally.
    private func commitNameIfValid() {
        guard !isNameCollision else { return }
        let typed = nameField.stringValue.trimmingCharacters(in: .whitespacesAndNewlines)
        guard typed != variable.name else { return }
        variable.name = typed
        onChange?(variable)
    }

    /// The settle point for dismissal the VC cannot refuse: a tab switch (or
    /// anything else that tears the detail level down out from under the
    /// user) calls this — not `attemptBack` — because there is nowhere to
    /// send the user back to argue about a collision. A valid typed name
    /// still commits; a colliding one is simply dropped, which is exactly
    /// what `commitNameIfValid`'s existing collision guard already does, so
    /// this is only a public name for calling it from outside the VC.
    ///
    /// The caller (`QueryVariablesPanelVC.dismissDetail`) must call this
    /// *before* reading `variable` for its own abandoned-row prune check:
    /// settling first means a freshly added row that was given a valid name
    /// is no longer empty, so it is correctly kept rather than pruned as
    /// abandoned.
    func settleForDismissal() {
        commitNameIfValid()
    }

    // MARK: - Value control switching

    /// Maps a stored value to a segment index by asking the substitutor which of
    /// `Bool`'s three values it means. The accepted spellings and the canonical
    /// ones live there and only there — this view restated all three sets by hand
    /// at first, which is precisely how a control ends up disagreeing with the SQL
    /// it produces after someone edits one list and not the other.
    ///
    /// Returns `nil` — no segment selected — for anything that means none of the
    /// three, including `""` and leftovers like `"abc"` from a value typed while
    /// the type was `.text`. Never guesses a default: an unmatched value must leave
    /// the control looking exactly as unresolved as the red badge says it is.
    ///
    /// Segment order therefore has to match `BoolChoice.allCases`.
    /// `PharosTests/VariableDetailVCTests.swift`'s
    /// `testBoolSegmentLabelsMatchChoiceOrder` ties the control's actual
    /// label *text* at each index to what that index means — index-only
    /// comparisons (which every other Bool test here makes) stay green even
    /// if the construction-time `labels:` array is reordered independently
    /// of this function, so that test is the one actually asserting the two
    /// stay in step, not merely trusting them to.
    private static func boolSegmentIndex(for value: String) -> Int? {
        guard let choice = VariableSubstitutor.boolChoice(for: value) else { return nil }
        return VariableSubstitutor.BoolChoice.allCases.firstIndex(of: choice)
    }

    /// Shows the value editor that matches `variable.type` — the free-text
    /// editor for everything else, the True/False/NULL choice for `.bool` —
    /// and hides the other. `body` is a stack, so hiding either side
    /// collapses it rather than leaving a gap (same mechanism the
    /// duplication note already relies on).
    ///
    /// Also keeps whichever control is *becoming* hidden's content in sync
    /// with `variable.value` before it goes: switching type never clears or
    /// otherwise mutates the value (`"true"` is a perfectly good `Literal`),
    /// but each control only actively tracks `variable.value` while it is the
    /// one visible, so the other one needs a one-time refresh on the way in.
    private func applyValueControlVisibility() {
        let isBool = variable.type == .bool
        editorContainer.isHidden = isBool
        captionLabel.isHidden = isBool
        valueChoiceContainer.isHidden = !isBool

        if isBool {
            if let index = Self.boolSegmentIndex(for: variable.value) {
                valueChoiceControl.selectedSegment = index
            } else {
                valueChoiceControl.selectedSegment = -1
            }
        } else {
            valueTextView.string = variable.value
            captionLabel.stringValue = VariableValuePreview.caption(for: variable.value)
        }
        updateValuePlaceholderVisibility()
    }
}

extension VariableDetailVC: NSTextFieldDelegate {
    /// Updates the live collision signal — red tint, inline message — on
    /// every keystroke. Deliberately does NOT write to `variable.name` or
    /// fire `onChange` here, unlike every other control in this view: see
    /// `commitNameIfValid` for why the name field alone defers its actual
    /// commit to a handful of settle points instead of applying live.
    ///
    /// The collision check itself is unchanged and still runs against the
    /// field's live content: exact (case-sensitive) match on the trimmed
    /// text against another variable's trimmed name, with an empty trimmed
    /// name never colliding — including with another empty name, since two
    /// freshly added rows are not duplicates of each other.
    func controlTextDidChange(_ obj: Notification) {
        let trimmed = nameField.stringValue.trimmingCharacters(in: .whitespacesAndNewlines)
        isNameCollision = !trimmed.isEmpty && otherNames.contains(trimmed)
        updateNameFieldColor()
        updateDuplicationDisplay()
    }

    /// Losing first responder is a settle point (see `commitNameIfValid`):
    /// this fires whenever the name field's editing session ends for any
    /// reason — Tab, a click elsewhere, or Return (which ends editing on a
    /// single-line field even when focus doesn't visibly move) — covering
    /// "the name field losing first responder" on its own. Return is also
    /// handled explicitly below, so the two can both fire for the same
    /// keystroke; `commitNameIfValid`'s no-op guard absorbs that safely.
    func controlTextDidEndEditing(_ obj: Notification) {
        commitNameIfValid()
    }

    /// Escape while the name field has focus returns to the list — unless
    /// the field currently collides, in which case `attemptBack` refuses to
    /// leave. Return is a settle point in its own right (see
    /// `commitNameIfValid`): commit if valid and swallow the keystroke
    /// either way, since this is a single-line field with nowhere for an
    /// actual newline to go.
    func control(
        _ control: NSControl, textView: NSTextView, doCommandBy commandSelector: Selector
    ) -> Bool {
        if commandSelector == #selector(NSResponder.cancelOperation(_:)) {
            attemptBack()
            return true
        }
        if commandSelector == #selector(NSResponder.insertNewline(_:)) {
            commitNameIfValid()
            return true
        }
        return false
    }
}

extension VariableDetailVC: NSTextViewDelegate {
    func textDidChange(_ notification: Notification) {
        variable.value = valueTextView.string
        captionLabel.stringValue = VariableValuePreview.caption(for: variable.value)
        updateValuePlaceholderVisibility()
        onChange?(variable)
    }
}

/// Field-style rounded background for the value editor. Uses `updateLayer` (not
/// a one-shot `layer.backgroundColor = ....cgColor`) so the semantic colors are
/// re-resolved when the effective appearance changes.
private final class EditorBackgroundView: NSView {
    override var wantsUpdateLayer: Bool { true }
    override func updateLayer() {
        layer?.cornerRadius = 6
        layer?.borderWidth = 1
        layer?.backgroundColor = NSColor.textBackgroundColor.cgColor
        layer?.borderColor = NSColor.separatorColor.cgColor
    }
}

/// A 1pt hairline that tracks light/dark via `updateLayer`, matching
/// `VariableListView`'s private `HairlineView` (duplicated rather than shared
/// since that one is private to its own file). See the comment at
/// `headerSeparator`'s construction above for why this replaces `NSBox`.
private final class HairlineView: NSView {
    override var wantsUpdateLayer: Bool { true }
    override func updateLayer() {
        layer?.backgroundColor = NSColor.separatorColor.cgColor
    }
}
