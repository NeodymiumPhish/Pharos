# Results-Grid Column Width & Two-Row Header — Design Spec

**Date:** 2026-07-21
**Status:** Approved for planning

## Summary

Results-grid columns default to an oversized width (short-content columns open at
~150px of dead space) and can't be resized past 720px. The root cause is the
**header packing four things onto one horizontal row** — column name, grey type
suffix, sort arrow (left), filter funnel (right) — which sets a width floor no
data-fit can beat.

Fix it by making the header **two rows**: row 1 the column **name**, row 2 the
**data type**, with the sort/filter affordances drawn as **overlays on row 2's
right** (appearing on hover / when active/sorted) so they reserve **no** horizontal
width. A column's width then collapses to `max(nameWidth, typeWidth, contentWidth)`.
Pair this with a **content-aware measurement** (measure what's actually rendered,
including the compact BOOL glyph) and raise the resize cap to **1000px**.

## Goals

- Columns open snug to `max(name, type, rendered-content)` — no wasted whitespace.
- Header shows the name prominently with the type as a subtitle; sort/filter
  affordances never widen a column (overlay on hover / when sorted).
- Width calc measures what's actually *drawn* (BOOL ✓/✗ glyph, null string,
  flattened text), not the raw value.
- Users can drag any column up to 1000px (horizontal scroll handles overflow).
- One shared measurement for the initial default and on-demand auto-fit.

## Non-Goals

- No change to the row-number column (`__rownum__`, fixed 40 / 30–60), other than
  it living in the now-taller header.
- No change to saved-width restore (`applyGridState`) — it overwrites the default.
- No per-window-resize width cap (static 1000; see brainstorming).
- No change to sorting/filtering *behavior* — only where the affordances are drawn
  and hit-tested.

## Current behavior (what's wrong)

`ResultsGridVC.swift`:
- **Default width** ([`estimateColumnWidth`:456](../../Pharos/ViewControllers/ResultsGridVC.swift)) ignores row data: `max(nameWidth, typeWidth)` with `typeWidth` a per-type constant (**text/default = 150**). A 2-char `cc` column opens at 150px. Set at column creation ([:433](../../Pharos/ViewControllers/ResultsGridVC.swift)), `minWidth = 50`, `maxWidth = 720`.
- **Auto-fit** ([`autoFitColumn`:661](../../Pharos/ViewControllers/ResultsGridVC.swift)) measures content but over-pads: header `+50`, content `+12`, clamp 720. It measures the **raw** `displayString` (BOOL → "true"/"false" ~30px vs the ~10px glyph) and, being one-row, can't shrink below `name+type+icons`.
- **Header** ([:437–451](../../Pharos/ViewControllers/ResultsGridVC.swift)): the cell's `attributedStringValue` is `"name  type"` on one line, in a `SortAwareHeaderCell`; the custom `filterableHeaderView` is the table's header view ([:121](../../Pharos/ViewControllers/ResultsGridVC.swift)).

Supporting facts (verified):
- `tableView.headerView = filterableHeaderView` — a custom `NSTableHeaderView`; the results layout already reads `headerView?.frame.height` ([`ResultsGridVC+Setup`:26](../../Pharos/ViewControllers/ResultsGrid/ResultsGridVC+Setup.swift)), so a taller header propagates to the layout.
- Cell text insets: leading **6** / trailing **6** ([`ResultsDataSource`:247–248](../../Pharos/ViewControllers/ResultsGrid/ResultsDataSource.swift)) → the content `+12` pad is exact.
- BOOL renders `boolTrueString`/`boolFalseString`, NULL renders `nullDisplayString` (italic), string/json/array are newline-flattened (`flattenedForCell`) — all in [`styleCell`:402](../../Pharos/ViewControllers/ResultsGrid/ResultsDataSource.swift). Cell font `regularFont` = `NSFont.monospacedSystemFont(ofSize:12)`.
- Sort arrow ([`SortAwareHeaderCell`:9–24](../../Pharos/ViewControllers/ResultsGrid/FilterableHeaderView.swift)): drawn **left** at `frame.minX + 4` when sorted and shifts the title right ~17px (removed by this redesign).
- Filter funnel ([`FilterableHeaderView`:249–256,207–229](../../Pharos/ViewControllers/ResultsGrid/FilterableHeaderView.swift)): `side = 13 + 6*2 = 25`, drawn at `maxX - 25 - 8`, only when hovered or filtered.
- Header click routing ([`FilterableHeaderView.mouseDown`:147–188](../../Pharos/ViewControllers/ResultsGrid/FilterableHeaderView.swift)): double-click near right edge → auto-fit; click inside `filterIconRect` → open filter; else → `super` (sort via `sortDescriptorPrototype`). Hit-testing follows `filterIconRect`, so moving that rect moves the hit area.

