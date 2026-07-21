# Results-Grid Column Width — Design Spec

**Date:** 2026-07-21
**Status:** Approved for planning

## Summary

Fix results-grid columns defaulting to an oversized width (short-content columns
open at ~150px of dead space) and being un-resizable past 720px. Make the default
width **content-aware** — the width of the column name/type header and the actual
rendered cell contents — and tighten that measurement so it doesn't bake in
excess padding. Raise the resize cap to **1000px**.

## Goals

- Columns open snug to their header + rendered contents (no wasted whitespace).
- The width calc measures what is actually *drawn* (e.g. the BOOL ✓/✗ glyph), not
  the raw value ("true"/"false").
- Users can drag any column up to 1000px (horizontal scroll handles overflow).
- One shared measurement used by both the initial default and the on-demand
  auto-fit, so they never diverge.

## Non-Goals

- No change to the row-number column (`__rownum__`, fixed 40 / 30–60).
- No change to saved-width restore (`applyGridState`) — it still overrides the
  default when a workspace has a stored width per column.
- No dynamic per-window-resize width cap (a static 1000px cap; see brainstorming).
- No change to horizontal scrolling, sorting, or filtering.

## Current behavior (what's wrong)

`ResultsGridVC.swift`:
- **Default width** ([`estimateColumnWidth`:456](../../Pharos/ViewControllers/ResultsGridVC.swift)) ignores row data: `max(nameWidth, typeWidth)` where `nameWidth = name.count*8 + 20` and `typeWidth` is a per-type constant (**text/default = 150**, bool = 60, …). So a 2-char `cc` text column opens at 150px. Applied at column creation ([:433](../../Pharos/ViewControllers/ResultsGridVC.swift)) with `minWidth = 50`, `maxWidth = 720`.
- **Auto-fit** ([`autoFitColumn`:661](../../Pharos/ViewControllers/ResultsGridVC.swift)) *does* measure content but over-pads: header = `attributedStringValue.size().width + 50`; content = `value.displayString.size(font).width + 12`; clamps to `min(max(…), 720)`. Three flaws: (a) the **+50** is `33` (funnel footprint: box `25` + `8` right margin) + `17` (sort arrow) reserved **unconditionally** even for unsorted columns; (b) it measures the **raw** `displayString` — for BOOL that's "true"/"false" (~30px) though the cell renders the compact glyph (~10px); (c) it never accounts for the sort arrow when the column *is* sorted (the arrow isn't in `attributedStringValue`), so a sorted column's auto-fit is ~17px too narrow and its header text clips.

Supporting facts:
- Cell text insets are leading **6** / trailing **6** ([`ResultsDataSource`:247–248](../../Pharos/ViewControllers/ResultsGrid/ResultsDataSource.swift)) → the `+12` content pad is exact; keep it.
- BOOL cells render `boolTrueString`/`boolFalseString`, NULL renders `nullDisplayString`, and string/json/array are newline-flattened (`flattenedForCell`) — all in [`styleCell`:402](../../Pharos/ViewControllers/ResultsGrid/ResultsDataSource.swift). The measurement must mirror this.
- Header icons: filter funnel ([`FilterableHeaderView`:65–66,249–256](../../Pharos/ViewControllers/ResultsGrid/FilterableHeaderView.swift)) `side = iconSize(13) + iconPadding(6)*2 = 25`, drawn at `maxX - 25 - 8` (footprint 33px from the right edge; glyph inset 6 within the box), **only when hovered or the column is filtered**.
- Sort arrow ([`SortAwareHeaderCell`:9–24](../../Pharos/ViewControllers/ResultsGrid/FilterableHeaderView.swift)): drawn on the **left** at `frame.minX + 4` **when sorted**, then shifts the title frame right by `arrowWidth + 8 ≈ 17px` — and it is **not** part of `attributedStringValue`, so any header measurement must add this allowance itself for sorted columns.

## Design

### 1. Resize cap → 1000px
At column creation set `col.maxWidth = 1000` (was 720). Clamp `autoFitColumn` to
1000 (was 720). `minWidth` stays 50.

