import AppKit

/// The variables panel's detail level: everything about one variable. The list
/// level is read-only, so this is the only place a name, type, or value is
/// edited. Edits apply live (as the panel has always behaved) — there is no
/// save/cancel model, and therefore no way to lose work by navigating back.
final class VariableDetailVC: NSViewController {

    /// Fired on every keystroke / type change with the updated variable.
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

        // Measured directly (see PharosTests/VariableDetailVCTests.swift):
        // `NSBox(boxType: .separator)` with an explicit `heightAnchor == 1`
        // constraint — the form the plan originally specified here — still
        // resolves to 5pt tall in this view's actual layout, not 1pt. An isolated
        // probe of the same shape measured 1pt, so the mechanism is unresolved —
        // plausibly the same settle-timing effect the harness documents (stack
        // geometry here needs a second layout pass before it is final), or
        // something about this assembly. Rather than chase it: a layer-backed view
        // cannot acquire a height by accident, since nothing but one explicit
        // constraint can influence it, and the harness asserts the 1pt result.
        // `VariableListView` hit the same "unconstrained separator measures
        // 5pt" problem for its row hairlines and fixed it with a plain
        // layer-backed 1pt view instead of `NSBox` — used here for the same
        // reason: a layer-backed view cannot acquire a height by accident,
        // since nothing but this one explicit constraint can influence it.
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
        valueTextView.onCancel = { [weak self] in self?.onBack?() }
        scrollView.documentView = valueTextView

        nameField.nextKeyView = valueTextView

        let gutterView = LineNumberGutter(textView: valueTextView, scrollView: scrollView)
        gutterView.onWidthChange = { [weak self] in self?.view.needsLayout = true }
        gutter = gutterView

        editorContainer.wantsLayer = true
        editorContainer.translatesAutoresizingMaskIntoConstraints = false
        editorContainer.addSubview(gutterView)
        editorContainer.addSubview(scrollView)

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

    @objc private func backTapped() {
        revertNameFieldIfColliding()
        onBack?()
    }
    @objc private func deleteTapped() { onDelete?() }

    @objc private func typeChanged() {
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
    override func cancelOperation(_ sender: Any?) {
        revertNameFieldIfColliding()
        onBack?()
    }

    // MARK: - Name collision refusal

    /// Tints the name field red for either signal that can cause it — a live
    /// typed collision takes priority since it means an edit is actively
    /// being refused right now; otherwise falls back to the committed
    /// `problem` `setState` reported — and reverts to the normal indigo when
    /// neither applies.
    private func updateNameFieldColor() {
        if isNameCollision {
            nameField.textColor = .systemRed
            nameField.toolTip = "A variable named \(collidingName.debugDescription) already exists."
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
            duplicationLabel.stringValue = "A variable named \(collidingName.debugDescription) already exists."
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

    /// Called on every path back to the list level. A colliding name was
    /// never written to the model (`controlTextDidChange` refused it), so
    /// this only needs to fix up what the field is *displaying* — restore the
    /// variable's actual, last-valid name — rather than undo anything on
    /// `variable` itself. Never blocks navigation: the whole point of the
    /// refusal is that the user is not trapped on this screen by an
    /// unresolved collision.
    private func revertNameFieldIfColliding() {
        guard isNameCollision else { return }
        isNameCollision = false
        nameField.stringValue = variable.name
        updateNameFieldColor()
        updateDuplicationDisplay()
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
    /// Segment order therefore has to match `BoolChoice.allCases`, which the
    /// harness asserts rather than trusting the labels to stay in step.
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
    }
}

extension VariableDetailVC: NSTextFieldDelegate {
    /// While the trimmed typed name exactly (case-sensitively) matches
    /// another variable's trimmed name, the edit is refused outright: it is
    /// never written to `variable.name`, and `onChange` never fires for it.
    /// The field itself is left showing exactly what was typed — the point is
    /// to stop a duplicate from ever reaching the model, not to fight the
    /// user's typing — with the collision explained inline instead (see
    /// `updateDuplicationDisplay`). An empty trimmed name never collides,
    /// including with another empty name: two freshly added rows are not
    /// duplicates of each other.
    func controlTextDidChange(_ obj: Notification) {
        let typed = nameField.stringValue
        let trimmed = typed.trimmingCharacters(in: .whitespacesAndNewlines)

        guard trimmed.isEmpty || !otherNames.contains(trimmed) else {
            isNameCollision = true
            updateNameFieldColor()
            updateDuplicationDisplay()
            return
        }

        isNameCollision = false
        variable.name = typed
        updateNameFieldColor()
        updateDuplicationDisplay()
        onChange?(variable)
    }

    /// Escape while the name field has focus returns to the list, after
    /// reverting any uncommitted colliding text (see
    /// `revertNameFieldIfColliding`).
    func control(
        _ control: NSControl, textView: NSTextView, doCommandBy commandSelector: Selector
    ) -> Bool {
        guard commandSelector == #selector(NSResponder.cancelOperation(_:)) else { return false }
        revertNameFieldIfColliding()
        onBack?()
        return true
    }
}

extension VariableDetailVC: NSTextViewDelegate {
    func textDidChange(_ notification: Notification) {
        variable.value = valueTextView.string
        captionLabel.stringValue = VariableValuePreview.caption(for: variable.value)
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
