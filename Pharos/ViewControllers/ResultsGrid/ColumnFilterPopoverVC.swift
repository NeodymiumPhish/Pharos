import AppKit

// MARK: - Column Filter Popover Delegate

protocol ColumnFilterPopoverDelegate: AnyObject {
    func columnFilterPopover(_ popover: ColumnFilterPopoverVC, didApplyFilter filter: ColumnFilter)
    func columnFilterPopover(_ popover: ColumnFilterPopoverVC, didClearFilterForColumn column: String)
}

// MARK: - Temporal Sub-Type

private enum TemporalSubType {
    case date
    case time
    case timestamp
    case interval
    case none
}

// MARK: - ColumnFilterPopoverVC

class ColumnFilterPopoverVC: NSViewController {

    private let columnName: String
    private let displayName: String
    private let category: PGTypeCategory
    private let dataType: String
    private let existingFilter: ColumnFilter?
    private let referenceSize: CGSize

    // Value picker (checklist)
    private let checklistValues: [String]     // distinct values + optional blanks sentinel
    private let searchField = NSSearchField()
    private let valueList = FilterValueListView()
    // Advanced operator UI lives in this container, collapsed under a disclosure button
    private let advancedContainer = NSStackView()
    private let advancedDisclosure = NSButton()

    weak var filterDelegate: ColumnFilterPopoverDelegate?

    private var operators: [FilterOperator] = []
    private var temporalSubType: TemporalSubType = .none

    // Main stack
    private let stackView = NSStackView()
    /// Current popover content width. Set by auto-size on open and by drag-resize.
    private var currentWidth: CGFloat = FilterPopoverSizing.minWidth
    /// The presenting popover — used only to disable animation during drag.
    weak var hostPopover: NSPopover?
    /// Width constraints on the advanced-mode input fields; their constant tracks
    /// the popover width so those fields fill it (left-aligned) as it resizes.
    private var advancedFieldWidthConstraints: [NSLayoutConstraint] = []

    // Fixed controls (always in stack)
    private let headerLabel = NSTextField(labelWithString: "")
    private let operatorPopup = NSPopUpButton()

    // Dynamic value area — swapped in/out of stack
    private var currentValueViews: [NSView] = []

    // Standard text fields
    private let valueField = NSTextField()
    private let value2Field = NSTextField()

    // Date pickers — calendar for date portion, stepper for time portion
    private let datePicker = NSDatePicker()       // calendar style (date)
    private let timePicker = NSTextField()         // time text field for timestamp
    private let datePicker2 = NSDatePicker()       // calendar style (date) — for "between"
    private let timePicker2 = NSTextField()        // time text field — for "between"

    // Token field for multi-value
    private let tokenField = NSTokenField()

    // Interval fields (d/h/m/s)
    private let intervalDays = NSTextField()
    private let intervalHours = NSTextField()
    private let intervalMinutes = NSTextField()
    private let intervalSeconds = NSTextField()
    private let interval2Days = NSTextField()
    private let interval2Hours = NSTextField()
    private let interval2Minutes = NSTextField()
    private let interval2Seconds = NSTextField()

    // Buttons
    private let applyButton = NSButton(title: "Apply", target: nil, action: nil)
    private let clearButton = NSButton(title: "Clear", target: nil, action: nil)

    init(columnName: String, displayName: String, category: PGTypeCategory, dataType: String,
         existingFilter: ColumnFilter?, distinctValues: [String], hasBlanks: Bool,
         referenceSize: CGSize) {
        self.columnName = columnName
        self.displayName = displayName
        self.category = category
        self.dataType = dataType
        self.existingFilter = existingFilter
        self.checklistValues = distinctValues + (hasBlanks ? [ColumnFilter.blanksSentinel] : [])
        self.referenceSize = referenceSize
        super.init(nibName: nil, bundle: nil)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError() }

