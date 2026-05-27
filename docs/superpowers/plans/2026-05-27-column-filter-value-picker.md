# Column Filter Value Picker (Excel-style) Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Add an Excel-style distinct-values checklist as the primary column filter (searchable, cascading, all column types), with the existing operator UI demoted to a collapsible "Advanced text filter" section.

**Architecture:** A new `.isAnyOf` exact-match operator represents a checklist selection in the existing `ColumnFilter` model. `ResultsColumnFilterController` gains a cascading `distinctValues(...)` computation and an `.isAnyOf` evaluation branch. A new self-contained `FilterValueListView` (virtualized NSTableView checklist) renders the values. `ColumnFilterPopoverVC` is restructured to host the search field + checklist + collapsible advanced section, and the call site computes/passes the distinct values.

**Tech Stack:** Swift 5 / AppKit, XcodeGen (`project.yml`). No `pharos-core` (Rust) changes.

**Spec:** `docs/superpowers/specs/2026-05-27-column-filter-value-picker-design.md`

**Verification:** No XCTest target. After each task, build with `xcodebuild -scheme Pharos -configuration Debug -quiet build` and confirm `** BUILD SUCCEEDED **`. Behavior is verified manually by running the app (Task 7).

---

## File Structure

**Created:**
- `Pharos/ViewControllers/ResultsGrid/FilterValueListView.swift` — virtualized checklist view (one responsibility: render a list of strings with checkboxes + Select All, report the checked set).

**Modified:**
- `Pharos/Utilities/ColumnFilter.swift` — add `FilterOperator.isAnyOf` + `ColumnFilter.blanksSentinel`.
- `Pharos/ViewControllers/ResultsGrid/ResultsColumnFilterController.swift` — add `.isAnyOf` evaluation branch + `distinctValues(...)` + `sortValues(...)`.
- `Pharos/ViewControllers/ResultsGrid/ColumnFilterPopoverVC.swift` — restructure: new init params, search field, checklist, collapsible Advanced section, two-mode Apply.
- `Pharos/ViewControllers/ResultsGrid/ResultsGridVC+Delegates.swift` — compute and pass distinct values when opening the popover.

**Regenerated:**
- `Pharos.xcodeproj` via `xcodegen generate` (after adding the new file).

---

## Task 1: Model — `.isAnyOf` operator + blanks sentinel

**Files:**
- Modify: `Pharos/Utilities/ColumnFilter.swift`

- [ ] **Step 1.1: Add the `.isAnyOf` case to `FilterOperator`**

In `Pharos/Utilities/ColumnFilter.swift`, add a new case. Change:

```swift
    // Multi-value text
    case containsAnyOf, notContainsAnyOf
```

to:

```swift
    // Multi-value text
    case containsAnyOf, notContainsAnyOf
    // Exact-match multi-value (produced only by the value checklist, not the operator dropdown)
    case isAnyOf
```

- [ ] **Step 1.2: Add its label**

In the `label` computed property, add a case before the closing brace of the switch (e.g. after the `notContainsAnyOf` case):

```swift
        case .isAnyOf: return "is any of"
```

- [ ] **Step 1.3: Mark it multi-value**

Change `needsMultiValue`:

```swift
    var needsMultiValue: Bool {
        self == .containsAnyOf || self == .notContainsAnyOf
    }
```

to:

```swift
    var needsMultiValue: Bool {
        self == .containsAnyOf || self == .notContainsAnyOf || self == .isAnyOf
    }
```

`needsValue` already returns `true` for `.isAnyOf` via its `default` branch, and `needsSecondValue` returns `false` — both correct, leave them.

Do **NOT** add `.isAnyOf` to `operators(for:)` — it must never appear in the operator dropdown (it is produced only by the checklist).

- [ ] **Step 1.4: Add the blanks sentinel constant**

Change the `ColumnFilter` struct:

```swift
struct ColumnFilter {
    let columnName: String
    let op: FilterOperator
    let value: String
    let value2: String?
    let values: [String]?
    let dataType: String
}
```

to:

