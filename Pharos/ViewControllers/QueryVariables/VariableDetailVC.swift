import AppKit

/// The Variable Manager's detail: everything about one variable, as a
/// Settings-style form built from the furniture in `Pharos/Settings/Furniture`:
///
/// - **Variable**: the name, the type, and the type's second control — "With
///   time zone" for a Timestamp, "Items are" for a List.
/// - **Value**: the editor the type calls for, then "Renders as", the SQL the
///   value produces (or, in red, why it produces none).
/// - **Connections**: the host's `VariableConnectionsView`, when it passes one.
/// - Delete Variable.
///
/// Edits apply live — there is no save/cancel model. Every control writes
/// straight through to `variable` and fires `onChange` on every change, with
/// one deliberate exception: the name. It is the one field with a uniqueness
/// rule another variable can break one keystroke at a time, so it commits only
/// at a "settle" point (see `commitNameIfValid`).
///
/// The two boxes whose rows depend on the type are rebuilt from scratch when
/// it changes (`rebuildVariableBox`, `rebuildValueBox`); the controls in them
/// are kept and moved into the new rows. Rebuilt rather than hidden: a hidden
/// row stays among a `SettingsGroupBox`'s arranged subviews and the box would
/// draw a separator for it.
final class VariableDetailVC: NSViewController {

    /// Fired with the updated variable on every value or type edit, and on a
    /// name edit only at a settle point.
    var onChange: ((QueryVariable) -> Void)?
    var onDelete: (() -> Void)?
    /// Escape: the host settles the edit. Refused while the name collides.
    var onBack: (() -> Void)?

    private(set) var variable: QueryVariable

    /// The Connections box's content, owned by the host (which feeds it the
    /// choices). No box when nil.
    let connectionsView: VariableConnectionsView?

    /// The Bool segments, in `VariableSubstitutor.BoolChoice.allCases` order.
    /// They are SQL values, so they are not localized.
    static let boolSegmentLabels = ["True", "False", "NULL"]

    // MARK: Controls (internal: the harness drives them)

    let nameField = NSTextField()
    let typePopup = SettingsControlFactory.popup(titles: VariableTypeFamily.allCases.map(\.displayName))
    let timeZoneSwitch = SettingsControlFactory.toggle()
    let listElementPopup = SettingsControlFactory.popup(titles: VariableListElement.allCases.map(\.displayName))

    /// Literal, Text and List.
    let textEditor = VariableGrowingTextEditor()
    var valueTextView: VariableValueTextView { textEditor.textView }
    let numberField = VariableNumberField()
    let boolControl = SettingsControlFactory.segmented(labels: VariableDetailVC.boolSegmentLabels)
    /// Date: Fixed | Today.
    let dateModeControl = SettingsControlFactory.segmented(labels: [String(localized: "Fixed"),
                                                                    String(localized: "Today")])
    /// Timestamp: Fixed | Now.
    let timestampModeControl = SettingsControlFactory.segmented(labels: [String(localized: "Fixed"),
                                                                         String(localized: "Now")])
    let dateControl = VariableDateTimeControl(kind: .date)
    let timestampControl = VariableDateTimeControl(kind: .timestamp)
    let zonePopup = NSPopUpButton(frame: .zero, pullsDown: false)
    let rendersAsLabel = VariableFormWrappingLabel(wrappingLabelWithString: "")
    let deleteButton = SettingsControlFactory.actionButton(title: String(localized: "Delete Variable"),
                                                           destructive: true)

    /// The rows the form holds now. Rebuilt with their boxes.
    private(set) var nameRow: SettingsRow?
    private(set) var valueRow: SettingsRow?
    private(set) var collisionNoticeRow: SettingsRow?
    private(set) var rendersAsRow: SettingsRow?

    private let variableBoxSlot = VariableFormSlot()
    private let valueBoxSlot = VariableFormSlot()
    /// The form's scroll view (inside the surface the boxes sit on).
    private(set) var formScrollView: NSScrollView?

