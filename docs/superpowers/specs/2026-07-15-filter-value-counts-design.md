# Per-Value Row Counts in the Column Filter Popover

**Date:** 2026-07-15
**Status:** Approved (design)

## Problem

The column filter popover's checklist (`FilterValueListView`) shows each distinct
value with a checkbox, but nothing about how common each value is. An analyst
scanning a column like `resp_bytes` or `service` can't tell a dominant value from
a long-tail outlier, which is exactly the judgment the filter is meant to support.

## Goal

Show a subdued, right-aligned row count next to each value in the checklist:

- **`filtered/total`** when other active filters narrow the value
  (e.g. with `email = a@example.com` applied, the `service` value `web` shows
  `10/100`: 10 `web` rows within the email filter, 100 `web` rows overall).
- **`total`** alone when nothing narrows it (`filtered == total`), to avoid noise
  like `100/100` in the common no-other-filters case.

Plus a **sort toggle** (Value / Count) so the long tail and heavy hitters can be
surfaced directly, and a **partial-data indicator** because counts reflect only
the rows loaded into the grid so far.

## Non-Goals

- No database round-trip. Counts are computed over the in-memory loaded rows only
  (the same rows the filter already operates on). Whole-table counts for a
  truncated result set are out of scope — the partial indicator covers this.
- No live recount as the user checks/unchecks boxes in the popover. Counts reflect
  the *committed* filters at open time, not pending checklist edits.
- No count on the synthetic "(Select All)" row.

## Counting

