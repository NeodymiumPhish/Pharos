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
- **Auto-fit** ([`autoFitColumn`:661](../../Pharos/ViewControllers/ResultsGridVC.swift)) *does* measure content but over-pads: header = `attributedStringValue.size().width + 50`; content = `value.displayString.size(font).width + 12`; clamps to `min(max(…), 720)`. Two flaws: the **+50** header reserve is ~2× what the icons need, and it measures the **raw** `displayString` — for BOOL that's "true"/"false" (~30px) though the cell renders the compact glyph (~10px).

Supporting facts:
- Cell text insets are leading **6** / trailing **6** ([`ResultsDataSource`:247–248](../../Pharos/ViewControllers/ResultsGrid/ResultsDataSource.swift)) → the `+12` content pad is exact; keep it.
- BOOL cells render `boolTrueString`/`boolFalseString`, NULL renders `nullDisplayString`, and string/json/array are newline-flattened (`flattenedForCell`) — all in [`styleCell`:402](../../Pharos/ViewControllers/ResultsGrid/ResultsDataSource.swift). The measurement must mirror this.
- Header icons ([`FilterableHeaderView`:65–66,249–256](../../Pharos/ViewControllers/ResultsGrid/FilterableHeaderView.swift)): filter funnel `side = iconSize(13) + iconPadding(6)*2 = 25`, drawn at `maxX - 25 - 8`, **only when hovered or the column is filtered**; sort arrow ▲/▼ ~12px, only when sorted.

## Design

### 1. Resize cap → 1000px
At column creation set `col.maxWidth = 1000` (was 720). Clamp `autoFitColumn` to
1000 (was 720). `minWidth` stays 50.

### 2. Content-aware default via one shared measurement
Extract the measurement into a single method
`measuredColumnWidth(column: NSTableColumn, colId: String) -> CGFloat` and use it
for both the initial default and `autoFitColumn`. It returns
`min(max(headerWidth, contentWidth, column.minWidth), 1000)` where:
- `headerWidth = column.headerCell.attributedStringValue.size().width + headerIconReserve`
- `contentWidth` = max over the sampled rows of `renderedText.size(cellFont).width + 12`
  (cell font = `NSFont.monospacedSystemFont(ofSize: 12)`, matching the cells; sample = the existing "visible rows + first/last 100" set).

Apply it as the default **after the result's rows are available** (so the sample
is non-empty). If column construction currently runs before rows are set, add a
post-load "fit all columns" pass that sets each `col.width = measuredColumnWidth(...)`
for columns without a restored saved width. `estimateColumnWidth` (the type-based
heuristic) is removed.

### 3. Tighter, render-accurate measurement
- **`headerIconReserve` = 22** (was an inline `+50`). Covers the funnel glyph +
  a small margin. Accepted tradeoff (brainstorming): on a very narrow column the
  hover/active funnel may overlap the last few px of the small grey **type** label;
  the **column name is never obscured**. A one-line comment documents this.
- **Measure the rendered string, not the raw value.** Introduce a pure helper:
  ```
  ResultCellText.rendered(value: AnyCodable, category: PGTypeCategory,
                          boolTrue: String, boolFalse: String, nullString: String) -> String
  ```
  returning: NULL → `nullString`; BOOL → `boolTrue`/`boolFalse` for `t`/`true`/`f`/`false` (case-insensitive), else raw; string/json/array → `value.displayString.flattenedForCell`; numeric/temporal/other → `value.displayString`. The measurement calls this per sampled cell.
- **DRY:** `styleCell` is refactored to derive its displayed string from the same
  `ResultCellText.rendered(...)` helper, so what's measured and what's drawn can't
  drift. (Colour/font selection stays in `styleCell`.)

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

## Phasing

- **A — `ResultCellText.rendered` pure helper** (TDD) + refactor `styleCell` to use it.
- **B — Width measurement**: `measuredColumnWidth` (header reserve 22 + rendered-string
  content sampling), use it for the initial default (post-load fit pass) and
  `autoFitColumn`; remove `estimateColumnWidth`; `maxWidth`/clamp → 1000. Build-gated + manual.

## Risks / Open Questions

- **Column-build vs rows-ready ordering** — confirm whether columns are built
  before or after `rows`/`displayRows` are populated; if before, the default must
  be applied in a post-load pass (per §2). Verify during implementation.
- **Sample cost** — the measurement already samples ≤~300 rows (visible + first/last
  100) and runs once per column at load; negligible. Keep the same sample bounds.
- **Header reserve tradeoff** — 22px may let the funnel touch the type label on
  hover for the narrowest columns; accepted. If it reads poorly in practice, the
  constant is trivially tunable.