    init(variable: QueryVariable, connectionsView: VariableConnectionsView? = nil) {
        self.variable = variable
        self.connectionsView = connectionsView
        super.init(nibName: nil, bundle: nil)
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) not implemented")
    }

    // MARK: - View

    override func loadView() {
        configureControls()

        var sections: [NSView] = [
            Self.section(String(localized: "Variable"), variableBoxSlot),
            Self.section(String(localized: "Value"), valueBoxSlot),
        ]
        if let connectionsView {
            connectionsView.removeFromSuperview()
            let box = SettingsGroupBox(title: String(localized: "Connections"), rows: [connectionsView])
            sections.append(Self.section(String(localized: "Connections"), box))
        }
        sections.append(SettingsFooterButtonRow(buttons: [deleteButton]))

        let scroll = SettingsFormScroll.makePane(sections: sections)
        formScrollView = scroll
        let surface = VariableFormSurfaceView()
        surface.addSubview(scroll)
        NSLayoutConstraint.activate([
            // The surface's top, not its safe area: the scroll view insets
            // itself under the toolbar (`SettingsFormScroll.make`).
            scroll.topAnchor.constraint(equalTo: surface.topAnchor),
            scroll.leadingAnchor.constraint(equalTo: surface.leadingAnchor),
            scroll.trailingAnchor.constraint(equalTo: surface.trailingAnchor),
            scroll.bottomAnchor.constraint(equalTo: surface.bottomAnchor),
        ])
        view = surface

        // Sanitised on the way in, not only on edit: `recomputeCollisionState`
        // below must see the text the field holds, and a raw `ops<U+200B>`
        // reads as `ops` but collides with nothing until the first keystroke.
        nameField.stringValue = AuthoredLabelSanitizer.sanitized(variable.name)
        isNameCollision = computeCollision()
        updateNameFieldColor()
        rebuildVariableBox()
        rebuildValueBox()
    }

    /// A section: its bold header over its box, 8 pt apart, as
    /// `SettingsFormBuilder` builds them.
    private static func section(_ title: String, _ body: NSView) -> NSView {
        let stack = NSStackView(views: [SettingsSectionHeader.make(title), body])
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = SettingsMetrics.headerToBoxGap
        stack.translatesAutoresizingMaskIntoConstraints = false
        stack.spanArrangedSubviewsFullWidth()
        return stack
    }

    private func configureControls() {
        let mono = NSFont.monospacedSystemFont(ofSize: NSFont.systemFontSize, weight: .regular)

        nameField.placeholderString = String(localized: "name")
        nameField.font = mono
        nameField.textColor = .systemIndigo
        nameField.delegate = self
        nameField.translatesAutoresizingMaskIntoConstraints = false
        nameField.widthAnchor.constraint(equalToConstant: 240).isActive = true
        nameField.setAccessibilityIdentifier("variables.name")

        typePopup.target = self
        typePopup.action = #selector(typeControlChanged(_:))
        typePopup.setAccessibilityIdentifier("variables.type")
        timeZoneSwitch.target = self
        timeZoneSwitch.action = #selector(typeControlChanged(_:))
        timeZoneSwitch.setAccessibilityIdentifier("variables.withTimeZone")
        listElementPopup.target = self
        listElementPopup.action = #selector(typeControlChanged(_:))
        listElementPopup.setAccessibilityIdentifier("variables.listElement")

        valueTextView.delegate = self
        valueTextView.setAccessibilityIdentifier("variables.value")
        valueTextView.onBacktab = { [weak self] in
            guard let self else { return }
            self.view.window?.makeFirstResponder(self.nameField)
        }
        // Through `attemptBack`, not `onBack`: Escape here must not bypass
        // the collision refusal (the editor has focus of its own).
        valueTextView.onCancel = { [weak self] in self?.attemptBack() }

        numberField.font = mono
        numberField.placeholderString = String(localized: "number")
        numberField.delegate = self
        numberField.translatesAutoresizingMaskIntoConstraints = false
        numberField.widthAnchor.constraint(equalToConstant: SettingsMetrics.textFieldWidth).isActive = true
        numberField.setAccessibilityIdentifier("variables.value.number")

        boolControl.target = self
        boolControl.action = #selector(boolChanged(_:))
        boolControl.setAccessibilityIdentifier("variables.value.bool")

        for control in [dateModeControl, timestampModeControl] {
            control.target = self
            control.action = #selector(dateModeChanged(_:))
            control.setAccessibilityIdentifier("variables.value.mode")
        }
        dateControl.textualPicker.setAccessibilityIdentifier("variables.value.date")
        timestampControl.textualPicker.setAccessibilityIdentifier("variables.value.timestamp")
        dateControl.calendarButton.setAccessibilityIdentifier("variables.value.calendar")
        timestampControl.calendarButton.setAccessibilityIdentifier("variables.value.calendar")
        dateControl.onChange = { [weak self] date in self?.dateChosen(date) }
        timestampControl.onChange = { [weak self] date in self?.dateChosen(date) }

        zonePopup.target = self
        zonePopup.action = #selector(zoneChanged(_:))
        zonePopup.translatesAutoresizingMaskIntoConstraints = false
        zonePopup.widthAnchor.constraint(greaterThanOrEqualToConstant: SettingsMetrics.controlMinWidth).isActive = true
        zonePopup.setAccessibilityIdentifier("variables.value.timeZone")

        rendersAsLabel.font = .monospacedSystemFont(ofSize: NSFont.smallSystemFontSize, weight: .regular)
        rendersAsLabel.isSelectable = true
        rendersAsLabel.maximumNumberOfLines = 6
        // Words: a token longer than the line still breaks inside itself.
        rendersAsLabel.lineBreakMode = .byWordWrapping
        rendersAsLabel.cell?.truncatesLastVisibleLine = true
        rendersAsLabel.setAccessibilityIdentifier("variables.rendersAs")

        deleteButton.target = self
        deleteButton.action = #selector(deleteTapped)
        deleteButton.setAccessibilityIdentifier("variables.delete")
    }

    // MARK: - Boxes

    /// Name, Type, and the type's second control.
    private func rebuildVariableBox() {
        if let index = VariableTypeFamily.allCases.firstIndex(of: variable.type.family) {
            typePopup.selectItem(at: index)
        }
        timeZoneSwitch.state = variable.type.withTimeZone ? .on : .off
        if let element = variable.type.listElement,
           let index = VariableListElement.allCases.firstIndex(of: element) {
            listElementPopup.selectItem(at: index)
        }

        let name = SettingsRow(title: String(localized: "Name"), control: nameField)
        nameRow = name
        var rows: [NSView] = [name, SettingsRow(title: String(localized: "Type"), control: typePopup)]
        switch variable.type.family {
        case .timestamp:
            rows.append(SettingsRow(title: String(localized: "With time zone"), control: timeZoneSwitch))
        case .list:
            rows.append(SettingsRow(title: String(localized: "Items are"), control: listElementPopup))
        default:
            break
        }
        variableBoxSlot.setContent(SettingsGroupBox(title: String(localized: "Variable"), rows: rows))
        updateDuplicationDisplay()
        view.window?.recalculateKeyViewLoop()
    }

    /// The value's editor and "Renders as" — or, while the name collides, only
    /// the collision notice: a variable that cannot be saved has no value
    /// worth editing (the name field stays editable throughout).
    private func rebuildValueBox() {
        valueRow = nil
        collisionNoticeRow = nil
        rendersAsRow = nil
        dateControl.closePopover()
        timestampControl.closePopover()

        var rows: [NSView]
        if isNameCollision {
            let notice = SettingsRow(title: Self.collisionMessage(for: collidingName), control: nil)
            notice.titleLabel.textColor = .systemRed
            notice.titleLabel.setAccessibilityIdentifier("variables.collisionNotice")
            collisionNoticeRow = notice
            rows = [notice]
        } else {
            rows = valueRows()
            let renders = SettingsRow(title: String(localized: "Renders as"), control: rendersAsLabel,
                                      placement: .below)
            // A wrapping label: it must yield its width to the row, not hold
            // its one-line width at the required priority SettingsRow sets.
            rendersAsLabel.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
            // And it spans the row. SettingsRow's own hugging (defaultHigh)
            // beats its 749 span, so the label hugged its text: after "42" it
            // was a 16 pt column (and `preferredMaxLayoutWidth` kept it
            // there), and the span, unmet, pulled the whole form — and the
            // window under it — narrower, until the sidebar grew to its
            // maximum to make up the difference.
            rendersAsLabel.setContentHuggingPriority(.defaultLow, for: .horizontal)
            rendersAsRow = renders
            rows.append(renders)
        }
        valueBoxSlot.setContent(SettingsGroupBox(title: String(localized: "Value"), rows: rows))
        valueRow?.captionLabel.setAccessibilityIdentifier("variables.value.caption")
        refreshValueDisplay()
        view.window?.recalculateKeyViewLoop()
    }

    private func valueRows() -> [NSView] {
        switch variable.type {
        case .literal, .text:
            valueTextView.pasteTransform = nil
            textEditor.placeholder = String(localized: "value")
            textEditor.setText(variable.value)
            valueTextView.setAccessibilityLabel(String(localized: "Value"))
            let row = SettingsRow(title: String(localized: "Value"), control: textEditor, placement: .below)
            valueRow = row
            return [row]

        case .textList, .numberList:
            valueTextView.pasteTransform = { [weak self] pasted, range in
                VariableListPaste.insertion(for: pasted, in: self?.valueTextView.string ?? "", replacing: range)
            }
            textEditor.placeholder = String(localized: "One item per line")
            textEditor.setText(variable.value)
            valueTextView.setAccessibilityLabel(String(localized: "Items"))
            let row = SettingsRow(title: String(localized: "Items"), control: textEditor, placement: .below)
            valueRow = row
            return [row]

        case .number:
            if numberField.stringValue != variable.value { numberField.stringValue = variable.value }
            let row = SettingsRow(title: String(localized: "Value"), control: numberField)
            valueRow = row
            return [row]

        case .bool:
            boolControl.selectedSegment = Self.boolSegmentIndex(for: variable.value) ?? -1
            let row = SettingsRow(title: String(localized: "Value"), control: boolControl)
            valueRow = row
            return [row]

        case .date, .timestamp, .timestamptz:
            let isDate = variable.type == .date
            let mode = isDate ? dateModeControl : timestampModeControl
            let relative = VariableValueRules.isRelative(variable.value, as: variable.type)
            mode.selectedSegment = relative ? 1 : 0
            let row = SettingsRow(title: String(localized: "Value"), control: mode)
            valueRow = row
            var rows: [NSView] = [row]
            guard !relative else { return rows }

            let control = isDate ? dateControl : timestampControl
            control.dateValue = pickerDate()
            rows.append(SettingsRow(title: isDate ? String(localized: "Date") : String(localized: "Date and time"),
                                    control: control))
            if variable.type == .timestamptz {
                populateZonePopup(selecting: storedZoneIdentifier)
                rows.append(SettingsRow(title: String(localized: "Time zone"), control: zonePopup))
            }
            return rows
        }
    }

    // MARK: - Value display

    /// Caption, error outline and "Renders as" for the value as it stands.
    private func refreshValueDisplay() {
        guard !isNameCollision else { return }
        switch variable.type {
        case .literal, .text:
            valueRow?.caption = VariableValuePreview.caption(for: variable.value)
            valueRow?.captionLabel.textColor = .secondaryLabelColor
        case .textList, .numberList:
            valueRow?.caption = Self.listCaption(for: variable.value, as: variable.type)
            valueRow?.captionLabel.textColor = .secondaryLabelColor
        case .number:
            let reason = VariableValueRules.render(variable.value, as: .number).reason
            numberField.showsError = reason != nil
            valueRow?.caption = reason.map(Self.invalidSentence)
            valueRow?.captionLabel.textColor = reason == nil ? .secondaryLabelColor : .systemRed
        default:
            valueRow?.caption = nil
        }
        refreshRendersAs()
    }

    private func refreshRendersAs() {
        if let problem = VariableValueRules.validate(variable.value, as: variable.type) {
            switch problem {
            case .emptyLiteral:
                rendersAsLabel.stringValue = String(localized: "Nothing: the value is empty.")
            case .invalidValue(let reason):
                rendersAsLabel.stringValue = Self.invalidSentence(reason)
            }
            rendersAsLabel.textColor = .systemRed
            return
        }
        let sql = VariableValueRules.render(variable.value, as: variable.type).sql ?? ""
        rendersAsLabel.stringValue = Self.displayedSQL(sql)
        rendersAsLabel.textColor = .labelColor
    }

    /// "The value is <reason>." — the reasons are written to follow "the
    /// value is" (`VariableValueRules.Rendering`).
    static func invalidSentence(_ reason: String) -> String {
        String(localized: "The value is \(reason).")
    }

    /// A value problem as the Manager says it. Not `ValueProblem.message`:
    /// that says "Referenced in the query but…", and here every variable is
    /// checked, used or not.
    static func problemSentence(_ problem: VariableSubstitutor.ValueProblem) -> String {
        switch problem {
        case .emptyLiteral: return String(localized: "Nothing: the value is empty.")
        case .invalidValue(let reason): return invalidSentence(reason)
        }
    }

    /// The SQL as shown: hostile scalars disclosed, and capped, so a list of
    /// thousands of items does not lay out a label of megabytes.
    static func displayedSQL(_ sql: String) -> String {
        let limit = 2_000
        let shown = sql.count > limit ? String(sql.prefix(limit)) + "…" : sql
        return DisplayEscape.escapedMultiline(shown)
    }

    /// "12 items", and for a number list "12 items · 1 not a number (line 4)".
    static func listCaption(for value: String, as type: VariableType) -> String {
        let count = VariableValueRules.listItems(in: value).count
        var caption = CountedNounText.phrase(count, "item")
        guard type == .numberList else { return caption }
        let bad = VariableValueRules.invalidNumberItems(in: value)
        if bad.count == 1 {
            caption += " · " + String(localized: "1 not a number (line \(bad[0].line))")
        } else if bad.count > 1 {
            var lines = bad.prefix(3).map { String($0.line) }.joined(separator: ", ")
            if bad.count > 3 { lines += ", …" }
            caption += " · " + String(localized: "\(bad.count) not numbers (lines \(lines))")
        }
        return caption
    }

    // MARK: - Dates

    private static let utc = VariableDateTimeControl.utc

    /// What the picker shows: the stored fields, bound in UTC (see
    /// `VariableDateTimeControl`). A zoned timestamp shows its wall-clock time
    /// in its own zone. A relative or broken value shows now, here — and is
    /// not written until the user picks.
    private func pickerDate() -> Date {
        let value = variable.value
        switch variable.type {
        case .date, .timestamp:
            if let fixed = VariableValueRules.dateTime(from: value, as: variable.type) { return fixed.date }
        case .timestamptz:
            if let fixed = VariableValueRules.dateTime(from: value, as: .timestamptz) {
                let wallClock = VariableValueRules.format(fixed.date, timeZone: fixed.timeZone, as: .timestamp)
                if let civil = VariableValueRules.dateTime(from: wallClock, as: .timestamp) { return civil.date }
            }
        default:
            break
        }
        let type: VariableType = variable.type == .date ? .date : .timestamp
        let here = VariableValueRules.format(Date(), timeZone: .current, as: type)
        return VariableValueRules.dateTime(from: here, as: type)?.date ?? Date()
    }

    /// The zone a zoned timestamp is written in: its last word when that
    /// names a zone, else this Mac's zone.
    private var storedZoneIdentifier: String {
        let words = variable.value.trimmingCharacters(in: .whitespacesAndNewlines).split(whereSeparator: \.isWhitespace)
        if let last = words.last.map(String.init), words.count > 1, TimeZone(identifier: last) != nil { return last }
        return TimeZone.current.identifier
    }

    private var selectedZoneIdentifier: String {
        zonePopup.selectedItem?.representedObject as? String ?? storedZoneIdentifier
    }

    /// UTC, this Mac's zone, a separator, then every zone. Items are added
    /// one by one, never with `addItem(withTitle:)`, which deletes an item
    /// that has the same title (`PopupValueMenu`).
    private func populateZonePopup(selecting id: String) {
        let groups = TimeZoneChoices.groups(selected: id)
        let menu = NSMenu()
        func add(_ zone: String) {
            let item = NSMenuItem(title: zone, action: nil, keyEquivalent: "")
            item.representedObject = zone
            menu.addItem(item)
        }
        groups.pinned.forEach(add)
        menu.addItem(.separator())
        groups.all.forEach(add)
        zonePopup.menu = menu
        if let item = menu.items.first(where: { ($0.representedObject as? String) == id }) {
            zonePopup.select(item)
        }
    }

    /// The value for a fixed date picked in either picker.
    private func fixedValue(for date: Date) -> String {
        switch variable.type {
        case .timestamptz:
            return VariableValueRules.format(date, timeZone: Self.utc, zoneIdentifier: selectedZoneIdentifier,
                                             as: .timestamptz)
        default:
            return VariableValueRules.format(date, timeZone: Self.utc, as: variable.type)
        }
    }

    /// Now, here, as a fixed value of the current type.
    private func fixedNow() -> String {
        let now = Date()
        if variable.type == .timestamptz {
            return VariableValueRules.format(now, timeZone: .current, zoneIdentifier: TimeZone.current.identifier,
                                             as: .timestamptz)
        }
        return VariableValueRules.format(now, timeZone: .current, as: variable.type)
    }

    // MARK: - API

    /// Move focus to the name field — used right after + creates a variable.
    func focusNameField() {
        view.window?.makeFirstResponder(nameField)
    }

    /// Move focus to the value's editor — used right after a `{{` token makes
    /// a variable, whose name is already typed.
    func focusValueField() {
        switch variable.type {
        case .literal, .text, .textList, .numberList: view.window?.makeFirstResponder(valueTextView)
        case .number: view.window?.makeFirstResponder(numberField)
        default: break
        }
    }

    /// Apply the state the host resolved for this variable (the same
    /// `rowStates` pass the sidebar uses, so the two cannot disagree): red for
    /// a value that cannot render, and for legacy duplicate data a note on an
    /// inert `.shadowed` row.
    func setState(_ state: VariableSubstitutor.RowState?) {
        lastRowState = state
        updateNameFieldColor()
        updateDuplicationDisplay()
    }

    /// Another surface changed this variable in the store. Adopted only while
    /// the user is not typing in the form: a republish must not eat the edit
    /// in progress (lessons, 2026-09-16). The user's next keystroke writes the
    /// whole variable back anyway.
    func adoptExternalChange(_ incoming: QueryVariable) {
        var mine = variable
        mine.connectionIds = incoming.connectionIds
        guard incoming != mine, isViewLoaded, !isEditingText else { return }
        let nameChanged = incoming.name != variable.name
        variable.name = incoming.name
        variable.value = incoming.value
        variable.type = incoming.type
        variable.connectionIds = incoming.connectionIds
        if nameChanged { nameField.stringValue = AuthoredLabelSanitizer.sanitized(incoming.name) }
        isNameCollision = computeCollision()
        updateNameFieldColor()
        rebuildVariableBox()
        rebuildValueBox()
    }

    /// True while a text control of this form holds the keyboard (a field's
    /// editor is its subview while it edits).
    var isEditingText: Bool {
        guard let responder = view.window?.firstResponder as? NSView, responder is NSText else { return false }
        return responder.isDescendant(of: view)
    }

    // MARK: - Actions

    @objc private func deleteTapped() { onDelete?() }

    @objc private func typeControlChanged(_ sender: Any?) {
        // A settle point: the user has moved on to another control.
        commitNameIfValid()
        let index = typePopup.indexOfSelectedItem
        guard VariableTypeFamily.allCases.indices.contains(index) else { return }
        let elementIndex = listElementPopup.indexOfSelectedItem
        let element = VariableListElement.allCases.indices.contains(elementIndex)
            ? VariableListElement.allCases[elementIndex] : .text
        let type = VariableType.make(family: VariableTypeFamily.allCases[index],
                                     withTimeZone: timeZoneSwitch.state == .on, listElement: element)
        applyType(type)
    }

    /// Switch to `type`, converting the value (`VariableValueRules.convert`).
    func applyType(_ type: VariableType) {
        guard type != variable.type else { return }
        variable.value = VariableValueRules.convert(variable.value, from: variable.type, to: type)
        variable.type = type
        rebuildVariableBox()
        rebuildValueBox()
        onChange?(variable)
    }

    @objc private func boolChanged(_ sender: NSSegmentedControl) {
        let index = sender.selectedSegment
        guard VariableSubstitutor.BoolChoice.allCases.indices.contains(index) else { return }
        variable.value = VariableSubstitutor.BoolChoice.allCases[index].rawValue
        refreshValueDisplay()
        onChange?(variable)
    }

    /// Fixed | Today (or Now). Fixed starts from now, here, when the value was
    /// relative; Today writes the keyword.
    @objc private func dateModeChanged(_ sender: NSSegmentedControl) {
        if sender.selectedSegment == 1, let keyword = VariableValueRules.relativeKeyword(for: variable.type) {
            variable.value = keyword
        } else if sender.selectedSegment == 0, VariableValueRules.isRelative(variable.value, as: variable.type) {
            variable.value = fixedNow()
        } else {
            return
        }
        rebuildValueBox()
        onChange?(variable)
    }

    private func dateChosen(_ date: Date) {
        variable.value = fixedValue(for: date)
        refreshValueDisplay()
        onChange?(variable)
    }

    /// A new zone keeps the wall-clock time and changes the zone it is in.
    @objc private func zoneChanged(_ sender: NSPopUpButton) {
        variable.value = fixedValue(for: timestampControl.dateValue)
        refreshValueDisplay()
        onChange?(variable)
    }

    /// Escape with no text control focused.
    override func cancelOperation(_ sender: Any?) { attemptBack() }

    // MARK: - Name collision refusal

    /// Sibling variables' trimmed, non-empty names (this one's excluded),
    /// supplied by the host, which can see the whole list. Re-checks the
    /// collision on every set once the view exists; before that, `loadView`
    /// checks it, so a COMMITTED name that already collides (a duplicate pair
    /// from before the refusal rule) shows the notice at once.
    var otherNames: Set<String> = [] {
        didSet {
            guard isViewLoaded else { return }
            recomputeCollisionState()
        }
    }

    /// Whether the name field's DISPLAYED text collides with `otherNames` now.
    /// Live: set by the keystroke that collides, cleared by the one that does
    /// not. Independent of `lastRowState.duplication`, which reflects the
    /// committed model only.
    private(set) var isNameCollision = false

    private var lastRowState: VariableSubstitutor.RowState?

    private func computeCollision() -> Bool {
        let trimmed = collidingName
        return !trimmed.isEmpty && otherNames.contains(trimmed)
    }

    private func recomputeCollisionState() {
        let was = isNameCollision
        isNameCollision = computeCollision()
        updateNameFieldColor()
        if was != isNameCollision {
            rebuildValueBox()
        } else if isNameCollision {
            collisionNoticeRow?.titleLabel.stringValue = Self.collisionMessage(for: collidingName)
        }
    }

    /// Red for a live collision (an edit refused right now), else red for the
    /// committed value's problem, else the token indigo.
    private func updateNameFieldColor() {
        if isNameCollision {
            nameField.textColor = .systemRed
            nameField.toolTip = Self.collisionMessage(for: collidingName)
        } else {
            let problem = lastRowState?.problem
            nameField.textColor = problem == nil ? .systemIndigo : .systemRed
            nameField.toolTip = problem.map(Self.problemSentence)
        }
    }

    private var collidingName: String {
        nameField.stringValue.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    /// An instruction, not only an observation: while it shows, the name also
    /// blocks leaving (`attemptBack`), so it says what to do.
    static func collisionMessage(for name: String) -> String {
        String(localized: "A variable named \(name.debugDescription) already exists. Choose a different name.")
    }

    /// The Name row's caption: only the committed `.shadowed` note for legacy
    /// duplicate data (a row that has always been inert). `.overriding` says
    /// nothing — typing your way into a duplicate is refused before it reaches
    /// the model.
    private func updateDuplicationDisplay() {
        nameRow?.caption = lastRowState?.duplication == .shadowed
            ? String(localized: "Redefined below — this row has no effect.")
            : nil
    }

    /// The one way off this form that the user can be refused (Escape, in
    /// any of its three places). While the displayed name collides, leaving
    /// is refused and focus goes back to the name. Otherwise it is a settle
    /// point: commit what the field shows, then leave.
    ///
    /// (It once REVERTED the field instead of refusing. That mangled input:
    /// renaming to an existing "seed_list" walks through "s" … "seed_lis",
    /// and a revert after the colliding keystroke committed "seed_lis".)
    private func attemptBack() {
        guard !isNameCollision else {
            view.window?.makeFirstResponder(nameField)
            return
        }
        commitNameIfValid()
        onBack?()
    }

    /// Commit what the name field shows — only at a settle point (Return,
    /// the field losing focus, a type change, Escape, or a dismissal the form
    /// cannot refuse), never per keystroke. Every prefix typed on the way to a
    /// colliding name is unique on its own, so committing per keystroke would
    /// write those prefixes to the model before the collision was ever
    /// reached, and any door that skipped the refusal (a row switch) left the
    /// variable renamed to a prefix the user never meant.
    ///
    /// Commits the TRIMMED name: every collision rule trims, so an untrimmed
    /// commit ("ip ") would put a name in the model no `{{token}}` can reach,
    /// and refuse the correct "ip" elsewhere as a duplicate. A name of spaces
    /// commits as "" and is pruned like any abandoned row. A settle point
    /// reached with nothing changed fires nothing.
    private func commitNameIfValid() {
        guard !isNameCollision else { return }
        let typed = nameField.stringValue.trimmingCharacters(in: .whitespacesAndNewlines)
        guard typed != variable.name else { return }
        variable.name = typed
        onChange?(variable)
    }

    /// The settle point for a dismissal the form cannot refuse (another row
    /// chosen, the window closing): a valid name commits, a colliding one is
    /// dropped. The host calls this BEFORE reading `variable` for its
    /// abandoned-row check, so a new row that was given a name is kept.
    func settleForDismissal() {
        commitNameIfValid()
    }

    // MARK: - Bool

    /// The segment for a stored value, by asking the rules which of Bool's
    /// three values it means — the accepted spellings live there only. Nil
    /// (no segment) for a value that means none of them: an unresolved value
    /// must look as unresolved as the warning says it is.
    static func boolSegmentIndex(for value: String) -> Int? {
        guard let choice = VariableValueRules.boolChoice(for: value) else { return nil }
        return VariableSubstitutor.BoolChoice.allCases.firstIndex(of: choice)
    }
}