```swift
struct ColumnFilter {
    let columnName: String
    let op: FilterOperator
    let value: String
    let value2: String?
    let values: [String]?
    let dataType: String

    /// Sentinel placed in `values` (for an `.isAnyOf` filter) to mean "match
    /// null / empty cells". NUL-prefixed so it cannot collide with a rendered
    /// cell value. Also used as the model value of the checklist's "(Blanks)" row.
    static let blanksSentinel = "\u{0}__pharos_blanks__"
}
```

- [ ] **Step 1.5: Build**

```bash
xcodebuild -scheme Pharos -configuration Debug -quiet build
```

Expected: `** BUILD SUCCEEDED **`.

- [ ] **Step 1.6: Commit**

```bash
git add Pharos/Utilities/ColumnFilter.swift
git commit -m "feat: add isAnyOf filter operator and blanks sentinel"
```

---

## Task 2: Evaluation — `.isAnyOf` branch

**Files:**
- Modify: `Pharos/ViewControllers/ResultsGrid/ResultsColumnFilterController.swift`

- [ ] **Step 2.1: Handle `.isAnyOf` in `evaluate` (before the non-null guard)**

In `evaluate(filter:value:category:)`, the first `switch filter.op` handles operators that must run before the "remaining operators require a non-null value" guard (because `.isAnyOf` with the blanks sentinel must match null cells). Change:

```swift
        case .isFalse:
            return boolValue(value) == false
        default:
            break
        }
```

to:

```swift
        case .isFalse:
            return boolValue(value) == false
        case .isAnyOf:
            let set = Set(filter.values ?? [])
            let isBlank = (value?.isNull ?? true) || (value?.displayString.isEmpty ?? true)
            if isBlank { return set.contains(ColumnFilter.blanksSentinel) }
            return set.contains(value!.displayString)
        default:
            break
        }
```

Exact equality on the rendered `displayString`, matching how the checklist gathers values — so it works uniformly across all column types.

- [ ] **Step 2.2: Build**

```bash
xcodebuild -scheme Pharos -configuration Debug -quiet build
```

Expected: `** BUILD SUCCEEDED **`.

- [ ] **Step 2.3: Commit**

```bash
git add Pharos/ViewControllers/ResultsGrid/ResultsColumnFilterController.swift
git commit -m "feat: evaluate isAnyOf filter (exact membership + blanks)"
```

---

## Task 3: Cascading distinct-values computation

**Files:**
- Modify: `Pharos/ViewControllers/ResultsGrid/ResultsColumnFilterController.swift`

- [ ] **Step 3.1: Add `distinctValues` and `sortValues`**

Add these two methods to `ResultsColumnFilterController` (e.g. just after `applyFilters(inputDisplayRows:)`). `colIndex(from:)` is a free function declared in `ResultsGridVC.swift:5` and is in scope. `evaluate(...)` is a private method of this same class.

```swift
    // MARK: - Distinct Values (for the value-picker checklist)

    /// Distinct display-string values for a column, computed over rows that pass
    /// every OTHER column's active filter (cascading). Sorted type-aware ascending.
    /// `hasBlanks` is true if any null/empty cell was seen (caller adds a "(Blanks)" row).
    func distinctValues(forColumnIndex idx: Int,
                        excludingColumnId colId: String,
                        category: PGTypeCategory) -> (values: [String], hasBlanks: Bool) {
        guard let delegate = delegate else { return ([], false) }
        let rows = delegate.filterableRows
        let categories = delegate.filterableColumnCategories

        // Every active filter except the column being edited (so all of this
        // column's values stay selectable even when it already has a filter).
        let otherFilters = activeFilters.filter { $0.key != colId }

        var seen = Set<String>()
        var hasBlanks = false

        rowLoop: for row in rows {
            for (fColId, filter) in otherFilters {
                guard let fIdx = colIndex(from: fColId) else { continue }
                let fCat = fIdx < categories.count ? categories[fIdx] : .string
                let fVal: AnyCodable? = fIdx < row.count ? row[fIdx] : nil
                if !evaluate(filter: filter, value: fVal, category: fCat) { continue rowLoop }
            }
            let cell: AnyCodable? = idx < row.count ? row[idx] : nil
            if cell == nil || cell!.isNull || cell!.displayString.isEmpty {
                hasBlanks = true
            } else {
                seen.insert(cell!.displayString)
            }
        }

        return (sortValues(Array(seen), category: category), hasBlanks)
    }

    /// Type-aware ascending sort of distinct display strings.
    private func sortValues(_ values: [String], category: PGTypeCategory) -> [String] {
        switch category {
        case .numeric:
            return values.sorted { a, b in
                switch (Double(a), Double(b)) {
                case let (x?, y?): return x < y
                case (nil, _?):    return false   // non-numeric strings sort after numeric
                case (_?, nil):    return true
                case (nil, nil):   return a.localizedStandardCompare(b) == .orderedAscending
                }
            }
        default:
            // Temporal display strings are ISO-ish, so natural compare is chronological;
            // strings/json/boolean use the same natural, case-insensitive ordering.
            return values.sorted { $0.localizedStandardCompare($1) == .orderedAscending }
        }
    }
```

