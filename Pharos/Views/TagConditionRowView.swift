import AppKit

/// One condition, as four controls and a hint.
///
/// The operator is a POPUP, not syntax: nothing to type wrong, and no ambiguity
/// between a comparator and a literal `>`. `TagConditionEditor` owns which
/// operators a family offers and what the hint says, so this view asks it rather
/// than holding a second list that could drift.
///
/// The value field is NOT sanitised as it is typed, unlike a tag name. A
/// condition value DESCRIBES hostile data — an analyst hunting Trojan Source or
/// IDN homograph abuse must be able to name a hostname that genuinely carries a
/// bidi override. It carries a `HostileTextBadge` instead, so what is invisible
/// is disclosed rather than removed.
final class TagConditionRowView: NSStackView, NSTextFieldDelegate {

    struct Callbacks {
        /// A well-formed condition, ready to store.
        var changed: (TagCondition) -> Void
        /// What is wrong, ready to draw. nil clears the error.
        var invalid: (TagConditionEditor.Invalid?) -> Void
        var removed: () -> Void
    }

    let familyPopup = NSPopUpButton()
    let operatorPopup = NSPopUpButton()
    let valueField = NSTextField()
    /// The upper bound. Hidden unless the operator is `between`.
    let upperField = NSTextField()
    let hintLabel = NSTextField(labelWithString: "")
    let errorLabel = NSTextField(labelWithString: "")
    let badge = HostileTextBadge()
    let removeButton = NSButton()

    /// The controls, on one line. Internal for the same reason the controls are:
    /// the suite measures whether a hidden `upperField` really leaves the
    /// layout, and a view walk would have to guess which stack it had found.
    let controlsRow = NSStackView()

    private let callbacks: Callbacks
    private var family: String
    private var kind: TagConditionKind

    // MARK: Construction

    init(condition: TagCondition, isEditable: Bool, callbacks: Callbacks) {
        self.callbacks = callbacks
        self.family = condition.family
        self.kind = condition.kind
        super.init(frame: .zero)

        valueField.stringValue = condition.display
        upperField.stringValue = condition.operand2 ?? ""

        buildControls()
        buildLayout()

        rebuildFamilies()
        rebuildOperators()
        syncForKind()
        // The badge is raised from the STORED value too. A hostile value that
        // predates this row — or one in a rule this build cannot edit — is
        // exactly the one a reader most needs told about.
        badge.update(for: valueField.stringValue)
        showError(nil)

        setEditable(isEditable)
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) is not used") }

    private func buildControls() {
        familyPopup.target = self
        familyPopup.action = #selector(familyChanged)
        operatorPopup.target = self
        operatorPopup.action = #selector(operatorChanged)
        for popup in [familyPopup, operatorPopup] {
            popup.setContentHuggingPriority(.defaultHigh, for: .horizontal)
            popup.setContentCompressionResistancePriority(.defaultHigh, for: .horizontal)
        }

        // The fields take the slack, so the popups keep their natural width.
        valueField.placeholderString = "Value"
        upperField.placeholderString = "Upper bound"
        for field in [valueField, upperField] {
            field.delegate = self
            field.setContentHuggingPriority(.defaultLow, for: .horizontal)
        }
        valueField.setAccessibilityLabel("Condition value")
        upperField.setAccessibilityLabel("Upper bound")

        removeButton.image = NSImage(systemSymbolName: "minus.circle",
                                     accessibilityDescription: "Remove this condition")
        removeButton.bezelStyle = .accessoryBarAction
        removeButton.isBordered = false
        removeButton.target = self
        removeButton.action = #selector(removeTapped)
        removeButton.setAccessibilityLabel("Remove this condition")
        removeButton.setContentHuggingPriority(.required, for: .horizontal)

        // Both explanation labels wrap: a hint cut mid-clause explains nothing,
        // and a refusal that ends before its example is worse than none.
        for label in [hintLabel, errorLabel] {
            label.font = .preferredFont(forTextStyle: .caption1)
            label.lineBreakMode = .byWordWrapping
            label.maximumNumberOfLines = 0
            label.cell?.wraps = true
            label.isHidden = true
        }
        hintLabel.textColor = .secondaryLabelColor
        errorLabel.textColor = .systemRed
    }