    override func loadView() {
        let container = NSView()
        self.view = container

        temporalSubType = detectTemporalSubType(dataType)
        operators = FilterOperator.operators(for: category)

        // Stack view setup
        stackView.orientation = .vertical
        stackView.alignment = .width
        stackView.spacing = 8
        stackView.edgeInsets = NSEdgeInsets(top: 12, left: 12, bottom: 12, right: 12)
        stackView.translatesAutoresizingMaskIntoConstraints = false

        container.addSubview(stackView)
        NSLayoutConstraint.activate([
            stackView.topAnchor.constraint(equalTo: container.topAnchor),
            stackView.leadingAnchor.constraint(equalTo: container.leadingAnchor),
            stackView.trailingAnchor.constraint(equalTo: container.trailingAnchor),
            stackView.bottomAnchor.constraint(equalTo: container.bottomAnchor),
        ])

        // Header
        headerLabel.stringValue = "Filter: \(displayName)"
        headerLabel.font = .systemFont(ofSize: 12, weight: .semibold)
        headerLabel.setContentHuggingPriority(.required, for: .vertical)

        // Operator popup
        operatorPopup.font = .systemFont(ofSize: 12)
        operatorPopup.removeAllItems()
        for op in operators {
            operatorPopup.addItem(withTitle: op.label)
        }
        operatorPopup.target = self
        operatorPopup.action = #selector(operatorChanged)

        // Value field
        configureTextField(valueField, placeholder: "Value")
        configureTextField(value2Field, placeholder: "Value 2")

        // Date pickers
        configureDatePicker(datePicker)
        configureDatePicker(datePicker2)

        // Time text fields (for timestamp: calendar + time field)
        configureTimePicker(timePicker, placeholder: "HH:MM:SS")
        configureTimePicker(timePicker2, placeholder: "HH:MM:SS")

        // Token field
        tokenField.font = .monospacedSystemFont(ofSize: 12, weight: .regular)
        tokenField.placeholderString = "Enter values, press Enter to add"
        tokenField.tokenizingCharacterSet = CharacterSet(charactersIn: ",\n")

        // Interval fields
        configureIntervalField(intervalDays, placeholder: "0")
        configureIntervalField(intervalHours, placeholder: "0")
        configureIntervalField(intervalMinutes, placeholder: "0")
        configureIntervalField(intervalSeconds, placeholder: "0")
        configureIntervalField(interval2Days, placeholder: "0")
        configureIntervalField(interval2Hours, placeholder: "0")
        configureIntervalField(interval2Minutes, placeholder: "0")
        configureIntervalField(interval2Seconds, placeholder: "0")

        // Buttons
        applyButton.bezelStyle = .rounded
        applyButton.keyEquivalent = "\r"
        applyButton.target = self
        applyButton.action = #selector(applyFilter)

        clearButton.bezelStyle = .rounded
        clearButton.target = self
        clearButton.action = #selector(clearFilter)

        let buttonRow = NSStackView(views: [clearButton, NSView(), applyButton])
        buttonRow.orientation = .horizontal
        buttonRow.distribution = .fill

        // Search field above the checklist
        searchField.placeholderString = "Search"
        searchField.font = .systemFont(ofSize: 12)
        searchField.target = self
        searchField.action = #selector(searchChanged)
        searchField.sendsSearchStringImmediately = true

        // Checklist
        valueList.onSelectionChanged = { [weak self] in self?.updateApplyEnabled() }

        // Advanced operator container (operator popup first, then dynamic value views).
        // Left-aligned so the controls line up with the rest of the popover; the
        // text-entry controls get an explicit width (below) that fills the popover.
        advancedContainer.orientation = .vertical
        advancedContainer.alignment = .leading
        advancedContainer.spacing = 8
        advancedContainer.addArrangedSubview(operatorPopup)

        // These advanced input fields fill the popover width (left-aligned) and grow
        // with it when resized; the calendar/interval rows keep their intrinsic size.
        for field in [operatorPopup, valueField, value2Field, tokenField, timePicker, timePicker2] as [NSView] {
            let c = field.widthAnchor.constraint(equalToConstant: FilterPopoverSizing.minWidth - 24)
            c.isActive = true
            advancedFieldWidthConstraints.append(c)
        }

        // Disclosure header for advanced operator UI
        advancedDisclosure.setButtonType(.pushOnPushOff)
        advancedDisclosure.bezelStyle = .disclosure
        advancedDisclosure.title = ""
        advancedDisclosure.state = .off
        advancedDisclosure.target = self
        advancedDisclosure.action = #selector(toggleAdvanced)
        let advancedLabel = NSTextField(labelWithString: "Advanced text filter")
        advancedLabel.font = .systemFont(ofSize: 11)
        advancedLabel.textColor = .secondaryLabelColor
        advancedLabel.addGestureRecognizer(
            NSClickGestureRecognizer(target: self, action: #selector(advancedLabelClicked))
        )
        let advancedHeader = NSStackView(views: [advancedDisclosure, advancedLabel])
        advancedHeader.orientation = .horizontal
        advancedHeader.spacing = 4

        // Assemble main stack: header, search, checklist, disclosure header, advanced, buttons
        stackView.addArrangedSubview(headerLabel)
        stackView.addArrangedSubview(searchField)
        stackView.addArrangedSubview(valueList)
        stackView.addArrangedSubview(advancedHeader)
        stackView.addArrangedSubview(advancedContainer)
        stackView.addArrangedSubview(buttonRow)

        advancedContainer.isHidden = true   // collapsed by default

        // Determine initial mode + checklist state from the existing filter.
        let allValues = Set(checklistValues)
        if let existing = existingFilter, existing.op == .isAnyOf {
            // Checklist mode: restore checked values.
            valueList.setValues(checklistValues, checked: Set(existing.values ?? []))
        } else if let existing = existingFilter, let idx = operators.firstIndex(of: existing.op) {
            // Advanced operator was active: all checked in the list, restore + expand advanced UI.
            valueList.setValues(checklistValues, checked: allValues)
            operatorPopup.selectItem(at: idx)
            restoreExistingFilter(existing)
            advancedDisclosure.state = .on
            advancedContainer.isHidden = false
        } else {
            // No filter: everything checked.
            valueList.setValues(checklistValues, checked: allValues)
        }

        autoSizeWidth()
        updateValueArea()
        updateApplyEnabled()

        // Bottom-right resize grip: widen the popover and grow the value list.
        let grip = ResizeGripView()
        grip.translatesAutoresizingMaskIntoConstraints = false
        container.addSubview(grip)   // added last → sits above the stack
        NSLayoutConstraint.activate([
            grip.trailingAnchor.constraint(equalTo: container.trailingAnchor, constant: -2),
            grip.bottomAnchor.constraint(equalTo: container.bottomAnchor, constant: -2),
            grip.widthAnchor.constraint(equalToConstant: 14),
            grip.heightAnchor.constraint(equalToConstant: 14),
        ])

        var dragStartWidth: CGFloat = 0
        var dragStartListHeight: CGFloat = 0
        grip.onDragBegan = { [weak self] in
            guard let self else { return }
            dragStartWidth = self.currentWidth
            dragStartListHeight = self.valueList.listHeight
            self.hostPopover?.animates = false
        }
        grip.onDrag = { [weak self] dx, dy in
            guard let self else { return }
            self.currentWidth = FilterPopoverSizing.clampWidth(
                dragStartWidth + dx, referenceWidth: self.referenceSize.width)
            let h = FilterPopoverSizing.clampListHeight(
                dragStartListHeight + dy, referenceHeight: self.referenceSize.height)
            self.valueList.setListHeight(h)
            self.recalculateSize()
        }
        grip.onDragEnded = { [weak self] in
            self?.hostPopover?.animates = true
        }
    }

    // MARK: - Actions

    @objc private func toggleAdvanced() {
        advancedContainer.isHidden = (advancedDisclosure.state != .on)
        updateApplyEnabled()
        recalculateSize()
    }

    @objc private func advancedLabelClicked() {
        // Clicking the label flips the disclosure (which doesn't auto-toggle for
        // a gesture), then runs the same show/hide logic.
        advancedDisclosure.state = (advancedDisclosure.state == .on) ? .off : .on
        toggleAdvanced()
    }

    @objc private func operatorChanged() {
        updateValueArea()
        updateApplyEnabled()
    }

    @objc private func searchChanged() {
        valueList.applySearch(searchField.stringValue)
    }

    /// Apply enabled unless the checklist has zero checked AND advanced isn't valid.
    private func updateApplyEnabled() {
        if buildAdvancedFilter() != nil {
            applyButton.isEnabled = true
        } else {
            applyButton.isEnabled = !valueList.checkedValues.isEmpty
        }
    }

    @objc private func applyFilter() {
        // Advanced text filter wins only when it forms a valid operator filter.
        if let advanced = buildAdvancedFilter() {
            filterDelegate?.columnFilterPopover(self, didApplyFilter: advanced)
            dismiss(nil)
            return
        }

        // Checklist mode.
        let allValues = Set(checklistValues)
        let checked = valueList.checkedValues
        if checked.isEmpty { return }   // Apply is disabled in this state anyway
        if checked == allValues {
            // Everything checked → no effective filter.
            filterDelegate?.columnFilterPopover(self, didClearFilterForColumn: columnName)
        } else {
            let filter = ColumnFilter(
                columnName: columnName, op: .isAnyOf, value: "",
                value2: nil, values: Array(checked), dataType: dataType
            )
            filterDelegate?.columnFilterPopover(self, didApplyFilter: filter)
        }
        dismiss(nil)
    }

    /// Builds a `ColumnFilter` from the advanced operator UI, or `nil` if the
    /// advanced section is collapsed (`advancedIsActive` false) or not validly
    /// populated — so Apply falls through to checklist mode.
    private func buildAdvancedFilter() -> ColumnFilter? {
        guard advancedIsActive, let op = selectedOperator() else { return nil }

        var value = ""
        var value2: String? = nil
        var values: [String]? = nil

        if op.needsMultiValue {
            let tokens = (tokenField.objectValue as? [String]) ?? []
            guard !tokens.isEmpty else { return nil }
            values = tokens
        } else if op.needsValue {
            if temporalSubType == .interval {
                value = intervalToFilterValue(intervalDays, intervalHours, intervalMinutes, intervalSeconds)
                if op.needsSecondValue {
                    value2 = intervalToFilterValue(interval2Days, interval2Hours, interval2Minutes, interval2Seconds)
                }
            } else if temporalSubType != .none {
                value = datePickerToFilterValue(datePicker, timeField: timePicker)
                if op.needsSecondValue {
                    value2 = datePickerToFilterValue(datePicker2, timeField: timePicker2)
                }
            } else {
                value = valueField.stringValue
                if op.needsSecondValue {
                    value2 = value2Field.stringValue
                }
            }
            guard !value.isEmpty else { return nil }
            if op.needsSecondValue, (value2?.isEmpty ?? true) { return nil }
        }

        return ColumnFilter(
            columnName: columnName, op: op, value: value,
            value2: value2, values: values, dataType: dataType
        )
    }

    /// The advanced operator UI is considered for Apply only while expanded.
    private var advancedIsActive: Bool { advancedDisclosure.state == .on }

    @objc private func clearFilter() {
        filterDelegate?.columnFilterPopover(self, didClearFilterForColumn: columnName)
        resetControls()
    }

    /// Resets every popover control to the no-filter default: checklist all
    /// checked, search empty, Advanced collapsed with its operator/value inputs
    /// cleared. Leaves the popover open so the cleared state is visible.
    private func resetControls() {
        // Checklist + search (reset the search query first so setValues doesn't
        // re-apply a stale filter).
        searchField.stringValue = ""
        valueList.applySearch("")
        valueList.setValues(checklistValues, checked: Set(checklistValues))

        // Advanced: collapse and reset every input.
        advancedDisclosure.state = .off
        advancedContainer.isHidden = true
        if !operators.isEmpty { operatorPopup.selectItem(at: 0) }
        valueField.stringValue = ""
        value2Field.stringValue = ""
        tokenField.objectValue = []
        timePicker.stringValue = ""
        timePicker2.stringValue = ""
        datePicker.dateValue = Date()
        datePicker2.dateValue = Date()
        for f in [intervalDays, intervalHours, intervalMinutes, intervalSeconds,
                  interval2Days, interval2Hours, interval2Minutes, interval2Seconds] {
            f.stringValue = ""
        }

        updateValueArea()       // rebuild the value area for the reset operator
        updateApplyEnabled()
        recalculateSize()
    }

    // MARK: - Value Area Management

    private func updateValueArea() {
        // Remove existing dynamic value views from advancedContainer
        for v in currentValueViews {
            advancedContainer.removeArrangedSubview(v)
            v.removeFromSuperview()
        }
        currentValueViews.removeAll()

        guard let op = selectedOperator() else {
            recalculateSize()
            return
        }

        // Insert value views into the advanced container, after the operator popup.
        let insertIndex = advancedContainer.arrangedSubviews.count

        if op.needsMultiValue {
            // Token field for containsAnyOf
            advancedContainer.insertArrangedSubview(tokenField, at: insertIndex)
            currentValueViews = [tokenField]
        } else if op.needsValue {
            if temporalSubType == .interval {
                let row1 = makeIntervalRow(dField: intervalDays, hField: intervalHours,
                                            mField: intervalMinutes, sField: intervalSeconds)
                advancedContainer.insertArrangedSubview(row1, at: insertIndex)
                currentValueViews = [row1]

                if op.needsSecondValue {
                    let andLabel = NSTextField(labelWithString: "and")
                    andLabel.font = .systemFont(ofSize: 11)
                    andLabel.textColor = .secondaryLabelColor
                    let row2 = makeIntervalRow(dField: interval2Days, hField: interval2Hours,
                                                mField: interval2Minutes, sField: interval2Seconds)
                    let idx = insertIndex + 1
                    advancedContainer.insertArrangedSubview(andLabel, at: idx)
                    advancedContainer.insertArrangedSubview(row2, at: idx + 1)
                    currentValueViews.append(contentsOf: [andLabel, row2])
                }
            } else if temporalSubType != .none {
                advancedContainer.insertArrangedSubview(datePicker, at: insertIndex)
                currentValueViews = [datePicker]

                // For timestamps, add a time text field below the calendar
                if temporalSubType == .timestamp {
                    advancedContainer.insertArrangedSubview(timePicker, at: insertIndex + 1)
                    currentValueViews.append(timePicker)
                }

                if op.needsSecondValue {
                    let andLabel = NSTextField(labelWithString: "and")
                    andLabel.font = .systemFont(ofSize: 11)
                    andLabel.textColor = .secondaryLabelColor
                    let idx = insertIndex + currentValueViews.count
                    advancedContainer.insertArrangedSubview(andLabel, at: idx)
                    advancedContainer.insertArrangedSubview(datePicker2, at: idx + 1)
                    currentValueViews.append(contentsOf: [andLabel, datePicker2])

                    if temporalSubType == .timestamp {
                        advancedContainer.insertArrangedSubview(timePicker2, at: idx + 2)
                        currentValueViews.append(timePicker2)
                    }
                }
            } else {
                // Plain text fields
                advancedContainer.insertArrangedSubview(valueField, at: insertIndex)
                currentValueViews = [valueField]

                if op.needsSecondValue {
                    let andLabel = NSTextField(labelWithString: "and")
                    andLabel.font = .systemFont(ofSize: 11)
                    andLabel.textColor = .secondaryLabelColor
                    let idx = insertIndex + 1
                    advancedContainer.insertArrangedSubview(andLabel, at: idx)
                    advancedContainer.insertArrangedSubview(value2Field, at: idx + 1)
                    currentValueViews.append(contentsOf: [andLabel, value2Field])
                }
            }
        }

        recalculateSize()
    }

    /// Size the popover width to fit the widest value, clamped to
    /// [minWidth, 0.6 × referenceWidth]. Runs once when the popover opens.
    private func autoSizeWidth() {
        let font = NSFont.systemFont(ofSize: 12)               // matches the checklist row font
        let widest = valueList.maxValueWidth(font: font)
        // Row chrome (checkbox glyph + gaps + trailing) + scroller + list bezel + stack insets.
        let chrome: CGFloat = 78
        currentWidth = FilterPopoverSizing.clampWidth(widest + chrome,
                                                      referenceWidth: referenceSize.width)
    }

    private func recalculateSize() {
        updateAdvancedFieldWidths()
        stackView.layoutSubtreeIfNeeded()
        let fitting = stackView.fittingSize
        // Width is driven by auto-size / drag (currentWidth); height stays content-driven.
        preferredContentSize = NSSize(width: currentWidth, height: fitting.height)
    }

    /// Keep the advanced input fields filling the popover width (minus the stack's
    /// 12pt side insets) as `currentWidth` changes via auto-size or drag-resize.
    private func updateAdvancedFieldWidths() {
        let w = currentWidth - 24
        for constraint in advancedFieldWidthConstraints { constraint.constant = w }
    }

    // MARK: - Restore Existing Filter

    private func restoreExistingFilter(_ filter: ColumnFilter) {
        if filter.op.needsMultiValue {
            tokenField.objectValue = filter.values ?? []
        } else if filter.op.needsValue {
            if temporalSubType == .interval {
                restoreIntervalFields(filter.value, days: intervalDays, hours: intervalHours,
                                       minutes: intervalMinutes, seconds: intervalSeconds)
                if let v2 = filter.value2 {
                    restoreIntervalFields(v2, days: interval2Days, hours: interval2Hours,
                                           minutes: interval2Minutes, seconds: interval2Seconds)
                }
            } else if temporalSubType != .none {
                if let date = parseFilterDate(filter.value) {
                    datePicker.dateValue = date
                }
                if temporalSubType == .timestamp {
                    timePicker.stringValue = extractTimeComponent(filter.value)
                }
                if let v2 = filter.value2, let date2 = parseFilterDate(v2) {
                    datePicker2.dateValue = date2
                    if temporalSubType == .timestamp {
                        timePicker2.stringValue = extractTimeComponent(v2)
                    }
                }
            } else {
                valueField.stringValue = filter.value
                if let v2 = filter.value2 {
                    value2Field.stringValue = v2
                }
            }
        }
    }

    // MARK: - Temporal Sub-Type Detection

    private func detectTemporalSubType(_ raw: String) -> TemporalSubType {
        guard category == .temporal else { return .none }
        let lower = raw.lowercased()
        if lower == "interval" { return .interval }
        if lower == "date" { return .date }
        if lower.hasPrefix("timestamp") { return .timestamp }
        if lower.hasPrefix("time") { return .time }
        return .timestamp // default for unknown temporal types
    }

    // MARK: - Date Picker Helpers

    private func configureDatePicker(_ picker: NSDatePicker) {
        picker.dateValue = Date()

        switch temporalSubType {
        case .time:
            // Time-only: text field + stepper is appropriate
            picker.datePickerStyle = .textFieldAndStepper
            picker.datePickerElements = [.hourMinuteSecond]
            picker.font = .monospacedSystemFont(ofSize: 12, weight: .regular)
        default:
            // Date and timestamp: graphical calendar
            picker.datePickerStyle = .clockAndCalendar
            picker.datePickerElements = [.yearMonthDay]
        }
    }

    private func configureTimePicker(_ field: NSTextField, placeholder: String) {
        field.font = .monospacedSystemFont(ofSize: 12, weight: .regular)
        field.placeholderString = placeholder
        field.target = self
        field.action = #selector(applyFilter)
    }

    private func datePickerToFilterValue(_ picker: NSDatePicker, timeField: NSTextField? = nil) -> String {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        switch temporalSubType {
        case .date:
            formatter.dateFormat = "yyyy-MM-dd"
            return formatter.string(from: picker.dateValue)
        case .time:
            formatter.dateFormat = "HH:mm:ss"
            return formatter.string(from: picker.dateValue)
        default:
            // Timestamp: date from calendar picker, time from text field
            formatter.dateFormat = "yyyy-MM-dd"
            let dateStr = formatter.string(from: picker.dateValue)
            let timeStr = timeField?.stringValue.trimmingCharacters(in: .whitespaces) ?? ""
            if timeStr.isEmpty {
                return "\(dateStr) 00:00:00"
            }
            return "\(dateStr) \(timeStr)"
        }
    }

    private func parseFilterDate(_ str: String) -> Date? {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        // Try multiple formats
        for fmt in ["yyyy-MM-dd HH:mm:ss", "yyyy-MM-dd'T'HH:mm:ss", "yyyy-MM-dd", "HH:mm:ss"] {
            formatter.dateFormat = fmt
            if let d = formatter.date(from: str) { return d }
        }
        return nil
    }

    /// Extracts the time component (HH:mm:ss) from a "yyyy-MM-dd HH:mm:ss" string.
    private func extractTimeComponent(_ str: String) -> String {
        // Split on space and take the second part
        let parts = str.split(separator: " ", maxSplits: 1)
        if parts.count >= 2 {
            return String(parts[1])
        }
        // Try splitting on T for ISO format
        let tParts = str.split(separator: "T", maxSplits: 1)
        if tParts.count >= 2 {
            return String(tParts[1])
        }
        return ""
    }

    // MARK: - Interval Helpers

    private func makeIntervalRow(dField: NSTextField, hField: NSTextField,
                                  mField: NSTextField, sField: NSTextField) -> NSView {
        func makeLabel(_ text: String) -> NSTextField {
            let label = NSTextField(labelWithString: text)
            label.font = .systemFont(ofSize: 11)
            label.textColor = .secondaryLabelColor
            return label
        }
        let row = NSStackView(views: [dField, makeLabel("d"), hField, makeLabel("h"),
                                       mField, makeLabel("m"), sField, makeLabel("s")])
        row.orientation = .horizontal
        row.spacing = 3
        return row
    }

    private func configureIntervalField(_ field: NSTextField, placeholder: String) {
        field.font = .monospacedSystemFont(ofSize: 12, weight: .regular)
        field.placeholderString = placeholder
        field.widthAnchor.constraint(equalToConstant: 40).isActive = true
    }

    private func intervalToFilterValue(_ dField: NSTextField, _ hField: NSTextField,
                                        _ mField: NSTextField, _ sField: NSTextField) -> String {
        let d = Int(dField.stringValue) ?? 0
        let h = Int(hField.stringValue) ?? 0
        let m = Int(mField.stringValue) ?? 0
        let s = Int(sField.stringValue) ?? 0
        let totalSeconds = d * 86400 + h * 3600 + m * 60 + s
        return String(totalSeconds)
    }

    private func restoreIntervalFields(_ totalSecondsStr: String, days: NSTextField,
                                        hours: NSTextField, minutes: NSTextField, seconds: NSTextField) {
        guard let total = Int(totalSecondsStr) else { return }
        let d = total / 86400
        let remainder = total % 86400
        let h = remainder / 3600
        let m = (remainder % 3600) / 60
        let s = (remainder % 3600) % 60
        days.stringValue = d > 0 ? String(d) : ""
        hours.stringValue = h > 0 ? String(h) : ""
        minutes.stringValue = m > 0 ? String(m) : ""
        seconds.stringValue = s > 0 ? String(s) : ""
    }

    // MARK: - Configuration Helpers

    private func configureTextField(_ field: NSTextField, placeholder: String) {
        field.font = .monospacedSystemFont(ofSize: 12, weight: .regular)
        field.placeholderString = placeholder
        field.target = self
        field.action = #selector(applyFilter)
    }

    private func selectedOperator() -> FilterOperator? {
        let idx = operatorPopup.indexOfSelectedItem
        guard idx >= 0, idx < operators.count else { return nil }
        return operators[idx]
    }
}