`ResultsColumnFilterController.distinctValues(forColumnIndex:excludingColumnId:category:)`
(`ResultsColumnFilterController.swift:76-106`) already iterates every loaded row
(`delegate.filterableRows`) applying `otherFilters` (all active filters except the
edited column's own). Extend that single pass to build two tallies keyed by the
value's display string (and `ColumnFilter.blanksSentinel` for null/empty cells):

- `total[key] += 1` for **every** row (ignores all filters).
- `filtered[key] += 1` only when the row passes `otherFilters`.

A value is included in the list only if it appears in at least one row passing
`otherFilters` (unchanged from today — the shown set is identical). Its `total`
still counts all its rows, including ones the other filters exclude, so
`total >= filtered >= 1` for every listed value. Blanks are tallied the same way
under the sentinel key.

The method returns, in addition to the existing sorted `values` and `hasBlanks`,
a `counts: [String: FilterValueCount]` map. Cost is unchanged asymptotically —
one pass over loaded rows, same `evaluate(...)` calls as today.

## Components

### 1. `FilterValueCount.swift` (new — pure, unit-tested)

```swift
struct FilterValueCount {
    let filtered: Int
    let total: Int

    /// "total" when nothing narrows the value (filtered == total),
    /// otherwise "filtered/total".
    var display: String {
        filtered == total ? "\(total)" : "\(filtered)/\(total)"
    }
}
```

No AppKit import — testable via the standalone `swiftc` harness (see Testing).

### 2. `ResultsColumnFilterController.swift` (edit)

- Change `distinctValues(...)`'s return type to also carry the counts map. Define
  the return as a small struct (e.g. `DistinctValuesResult { values; hasBlanks;
  counts }`) or a 3-tuple; the struct is preferred for a named, documented
  interface.
- Build `total`/`filtered` tallies in the existing loop (`:95-102`) instead of a
  single `Set`. The set of shown values = keys with `filtered >= 1`, sorted by the
  existing `sortValues(_:category:)` (type-aware ascending, `:109-125`) — order
  unchanged.

### 3. `FilterValueListView.swift` (edit)

**Row layout.** Replace the bare `NSButton(checkboxWithTitle:)` cell
(`:143-171`) with a reused cell view containing the checkbox plus a trailing count
label:

```
[ checkbox: value (fills, .byTruncatingTail) ][ countLabel (right-aligned, hugs) ]
```

- The checkbox keeps its identity: same reuse identifier, `tag = row`,
  `target/action = toggleRow(_:)`, tri-state "(Select All)" behavior at row 0.
- `countLabel`: `NSTextField` (label), `.monospacedDigitSystemFont(ofSize: 11)`,
  `secondaryLabelColor`, right-aligned. Text = the value's
  `FilterValueCount.display`; empty on the "(Select All)" row.
- Use a container `NSView` with Auto Layout (checkbox leading, label trailing,
  label content-hugging high so the checkbox yields width). Avoid an `NSStackView`
  per row if reuse churn is a concern; a plain container with pinned constraints
  reuses cleanly.

**Counts model.** `setValues` gains a `counts: [String: FilterValueCount]`
parameter, stored alongside `allValues`. Missing key → treat as absent (no label).

**Sort.** Add sort state: `enum SortField { case value, count }`,
`sortField: SortField = .value`, `sortAscending: Bool = true`. Values arrive in
type-aware ascending order and are stored with their original index for stable
tiebreaking. `applySort()` orders `allValues` (before search filtering):

- `.value` ascending → original order; descending → reversed.
- `.count` → by `filtered` (then `total`, then original index) — descending puts
  heavy hitters first; ascending reverses.

The "(Select All)" row is always row 0 regardless of sort. Search filtering
applies to the sorted order. Expose `func setSort(field:ascending:)` for the VC's
control to drive; re-sort + reload on change without altering checked state.

**Partial-data footer.** Owned by the VC, not this view (keeps `setValues`
focused on the list). See §4 — the VC adds a subdued label to its stack, fed by
`hasMore`/`loadedRowCount` from its initializer.

### 4. `ColumnFilterPopoverVC.swift` (edit)

- Accept `counts: [String: FilterValueCount]`, `loadedRowCount: Int`,
  `hasMore: Bool` in the initializer; pass counts into `valueList.setValues(...)`.
- **Partial-data footer.** Add a subdued `NSTextField` label to the main stack
  just below the checklist (above the advanced-header row). When `hasMore`, set its
  text to `counts over \(loadedRowCount, thousands-separated) loaded rows` and show
  it; otherwise keep it hidden (`isHidden = true`, so it consumes no height). Font
  `.systemFont(ofSize: 11)`, `secondaryLabelColor`.
- **Sort control.** Put the header on a horizontal row:
  `[ "Filter: <name>" —— sortControl ]`, right-aligned, no added vertical space.
  `sortControl` is an `NSSegmentedControl` with two segments (`Value`, `Count`),
  `trackingMode = .momentary`, small control size. Momentary mode is required so a
  click on the *already-active* field still fires the action (select-one mode
  would swallow it). The VC holds `sortField`/`sortAscending` and on each click:
  - clicked segment == active field → flip `sortAscending`;
  - clicked segment != active field → switch field, set default direction
    (`.value` → ascending, `.count` → descending).
  Then update segment titles so the active segment shows a direction arrow
  (`Value ▲`/`Value ▾` or `Count ▲`/`Count ▾`) and the inactive shows its plain
  name, and call `valueList.setSort(field:ascending:)`.
- **Auto-size.** Extend `autoSizeWidth()` (`:497-506`) so the measured width
  includes the widest count label plus the gap, and bump the `chrome` accounting,
  so the popover opens wide enough for both the value and its count. Measure the
  count column via a helper on `FilterValueListView` (widest `display` string in
  the count font).

### 5. `ResultsGridVC+Delegates.swift` (edit)

Where the popover is built (`:132-150`): take the new `counts` from the
`distinctValues(...)` result, and pass the grid's loaded row count (`rows.count`)
and `hasMore` into the `ColumnFilterPopoverVC` initializer.

## Data Flow

1. User clicks a column's filter glyph.
2. `ResultsGridVC+Delegates` calls `distinctValues(...)`, which returns values +
   `hasBlanks` + `counts` (filtered/total per value), computed in one pass over the
   loaded rows with other-column filters applied.
3. The presenter builds `ColumnFilterPopoverVC` with the values, counts, and the
   grid's `rows.count` / `hasMore`.
4. The VC renders the checklist rows with right-aligned counts, a header sort
   control (default Value ▲), and — if `hasMore` — the partial-data footer.
5. User toggles the sort control: same field re-click flips direction, other field
   switches with its default direction; the list re-sorts in place.
6. Applying/clearing the filter is unchanged; counts are display-only.

## Error / Edge Handling

- **No other filters active:** every value has `filtered == total`, so each shows a
  single number — no `/`.
- **Blanks:** the `(Blanks)` row shows counts for null/empty cells like any value.
- **Value with count 0 filtered:** cannot occur in the list (shown set requires
  `filtered >= 1`).
- **Missing count for a value:** label is empty; no crash.
- **`hasMore` false:** footer hidden; counts are whole-result-set-accurate.
- **Long values + counts:** the value still truncates with its existing tooltip;
  the count column is fixed to the widest count and never truncates.
- **Re-clicking sort rapidly / during search:** sort and search compose; checked
  state is preserved across both.

## Testing

- **Unit (swiftc harness):** `FilterValueCount.display` — `10/100` when they
  differ, `100` when equal, `0` edge, single-row cases. Add
  `scripts/test-filter-value-count.sh` mirroring the existing harness pattern.
- **Unit (swiftc harness), optional:** a pure count-sort comparator if extracted
  from `FilterValueListView` — verify descending-by-filtered with total/index
  tiebreak, and direction flip.
- **Manual:** on a Zeek table, open a filter with no other filters → single totals;
  apply a second column's filter, reopen → `filtered/total` on the narrowed values;
  toggle Value/Count and re-click to reverse (arrow updates, order reverses);
  confirm counts are right-aligned and digit-aligned; with a truncated result set
  (`hasMore`) confirm the footer appears with the loaded row count; confirm
  Select-All, blanks, tooltips, search, Clear/Apply still behave.
