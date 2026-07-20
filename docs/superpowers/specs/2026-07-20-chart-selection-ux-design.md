# Chart Selection & Drill UX — Design Spec

**Date:** 2026-07-20
**Status:** Approved for planning
**Builds on:** query result charts phases 1–4 (all merged).

## Summary

Rework the chart→grid drill from *commit-on-click* to a **staged selection** model with
visual feedback. A gesture (single / Shift / ⌘ click, or drag-marquee) builds a
selection that dims the unselected marks and surfaces a single **commit button** in
the result action bar; nothing touches the grid (or spawns a query) until the user
presses it. A new selection **replaces** the previous one rather than stacking, and
the commit button + post-commit chip both **label which columns are filtered and how
many values each contributes** (e.g. `dst_country (2); protocol (2)`). Separately,
fix the results **grid** so ⌘-click toggles rows into a discontiguous selection
(macOS parity), matching the existing Shift-click range behavior.

All chart types reuse the phase-4 `DrillKey` / `DrillMerge` machinery, so multi-column
selections, null buckets, and binned-axis ranges commit correctly with no new drill
vocabulary. One new pure helper (`DrillSummary`) produces the button/chip labels.

## Goals

- Give every filter-building gesture a clear on-chart indicator (marquee + dimming).
- Defer the grid switch / query spawn to an explicit commit button.
- Make a new selection replace the prior chart filter, never accumulate silently.
- Label the commit button and the chip with the columns + value counts selected.
- Support macOS-standard single / Shift-range / ⌘-toggle selection on the chart **and**
  bring the results grid to ⌘-click parity.
- Keep selection→keys mapping and label generation pure and unit-tested; keep
  gesture/rendering/AppKit-wiring thin and build-gated + manually verified.

## Non-Goals

- No new chart types, drill predicates, or persisted state (selection is ephemeral).
- No discontiguous *cell*-range selection in the grid (row parity only; the existing
  rectangular cell selection is unchanged).
- No pie drag-brush (radial), no scatter click-selection (dense) — unchanged from the
  gesture affordances each type already has.
- No change to the push-down SQL, `ChartData`, or the phase-4 translators/merge.

## Decisions (from brainstorming)

| Decision | Choice |
|---|---|
| Interaction model | Staged selection → dim unselected + action-bar commit button; commit switches to grid (client) or spawns detail query (server). |
| Server-aggregation mode | Same staged UX; commit button reads **"Query Selected Rows"** and spawns the filtered detail-query tab (phase-3 behavior, deferred + staged). |
| Replace vs add | A plain click or fresh drag starts a new working set; Shift/⌘ extend it; commit replaces any prior committed chart filter entirely. |
| Button/chip label | Shared summary: `col (N)` per discrete column, `col (range)` for a range/overlap column, joined `; `, ordered by column index. Client button "Filter in Grid — …", server "Query Selected Rows — …", chip "Filtered by Chart — …". |
| Selection semantics | Per-type (see §1): bar/line/area/pie/heatmap/gantt-rows are discrete-mark; scatter + gantt-time-axis are continuous (marquee/overlap). |
| Marquee | Dashed accent rubber-band in the plot area; x-band for categorical, 2D rect for heatmap/scatter. |
| Dimming | Unselected marks → ~20% opacity when a selection is non-empty; the lit set is derived from `DrillMerge.merge(stagedKeys)` so the preview matches the commit. |
| Clear | Click empty plot area or **Esc**; also cleared on config change / tab switch. |
| Grid ⌘-click | Add a `.command` toggle branch to the grid's row-selection mouse handler (Shift range unchanged). |
| Persistence | None new — selection is runtime-only; committed grid filter stays in-memory as today. |

## Current behavior (what changes)

`ChartCanvas` gestures call `onDrill([DrillKey])` immediately on click/brush/pie-select;
that chains `ChartCanvas.onDrill` → `ChartRootView` (`model.onDrill`) →
`ChartHostingController.onDrill` → `ContentViewController.applyDrill`, which (client mode)
sets grid `ColumnFilter`s **accumulating** across columns, switches to grid, and shows a
`drillChip` labelled "Filtered by chart (N)" ([ContentViewController.swift:2527](../../Pharos/ViewControllers/ContentViewController.swift)),
or (server mode) spawns a filtered detail-query tab (`applyServerDrill`). There is no
on-chart feedback and the switch is immediate.

**After this change:** a gesture updates a *staged selection* (dim + marquee) and reports
`[DrillKey]` up via a new `onSelectionChanged` callback; `applyDrill`/`applyServerDrill`
are triggered only by the action-bar button, and `applyDrill` first tears down the prior
committed drill (replace).