    private func buildLayout() {
        controlsRow.orientation = .horizontal
        controlsRow.alignment = .centerY
        controlsRow.spacing = 6
        for control in [familyPopup, operatorPopup, valueField, badge,
                        upperField, removeButton] as [NSView] {
            controlsRow.addArrangedSubview(control)
        }

        // Both fields hug their content equally weakly, which on its own leaves
        // the solver free to hand ONE of them all the slack — measured: with
        // `between` selected the upper bound took 381pt and the value field
        // collapsed to ZERO, so the lower bound could be neither read nor
        // typed. The equal-width pin splits the slack; the floor is what stops
        // a narrow row from collapsing either field again.
        //
        // Priorities, not `required`: a container narrower than both floors
        // must degrade rather than break the layout, and the equal pin must
        // yield to the floor rather than fight it. The equal pin stays active
        // while the upper bound is hidden — harmless, because a detached
        // arranged subview is not laid out, so the solver simply matches its
        // width to the value field's and draws neither.
        let equalWidths = valueField.widthAnchor.constraint(equalTo: upperField.widthAnchor)
        equalWidths.priority = .defaultLow + 1
        equalWidths.isActive = true
        for field in [valueField, upperField] {
            let floor = field.widthAnchor.constraint(greaterThanOrEqualToConstant: 120)
            floor.priority = .defaultHigh
            floor.isActive = true
        }

        orientation = .vertical
        // `.leading` pins where a row STARTS; the span pin is what makes each
        // row the stack's own width. `.width` is silently discarded by
        // NSStackView — see NSStackView+SpanFullWidth.swift.
        alignment = .leading
        spacing = 4
        addArrangedSubview(controlsRow)
        addArrangedSubview(hintLabel)
        addArrangedSubview(errorLabel)
        spanArrangedSubviewsFullWidth()
    }

    // MARK: Enablement

    /// Greys the row, never hides it.
    ///
    /// A rule this build cannot understand must still be READABLE: an analyst
    /// has to see what it matches in order to decide whether to delete it.
    /// Hiding the controls would hide the values with them.
    ///
    /// The remove button is disabled too. Such a rule is deleted WHOLE, not
    /// condition by condition — a rule missing one condition is EASIER to
    /// satisfy than the analyst wrote, and a too-easy rule is a false match.
    private func setEditable(_ isEditable: Bool) {
        familyPopup.isEnabled = isEditable
        operatorPopup.isEnabled = isEditable
        valueField.isEnabled = isEditable
        valueField.isEditable = isEditable
        upperField.isEnabled = isEditable
        upperField.isEditable = isEditable
        removeButton.isEnabled = isEditable
    }

    // MARK: Popup contents

    /// Every family this build can describe, plus the condition's own if it is
    /// not one of them.
    ///
    /// The extra row is what stops an exotic `type:bytea` condition from
    /// displaying as `Text` — a popup that cannot show what the condition IS
    /// would be lying about stored data.
    private func rebuildFamilies() {
        var rows = TagFamilyLabel.known.map {
            PopupValueMenu.Row(display: $0.label, value: $0.family)
        }
        if !rows.contains(where: { $0.value == family }) {
            rows.append(PopupValueMenu.Row(display: TagFamilyLabel.text(for: family),
                                           value: family))
        }
        PopupValueMenu.populate(familyPopup, sentinel: nil, rows: rows)
        PopupValueMenu.selectValue(family, in: familyPopup)
    }