// MARK: - Text delegates

extension VariableDetailVC: NSTextFieldDelegate {

    func controlTextDidChange(_ obj: Notification) {
        if (obj.object as? NSTextField) === nameField {
            // Sanitised BEFORE the collision check. A name is a `{{token}}`
            // key, and the token grammar is `[A-Za-z0-9_]`: every scalar this
            // removes was already outside it, so it cannot break a name that
            // worked — only make an unreferenceable one behave as it looks.
            nameField.sanitizeAsAuthoredLabel()
            recomputeCollisionState()
        } else if (obj.object as? NSTextField) === numberField {
            // Live: a bad value keeps its text, and the outline and caption
            // say why.
            variable.value = numberField.stringValue
            refreshValueDisplay()
            onChange?(variable)
        }
    }

    /// The name field losing focus (Tab, a click elsewhere, Return) is a
    /// settle point.
    func controlTextDidEndEditing(_ obj: Notification) {
        if (obj.object as? NSTextField) === nameField { commitNameIfValid() }
    }

    /// Escape goes through `attemptBack` (refused while the name collides).
    /// Return in the name field commits it and is swallowed: a single-line
    /// field has nowhere for a newline to go.
    func control(_ control: NSControl, textView: NSTextView, doCommandBy commandSelector: Selector) -> Bool {
        if commandSelector == #selector(NSResponder.cancelOperation(_:)) {
            attemptBack()
            return true
        }
        if control === nameField, commandSelector == #selector(NSResponder.insertNewline(_:)) {
            commitNameIfValid()
            return true
        }
        return false
    }
}