## Design

### 1. Two-row header
Increase the header height to fit two text lines (target ≈ **34px**, from ~24) by
sizing `filterableHeaderView` taller; the results layout already respects
`headerView.frame.height`.

- **Header cell** (`SortAwareHeaderCell`, or a small rename): holds the **name** and
  **type** as separate strings (not one `attributedStringValue`). `drawInterior`
  draws the name on the **top** sub-row (semibold ~11–12pt, primary colour) and the
  type on the **bottom** sub-row (~9pt, secondary colour), both left-aligned at the
  standard leading inset. The old left sort-arrow + `frame.origin.x` shift is
  **removed**.
- **Affordances drawn by `filterableHeaderView` as row-2 right overlays** (reserving
  no layout width):
  - **filter funnel** — on hover or when the column is filtered (as today), y
    repositioned to row 2.
  - **sort arrow** (▲/▼) — whenever the column is sorted (persistent, so sort state
    is visible at rest), drawn just left of the funnel slot, also on row 2.
  On a narrow column these overlay the tail of the small type label; the **name
  (row 1) is never touched**. Sort-arrow rendering moves out of the cell into the
  header view (which already holds `sortDirections`), so it no longer shifts text.
- **Hit-testing / interaction unchanged in behavior**: `filterIconRect` is
  recomputed for the row-2 position; `mouseDown` routing (funnel-rect → filter,
  elsewhere → sort, right-edge double-click → auto-fit) is untouched. `minWidth`
  stays **50**, which guarantees room for the overlay affordances.

### 2. Content-aware width via one shared measurement
Replace `estimateColumnWidth` with a single method
`measuredColumnWidth(column:colId:includeVisibleSample:) -> CGFloat` used by both
the initial default and `autoFitColumn`, returning
`min(max(nameWidth, typeWidth, contentWidth, column.minWidth), 1000)`:
- `nameWidth = name.size(headerNameFont).width + headerInset`
- `typeWidth = type.size(headerTypeFont).width + headerInset`
- `contentWidth = maxₛₐₘₚₗₑ renderedText.size(cellFont).width + 12` (`cellFont = regularFont`)
- **No funnel reserve, no sort allowance** — both overlay row 2 (this is the payoff
  of the two-row header, and it removes the sort-arrow-shift bug by construction).
- `headerInset` = the cell's leading+trailing text inset (small, matching the cell's
  drawInterior insets).

Ordering (settled from code): `showResult` sets `rows` ([:191](../../Pharos/ViewControllers/ResultsGridVC.swift)) and `displayRows` ([:197](../../Pharos/ViewControllers/ResultsGridVC.swift)) **before** `rebuildColumns()` ([:207](../../Pharos/ViewControllers/ResultsGridVC.swift)); `reloadData()` runs after ([:210](../../Pharos/ViewControllers/ResultsGridVC.swift)). So the default is measured **at column creation** with `includeVisibleSample: false` (sample **first/last 100** only, since the visible-rect is stale pre-reload); `autoFitColumn` passes `true` (adds visible rows). Saved-width restore (`applyGridState` [:271](../../Pharos/ViewControllers/ResultsGridVC.swift)) runs after and overwrites — no carve-out.