    /// The operators the current family offers, plus the current kind if it is
    /// not one of them — which is how a kind written by a NEWER build gets a row
    /// saying what it tests, rather than silently reading as `is`.
    private func rebuildOperators() {
        var kinds = TagConditionEditor.operators(for: family)
        if !kinds.contains(kind) { kinds.append(kind) }
        PopupValueMenu.populate(operatorPopup, sentinel: nil, rows: kinds.map {
            PopupValueMenu.Row(display: TagConditionEditor.label(for: $0, family: family),
                               value: $0.rawValue)
        })
        PopupValueMenu.selectValue(kind.rawValue, in: operatorPopup)
    }

    private func syncForKind() {
        let hint = TagConditionEditor.hint(for: kind)
        hintLabel.stringValue = hint
        // Hidden only when there is nothing to say. NOT on focus — a hint that
        // appears only while the field is being edited is one the analyst
        // cannot read while deciding what to type.
        hintLabel.isHidden = hint.isEmpty
        // NSStackView detaches a hidden arranged subview, so this removes the
        // field from the layout rather than leaving an empty slot beside every
        // operator that takes no bound.
        upperField.isHidden = !TagConditionEditor.needsSecondOperand(kind)
    }

    // MARK: Actions

    @objc private func familyChanged(_ sender: Any?) {
        guard let picked = PopupValueMenu.selectedValue(in: familyPopup) else { return }
        family = picked
        let offered = TagConditionEditor.operators(for: family)
        if !offered.contains(kind) {
            // The new family cannot host this operator, so it falls back to the
            // one that family offers first — always `exact`. Keeping the old
            // operator would leave the popup showing something the matcher
            // refuses, and a condition that saves but never matches is the
            // worst outcome available here.
            //
            // Nothing is lost silently: the popup the analyst is looking at
            // visibly changes, and the operator SURVIVES wherever the new
            // family also offers it — Number to Date & time keeps `after`,
            // which is the swap worth preserving. What the analyst TYPED is
            // never touched either way.
            kind = offered.first ?? .exact
        }
        rebuildOperators()
        syncForKind()
        validate()
    }

    @objc private func operatorChanged(_ sender: Any?) {
        guard let raw = PopupValueMenu.selectedValue(in: operatorPopup) else { return }
        kind = TagConditionKind(rawValue: raw)
        syncForKind()
        validate()
    }

    @objc private func removeTapped(_ sender: Any?) {
        callbacks.removed()
    }

    func controlTextDidChange(_ obj: Notification) {
        validate()
    }

    // MARK: Validation

    /// Re-reads the controls and tells the owner what the row now holds.
    ///
    /// The typed text goes to `TagConditionEditor` UNTOUCHED — no sanitising,
    /// no trimming — so that `display` comes back byte for byte, bidi override
    /// and all.
    private func validate() {
        badge.update(for: valueField.stringValue)
        switch TagConditionEditor.condition(family: family, kind: kind,
                                            value: valueField.stringValue,
                                            operand2: upperField.stringValue) {
        case .success(let built):
            showError(nil)
            // The clear goes first, so an owner that disables Save on `invalid`
            // has already re-enabled it by the time the condition arrives.
            callbacks.invalid(nil)
            callbacks.changed(built)
        case .failure(let why):
            showError(why)
            callbacks.invalid(why)
        }
    }

    private func showError(_ why: TagConditionEditor.Invalid?) {
        let text = why.map(Self.message(for:)) ?? ""
        errorLabel.stringValue = text
        errorLabel.isHidden = text.isEmpty
    }

    /// What to draw beside the field for a refusal.
    ///
    /// An EMPTY field draws nothing. A row the analyst has not filled in yet is
    /// not a mistake they made, and a red line under every freshly added
    /// condition is nagging rather than guidance. The owner is still told
    /// through `invalid`, so Save stays disabled — quiet in the label, loud in
    /// the callback.
    private static func message(for invalid: TagConditionEditor.Invalid) -> String {
        switch invalid {
        case .emptyValue, .emptySecondOperand: return ""
        case .unparseable(let message), .wrongOperator(let message): return message
        }
    }
}