### 2. Content-aware default via one shared measurement
Extract the measurement into a single method
`measuredColumnWidth(column: NSTableColumn, colId: String, includeVisibleSample: Bool) -> CGFloat`
and use it for both the initial default and `autoFitColumn`. It returns
`min(max(headerWidth, contentWidth, column.minWidth), 1000)` where:
- `headerWidth = column.headerCell.attributedStringValue.size().width + funnelReserve + (isSorted(colId) ? sortArrowAllowance : 0)` (see §3).
- `contentWidth` = max over the sampled rows of `renderedText.size(cellFont).width + 12`
  (`cellFont = NSFont.monospacedSystemFont(ofSize: 12)` — this equals the cells' `regularFont`; verified).

Ordering is settled from the code: `showResult` sets `rows`
([:191](../../Pharos/ViewControllers/ResultsGridVC.swift)) and `displayRows`
([:197](../../Pharos/ViewControllers/ResultsGridVC.swift)) **before** calling
`rebuildColumns()` ([:207](../../Pharos/ViewControllers/ResultsGridVC.swift)), so the
default is measured **directly at column creation** (no post-load pass). But
`tableView.reloadData()` runs *after* ([:210](../../Pharos/ViewControllers/ResultsGridVC.swift)),
so at creation `tableView.rows(in: visibleRect)` still reflects the *previous*
result — therefore the initial default passes `includeVisibleSample: false` and
samples **first/last 100 only** (both drawn from the already-set `displayRows`/`rows`);
`autoFitColumn` passes `includeVisibleSample: true`. `estimateColumnWidth` (the
type-based heuristic) is removed. Saved-width restore (`applyGridState`
[:271](../../Pharos/ViewControllers/ResultsGridVC.swift)) runs after `showResult`
and simply overwrites the default for stored columns — no carve-out needed.

### 3. Tighter, render-accurate measurement
- **Header reserve = `funnelReserve(22)` + `sortArrowAllowance(17)` when sorted** (was a flat inline `+50`).
  - `funnelReserve = 22`: enough that the hover/active funnel grazes but doesn't hide the header. Accepted tradeoff (brainstorming): on a very narrow column the funnel may overlap the last few px of the small grey **type** label; the **column name is never obscured**.
  - `sortArrowAllowance ≈ 17` (`arrowWidth + 8`) is added **only when the column is sorted** (`sortController`/`sortDirections[colId] != nil`), because the arrow is drawn left-of-title and isn't in `attributedStringValue`. This fixes the current auto-fit-while-sorted under-measure (flaw (c) above): without it, sorting a snug column clips its type label *permanently* (not just on hover) and shifts the name under the funnel.
  - A comment documents both reserves.
- **Measure the rendered string, not the raw value.** Introduce a pure helper:
  ```
  ResultCellText.rendered(value: AnyCodable, category: PGTypeCategory,
                          boolTrue: String, boolFalse: String, nullString: String) -> String
  ```
  returning: NULL → `nullString`; BOOL → `boolTrue`/`boolFalse` for `t`/`true`/`f`/`false` (case-insensitive), else raw; string/json/array → `value.displayString.flattenedForCell`; numeric/temporal/other → `value.displayString`. The measurement calls this per sampled cell.
- **DRY:** `styleCell` is refactored to derive its displayed string from the same
  `ResultCellText.rendered(...)` helper, so what's measured and what's drawn can't
  drift. (Colour/font selection stays in `styleCell`.)
- **Settings source:** `boolTrue`/`boolFalse`/`nullString` are runtime settings the
  data source already holds (`boolTrueString`/`boolFalseString`/`nullDisplayString`,
  [`ResultsDataSource`:160–162](../../Pharos/ViewControllers/ResultsGrid/ResultsDataSource.swift)).
  The measurement reads those same fields so it can't diverge from the render.
  Accepted: changing a bool/null display setting doesn't re-measure existing column
  widths (only affects the next result load) — a sub-pixel, transient discrepancy.
- **NULL font:** null cells render in the *italic* mono variant while the measurement
  uses regular mono; the width slack is sub-pixel and ignored.

### Net effect
`cc` (text, 2-char values) → ~header("cc TEXT")+22 ≈ 65px; the BOOL columns →
~header("is_selector BOOL")+22, snug to the glyph. Long-content columns cap at
1000px by default and can be dragged no wider than 1000.

## Testing

- **Pure (`swiftc` harness `scripts/test-result-cell-text.sh`)** for
  `ResultCellText.rendered`: BOOL `t`/`true`/`f`/`false`/`TRUE` → glyphs; unknown
  bool → raw; NULL → null string; string with newlines → flattened (single line);
  numeric/temporal/json/array → expected. This is where the BOOL over-measure bug
  lived, so it's the highest-value test.
- **Build-gated + manual (GUI):** short text/BOOL columns open snug (the reported
  screenshot); a long-text/JSON column opens capped at 1000 and fits its content
  otherwise; drag a column — stops at 1000; divider double-click auto-fit matches
  the default width; a workspace with saved widths still restores them; the header
  **name** is never clipped by the funnel (type-label overlap on hover is expected).
  - **Sorted column:** sort a snug-fit column → its header text (name) stays fully
    visible (the arrow allowance widened it), and double-click auto-fit while sorted
    lands at the same width (no ~17px under-measure / clip).

## Phasing

- **A — `ResultCellText.rendered` pure helper** (TDD) + refactor `styleCell` to use it.
- **B — Width measurement**: `measuredColumnWidth` (funnelReserve 22 + sorted arrow
  allowance + rendered-string content sampling), applied as the default at column
  creation (`includeVisibleSample: false`) and by `autoFitColumn` (`true`); remove
  `estimateColumnWidth`; `maxWidth`/clamp → 1000. Build-gated + manual.

## Risks / Open Questions

- **Sample cost** — the measurement samples ≤~200–300 rows (first/last 100, plus
  visible rows for on-demand auto-fit) once per column; negligible. Keep the same bounds.
- **Header reserve tradeoff** — 22px may let the funnel touch the type label on
  hover for the narrowest columns; accepted. If it reads poorly in practice, the
  constant is trivially tunable.
