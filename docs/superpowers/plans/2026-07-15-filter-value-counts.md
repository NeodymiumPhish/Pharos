# Per-Value Row Counts in the Column Filter Popover — Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Show a subdued, right-aligned `filtered/total` (or single `total`) row count beside each value in the filter popover checklist, with a Value/Count sort toggle and a partial-data footer.

**Architecture:** Extend the existing in-memory distinct-values pass to also tally per-value `total` (all rows) and `filtered` (rows passing other columns' filters), returned as a `[String: FilterValueCount]` map. A pure `FilterValueCount` renders the count string; a pure `FilterValueSort` orders values by value or count. The checklist row becomes a `FilterCheckRowView` (checkbox + trailing count label). The popover threads the counts through, adds a header sort control (momentary segmented control with re-click-to-reverse) and a `hasMore` footer.

**Tech Stack:** Swift / AppKit. Pure logic tested via standalone `swiftc` harness (no XCTest target — see `scripts/test-*.sh`). App build via `xcodebuild`. New files require `xcodegen generate`.

---

## File Structure

- **Create** `Pharos/ViewControllers/ResultsGrid/FilterValueCount.swift` — pure struct: `filtered`, `total`, `display`. Unit-tested.
- **Create** `Pharos/ViewControllers/ResultsGrid/FilterValueSort.swift` — pure: `FilterValueSortField` enum + `FilterValueSort.ordered(...)`. Unit-tested.
- **Create** `Pharos/ViewControllers/ResultsGrid/FilterCheckRowView.swift` — AppKit cell view: checkbox + right-aligned count label.
- **Create** `PharosTests/FilterValueCountsTests.swift` + `scripts/test-filter-value-counts.sh` — harness for the two pure types.
- **Modify** `Pharos/ViewControllers/ResultsGrid/ResultsColumnFilterController.swift` — tally counts; return `DistinctValuesResult`.
- **Modify** `Pharos/ViewControllers/ResultsGrid/FilterValueListView.swift` — counts-aware `setValues`, `FilterCheckRowView` rows, sort mode, `maxCountWidth`.
- **Modify** `Pharos/ViewControllers/ResultsGrid/ColumnFilterPopoverVC.swift` — thread counts/rowCount/hasMore, header sort control, footer, auto-size for count column.
- **Modify** `Pharos/ViewControllers/ResultsGrid/ResultsGridVC+Delegates.swift` — pass counts + `rows.count` + `hasMore`.

**Standard app build command** (used below; also compiles the Rust core via the pre-build script):

```bash
xcodebuild -project Pharos.xcodeproj -scheme Pharos -configuration Debug build 2>&1 | tail -8
```
Expected on success: a line `** BUILD SUCCEEDED **`.

**Ordering note:** Tasks are ordered so every app build stays green. Leaf signatures (`setValues`, the VC initializer) gain **defaulted** parameters so their callers keep compiling until the final wiring task passes real data.

---

## Task 1: `FilterValueCount` + `FilterValueSort` (pure, TDD)

**Files:**
- Create: `Pharos/ViewControllers/ResultsGrid/FilterValueCount.swift`
- Create: `Pharos/ViewControllers/ResultsGrid/FilterValueSort.swift`
- Test: `PharosTests/FilterValueCountsTests.swift`
- Runner: `scripts/test-filter-value-counts.sh`

- [ ] **Step 1: Write the failing test**

Create `PharosTests/FilterValueCountsTests.swift`:

```swift
// Standalone test runner for FilterValueCount + FilterValueSort — no Xcode project.
// Compiled with the two source files by scripts/test-filter-value-counts.sh.
import Foundation

var failures = 0

func expectStr(_ actual: String, _ expected: String, _ name: String) {
    if actual == expected { print("PASS \(name)") } else {
        failures += 1
        print("FAIL \(name)\n  expected: \(expected)\n  actual:   \(actual)")
    }
}

func expectArr(_ actual: [String], _ expected: [String], _ name: String) {
    if actual == expected { print("PASS \(name)") } else {
        failures += 1
        print("FAIL \(name)\n  expected: \(expected)\n  actual:   \(actual)")
    }
}

func runTests() {
    // FilterValueCount.display
    expectStr(FilterValueCount(filtered: 10, total: 100).display, "10/100", "display differs → f/t")
    expectStr(FilterValueCount(filtered: 100, total: 100).display, "100", "display equal → total only")
    expectStr(FilterValueCount(filtered: 0, total: 0).display, "0", "display zero")
    expectStr(FilterValueCount(filtered: 1, total: 8).display, "1/8", "display small")

    // FilterValueSort.ordered — canonical (value-ascending) input
    let values = ["a", "b", "c"]
    let counts: [String: FilterValueCount] = [
        "a": FilterValueCount(filtered: 10, total: 100),
        "b": FilterValueCount(filtered: 3, total: 42),
        "c": FilterValueCount(filtered: 1, total: 8),
    ]
    expectArr(FilterValueSort.ordered(values, counts: counts, field: .value, ascending: true),
              ["a", "b", "c"], "value asc → as-provided")
    expectArr(FilterValueSort.ordered(values, counts: counts, field: .value, ascending: false),
              ["c", "b", "a"], "value desc → reversed")
    expectArr(FilterValueSort.ordered(values, counts: counts, field: .count, ascending: false),
              ["a", "b", "c"], "count desc → heavy first")
    expectArr(FilterValueSort.ordered(values, counts: counts, field: .count, ascending: true),
              ["c", "b", "a"], "count asc → light first")

    // Tie-break: equal filtered & total → stable by original order
    let tied = ["x", "y"]
    let tiedCounts: [String: FilterValueCount] = [
        "x": FilterValueCount(filtered: 5, total: 5),
        "y": FilterValueCount(filtered: 5, total: 5),
    ]
    expectArr(FilterValueSort.ordered(tied, counts: tiedCounts, field: .count, ascending: false),
              ["x", "y"], "count tie → stable original order")

    // Missing count entry → treated as zero, sorts last on desc
    expectArr(FilterValueSort.ordered(["a", "z"], counts: ["a": FilterValueCount(filtered: 4, total: 4)],
                                      field: .count, ascending: false),
              ["a", "z"], "missing count → zero")

    if failures == 0 { print("\nAll tests passed.") } else { print("\n\(failures) failure(s)."); exit(1) }
}
```

Create `scripts/test-filter-value-counts.sh`:

```bash
#!/bin/bash
# Standalone test runner for FilterValueCount + FilterValueSort — no Xcode project.
set -euo pipefail
cd "$(dirname "$0")/.."
TMPMAIN=$(mktemp -d)/main.swift
echo "runTests()" > "$TMPMAIN"
swiftc -o /tmp/filter-value-counts-tests \
  Pharos/ViewControllers/ResultsGrid/FilterValueCount.swift \
  Pharos/ViewControllers/ResultsGrid/FilterValueSort.swift \
  PharosTests/FilterValueCountsTests.swift \
  "$TMPMAIN"
/tmp/filter-value-counts-tests
```

- [ ] **Step 2: Run test to verify it fails**

Run:
```bash
chmod +x scripts/test-filter-value-counts.sh && ./scripts/test-filter-value-counts.sh
```
Expected: FAIL — compile error, the source files don't exist yet.

- [ ] **Step 3: Write `FilterValueCount.swift`**

```swift
/// A per-value row tally for the column filter checklist. Pure (no AppKit) so it
/// is unit-testable via scripts/test-filter-value-counts.sh.
struct FilterValueCount {
    /// Rows with this value that pass the other columns' active filters.
    let filtered: Int
    /// Rows with this value ignoring all filters (the denominator).
    let total: Int

    /// "total" when nothing narrows the value (filtered == total),
    /// otherwise "filtered/total".
    var display: String {
        filtered == total ? "\(total)" : "\(filtered)/\(total)"
    }
}
```

- [ ] **Step 4: Write `FilterValueSort.swift`**

```swift
/// Which key the filter checklist is sorted by.
enum FilterValueSortField {
    case value
    case count
}

/// Pure ordering for the filter checklist. `values` must arrive in the canonical
/// type-aware ascending order; this reorders them for display. No AppKit.
enum FilterValueSort {
    static func ordered(_ values: [String],
                        counts: [String: FilterValueCount],
                        field: FilterValueSortField,
                        ascending: Bool) -> [String] {
        switch field {
        case .value:
            return ascending ? values : values.reversed()
        case .count:
            let index = Dictionary(uniqueKeysWithValues: values.enumerated().map { ($1, $0) })
            return values.sorted { a, b in
                let fa = counts[a]?.filtered ?? 0
                let fb = counts[b]?.filtered ?? 0
                if fa != fb { return ascending ? fa < fb : fa > fb }
                let ta = counts[a]?.total ?? 0
                let tb = counts[b]?.total ?? 0
                if ta != tb { return ascending ? ta < tb : ta > tb }
                return (index[a] ?? 0) < (index[b] ?? 0)   // stable by original order
            }
        }
    }
}
```

- [ ] **Step 5: Run test to verify it passes**

Run: `./scripts/test-filter-value-counts.sh`
Expected: all `PASS`, then `All tests passed.`

- [ ] **Step 6: Commit**

```bash
git add Pharos/ViewControllers/ResultsGrid/FilterValueCount.swift \
        Pharos/ViewControllers/ResultsGrid/FilterValueSort.swift \
        PharosTests/FilterValueCountsTests.swift \
        scripts/test-filter-value-counts.sh
git commit -m "feat: FilterValueCount + FilterValueSort pure helpers with tests"
```
End the commit body with:
`Co-Authored-By: Claude Opus 4.8 <noreply@anthropic.com>`

---

## Task 2: `FilterCheckRowView` (checklist cell view)

**Files:**
- Create: `Pharos/ViewControllers/ResultsGrid/FilterCheckRowView.swift`

- [ ] **Step 1: Write the implementation**

```swift
import AppKit

/// One checklist row: a checkbox (the value) plus a right-aligned, subdued count
/// label. The owning view configures `checkbox` (title/state/target/action/tag)
/// and `countLabel.stringValue` per row and reuses instances by identifier.
final class FilterCheckRowView: NSView {

    let checkbox = NSButton(checkboxWithTitle: "", target: nil, action: nil)
    let countLabel = NSTextField(labelWithString: "")

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)

        checkbox.lineBreakMode = .byTruncatingTail
        checkbox.translatesAutoresizingMaskIntoConstraints = false
        // Let the checkbox title truncate instead of pushing the count off-screen.
        checkbox.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        checkbox.setContentHuggingPriority(.defaultLow, for: .horizontal)

        countLabel.font = .monospacedDigitSystemFont(ofSize: 11, weight: .regular)
        countLabel.textColor = .secondaryLabelColor
        countLabel.alignment = .right
        countLabel.translatesAutoresizingMaskIntoConstraints = false
        countLabel.setContentHuggingPriority(.required, for: .horizontal)
        countLabel.setContentCompressionResistancePriority(.required, for: .horizontal)

        addSubview(checkbox)
        addSubview(countLabel)
        NSLayoutConstraint.activate([
            checkbox.leadingAnchor.constraint(equalTo: leadingAnchor),
            checkbox.centerYAnchor.constraint(equalTo: centerYAnchor),
            checkbox.trailingAnchor.constraint(lessThanOrEqualTo: countLabel.leadingAnchor, constant: -6),
            countLabel.trailingAnchor.constraint(equalTo: trailingAnchor),
            countLabel.centerYAnchor.constraint(equalTo: centerYAnchor),
        ])
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) not used") }
}
```

- [ ] **Step 2: Syntax-check**

Run: `swiftc -parse Pharos/ViewControllers/ResultsGrid/FilterCheckRowView.swift`
Expected: no output, exit 0. (Full app build happens in Task 3 after the project is regenerated.)

- [ ] **Step 3: Commit**

```bash
git add Pharos/ViewControllers/ResultsGrid/FilterCheckRowView.swift
git commit -m "feat: FilterCheckRowView — checklist row with checkbox + count label"
```
End the commit body with the `Co-Authored-By` trailer.

---

## Task 3: Regenerate project & verify new files build

- [ ] **Step 1: Regenerate**

Run: `xcodegen generate`
Expected: `Created project at .../Pharos.xcodeproj`. Picks up the three new files.

- [ ] **Step 2: Build**

Run: `xcodebuild -project Pharos.xcodeproj -scheme Pharos -configuration Debug build 2>&1 | tail -8`
Expected: `** BUILD SUCCEEDED **`. (The three new types are unused so far — this confirms they compile in-project.)

- [ ] **Step 3: Commit the regenerated project**

```bash
git add Pharos.xcodeproj/project.pbxproj
git commit -m "chore: xcodegen — add FilterValueCount/Sort + FilterCheckRowView to project"
```
End the commit body with the `Co-Authored-By` trailer.

---

## Task 4: Tally counts in `distinctValues`

**Files:**
- Modify: `Pharos/ViewControllers/ResultsGrid/ResultsColumnFilterController.swift:76-106`

- [ ] **Step 1: Add the result struct**

At file scope in `ResultsColumnFilterController.swift` (e.g. just above the class, or directly above the `distinctValues` method), add:

```swift
/// Distinct values for a column plus per-value row counts, for the filter checklist.
struct DistinctValuesResult {
    let values: [String]                       // shown values, type-aware ascending
    let hasBlanks: Bool                         // any null/empty in rows passing other filters
    let counts: [String: FilterValueCount]      // keyed by display string + blanksSentinel
}
```

- [ ] **Step 2: Replace the method body**

Replace the whole `distinctValues(...)` method (currently `:76-106`, the tuple-returning version) with:

```swift
    /// Distinct display-string values for a column, computed over rows that pass
    /// every OTHER column's active filter (cascading). Also tallies, per value,
    /// `filtered` (rows passing the other filters) and `total` (all rows). Values
    /// are sorted type-aware ascending. `hasBlanks` is true if any null/empty cell
    /// appeared among rows passing the other filters (caller adds a "(Blanks)" row).
    func distinctValues(forColumnIndex idx: Int,
                        excludingColumnId colId: String,
                        category: PGTypeCategory) -> DistinctValuesResult {
        guard let delegate = delegate else {
            return DistinctValuesResult(values: [], hasBlanks: false, counts: [:])
        }
        let rows = delegate.filterableRows
        let categories = delegate.filterableColumnCategories

        // Every active filter except the column being edited (so all of this
        // column's values stay selectable even when it already has a filter).
        let otherFilters = activeFilters.filter { $0.key != colId }

        var total: [String: Int] = [:]
        var filtered: [String: Int] = [:]

        for row in rows {
            // Does this row pass every OTHER column's filter?
            var passes = true
            for (fColId, filter) in otherFilters {
                guard let fIdx = colIndex(from: fColId) else { continue }
                let fCat = fIdx < categories.count ? categories[fIdx] : .string
                let fVal: AnyCodable? = fIdx < row.count ? row[fIdx] : nil
                if !evaluate(filter: filter, value: fVal, category: fCat) { passes = false; break }
            }

            let cell: AnyCodable? = idx < row.count ? row[idx] : nil
            let key: String
            if cell == nil || cell!.isNull || cell!.displayString.isEmpty {
                key = ColumnFilter.blanksSentinel
            } else {
                key = cell!.displayString
            }
            total[key, default: 0] += 1
            if passes { filtered[key, default: 0] += 1 }
        }

        // Shown values = those appearing in >=1 row passing the other filters.
        let blanks = ColumnFilter.blanksSentinel
        let sorted = sortValues(filtered.keys.filter { $0 != blanks }, category: category)
        let hasBlanks = (filtered[blanks] ?? 0) >= 1

        var counts: [String: FilterValueCount] = [:]
        for key in sorted {
            counts[key] = FilterValueCount(filtered: filtered[key] ?? 0, total: total[key] ?? 0)
        }
        if hasBlanks {
            counts[blanks] = FilterValueCount(filtered: filtered[blanks] ?? 0, total: total[blanks] ?? 0)
        }
        return DistinctValuesResult(values: sorted, hasBlanks: hasBlanks, counts: counts)
    }
```

Note: `sortValues` takes `_ values: [String]`; `filtered.keys.filter { ... }` yields `[String]`, which is fine to pass directly. The existing caller in `ResultsGridVC+Delegates.swift` reads `distinct.values` / `distinct.hasBlanks`, which are unchanged property names, so it keeps compiling.

- [ ] **Step 3: Confirm there are no other callers**

Run: `grep -rn "distinctValues(" Pharos/`
Expected: only the definition and the single call in `ResultsGridVC+Delegates.swift`. If any other caller exists that destructured the old tuple, update it to use the struct's `.values`/`.hasBlanks`.

- [ ] **Step 4: Build**

Run the standard build command.
Expected: `** BUILD SUCCEEDED **`.

- [ ] **Step 5: Commit**

```bash
git add Pharos/ViewControllers/ResultsGrid/ResultsColumnFilterController.swift
git commit -m "feat: tally per-value filtered/total counts in distinctValues"
```
End the commit body with the `Co-Authored-By` trailer.

---

## Task 5: Counts, cell view, and sort in `FilterValueListView`

**Files:**
- Modify: `Pharos/ViewControllers/ResultsGrid/FilterValueListView.swift`

- [ ] **Step 1: Add stored state**

After `private var searchQuery: String = ""` (`:20`), add:

```swift
    private var counts: [String: FilterValueCount] = [:]
    private var sortField: FilterValueSortField = .value
    private var sortAscending: Bool = true
```

- [ ] **Step 2: Update `setValues` to accept counts (defaulted)**

Replace the existing `setValues` (`:79-84`):

```swift
    /// Replace the list contents and the initial checked set.
    func setValues(_ values: [String], checked: Set<String>) {
        self.allValues = values
        self.checked = checked
        applySearch(searchQuery)
    }
```

with:

```swift
    /// Replace the list contents, the initial checked set, and per-value counts.
    /// `values` must be in canonical (type-aware ascending) order. `counts`
    /// defaults empty (no count labels) so callers can omit it.
    func setValues(_ values: [String], checked: Set<String>,
                   counts: [String: FilterValueCount] = [:]) {
        self.allValues = values
        self.checked = checked
        self.counts = counts
        applySearch(searchQuery)
    }
```

- [ ] **Step 3: Sort by the current mode inside `applySearch`, and add `setSort`**

Replace `applySearch` (`:91-100`):

```swift
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
```

with:

```swift
    func applySearch(_ query: String) {
        searchQuery = query
        let base = FilterValueSort.ordered(allValues, counts: counts,
                                           field: sortField, ascending: sortAscending)
        let q = query.trimmingCharacters(in: .whitespaces).lowercased()
        if q.isEmpty {
            visibleValues = base
        } else {
            visibleValues = base.filter { displayLabel(for: $0).lowercased().contains(q) }
        }
        tableView.reloadData()
    }

    /// Change the sort field/direction and re-render (checked state preserved).
    func setSort(field: FilterValueSortField, ascending: Bool) {
        sortField = field
        sortAscending = ascending
        applySearch(searchQuery)
    }
```

- [ ] **Step 4: Add `maxCountWidth`**

Immediately after `maxValueWidth(font:)` (`:69-77`), add:

```swift
    /// Widest rendered count-label width across the value set, using the given
    /// font. Returns 0 if no value has a count. Used to size the popover's count
    /// column.
    func maxCountWidth(font: NSFont) -> CGFloat {
        let attrs: [NSAttributedString.Key: Any] = [.font: font]
        var widest: CGFloat = 0
        for value in allValues {
            guard let text = counts[value]?.display, !text.isEmpty else { continue }
            let w = (text as NSString).size(withAttributes: attrs).width
            if w > widest { widest = w }
        }
        return widest
    }
```

- [ ] **Step 5: Render rows with `FilterCheckRowView`**

Replace the `tableView(_:viewFor:row:)` method (`:143-171`) with:

```swift
    func tableView(_ tableView: NSTableView, viewFor tableColumn: NSTableColumn?, row: Int) -> NSView? {
        let id = NSUserInterfaceItemIdentifier("checkRow")
        let cell = (tableView.makeView(withIdentifier: id, owner: self) as? FilterCheckRowView)
            ?? FilterCheckRowView()
        cell.identifier = id

        let box = cell.checkbox
        box.target = self
        box.action = #selector(toggleRow(_:))
        box.tag = row

        if row == 0 {
            box.title = "(Select All)"
            box.font = .systemFont(ofSize: 12, weight: .medium)
            box.allowsMixedState = true
            box.state = selectAllState
            box.isEnabled = !visibleValues.isEmpty
            box.toolTip = nil
            cell.countLabel.stringValue = ""
        } else {
            let value = visibleValues[row - 1]
            let label = displayLabel(for: value)
            box.title = label
            box.font = .systemFont(ofSize: 12)
            box.allowsMixedState = false
            box.state = checked.contains(value) ? .on : .off
            box.isEnabled = true
            box.toolTip = label
            cell.countLabel.stringValue = counts[value]?.display ?? ""
        }
        return cell
    }
```

`toggleRow(_:)` is unchanged — it still reads `sender.tag` / `sender.state`, and `sender` is now `cell.checkbox` (an `NSButton`), so its logic is unaffected.

- [ ] **Step 6: Build**

Run the standard build command.
Expected: `** BUILD SUCCEEDED **`. (The VC still calls `setValues` without counts → the default `[:]` applies, so no count labels render yet; sort defaults to value-ascending = current behavior.)

- [ ] **Step 7: Commit**

```bash
git add Pharos/ViewControllers/ResultsGrid/FilterValueListView.swift
git commit -m "feat: FilterValueListView renders counts + supports value/count sort"
```
End the commit body with the `Co-Authored-By` trailer.

---

## Task 6: Thread counts + sort control + footer into `ColumnFilterPopoverVC`

**Files:**
- Modify: `Pharos/ViewControllers/ResultsGrid/ColumnFilterPopoverVC.swift`

- [ ] **Step 1: Add stored properties**

After `weak var hostPopover: NSPopover?` and the `advancedFieldWidthConstraints` line (near `:49-52`), add:

```swift
    private let counts: [String: FilterValueCount]
    private let loadedRowCount: Int
    private let hasMore: Bool

    private let sortControl = NSSegmentedControl()
    private let partialFooter = NSTextField(labelWithString: "")
    private var sortField: FilterValueSortField = .value
    private var sortAscending: Bool = true
```

- [ ] **Step 2: Accept the new init parameters (defaulted)**

The initializer currently ends its parameter list with `hasBlanks: Bool, referenceSize: CGSize`. Add three defaulted parameters and store them. Change the signature+body to:

```swift
    init(columnName: String, displayName: String, category: PGTypeCategory, dataType: String,
         existingFilter: ColumnFilter?, distinctValues: [String], hasBlanks: Bool,
         referenceSize: CGSize,
         counts: [String: FilterValueCount] = [:], loadedRowCount: Int = 0, hasMore: Bool = false) {
        self.columnName = columnName
        self.displayName = displayName
        self.category = category
        self.dataType = dataType
        self.existingFilter = existingFilter
        self.checklistValues = distinctValues + (hasBlanks ? [ColumnFilter.blanksSentinel] : [])
        self.referenceSize = referenceSize
        self.counts = counts
        self.loadedRowCount = loadedRowCount
        self.hasMore = hasMore
        super.init(nibName: nil, bundle: nil)
    }
```

(Match the exact existing assignments for the first parameters; only the last three lines and the three new parameters are added.)

- [ ] **Step 3: Configure the sort control + footer in `loadView`**

In `loadView`, before the "Assemble main stack" block (currently `:224`), add:

```swift
        // Sort control (Value / Count), momentary so a re-click on the active
        // field flips its direction. Lives in the header row, right-aligned.
        sortControl.segmentCount = 2
        sortControl.setLabel("Value ▲", forSegment: 0)
        sortControl.setLabel("Count", forSegment: 1)
        sortControl.trackingMode = .momentary
        sortControl.controlSize = .small
        sortControl.font = .systemFont(ofSize: 11)
        sortControl.target = self
        sortControl.action = #selector(sortSegmentClicked(_:))
        sortControl.setContentHuggingPriority(.required, for: .horizontal)

        let headerRow = NSStackView(views: [headerLabel, NSView(), sortControl])
        headerRow.orientation = .horizontal
        headerRow.distribution = .fill

        // Partial-data footer (shown only when more rows are unfetched).
        partialFooter.font = .systemFont(ofSize: 11)
        partialFooter.textColor = .secondaryLabelColor
        partialFooter.isHidden = true
        if hasMore {
            let fmt = NumberFormatter()
            fmt.numberStyle = .decimal
            let n = fmt.string(from: NSNumber(value: loadedRowCount)) ?? "\(loadedRowCount)"
            partialFooter.stringValue = "counts over \(n) loaded rows"
            partialFooter.isHidden = false
        }
```

- [ ] **Step 4: Use the header row + footer in stack assembly**

Replace the assembly block (`:224-230`):

```swift
        // Assemble main stack: header, search, checklist, disclosure header, advanced, buttons
        stackView.addArrangedSubview(headerLabel)
        stackView.addArrangedSubview(searchField)
        stackView.addArrangedSubview(valueList)
        stackView.addArrangedSubview(advancedHeader)
        stackView.addArrangedSubview(advancedContainer)
        stackView.addArrangedSubview(buttonRow)
```

with:

```swift
        // Assemble main stack: header row (+sort), search, checklist, footer,
        // disclosure header, advanced, buttons
        stackView.addArrangedSubview(headerRow)
        stackView.addArrangedSubview(searchField)
        stackView.addArrangedSubview(valueList)
        stackView.addArrangedSubview(partialFooter)
        stackView.addArrangedSubview(advancedHeader)
        stackView.addArrangedSubview(advancedContainer)
        stackView.addArrangedSubview(buttonRow)
```

- [ ] **Step 5: Pass counts into the three `setValues` calls**

In the "Determine initial mode" block (`:236-249`), add `counts: counts` to each `valueList.setValues(...)` call. The three become:

```swift
            valueList.setValues(checklistValues, checked: Set(existing.values ?? []), counts: counts)
```
```swift
            valueList.setValues(checklistValues, checked: allValues, counts: counts)
```
```swift
            valueList.setValues(checklistValues, checked: allValues, counts: counts)
```
(First is the `.isAnyOf` branch, second the advanced-operator branch, third the no-filter branch — mirror the existing `checked:` arguments exactly, only appending `counts: counts`.)

- [ ] **Step 6: Add the sort handler + label updater**

Add these methods to the class (e.g. near the other `@objc` actions):

```swift
    @objc private func sortSegmentClicked(_ sender: NSSegmentedControl) {
        let clicked: FilterValueSortField = (sender.selectedSegment == 1) ? .count : .value
        if clicked == sortField {
            sortAscending.toggle()                 // re-click active field → reverse
        } else {
            sortField = clicked
            sortAscending = (clicked == .value)    // value defaults asc, count defaults desc
        }
        updateSortControlLabels()
        valueList.setSort(field: sortField, ascending: sortAscending)
    }

    private func updateSortControlLabels() {
        let arrow = sortAscending ? "▲" : "▾"
        sortControl.setLabel(sortField == .value ? "Value \(arrow)" : "Value", forSegment: 0)
        sortControl.setLabel(sortField == .count ? "Count \(arrow)" : "Count", forSegment: 1)
    }
```

- [ ] **Step 7: Include the count column in `autoSizeWidth`**

Replace `autoSizeWidth()` (currently `:497-506`):

```swift
    private func autoSizeWidth() {
        let font = NSFont.systemFont(ofSize: 12)               // matches the checklist row font
        let widest = valueList.maxValueWidth(font: font)
        // Row chrome (checkbox glyph + gaps + trailing) + scroller + list bezel + stack insets.
        let chrome: CGFloat = 78
        currentWidth = FilterPopoverSizing.clampWidth(widest + chrome,
                                                      referenceWidth: referenceSize.width)
    }
```

with:

```swift
    private func autoSizeWidth() {
        let valueFont = NSFont.systemFont(ofSize: 12)          // matches the checklist row font
        let countFont = NSFont.monospacedDigitSystemFont(ofSize: 11, weight: .regular)
        let valueW = valueList.maxValueWidth(font: valueFont)
        let countW = valueList.maxCountWidth(font: countFont)
        let gap: CGFloat = countW > 0 ? 6 : 0
        // Row chrome (checkbox glyph + gaps + trailing) + scroller + list bezel + stack insets.
        let chrome: CGFloat = 78
        currentWidth = FilterPopoverSizing.clampWidth(valueW + gap + countW + chrome,
                                                      referenceWidth: referenceSize.width)
    }
```

- [ ] **Step 8: Build**

Run the standard build command.
Expected: `** BUILD SUCCEEDED **`. (The presenter still doesn't pass `counts`/`loadedRowCount`/`hasMore` → defaults apply, so counts are empty and the footer stays hidden until Task 7.)

- [ ] **Step 9: Commit**

```bash
git add Pharos/ViewControllers/ResultsGrid/ColumnFilterPopoverVC.swift
git commit -m "feat: filter popover header sort control, count plumbing, partial-data footer"
```
End the commit body with the `Co-Authored-By` trailer.

---

## Task 7: Wire counts + row count + hasMore from the presenter

**Files:**
- Modify: `Pharos/ViewControllers/ResultsGrid/ResultsGridVC+Delegates.swift:141-150`

- [ ] **Step 1: Pass the new arguments**

In `headerView(_:didClickFilterForColumn:at:)`, update the `ColumnFilterPopoverVC(...)` construction (`:141-150`) to pass the counts and grid state. Replace:

```swift
        let popoverVC = ColumnFilterPopoverVC(
            columnName: colId,
            displayName: columns[idx].name,
            category: category,
            dataType: rawDataType,
            existingFilter: existing,
            distinctValues: distinct.values,
            hasBlanks: distinct.hasBlanks,
            referenceSize: referenceSize
        )
```

with:

```swift
        let popoverVC = ColumnFilterPopoverVC(
            columnName: colId,
            displayName: columns[idx].name,
            category: category,
            dataType: rawDataType,
            existingFilter: existing,
            distinctValues: distinct.values,
            hasBlanks: distinct.hasBlanks,
            referenceSize: referenceSize,
            counts: distinct.counts,
            loadedRowCount: rows.count,
            hasMore: hasMore
        )
```

`rows` and `hasMore` are properties on `ResultsGridVC` (this file is an `extension ResultsGridVC`), so both are in scope. If the build reports either name is unresolved, run `grep -n "var rows\|var hasMore\|let rows\|let hasMore" Pharos/ViewControllers/ResultsGridVC.swift` and use the actual property names.

- [ ] **Step 2: Build**

Run the standard build command.
Expected: `** BUILD SUCCEEDED **`. Counts now flow end-to-end.

- [ ] **Step 3: Commit**

```bash
git add Pharos/ViewControllers/ResultsGrid/ResultsGridVC+Delegates.swift
git commit -m "feat: pass per-value counts, loaded row count, and hasMore to filter popover"
```
End the commit body with the `Co-Authored-By` trailer.

---

## Task 8: Manual verification

Run the app (`open Pharos.xcodeproj`, Cmd+R, or the built `.app`) against a database — e.g. a Zeek table with a categorical column like `service` and something long-tailed like `resp_bytes`.

- [ ] **Step 1: Single totals when unfiltered.** Open the filter on a column with no other filters active. Each value shows a single count (e.g. `100`), right-aligned and digit-aligned. `(Select All)` shows no count.

- [ ] **Step 2: `filtered/total` when narrowed.** Apply a filter on a *different* column (e.g. `email = a@example.com`), then reopen this column's filter. Values now show `filtered/total` (e.g. `web  10/100`); values fully within the other filter still show a single number.

- [ ] **Step 3: Sort toggle + reverse.** Click **Count** → list sorts heavy-hitters first, arrow shows `▾`. Click **Count** again → reverses to `▲` (long tail first). Click **Value** → back to type-aware order, `▲`; click **Value** again → reversed `▾`. Confirm checked state is preserved across sorts and that search + sort compose.

- [ ] **Step 4: Blanks.** On a column with null/empty cells, the `(Blanks)` row shows a count like any value.

- [ ] **Step 5: Partial-data footer.** On a result set with more rows available (the grid shows a "Load More" affordance / `hasMore`), the footer reads `counts over N,NNN loaded rows`. On a fully-loaded result set, no footer appears.

- [ ] **Step 6: Auto-size.** The popover opens wide enough that values and their counts both fit without the count overlapping the value; counts never truncate (long values still truncate with tooltip).

- [ ] **Step 7: Regressions.** Apply/Clear still work; Select-All tri-state, tooltips, search, the advanced text filter, and popover drag-resize all behave as before.

- [ ] **Step 8: Record results** in the plan's review section or `tasks/todo.md`. If any check fails, STOP and re-plan rather than pushing forward.

---

## Self-Review Notes

- **Spec coverage:** counts via extended single pass (Task 4) ✓; `FilterValueCount.display` single-vs-`f/t` (Task 1) ✓; right-aligned subdued monospaced count label (Tasks 2, 5) ✓; no count on Select-All (Task 5) ✓; header sort control with re-click-to-reverse and ▲/▾ arrows, Value→asc / Count→desc defaults (Tasks 1, 6) ✓; sort composes with search, checked state preserved (Task 5) ✓; partial-data footer, VC-owned, only when `hasMore` (Task 6) ✓; auto-size includes count column (Task 6) ✓; presenter supplies counts/rowCount/hasMore (Task 7) ✓.
- **Green-build seams:** `setValues` `counts` param and the VC init's `counts`/`loadedRowCount`/`hasMore` params are **defaulted**, so Tasks 4–6 build green before Task 7 wires real data. This is an intentional, harmless API default ("no counts available"), not dead code.
- **Type consistency:** `FilterValueCount(filtered:total:)` / `.display`, `FilterValueSortField.{value,count}`, `FilterValueSort.ordered(_:counts:field:ascending:)`, `DistinctValuesResult.{values,hasBlanks,counts}`, `FilterValueListView.setValues(_:checked:counts:)` / `setSort(field:ascending:)` / `maxCountWidth(font:)`, `FilterCheckRowView.{checkbox,countLabel}`, and the VC's `sortSegmentClicked`/`updateSortControlLabels` are used consistently across tasks.
- **Line numbers** are from the current files and will drift as edits land; anchor on the quoted code, not the numbers.