## 1 — Selection semantics per chart type

A selection is a set of chart marks; each mark's `DrillKey`(s) already come from the
phase-4 aggregator/generator. `ChartCanvas` owns the selection as SwiftUI `@State` and
maps it to `[DrillKey]` for the callback; committing runs `DrillMerge.merge(...)` over
those keys (existing), then the existing client/server drill path applies it.

Two selection shapes:

- **Discrete-mark** (`bar`, `line`, `area`, `pie`, `heatmap`, gantt rows): a
  `Set<String>` of stable mark IDs + an anchor ID. Mark ID: `xLabel + "\u{1}" +
  seriesName` for bar/line/area/pie (the same compound-ID pattern as `HeatmapCell.id`;
  `seriesName` is `""` for single-series charts, so a **per-series band is individually
  addressable** — two series at one category are distinct members and dim
  independently); `HeatmapCell.id` (`x\u{1}y`) for heatmap; the bar label for gantt
  rows. A Shift-range or marquee spanning a block of categories expands to **all series
  IDs** within that block. Which marks render *lit* is derived from the merged selection
  — see §2.
- **Continuous** (`scatter` marquee, gantt time-axis overlap): a single range value
  (x/y bounds, or a `[t0,t1]` window). Marks inside are lit; commit yields the
  `.range`/`.overlap` key. Only one selection shape is active at a time.

| Chart | Single-click | Shift-click ("between") | ⌘-click | Drag |
|---|---|---|---|---|
| Bar / Line / Area | one mark (category, or category+series if multi-series) | all marks between anchor & target **along the category axis**, inclusive | toggle one mark | marquee over x-span → marks inside |
| Pie | one slice | slice range in slice order | toggle one slice | — |
| Heatmap | one cell | **bounding rectangle** of cells between anchor & target (x-range × y-range) | toggle one cell | marquee rect → covered cells |
| Gantt (rows) | one row/label | row range between | toggle rows | — |
| Gantt (time axis) | — | — | — | overlap brush → time window |
| Scatter | clears selection (inspect callout unchanged) | — | — | marquee → x/y range (only selection method) |

Notes:
- **Scatter is drag-only** — points are too dense for click selection; the marquee *is*
  the selection (dims points outside).
- **Gantt has two selection surfaces** — bar clicks build a label set; a time-axis drag
  builds an overlap window; each replaces the other (last gesture wins).
- **Multi-series bar/line "between" runs along the category axis** — a Shift-range spans a
  contiguous block of categories across all their series; ⌘-click toggles an individual
  band/point. On commit `DrillMerge` yields both the category- and series-column keys.
- **Modifier detection** uses `NSEvent.modifierFlags` inside the gesture `onEnded`
  (already the pattern used by the phase-4 pie multi-select).

## 2 — Visual feedback

- **Marquee:** a dashed, accent-colored, translucent rubber-band drawn in the plot area,
  tracking the live drag translation in the existing `chartOverlay` `GeometryReader`.
  Full-height x-band for bar/line/area; a 2D rectangle for heatmap and scatter.
- **Dimming:** when the selection is non-empty, unselected marks render at ~0.2 opacity,
  lit marks at full. **The lit set is derived from `DrillMerge.merge(stagedKeys)`, not the
  raw click set**, so the preview matches exactly what commit will filter: discontiguous
  ⌘-selected bins whose merge coalesces into one covering span light the in-between bins
  *live*, and a null bucket the merge drops (when it coexists with a range on the same
  column) dims as it will commit. A mark is lit iff its own `DrillKey` is subsumed by the
  merged selection for its column (`.anyOf` value membership incl. the null sentinel;
  `.range`/`.overlap` containment). During a drag, marks under the marquee join the staged
  set; on release the set freezes. Empty selection → no dimming.
- **Clearing:** click on empty plot area, or press **Esc**, clears the selection
  (un-dim, hide the commit button). Esc is handled by the hosting VC / first responder (a
  click on empty plot area is the primary path; Esc is a convenience).
- A chart **config change** (remapping roles, switching chart type/bins) or a **result-tab
  switch** clears any pending selection, since the marks change underneath it. Because
  SwiftUI `@State` survives view updates and resets only on identity change, `ChartCanvas`
  clears its selection via an explicit `onChange(of: configFingerprint)` (a hash of the
  mappings + chart type + bins) — not by relying on view diffing.

## 3 — Commit flow, action bar & labels

- A single **chart-filter button** is shown in the result action bar only while a
  selection exists in chart mode. Label = the shared summary (see below):
  - client mode → **`Filter in Grid — dst_country (2); protocol (2)`**
  - server-aggregation mode → **`Query Selected Rows — dst_country (2); protocol (2)`**