### 3. Render-accurate content string
Introduce a pure helper so measured text == drawn text:
```
ResultCellText.rendered(value: AnyCodable, category: PGTypeCategory,
                        boolTrue: String, boolFalse: String, nullString: String) -> String
```
Returns: NULL → `nullString`; BOOL → `boolTrue`/`boolFalse` for `t`/`true`/`f`/`false`
(case-insensitive), else raw; string/json/array → `value.displayString.flattenedForCell`;
numeric/temporal/other → `value.displayString`. The measurement calls this per
sampled cell. **DRY:** `styleCell` is refactored to derive its displayed string from
the same helper (colour/font selection stays in `styleCell`), so measurement and
render can't drift.
- **Settings source:** `boolTrue`/`boolFalse`/`nullString` are the data source's
  existing `boolTrueString`/`boolFalseString`/`nullDisplayString` ([:160–162](../../Pharos/ViewControllers/ResultsGrid/ResultsDataSource.swift)); the measurement reads the same fields. Accepted: changing a display setting doesn't re-measure existing widths (affects the next load only).
- **NULL font:** null renders italic mono, measured with regular mono — sub-pixel slack, ignored.

### Net effect
`cc` measures ~40px from `max(name, type, content)` but **opens at exactly 50px —
the `minWidth` floor** (which also guarantees room for the row-2 overlay
affordances); the BOOL columns open to about their `is_selector` / `routable` name
width. Sort/filter never change a column's width. Long-content columns cap at 1000
by default and drag no wider than 1000.

## Testing

- **Pure (`swiftc` harness `scripts/test-result-cell-text.sh`)** for
  `ResultCellText.rendered`: BOOL `t`/`true`/`f`/`false`/`TRUE` → glyphs; unknown
  bool → raw; NULL → null string; string with newlines → flattened; numeric/
  temporal/json/array → expected. (This is where the BOOL over-measure lived.)
- **Build-gated + manual (GUI):**
  - Two-row header renders: name on top, type beneath; header height looks right
    (not too tall); row-number "#" reads cleanly in the taller header.
  - Short text/BOOL columns open snug — down to the 50px `minWidth` floor (the
    reported screenshot); a long-text/JSON column opens capped at 1000 and otherwise fits.
  - Sort/filter affordances overlay row 2 on hover / when sorted, **never shifting
    or widening** the column; the column **name** is never obscured; sort direction
    is visible at rest when a column is sorted.
  - Filter funnel still opens the filter popover; header click still sorts;
    right-edge double-click auto-fits; drag stops at 1000; saved widths restore.

## Phasing

- **A — `ResultCellText.rendered` pure helper** (TDD) + refactor `styleCell` to use it.
- **B — Two-row header rendering**: size `filterableHeaderView` taller; two-row cell
  drawing (name row 1 / type row 2). **Remove `SortAwareHeaderCell.sortIndicator` +
  its `drawInterior` left-shift, and delete or repurpose `updateSortCellIndicators`
  ([`FilterableHeaderView`:234–245](../../Pharos/ViewControllers/ResultsGrid/FilterableHeaderView.swift)) to trigger a header-view redraw** instead of pushing the arrow onto the cell — otherwise the cell still draws its left arrow and *both* arrows render. Draw the sort arrow + filter funnel as row-2 right overlays in the header view; reposition `filterIconRect`. **Keep `col.title = colDef.name` ([:432](../../Pharos/ViewControllers/ResultsGridVC.swift))** (feeds accessibility + the column-drag image) even though the combined `attributedStringValue` is dropped. Build-gated + manual.
- **C — Width measurement**: `measuredColumnWidth` (`max(name, type, content)`, no
  icon reserve), applied as the default at column creation (`includeVisibleSample:false`)
  and by `autoFitColumn` (`true`); remove `estimateColumnWidth`; `maxWidth`/clamp → 1000.
  Build-gated + manual.

## Risks / Open Questions

- **Custom header height** — `NSTableHeaderView` normally matches a system height;
  setting `filterableHeaderView` taller must actually take effect and stay in sync
  with the scroll/clip layout ([`ResultsGridVC+Setup`:26](../../Pharos/ViewControllers/ResultsGrid/ResultsGridVC+Setup.swift) reads it). Verify early in Phase B; if the header won't grow cleanly, that's the task's main risk.
- **Two-line cell drawing** — vertical placement of name/type within the taller cell
  (baseline math, retina), and the `#` header rendering acceptably. Manual-tune.
- **Overlay on narrow columns** — funnel/sort cover the type label's tail on the
  narrowest columns; accepted per brainstorming (name always clear). `minWidth = 50`
  keeps the affordances usable.
- **Sample cost** — ≤~200–300 rows sampled once per column; negligible.