extension VariableDetailVC: NSTextViewDelegate {
    func textDidChange(_ notification: Notification) {
        variable.value = valueTextView.string
        refreshValueDisplay()
        onChange?(variable)
    }
}

// MARK: - Form pieces

/// The detail's surface: the grey the group boxes sit on
/// (`SettingsMetrics.paneSurfaceColor`). Drawn, so the dynamic colour
/// resolves for the appearance in force when it draws.
final class VariableFormSurfaceView: NSView {
    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        translatesAutoresizingMaskIntoConstraints = false
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("VariableFormSurfaceView is built in code") }

    override var isFlipped: Bool { true }

    override func draw(_ dirtyRect: NSRect) {
        SettingsMetrics.paneSurfaceColor.setFill()
        dirtyRect.fill()
    }

    override func viewDidChangeEffectiveAppearance() {
        super.viewDidChangeEffectiveAppearance()
        needsDisplay = true
    }
}

/// A fixed place in the form whose one child is swapped: a box rebuilt for a
/// new type goes where the old one was.
final class VariableFormSlot: NSView {
    private(set) var content: NSView?

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        translatesAutoresizingMaskIntoConstraints = false
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("VariableFormSlot is built in code") }

    func setContent(_ view: NSView) {
        content?.removeFromSuperview()
        content = view
        view.translatesAutoresizingMaskIntoConstraints = false
        addSubview(view)
        NSLayoutConstraint.activate([
            view.topAnchor.constraint(equalTo: topAnchor),
            view.leadingAnchor.constraint(equalTo: leadingAnchor),
            view.trailingAnchor.constraint(equalTo: trailingAnchor),
            view.bottomAnchor.constraint(equalTo: bottomAnchor),
        ])
    }
}

/// A wrapping label that reports its height for the width it was given,
/// not its one-line width: it feeds its own width to
/// `preferredMaxLayoutWidth` after each pass, as `SettingsRow` does for its
/// labels.
final class VariableFormWrappingLabel: NSTextField {
    override func layout() {
        super.layout()
        let width = bounds.width
        if width > 0, preferredMaxLayoutWidth != width { preferredMaxLayoutWidth = width }
    }
}