- **Commit (client):** `applyDrill(selectedKeys)` — first `tearDownDrill(restoreManual:true)`
  to drop the prior committed chart filter (restoring any displaced manual filters), then
  set the new grid filters, switch to grid, show the chip. **Commit (server):**
  `applyServerDrill(selectedKeys, …)` — spawns the filtered detail-query tab (unchanged);
  no chip (the new tab *is* the result).
- **Chip (grid, client mode):** `Filtered by Chart — <summary>` with a ✕ that clears
  (existing `clearDrill`, relabelled). Replaces the current "Filtered by chart (N)" text.
- The old immediate-on-gesture commit is removed — a gesture updates only the staged
  selection.
- **After commit** the staged selection clears and the button hides. When the chart of a
  committed client-mode filter is shown again, its marks re-derive their lit state from the
  *committed* keys (so the active filter stays visible on the chart) — there is no retained
  staged state. A fresh gesture stages a new selection that replaces the committed filter on
  the next commit. This keeps "selection is ephemeral" literally true and resolves any
  still-lit ambiguity.

### DrillSummary (label generation — new pure helper)

`DrillSummary.describe(_ keys: [DrillKey], columns: [ColumnDef]) -> [(column: String, detail: String)]`

- Flattens `.compound`; groups by `ColumnRef`; orders results by column index (ascending)
  for determinism.
- Detail per column:
  - `.anyOf(ref, vals)` → `"(\(count))"` where `count` = number of selected value buckets
    (distinct real values, plus 1 if `PharosBlanks.sentinel` is present, i.e. the null
    bucket counts as one).
  - `.blank(ref)` alone → `"(null)"`.
  - `.range(ref, …)` / `.overlap(startRef, endRef, …)` → `"(range)"`. For `.overlap`, the
    column shown is the start column's name (the pair reads as one time-window filter).
- The label string is `parts.map { "\($0.column) \($0.detail)" }.joined(separator: "; ")`,
  prefixed per context ("Filter in Grid — ", "Query Selected Rows — ", "Filtered by Chart — ").
- Overly long labels truncate with an ellipsis; the full text is the button/chip tooltip.

## 4 — Grid ⌘-click parity

In `ResultsCellSelection.handleMouseDown` ([ResultsCellSelection.swift:99](../../Pharos/ViewControllers/ResultsGrid/ResultsCellSelection.swift)),
the row-number/row-mode branch currently handles Shift (range from anchor) and plain
click (single). Add a `.command` branch: **toggle** the clicked row in
`state.selectedRows` (insert if absent, remove if present) and set `rowAnchor` to the
clicked row so a subsequent Shift-click extends from there. The ⌘ branch must **leave
`state.isSelecting = false`** (unlike the plain/shift branches): `handleMouseDragged`'s
row-mode path ([ResultsCellSelection.swift:146](../../Pharos/ViewControllers/ResultsGrid/ResultsCellSelection.swift))
rewrites `selectedRows` as a contiguous anchor→cursor range, so a one-pixel drag during a
⌘-click would otherwise wipe the whole discontiguous set. (A future ⌘-drag-to-add-range
could union the drag range with the pre-drag set — out of scope.) Shift and plain-click are
unchanged. Rectangular *cell* selection (the data-cell branch) is out of scope.

## 5 — Architecture & components

- **`ChartView.swift` (`ChartCanvas`):** holds `@State` selection (a `Set<String>` of
  compound mark IDs + anchor for discrete charts, or a range value for scatter/gantt-time);
  modifier-aware gestures replace the phase-4 `onDrill(...)` commit calls with selection
  updates; computes `merged = DrillMerge.merge(stagedKeys)` and renders per-mark dimming
  from *merged* membership + the marquee overlay; reports the merged `[DrillKey]` via a new
  `var onSelectionChanged: ([DrillKey]) -> Void`. Clears its `@State` on
  `onChange(of: configFingerprint)`. Empty selection → `onSelectionChanged([])`.
- **`ChartRootView.swift` (`ChartViewModel`):** `@Published var selectionKeys: [DrillKey] = []`
  set from `onSelectionChanged`; forwarded to the host. (The rail is unchanged.)
- **`ChartHostingController.swift`:** replaces `onDrill` with `onSelectionChanged`; exposes
  `var currentSelectionKeys: [DrillKey]` for the VC's commit; keeps `buildExportSnapshot`
  etc. unchanged.
