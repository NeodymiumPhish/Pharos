# Column Filter Value Picker (Excel-style) — Design

**Date:** 2026-05-27
**Status:** Design — pending implementation plan

## Problem

The results-grid column filter popover (`ColumnFilterPopoverVC`) today offers a type-aware operator dropdown (contains, equals, between, contains any of, …) with text/token/date inputs. To filter a column to a specific set of observed values — e.g. pick 5 of the 30 distinct `source_ip` values — the user must know the values in advance and type them into a token field. There is no way to see and pick from the values actually present in the column.

## Goal

Add an Excel-style distinct-values checklist as the **primary** filter UI for every column: a searchable, scrollable list of the column's distinct values with checkboxes, so the user checks the values to keep. The existing operator-based filtering moves into a collapsible "Advanced text filter" section for substring/range/comparison filters.

## Non-Goals

- No "Sort (A→Z / Z→A)" controls in the popover — sorting stays on the column-header click. (Filter-only scope.)
- No "By color" filtering — Pharos cells are not colored by data value.
- No `pharos-core` / Rust changes — distinct values are computed Swift-side from already-loaded rows.
- No auto-apply — keep the explicit Apply/Clear buttons the popover uses today.
- No server-side distinct-value query — the list is computed from loaded rows only.

## Decisions (locked during brainstorming)