- [ ] **Step 3.2: Build**

```bash
xcodebuild -scheme Pharos -configuration Debug -quiet build
```

Expected: `** BUILD SUCCEEDED **`. (The methods are unused for now — that's fine; Task 5 wires them in.)

- [ ] **Step 3.3: Commit**

```bash
git add Pharos/ViewControllers/ResultsGrid/ResultsColumnFilterController.swift
git commit -m "feat: cascading distinct-values computation for column filter"
```

---

## Task 4: `FilterValueListView` (virtualized checklist)

**Files:**
- Create: `Pharos/ViewControllers/ResultsGrid/FilterValueListView.swift`

- [ ] **Step 4.1: Create the file**

Create `Pharos/ViewControllers/ResultsGrid/FilterValueListView.swift`:

```swift
import AppKit

/// A virtualized checklist of string values with a leading "(Select All)" row.
/// Self-contained: knows nothing about filters or the grid. Reports the checked
/// set and notifies on change. Search filters which rows are visible without
/// altering hidden rows' checked state.
final class FilterValueListView: NSView {

    /// Fired whenever the checked set changes (row toggle or Select All).
    var onSelectionChanged: (() -> Void)?

    private let scrollView = NSScrollView()
    private let tableView = NSTableView()

    private var allValues: [String] = []       // full model (post setValues)
    private var visibleValues: [String] = []    // currently shown (post search)
    private var checked: Set<String> = []
    private var searchQuery: String = ""

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        setup()
    }
    required init?(coder: NSCoder) { fatalError("init(coder:) not used") }

    private func setup() {
        translatesAutoresizingMaskIntoConstraints = false

        let column = NSTableColumn(identifier: NSUserInterfaceItemIdentifier("value"))
        column.resizingMask = .autoresizingMask
        tableView.addTableColumn(column)
        tableView.headerView = nil
        tableView.rowSizeStyle = .custom
        tableView.rowHeight = 20
        tableView.intercellSpacing = NSSize(width: 0, height: 2)
        tableView.selectionHighlightStyle = .none
        tableView.backgroundColor = .clear
        tableView.dataSource = self
        tableView.delegate = self

        scrollView.documentView = tableView
        scrollView.hasVerticalScroller = true
        scrollView.drawsBackground = false
        scrollView.borderType = .bezelBorder
        scrollView.translatesAutoresizingMaskIntoConstraints = false
        addSubview(scrollView)

        NSLayoutConstraint.activate([
            scrollView.topAnchor.constraint(equalTo: topAnchor),
            scrollView.leadingAnchor.constraint(equalTo: leadingAnchor),
            scrollView.trailingAnchor.constraint(equalTo: trailingAnchor),
            scrollView.bottomAnchor.constraint(equalTo: bottomAnchor),
            heightAnchor.constraint(equalToConstant: 180),
        ])
    }

    /// Replace the list contents and the initial checked set.
    func setValues(_ values: [String], checked: Set<String>) {
        self.allValues = values
        self.checked = checked
        applySearch(searchQuery)
    }

    /// Checked values (excludes the synthetic Select All row).
    var checkedValues: Set<String> { checked }

    /// Filter which rows are visible (case-insensitive substring). Hidden rows
    /// keep their checked state.
    func applySearch(_ query: String) {
        searchQuery = query
        let q = query.trimmingCharacters(in: .whitespaces).lowercased()
        if q.isEmpty {
            visibleValues = allValues
        } else {
            visibleValues = allValues.filter { displayLabel(for: $0).lowercased().contains(q) }
        }
        tableView.reloadData()
    }

    private func displayLabel(for value: String) -> String {
        value == ColumnFilter.blanksSentinel ? "(Blanks)" : value
    }

    /// Aggregate state of the Select All row over the currently visible rows.
    private var selectAllState: NSControl.StateValue {
        if visibleValues.isEmpty { return .off }
        let checkedCount = visibleValues.reduce(0) { $0 + (checked.contains($1) ? 1 : 0) }
        if checkedCount == 0 { return .off }
        if checkedCount == visibleValues.count { return .on }
        return .mixed
    }

    @objc private func toggleRow(_ sender: NSButton) {
        let row = sender.tag
        if row == 0 {
            // Select All toggles only the VISIBLE rows; check all unless already all-on.
            if selectAllState == .on {
                checked.subtract(visibleValues)
            } else {
                checked.formUnion(visibleValues)
            }
        } else {
            let value = visibleValues[row - 1]
            if sender.state == .on { checked.insert(value) } else { checked.remove(value) }
        }
        tableView.reloadData()   // refresh Select All tri-state + row states
        onSelectionChanged?()
    }
}

extension FilterValueListView: NSTableViewDataSource, NSTableViewDelegate {
    func numberOfRows(in tableView: NSTableView) -> Int {
        visibleValues.count + 1   // +1 for the Select All row
    }

    func tableView(_ tableView: NSTableView, viewFor tableColumn: NSTableColumn?, row: Int) -> NSView? {
        let id = NSUserInterfaceItemIdentifier("checkRow")
        let cell = (tableView.makeView(withIdentifier: id, owner: self) as? NSButton)
            ?? NSButton(checkboxWithTitle: "", target: nil, action: nil)
        cell.identifier = id
        cell.lineBreakMode = .byTruncatingTail
        cell.target = self
        cell.action = #selector(toggleRow(_:))
        cell.tag = row

        if row == 0 {
            cell.title = "(Select All)"
            cell.font = .systemFont(ofSize: 12, weight: .medium)
            cell.allowsMixedState = true
            cell.state = selectAllState
            cell.isEnabled = !visibleValues.isEmpty
            cell.toolTip = nil
        } else {
            let value = visibleValues[row - 1]
            let label = displayLabel(for: value)
            cell.title = label
            cell.font = .systemFont(ofSize: 12)
            cell.allowsMixedState = false
            cell.state = checked.contains(value) ? .on : .off
            cell.isEnabled = true
            cell.toolTip = label
        }
        return cell
    }
}
```

Notes:
- `ColumnFilter.blanksSentinel` comes from Task 1.
- Virtualized (`viewFor` realizes only visible rows), so thousands of values scroll efficiently.
- The Select All row computes its tri-state from the model and toggles only visible rows; `reloadData` after each change keeps the tri-state and row checkmarks in sync with the model regardless of the checkbox's own click cycling.

- [ ] **Step 4.2: Regenerate the Xcode project**

```bash
cd /Users/nfinn/Projects/aSideProjects/Pharos && xcodegen generate
```

- [ ] **Step 4.3: Build**

```bash
xcodebuild -scheme Pharos -configuration Debug -quiet build
```

Expected: `** BUILD SUCCEEDED **`.

- [ ] **Step 4.4: Commit**

```bash
git add Pharos/ViewControllers/ResultsGrid/FilterValueListView.swift Pharos.xcodeproj
git commit -m "feat: add FilterValueListView virtualized checklist"
```

---

## Task 5: Popover — checklist + search + two-mode Apply (Advanced still inline)

This task makes the popover functional: a search field + checklist on top, the operator UI grouped into an `advancedContainer` (kept visible for now — Task 6 collapses it), and Apply that chooses checklist vs advanced mode. It also updates the call site to compute and pass distinct values.

**Files:**
- Modify: `Pharos/ViewControllers/ResultsGrid/ColumnFilterPopoverVC.swift`
- Modify: `Pharos/ViewControllers/ResultsGrid/ResultsGridVC+Delegates.swift`

- [ ] **Step 5.1: Add init params and new stored properties**

In `ColumnFilterPopoverVC`, change the stored property block + `init` to accept the distinct values. Replace:

```swift
    private let columnName: String
    private let displayName: String
    private let category: PGTypeCategory
    private let dataType: String
    private let existingFilter: ColumnFilter?
```

with:

```swift
    private let columnName: String
    private let displayName: String
    private let category: PGTypeCategory
    private let dataType: String
    private let existingFilter: ColumnFilter?

    // Value picker (checklist)
    private let checklistValues: [String]     // distinct values + optional blanks sentinel
    private let searchField = NSSearchField()
    private let valueList = FilterValueListView()
    // Advanced operator UI lives in this container (collapsed under a disclosure in Task 6)
    private let advancedContainer = NSStackView()
```

Replace the `init`:

```swift
    init(columnName: String, displayName: String, category: PGTypeCategory, dataType: String, existingFilter: ColumnFilter?) {
        self.columnName = columnName
        self.displayName = displayName
        self.category = category
        self.dataType = dataType
        self.existingFilter = existingFilter
        super.init(nibName: nil, bundle: nil)
    }
```

with:

```swift
    init(columnName: String, displayName: String, category: PGTypeCategory, dataType: String,
         existingFilter: ColumnFilter?, distinctValues: [String], hasBlanks: Bool) {
        self.columnName = columnName
        self.displayName = displayName
        self.category = category
        self.dataType = dataType
        self.existingFilter = existingFilter
        self.checklistValues = distinctValues + (hasBlanks ? [ColumnFilter.blanksSentinel] : [])
        super.init(nibName: nil, bundle: nil)
    }
```

- [ ] **Step 5.2: Restructure `loadView`**

In `loadView`, the existing code adds `headerLabel`, `operatorPopup`, and `buttonRow` to `stackView` (lines ~162-165) and applies width constraints (lines ~167-172). Replace that section. Find:

```swift
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
```

Replace with:

```swift
        let innerWidth: CGFloat = 236  // 260 content - 24 padding

        // Search field above the checklist
        searchField.placeholderString = "Search"
        searchField.font = .systemFont(ofSize: 12)
        searchField.target = self
        searchField.action = #selector(searchChanged)
        searchField.sendsSearchStringImmediately = true
        searchField.widthAnchor.constraint(equalToConstant: innerWidth).isActive = true

        // Checklist
        valueList.widthAnchor.constraint(equalToConstant: innerWidth).isActive = true
        valueList.onSelectionChanged = { [weak self] in self?.updateApplyEnabled() }

        // Advanced operator container (operator popup first, then dynamic value views)
        advancedContainer.orientation = .vertical
        advancedContainer.alignment = .leading
        advancedContainer.spacing = 8
        operatorPopup.widthAnchor.constraint(equalToConstant: innerWidth).isActive = true
        advancedContainer.addArrangedSubview(operatorPopup)
        advancedContainer.widthAnchor.constraint(equalToConstant: innerWidth).isActive = true

        buttonRow.widthAnchor.constraint(equalToConstant: innerWidth).isActive = true

        // Assemble main stack: header, search, checklist, advanced, buttons
        stackView.addArrangedSubview(headerLabel)
        stackView.addArrangedSubview(searchField)
        stackView.addArrangedSubview(valueList)
        stackView.addArrangedSubview(advancedContainer)
        stackView.addArrangedSubview(buttonRow)

        // Determine initial mode + checklist state from the existing filter.
        let allValues = Set(checklistValues)
        if let existing = existingFilter, existing.op == .isAnyOf {
            // Checklist mode: restore checked values.
            valueList.setValues(checklistValues, checked: Set(existing.values ?? []))
        } else if let existing = existingFilter, let idx = operators.firstIndex(of: existing.op) {
            // Advanced operator was active: all checked in the list, restore advanced UI.
            valueList.setValues(checklistValues, checked: allValues)
            operatorPopup.selectItem(at: idx)
            restoreExistingFilter(existing)
        } else {
            // No filter: everything checked.
            valueList.setValues(checklistValues, checked: allValues)
        }

        updateValueArea()
        updateApplyEnabled()
```

(`buttonRow` is created earlier in `loadView` exactly as today. The `operators`/`temporalSubType` setup and all the field configuration above it are unchanged.)

- [ ] **Step 5.3: Point `updateValueArea` at `advancedContainer`**

`updateValueArea` currently inserts/removes the dynamic value views in `stackView` before the button row. It must operate inside `advancedContainer` (after the operator popup) instead. In `updateValueArea`, replace:

```swift
        // Button row is always the last arranged subview
        let insertIndex = stackView.arrangedSubviews.count - 1
        let innerWidth: CGFloat = 236
```

with:

```swift
        // Insert value views into the advanced container, after the operator popup.
        let insertIndex = advancedContainer.arrangedSubviews.count
        let innerWidth: CGFloat = 236
```

Then, within `updateValueArea`, replace **every** `stackView.insertArrangedSubview(` call with `advancedContainer.insertArrangedSubview(`. (There are several — for `tokenField`, interval rows, date pickers, text fields, and the `andLabel`s.) Do not change the `insertIndex + N` offsets; they remain relative to the container now. Leave the removal loop (`stackView.removeArrangedSubview(v)`) — change it too:

```swift
        for v in currentValueViews {
            stackView.removeArrangedSubview(v)
            v.removeFromSuperview()
        }
```

becomes:

```swift
        for v in currentValueViews {
            advancedContainer.removeArrangedSubview(v)
            v.removeFromSuperview()
        }
```

To find all the call sites:

```bash
grep -n "stackView.insertArrangedSubview\|stackView.removeArrangedSubview" Pharos/ViewControllers/ResultsGrid/ColumnFilterPopoverVC.swift
```

Every match inside `updateValueArea` becomes `advancedContainer.…`.

- [ ] **Step 5.4: Add search + Apply-enabled handlers, and refactor Apply into two modes**

Add a `searchChanged` action and an `updateApplyEnabled` helper, and split the existing `applyFilter` so the advanced path becomes `buildAdvancedFilter()` (returns `nil` when not validly populated). Replace the existing `applyFilter`:

```swift
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
```

with:

```swift
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

    /// Builds a `ColumnFilter` from the advanced operator UI, or `nil` if that
    /// UI is not validly populated (so Apply falls through to checklist mode).
    /// In this task the advanced UI is always visible; Task 6 gates it behind the
    /// disclosure so a collapsed/empty advanced section returns nil.
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

    /// Whether the advanced operator UI should be considered for Apply.
    /// In Task 5 the section is always shown, so it's active iff an operator is
    /// selected. Task 6 redefines this as "the disclosure is expanded".
    private var advancedIsActive: Bool { true }
```

- [ ] **Step 5.5: Re-evaluate Apply-enabled when the operator/value changes**

`operatorChanged()` currently just calls `updateValueArea()`. Make it also refresh the Apply state:

```swift
    @objc private func operatorChanged() {
        updateValueArea()
        updateApplyEnabled()
    }
```

- [ ] **Step 5.6: Update the call site to compute and pass distinct values**

In `Pharos/ViewControllers/ResultsGrid/ResultsGridVC+Delegates.swift`, the popover is created in `headerView(_:didClickFilterForColumn:at:)`. Replace:

```swift
        let popoverVC = ColumnFilterPopoverVC(
            columnName: colId,
            displayName: columns[idx].name,
            category: category,
            dataType: rawDataType,
            existingFilter: existing
        )
```

with:

```swift
        let distinct = columnFilterController.distinctValues(
            forColumnIndex: idx, excludingColumnId: colId, category: category
        )
        let popoverVC = ColumnFilterPopoverVC(
            columnName: colId,
            displayName: columns[idx].name,
            category: category,
            dataType: rawDataType,
            existingFilter: existing,
            distinctValues: distinct.values,
            hasBlanks: distinct.hasBlanks
        )
```

- [ ] **Step 5.7: Build**

```bash
xcodebuild -scheme Pharos -configuration Debug -quiet build
```

Expected: `** BUILD SUCCEEDED **`. If `recalculateSize()` complains, it is unchanged and still valid (it measures `stackView.fittingSize`).

- [ ] **Step 5.8: Commit**

```bash
git add Pharos/ViewControllers/ResultsGrid/ColumnFilterPopoverVC.swift Pharos/ViewControllers/ResultsGrid/ResultsGridVC+Delegates.swift
git commit -m "feat: value-picker checklist + search in column filter popover"
```

---

## Task 6: Popover — collapse Advanced under a disclosure + open-mode

Now hide the advanced operator UI behind an "Advanced text filter" disclosure (collapsed by default), expanded automatically only when the column already has a non-`.isAnyOf` operator filter. Redefine `advancedIsActive` as "expanded."

**Files:**
- Modify: `Pharos/ViewControllers/ResultsGrid/ColumnFilterPopoverVC.swift`

- [ ] **Step 6.1: Add the disclosure button property**

In the stored properties (next to `advancedContainer`), add:

```swift
    private let advancedDisclosure = NSButton()
```

- [ ] **Step 6.2: Configure + insert the disclosure, collapse the container by default**

In `loadView`, where the main stack is assembled (Step 5.2), change:

```swift
        stackView.addArrangedSubview(headerLabel)
        stackView.addArrangedSubview(searchField)
        stackView.addArrangedSubview(valueList)
        stackView.addArrangedSubview(advancedContainer)
        stackView.addArrangedSubview(buttonRow)
```

to:

```swift
        advancedDisclosure.setButtonType(.pushOnPushOff)
        advancedDisclosure.bezelStyle = .disclosure
        advancedDisclosure.title = ""
        advancedDisclosure.state = .off
        advancedDisclosure.target = self
        advancedDisclosure.action = #selector(toggleAdvanced)
        let advancedLabel = NSTextField(labelWithString: "Advanced text filter")
        advancedLabel.font = .systemFont(ofSize: 11)
        advancedLabel.textColor = .secondaryLabelColor
        let advancedHeader = NSStackView(views: [advancedDisclosure, advancedLabel])
        advancedHeader.orientation = .horizontal
        advancedHeader.spacing = 4

        stackView.addArrangedSubview(headerLabel)
        stackView.addArrangedSubview(searchField)
        stackView.addArrangedSubview(valueList)
        stackView.addArrangedSubview(advancedHeader)
        stackView.addArrangedSubview(advancedContainer)
        stackView.addArrangedSubview(buttonRow)

        advancedContainer.isHidden = true   // collapsed by default
```

- [ ] **Step 6.3: Expand the section when restoring a non-`.isAnyOf` filter**

In `loadView`, in the initial-mode block from Step 5.2, the advanced branch must also expand the disclosure. Change:

```swift
        } else if let existing = existingFilter, let idx = operators.firstIndex(of: existing.op) {
            // Advanced operator was active: all checked in the list, restore advanced UI.
            valueList.setValues(checklistValues, checked: allValues)
            operatorPopup.selectItem(at: idx)
            restoreExistingFilter(existing)
        } else {
```

to:

```swift
        } else if let existing = existingFilter, let idx = operators.firstIndex(of: existing.op) {
            // Advanced operator was active: all checked in the list, restore + expand advanced UI.
            valueList.setValues(checklistValues, checked: allValues)
            operatorPopup.selectItem(at: idx)
            restoreExistingFilter(existing)
            advancedDisclosure.state = .on
            advancedContainer.isHidden = false
        } else {
```

(The `advancedContainer.isHidden = true` from Step 6.2 runs first; this re-shows it for the advanced-restore case. For the `.isAnyOf` and no-filter cases it stays hidden.)

- [ ] **Step 6.4: Add the toggle action; redefine `advancedIsActive`**

Add the toggle handler (near `operatorChanged`):

```swift
    @objc private func toggleAdvanced() {
        advancedContainer.isHidden = (advancedDisclosure.state != .on)
        updateApplyEnabled()
        recalculateSize()
    }
```

Replace the Task-5 stub:

```swift
    /// Whether the advanced operator UI should be considered for Apply.
    /// In Task 5 the section is always shown, so it's active iff an operator is
    /// selected. Task 6 redefines this as "the disclosure is expanded".
    private var advancedIsActive: Bool { true }
```

with:

```swift
    /// The advanced operator UI is considered for Apply only while expanded.
    private var advancedIsActive: Bool { advancedDisclosure.state == .on }
```

- [ ] **Step 6.5: Build**

```bash
xcodebuild -scheme Pharos -configuration Debug -quiet build
```

Expected: `** BUILD SUCCEEDED **`.

- [ ] **Step 6.6: Commit**

```bash
git add Pharos/ViewControllers/ResultsGrid/ColumnFilterPopoverVC.swift
git commit -m "feat: collapse operator UI under Advanced text filter disclosure"
```

---

## Task 7: Manual verification pass

No code changes — verify behavior by running the app (open `Pharos.xcodeproj`, Cmd+R, connect to Postgres). Fix-commits reference the failing scenario.

- [ ] **Step 7.1: Basic checklist** — Run a query, click a string column's filter icon. Popover shows: header, Search, checklist with `(Select All)` + distinct values all checked, collapsed "Advanced text filter", Clear/Apply. Uncheck a few, Apply → grid filters to the checked set. Reopen → the same boxes are checked.

- [ ] **Step 7.2: Search + Select All** — Type in Search; list narrows. `(Select All)` toggles only the visible rows; clear search → previously-checked rows outside the search remain checked. Searching with no matches disables `(Select All)`.

- [ ] **Step 7.3: Blanks** — On a column with null/empty cells, a `(Blanks)` row appears last. Check only `(Blanks)` + Apply → only null/empty rows remain.

- [ ] **Step 7.4: Cascading** — Apply `proto = tcp` (via Advanced or checklist on proto). Open `source_ip` filter → its list shows only IPs present in tcp rows.

- [ ] **Step 7.5: All checked = clear** — Open a filtered column, check everything, Apply → the column's filter is removed (filter icon no longer active). Zero checked → Apply is disabled.

- [ ] **Step 7.6: Advanced mode + mutual exclusivity** — Open a column, expand "Advanced text filter", choose `contains` + type a value, Apply → grid filters by substring. Reopen → Advanced is expanded showing that operator. Now collapse Advanced, change the checklist, Apply → the checklist `.isAnyOf` filter replaces the advanced one.

- [ ] **Step 7.7: Numeric ordering** — On a numeric column (e.g. port), the list is sorted numerically (e.g. 20, 80, 443, 1000), not lexically (1000 before 20).

- [ ] **Step 7.8: High cardinality** — On a high-distinct-count column, the list scrolls smoothly and Search narrows it.

- [ ] **Step 7.9: Load More** — With an `.isAnyOf` filter active, click Load More → newly fetched rows are filtered by the same checked set.

- [ ] **Step 7.10: Other column types** — Confirm the checklist also appears for boolean, temporal, and JSON columns, and that the Advanced section still offers type-appropriate operators (between, <, >, is true/false, etc.).

---

## Self-Review Notes

Spec coverage:
- `.isAnyOf` operator + blanks sentinel (spec §Architecture/Model) → Task 1
- `.isAnyOf` evaluation (spec §Architecture/3) → Task 2
- Cascading distinct values, type-aware sort (spec §Architecture/2, §Edge Cases) → Task 3
- `FilterValueListView` virtualized checklist, Select All, search, blanks (spec §Architecture/4) → Task 4
- Popover restructure: search + checklist + two-mode Apply (spec §Architecture/5, §Data Flow) → Task 5
- Collapsible Advanced + open-mode restore + precedence (spec §Architecture/5) → Task 6
- All edge cases + behaviors (spec §Edge Cases, §Testing) → Task 7

Type consistency: `ColumnFilter.blanksSentinel`, `FilterOperator.isAnyOf`, `distinctValues(forColumnIndex:excludingColumnId:category:)`, `FilterValueListView.setValues(_:checked:)` / `.checkedValues` / `.applySearch(_:)` / `.onSelectionChanged`, and the new `ColumnFilterPopoverVC.init(…distinctValues:hasBlanks:)` are used consistently across Tasks 1–6.

No `pharos-core` changes — distinct values are computed Swift-side from loaded rows.