- **`ContentViewController.swift`:** owns a new action-bar button (`chartFilterButton`)
  shown/hidden + labelled from `DrillSummary` as the selection changes; its action commits
  via the existing `applyDrill`/`applyServerDrill` (now button-triggered, `applyDrill`
  gains the up-front `tearDownDrill(restoreManual:true)` for replace). `updateDrillChip`
  builds its label from `DrillSummary` over the committed keys (store the committed
  `[DrillKey]` alongside `drillColumns`). On commit the staged selection is cleared and the
  button hidden; clearing the selection also hides the button; Esc / empty-click routes
  through the host to clear.
- **`DrillSummary.swift`** (new, Foundation-only, `Pharos/Models/Charts/`): the pure label
  helper above.
- **`ResultsCellSelection.swift`:** the ⌘-click row toggle.

Interfaces stay small: the chart reports a selection (data), the VC owns the button and
the commit (side effects), and label generation is a pure function testable in isolation.

## Persistence

None new. Selection is runtime-only and cleared on tab switch / config change. The
committed client-mode grid filter remains in-memory (as today); server-mode commit still
records `query_history` via the spawned detail query.

## Testing

Per the repo's standalone-`swiftc` harnesses:

- **`DrillSummary` (new harness `scripts/test-drill-summary.sh`):**
  - `.anyOf` distinct count; `.anyOf` with `PharosBlanks.sentinel` counts the null bucket
    (+1); `.blank` alone → `(null)`; `.range` / `.overlap` → `(range)`.
  - Multi-column ordering by column index; `.compound` flattening (heatmap cell → two
    columns); the joined label string format.
- **Reuse:** `DrillMerge` / `DrillTranslator` / `DrillSqlTranslator` tests already cover
  selection→filter/predicate; no changes there.
- **Build-gated + manual (GUI):**
  - Marquee draws while dragging; unselected marks dim; Esc / empty-click clears.
  - Single / Shift-range / ⌘-toggle on bar, pie, heatmap, gantt rows; heatmap Shift =
    bounding rect; scatter drag-only; gantt time-axis overlap still works.
  - Per-series band toggles independently (two series at one category dim separately).
  - **Merged-preview honesty:** ⌘-select two non-adjacent numeric bins → the in-between
    span lights up *before* commit, and committing filters exactly the lit span; a lit null
    bucket beside a range dims (and drops) as it will commit.
  - "Filter in Grid" appears only with a selection, shows the correct summary, and on
    click switches to grid with the right filters + chip label; a *new* selection replaces
    the prior committed filter (no stacking).
  - Server mode: button reads "Query Selected Rows"; commit spawns the filtered tab; multi-
    select builds one compound `WHERE`.
  - Grid: ⌘-click toggles discontiguous rows; Shift-click still ranges; plain click single.

## Phasing

- **A — `DrillSummary` pure helper** (TDD + harness).
- **B — `ChartCanvas` selection model**: state, modifier-aware gestures, dimming, marquee,
  `onSelectionChanged` (replaces `onDrill`); view-model + host plumbing. Build-gated + manual.
- **C — VC commit + action bar**: `chartFilterButton` (label via `DrillSummary`), button-
  triggered `applyDrill`/`applyServerDrill` with replace, chip relabel, Esc/empty-click
  clear. Build-gated + manual.
- **D — Grid ⌘-click parity**: `ResultsCellSelection` toggle. Build-gated + manual.

## Risks / Open Questions

- **Modifier flags in SwiftUI gestures** — reading `NSEvent.modifierFlags` in `onEnded` is
  already used (pie); confirm it reads correctly for tap-sized drags across all types.
- **Esc handling** — the chart is `NSHostingController`-hosted; Esc may need a VC/first-
  responder key handler. Empty-plot-area click is the primary clear; Esc is a convenience
  and can be dropped if it fights the responder chain.
- **Shift-range on binned/heatmap axes** — "between" is index-based on the rendered axis
  order; verify it reads intuitively when the axis is a binned range.
- **Dimming re-render cost** — per-mark opacity on large categorical/scatter sets; the
  scatter `PointPlot` dims as a whole layer rather than per point if per-point is too costly.
- **Merged-preview correctness** — the lit set MUST derive from `DrillMerge.merge(stagedKeys)`,
  not the raw click set (§2). `DrillMerge` coalesces same-column ranges into one covering span
  and drops a lone null beside a range, so a raw-click preview would misrepresent a
  discontiguous or null-inclusive selection (dim marks the commit actually includes, or leave
  a null lit that the commit drops). Cover in manual verification.
- **Selection ↔ committed-filter sync** — staged selection is ephemeral and clears on commit;
  the chart re-derives its lit state from the *committed* keys when shown again, so there is
  no stale staged state to contradict. A fresh gesture stages anew and replaces the committed
  filter on the next commit (reuse `tearDownDrill`).