1. **Interaction model: Excel-pure.** The distinct-values checklist is the main filter; the operator dropdown is demoted into a collapsible "Advanced text filter" section.
2. **Cascading values.** A column's list shows only values present in rows passing **all other columns'** active filters (not the column's own).
3. **Mutually exclusive modes.** A column is filtered EITHER by a checklist selection OR by one Advanced operator — last applied wins. One filter per column (model unchanged except a new operator).
4. **Show all distinct values**, rely on the search box; no cardinality cap.
5. **All column types** get the checklist (text, numeric, temporal, boolean, JSON).

## Architecture

### 1. Model — new operator (`Pharos/Utilities/ColumnFilter.swift`)

Add a `FilterOperator` case:

- **`.isAnyOf`** — exact-equality, multi-value. Uses the existing `values: [String]?` field. Display label e.g. "is any of".

A checklist filter is represented as:

```swift
ColumnFilter(
    columnName: <col>,
    op: .isAnyOf,
    value: "",
    value2: nil,
    values: [<checked display strings>],
    dataType: <type>
)
```

`.isAnyOf` is `needsMultiValue == true`, `needsValue == false`, `needsSecondValue == false`. It is **not** offered in the Advanced operator dropdown (it is produced only by the checklist), so the dropdown's operator list is unchanged. `FilterOperator.operators(for:)` does **not** include `.isAnyOf`.

**Blanks sentinel:** the checklist's `(Blanks)` entry, when checked, contributes a reserved sentinel string to `values`. Define a constant:

```swift
extension ColumnFilter { static let blanksSentinel = "\u{0}__pharos_blanks__" }
```

(A NUL-prefixed string that cannot collide with a real rendered cell value.)

### 2. Distinct-values computation (`ResultsColumnFilterController`)

New method:

```swift
/// Distinct display-string values for a column, over rows that pass every
/// OTHER column's active filter (cascading). Sorted type-aware ascending;
/// `(Blanks)` sentinel appended last if any null/empty cells were seen.
func distinctValues(forColumnIndex idx: Int, excludingColumnId colId: String,
                    category: PGTypeCategory) -> (values: [String], hasBlanks: Bool)
```

Behavior:
- Iterate `filterableRows` (the full `rows: [[AnyCodable]]` from the delegate).
- For each row, evaluate all `activeFilters` **except** the one whose key is `colId` (the column being edited). Skip rows that fail.
- For passing rows, read `rows[r][idx]`. If null or its `displayString` is empty → mark `hasBlanks = true`. Else insert `displayString` into a `Set<String>`.
- Sort the set type-aware:
  - numeric category → ascending by `Double(s)` (non-parseable sort last among numerics, stable),
  - temporal category → chronological by the same date parsing the evaluator uses,
  - else → `localizedStandardCompare` (case/diacritic-insensitive, natural).
- Return `(sortedValues, hasBlanks)`. The popover appends a `(Blanks)` UI row when `hasBlanks`.

This is a single linear pass over loaded rows (≤ tens of thousands), executed when the popover opens — no caching needed.

### 3. Evaluation — `.isAnyOf` branch (`ResultsColumnFilterController.evaluate`)

Add a branch (reusing the `Set` membership pattern already used by "contains any of", but exact):

```swift
case .isAnyOf:
    let set = Set(filter.values ?? [])
    let isBlank = (value == nil) || value!.displayString.isEmpty
    if isBlank { return set.contains(ColumnFilter.blanksSentinel) }
    return set.contains(value!.displayString)
```

Exact equality on the rendered `displayString`, consistent with how the checklist gathers values, so it works uniformly across all column types.

### 4. Checklist view (`Pharos/ViewControllers/ResultsGrid/FilterValueListView.swift`, new)

A self-contained, virtualized checklist. One responsibility: display a list of strings with checkboxes and report the checked set. Knows nothing about filters or the grid.

- Backed by an `NSTableView` (single column, view-based, virtualized) inside an `NSScrollView` — realizes only visible rows so thousands of values scroll smoothly.
- Rows: a leading `(Select All)` row, then one checkbox row per value. `(Blanks)` is provided by the owner as just another value row (using the blanks sentinel as its model value, "(Blanks)" as its label).
- Each row: an `NSButton` checkbox (`.switch`/checkbox style) + a truncating label with the full value as `toolTip`.
- API:
  - `func setValues(_ values: [String], checked: Set<String>)`
  - `var checkedValues: Set<String> { get }`
  - `var onSelectionChanged: (() -> Void)?`
  - `func applySearch(_ query: String)` — filters which rows are visible (case-insensitive substring on the label); checked state of hidden rows is preserved.
- `(Select All)`:
  - Reflects checked / unchecked / mixed (dash) over the **currently visible** (post-search) rows.
  - Toggling it checks or unchecks **only the visible rows**, leaving hidden rows' state intact.
  - Disabled when no rows are visible (empty search result).

### 5. Popover restructure (`ColumnFilterPopoverVC`)

The popover becomes the coordinator. New top-to-bottom layout:

1. Header label `Filter: <displayName>` (unchanged).
2. Search field (`NSSearchField`) → `valueList.applySearch(_:)` on edit.
3. `FilterValueListView` (the checklist), with `(Select All)` as its first row.
4. Collapsible **"Advanced text filter"** disclosure (`NSButton` disclosure triangle). Collapsed by default. When expanded it reveals **today's** operator dropdown + dynamic value inputs (text/token/date/interval) — that existing subview tree is preserved and simply moved under the disclosure.
5. `Clear` / `Apply` buttons (unchanged positions).

**On open** (driven by the existing `existingFilter` passed in):
- Compute `(values, hasBlanks)` via the controller; build the checklist values (+ `(Blanks)` if `hasBlanks`).
- If no existing filter → all rows checked, Advanced collapsed.
- If existing `op == .isAnyOf` → check exactly `existingFilter.values`; Advanced collapsed.
- If existing filter with any other operator → all rows checked **and** Advanced expanded, pre-populated with that operator/value (today's restore logic).

**On Apply** (precedence is explicit to keep modes unambiguous):
- If the Advanced section is **expanded and forms a valid operator filter** (per today's validation — operator selected and its required value(s) present) → emit that operator's `ColumnFilter`. This replaces any checklist filter.
- Else (checklist mode — Advanced collapsed, or expanded but not validly populated):
  - All values checked (nothing excluded) → **clear** the column's filter (`didClearFilterForColumn`).
  - A strict subset checked → emit `ColumnFilter(op: .isAnyOf, values: Array(checkedValues), …)`.
  - Zero checked → Apply disabled (no emit).

**On Clear:** `didClearFilterForColumn`; reset checklist to all-checked, collapse Advanced.

Mutual exclusivity falls out naturally: only one `ColumnFilter` is ever emitted per Apply, and the popover opens in whichever mode the stored filter implies.

### 6. Delegate / wiring (unchanged contracts)

The existing `didApplyFilter(_:)` / `didClearFilterForColumn(_:)` delegate callbacks and `ResultsColumnFilterController` integration are unchanged — the popover still emits a single `ColumnFilter` or a clear. `ResultsGridVC` recomputes `columnFilteredDisplayRows` as today.

## Data Flow

```
Header filter-icon click
  → ColumnFilterPopoverVC opens
      → controller.distinctValues(forColumnIndex:excludingColumnId:category:)   // cascading
      → FilterValueListView.setValues(_, checked:)                              // initial state from existingFilter
  → user searches / checks / unchecks
      → applySearch filters visible rows; (Select All) toggles visible
  → Apply
      → checklist mode → ColumnFilter(.isAnyOf, values:)  OR  clear (all checked)
      → advanced mode  → existing operator ColumnFilter
  → delegate didApplyFilter / didClearFilterForColumn
  → ResultsColumnFilterController.applyFilters → evaluate (.isAnyOf branch)
  → ResultsGridVC recomputes columnFilteredDisplayRows → displayRows → reload
```

## Edge Cases

- **Numeric/temporal ordering:** distinct values sorted type-aware (numeric by `Double`, temporal chronological, else natural locale compare) so "100" doesn't sort before "20". `(Blanks)` always last.
- **High cardinality:** virtualized table + search; no cap.
- **Long values:** rows truncate with tail ellipsis; full value in `toolTip`.
- **All-null column:** list shows only `(Blanks)`.
- **Display-string collisions:** values rendering to the same string collapse to one entry (indistinguishable to the user).
- **Empty search result:** empty list; `(Select All)` disabled.
- **Cascading excludes own column:** a column's own active filter is ignored when building its list, so all its values stay selectable.
- **All checked → clear; zero checked → Apply disabled; mixed → `(Select All)` shows dash.**
- **Mutual-exclusivity restore:** reopening shows checklist state for `.isAnyOf`, or the expanded Advanced section for other operators.
- **Load More after filter:** newly fetched rows are evaluated against the active `.isAnyOf` set (correct); the distinct list refreshes on the next popover open.

## Testing (manual — no XCTest target)

1. String column (~30 distinct): open → all checked; uncheck some → Apply filters to checked set; reopen → state restored.
2. Search "10.0" → list narrows; `(Select All)` toggles only visible rows; clear search → prior selections intact.
3. `(Blanks)` filters null/empty rows.
4. Cascading: filter `proto = tcp`, then open `source_ip` → only IPs present in tcp rows listed.
5. Mutual exclusivity: apply checklist filter, reopen, expand Advanced, apply `contains x` → checklist filter replaced (and the reverse).
6. Numeric column (e.g. port): values sorted numerically.
7. High-cardinality column: smooth scroll + search.
8. All checked → Apply clears the filter; Clear resets to all-checked.
9. Load More after an `.isAnyOf` filter is active → newly fetched rows filtered correctly.

## Files Touched

- `Pharos/Utilities/ColumnFilter.swift` — add `FilterOperator.isAnyOf` (label, flags; excluded from `operators(for:)`); add `blanksSentinel` constant.
- `Pharos/ViewControllers/ResultsGrid/ResultsColumnFilterController.swift` — add `distinctValues(forColumnIndex:excludingColumnId:category:)`; add `.isAnyOf` branch in `evaluate`.
- `Pharos/ViewControllers/ResultsGrid/FilterValueListView.swift` — **new** virtualized checklist view.
- `Pharos/ViewControllers/ResultsGrid/ColumnFilterPopoverVC.swift` — restructure: search field + checklist + collapsible Advanced (existing operator UI) + Apply/Clear; open/apply logic for the two modes.
- `Pharos.xcodeproj` — regenerated for the new file.

No `pharos-core` changes.
