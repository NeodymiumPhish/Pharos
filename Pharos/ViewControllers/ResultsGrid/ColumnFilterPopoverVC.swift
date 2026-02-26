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
    private let category: PGTypeCategory
    private let dataType: String
    private let existingFilter: ColumnFilter?

    weak var filterDelegate: ColumnFilterPopoverDelegate?

    private var operators: [FilterOperator] = []
    private var temporalSubType: TemporalSubType = .none

    // Main stack
    private let stackView = NSStackView()

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

    init(columnName: String, category: PGTypeCategory, dataType: String, existingFilter: ColumnFilter?) {
        self.columnName = columnName
        self.category = category
        self.dataType = dataType
        self.existingFilter = existingFilter
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
        stackView.alignment = .leading
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
        headerLabel.stringValue = "Filter: \(columnName)"
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

        // Add fixed elements to stack
        stackView.addArrangedSubview(headerLabel)
        stackView.addArrangedSubview(operatorPopup)
        // Value area will be inserted here dynamically
        stackView.addArrangedSubview(buttonRow)

        // Width constraints
        let contentWidth: CGFloat = 260
        let innerWidth = contentWidth - 24 // 12pt padding on each side
        for v: NSView in [operatorPopup, buttonRow] {
            v.widthAnchor.constraint(equalToConstant: innerWidth).isActive = true
        }

        // Restore existing filter state
        if let existing = existingFilter,
           let idx = operators.firstIndex(of: existing.op) {
            operatorPopup.selectItem(at: idx)
            restoreExistingFilter(existing)
        }

        updateValueArea()
    }

    // MARK: - Actions

    @objc private func operatorChanged() {
        updateValueArea()
    }

    @objc private func applyFilter() {
        guard let op = selectedOperator() else { return }

        var value = ""
        var value2: String? = nil
        var values: [String]? = nil

        if op.needsMultiValue {
            let tokens = (tokenField.objectValue as? [String]) ?? []
            values = tokens.isEmpty ? nil : tokens
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
        }

        let filter = ColumnFilter(
            columnName: columnName,
            op: op,
            value: value,
            value2: value2,
            values: values,
            dataType: dataType
        )
        filterDelegate?.columnFilterPopover(self, didApplyFilter: filter)
        dismiss(nil)
    }

    @objc private func clearFilter() {
        filterDelegate?.columnFilterPopover(self, didClearFilterForColumn: columnName)
        dismiss(nil)
    }

    // MARK: - Value Area Management

    private func updateValueArea() {
        // Remove existing dynamic value views from stack
        for v in currentValueViews {
            stackView.removeArrangedSubview(v)
            v.removeFromSuperview()
        }
        currentValueViews.removeAll()

        guard let op = selectedOperator() else {
            recalculateSize()
            return
        }

        // Button row is always the last arranged subview
        let insertIndex = stackView.arrangedSubviews.count - 1
        let innerWidth: CGFloat = 236

        if op.needsMultiValue {
            // Token field for containsAnyOf
            tokenField.widthAnchor.constraint(equalToConstant: innerWidth).isActive = true
            stackView.insertArrangedSubview(tokenField, at: insertIndex)
            currentValueViews = [tokenField]
        } else if op.needsValue {
            if temporalSubType == .interval {
                let row1 = makeIntervalRow(dField: intervalDays, hField: intervalHours,
                                            mField: intervalMinutes, sField: intervalSeconds)
                row1.widthAnchor.constraint(equalToConstant: innerWidth).isActive = true
                stackView.insertArrangedSubview(row1, at: insertIndex)
                currentValueViews = [row1]

                if op.needsSecondValue {
                    let andLabel = NSTextField(labelWithString: "and")
                    andLabel.font = .systemFont(ofSize: 11)
                    andLabel.textColor = .secondaryLabelColor
                    let row2 = makeIntervalRow(dField: interval2Days, hField: interval2Hours,
                                                mField: interval2Minutes, sField: interval2Seconds)
                    row2.widthAnchor.constraint(equalToConstant: innerWidth).isActive = true
                    let idx = insertIndex + 1
                    stackView.insertArrangedSubview(andLabel, at: idx)
                    stackView.insertArrangedSubview(row2, at: idx + 1)
                    currentValueViews.append(contentsOf: [andLabel, row2])
                }
            } else if temporalSubType != .none {
                stackView.insertArrangedSubview(datePicker, at: insertIndex)
                currentValueViews = [datePicker]

                // For timestamps, add a time text field below the calendar
                if temporalSubType == .timestamp {
                    timePicker.widthAnchor.constraint(equalToConstant: innerWidth).isActive = true
                    stackView.insertArrangedSubview(timePicker, at: insertIndex + 1)
                    currentValueViews.append(timePicker)
                }

                if op.needsSecondValue {
                    let andLabel = NSTextField(labelWithString: "and")
                    andLabel.font = .systemFont(ofSize: 11)
                    andLabel.textColor = .secondaryLabelColor
                    let idx = insertIndex + currentValueViews.count
                    stackView.insertArrangedSubview(andLabel, at: idx)
                    stackView.insertArrangedSubview(datePicker2, at: idx + 1)
                    currentValueViews.append(contentsOf: [andLabel, datePicker2])

                    if temporalSubType == .timestamp {
                        timePicker2.widthAnchor.constraint(equalToConstant: innerWidth).isActive = true
                        stackView.insertArrangedSubview(timePicker2, at: idx + 2)
                        currentValueViews.append(timePicker2)
                    }
                }
            } else {
                // Plain text fields
                valueField.widthAnchor.constraint(equalToConstant: innerWidth).isActive = true
                stackView.insertArrangedSubview(valueField, at: insertIndex)
                currentValueViews = [valueField]

                if op.needsSecondValue {
                    let andLabel = NSTextField(labelWithString: "and")
                    andLabel.font = .systemFont(ofSize: 11)
                    andLabel.textColor = .secondaryLabelColor
                    value2Field.widthAnchor.constraint(equalToConstant: innerWidth).isActive = true
                    let idx = insertIndex + 1
                    stackView.insertArrangedSubview(andLabel, at: idx)
                    stackView.insertArrangedSubview(value2Field, at: idx + 1)
                    currentValueViews.append(contentsOf: [andLabel, value2Field])
                }
            }
        }

        recalculateSize()
    }

    private func recalculateSize() {
        stackView.layoutSubtreeIfNeeded()
        let fitting = stackView.fittingSize
        // Calendar pickers need more width than text fields
        let width: CGFloat = max(260, fitting.width)
        preferredContentSize = NSSize(width: width, height: fitting.height)
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
