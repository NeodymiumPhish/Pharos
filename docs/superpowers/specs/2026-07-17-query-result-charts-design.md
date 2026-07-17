# Query Result Charts — Design Spec

**Date:** 2026-07-17
**Status:** Approved for planning
**Scope:** Phase 1 (this spec) with phases 2–3 outlined for context.

## Summary

Add the ability to visualize a SQL query result as a chart. A `Grid` / `Chart`
toggle in the result action bar swaps the results grid for a Swift Charts canvas
with an adjacent config rail that maps result columns to chart roles. Phase 1
ships six chart types (bar, line, area, scatter, pie, gantt), aggregates
currently-loaded rows client-side, and persists chart configuration with the
workspace. Later phases add heatmaps, chart-driven drill-down, and image/SQL
export.

## Goals

- Turn any query result into a chart without leaving the result area.
- Zero new DB round-trips in the common case (chart the rows already loaded).
- Native look and feel — use Apple's Swift Charts, hosted in the existing AppKit
  UI.
- Configuration is durable: a chart comes back exactly when its workspace
  reopens.
- Keep the plotting logic pure and testable, isolated from the UI.

## Non-Goals (Phase 1)

- Heatmaps (phase 2).
- Chart-driven drill-down / filtering / query spawning (phase 2).
- Exporting charts as images or PDF (phase 3).
- Server-side (SQL `GROUP BY`) aggregation for full-dataset accuracy (phase 3).
- Charting across multiple result tabs at once.

## Decisions (from brainstorming)

| Decision | Choice | Rationale |
|---|---|---|
| Overall intent | All three (exploration → drill-down → reporting), **phased** | Build simple first, leave seams for later. |
| Renderer | **Swift Charts** via `NSHostingController` | Native macOS identity; bar/line/area/scatter/pie cheap, gantt via ranged bars, heatmap via `RectangleMark`. |
| Placement | **View-mode toggle** in the result action bar | Lowest friction; charting is a lens on the existing result. |
| Data source | **Loaded rows + client-side aggregation** | No new round-trips; readable charts from large results via grouping. |
| Phase-1 chart types | bar, line, area, scatter, pie, **gantt** | Workhorse set plus a named target (gantt). Heatmap deferred. |
| Persistence | **Persist with workspace** from day one | Charts durable across reopen/restart. |

## Architecture

### New Swift components (`Pharos/`)

| Component | Kind | Responsibility |
|---|---|---|
| `ChartType` | enum | `.bar .line .area .scatter .pie .gantt` (+ `.heatmap` reserved for phase 2). |
| `ChartColumnRole` | enum | Mapping vocabulary: `category, value, series, x, y, size, color, label, start, end`. |
| `AggregationFn` | enum | `.sum .avg .count .min .max`. |
| `ColumnKind` | enum | `.numeric .temporal .categorical`. |
| `ChartConfig` | Model (Codable) | Chart type + role→column mappings + aggregation + display options. Lives on `ResultTab`; serialized to JSON for workspace persistence. |
| `ChartDisplayOptions` | Model (Codable) | Title, legend on/off, stacked vs grouped, top-N cap. |
| `ColumnClassifier` | Pure logic | Classifies each `ColumnDef` → `ColumnKind` from pg `dataType` + value sniffing. Drives default mapping and per-role dropdown eligibility. |
| `ChartAggregator` | Pure logic | `(QueryResult, ChartConfig) → ChartData`. Coercion, grouping/aggregation, null handling, top-N capping. |
| `ChartData` | Model | Plot-ready, renderer-agnostic series/points + metadata. |
| `ChartViewModel` | ObservableObject | Holds current `ChartConfig`, recomputes `ChartData` on change, writes config back for persistence. |
| `ChartRootView` / `ChartView` | SwiftUI | Config rail + Swift Charts canvas; marks switch on chart type. |
| `ChartHostingController` | AppKit | `NSHostingController` wrapping `ChartRootView`; shown/hidden by the toggle. |

### Touched existing components

- **`ContentViewController`** — add a `Grid | Chart` `NSSegmentedControl` to the
  action bar's `actionStack` (alongside pin/export/copy/find). Add the chart host
  as a sibling of `resultsVC.view` in the result area, toggled visible. Wire the
  toggle to the view-mode swap and per-result-tab restore.
- **`ResultTab`** (`Pharos/Models/ResultTab.swift`) — add
  `var chartConfig: ChartConfig?` and `var resultViewMode: ResultViewMode`
  (`.grid` / `.chart`), restored on tab switch (same pattern as `gridState`).
- **Rust/SQLite/FFI** — persist chart config (see Persistence).

### Boundaries

`ColumnClassifier` and `ChartAggregator` are pure and UI-free — the real logic
and the tests live there. The SwiftUI layer is a thin renderer over `ChartData`.
The AppKit layer only manages show/hide and feeds the result in. Each unit can be
understood and tested independently: classifier (types in → kinds out),
aggregator (result + config in → chart data out), view (chart data in → pixels).

## Data Model

### ChartConfig

```
struct ChartConfig: Codable {
    var chartType: ChartType
    var mappings: [ChartColumnRole: String]   // role → column name
    var aggregation: AggregationFn            // ignored by scatter/gantt
    var seriesColumn: String?                 // optional grouping
    var display: ChartDisplayOptions
}
```

Codable uses plain camelCase with **no** key strategy and **no** `CodingKeys`,
matching the workspace JSON convention (see the FFI-casing lesson). `ChartType`,
`ChartColumnRole`, `AggregationFn` encode as their string raw values.

Role usage by chart type:

- **bar / line / area / pie** → `category` + `value` (+ optional `series`)
- **scatter** → `x` + `y` (+ optional `size`, `color`)
- **gantt** → `label` + `start` + `end` (+ optional `color`), no aggregation

### ColumnClassifier

Maps `ColumnDef.dataType` (pg type string) to `ColumnKind`:

- **numeric**: `int2/4/8`, `float4/8`, `numeric`, `decimal`, `money`,
  `serial*`, `smallserial`, `bigserial`
- **temporal**: `date`, `timestamp`, `timestamptz`, `time`, `timetz`
- **categorical**: `text`, `varchar`, `bpchar`/`char`, `bool`, `uuid`, enum
  types, and everything not matched above

When the type string is ambiguous, sniff the first N non-null values via
`AnyCodable` to refine the kind. Output drives:

1. the default `ChartConfig` inferred on first entering Chart mode
   (`ChartConfig.infer(from: [ColumnDef])`), and
2. which columns each rail dropdown offers (e.g. gantt Start/End list only
   temporal/numeric columns; bar Value lists numeric columns).

Note: pg internal `"char"` columns must be `::text`-cast in raw SQL upstream or
they decode as null (see the pg-char sqlx lesson); the classifier treats an
all-null value column as a degenerate case (see below), not a crash.

### ChartAggregator

Pure transform `(QueryResult, ChartConfig) → ChartData`:

1. **Project** the mapped columns out of each loaded row.
2. **Coerce** values by column kind — numeric parse of `AnyCodable`, date parse
   for temporal. Unparseable/null values are handled explicitly: dropped or
   bucketed as `"(null)"` per `display` options.
3. **Group** by `category` (and `series` if set); apply `aggregation` to
   `value`. Scatter emits raw `(x, y)` points; gantt emits `(label, start, end)`
   bars — neither aggregates.
4. **Cap cardinality** — keep top-N categories by aggregated value (default
   N = 25, configurable via `display`), roll the remainder into an `"Other"`
   bucket. Flagged on `ChartData`.

### ChartData

```
struct ChartData {
    var series: [ChartSeries]        // ordered; one for non-grouped charts
    var plottedRowCount: Int
    var totalLoadedRowCount: Int
    var wasTruncated: Bool           // top-N cap applied
    var otherBucketCount: Int
    var emptyReason: String?         // set when nothing plottable
}
```

Holds no `AnyCodable` and no `ChartConfig` — trivial to snapshot in tests. The
banner and the Swift Charts marks read directly from this.

### Degenerate handling

- No type-compatible columns for the chosen chart type → canvas shows an inline
  "pick columns to chart" empty state (via `emptyReason`), not a crash.
- All-null value column → empty state with the reason surfaced.

## Data Flow

1. User runs a query → `QueryResult` on the `ResultTab` (existing path).
2. User clicks the **Chart** toggle → `ChartHostingController` appears. If
   `ResultTab.chartConfig` is nil, `ChartConfig.infer(from:)` builds a default
   from the column kinds.
3. `ChartAggregator` transforms the currently-loaded rows → `ChartData`.
4. Swift Charts renders `ChartData`. A banner shows "Charting N of M loaded
   rows, aggregated client-side" with a **Load all rows** action when `hasMore`.
5. User edits type/columns/aggregation in the rail → `ChartViewModel` recomputes
   `ChartData` and re-renders; the updated `ChartConfig` is written back to the
   `ResultTab`.
6. Config changes are persisted (debounced) to the workspace; on reopen the
   config and view mode are restored.

## Persistence (Phase 1)

- Add `chart_config_json TEXT NULL` to the `workspace_results` table
  (`pharos-core/src/db/sqlite.rs` migration — additive, no backfill).
- Add a dedicated FFI call `updateResultChartConfig(resultId:, json:)`
  (`pharos-core/src/commands/workspace.rs`, `ffi/workspace.rs`, and Swift
  `PharosCore+Workspaces.swift`). Kept separate from `updateResultMeta` because
  chart config is a larger, independently-changing blob. Persisted debounced on
  config change, mirroring grid-state save behavior.
- Add `chartConfigJson: String?` to `WorkspaceResultMeta` so `loadWorkspace`
  returns it. On reopen, decode → `ResultTab.chartConfig`; if
  `resultViewMode == .chart`, open directly into the chart.
- All round-trips honor the existing casing rules (camelCase, no key strategy).

## UI Details

- **Toggle:** `NSSegmentedControl` (`Grid` | `Chart`) at the left of
  `actionStack`. Per result tab; restored on tab switch.
- **Banner:** amber, between the action bar and the canvas, only when charting a
  subset (`hasMore` or top-N truncation). Shows plotted vs total counts and a
  *Load all rows* link that triggers `fetch_more` to completion (respecting a
  safety cap), then re-aggregates.
- **Config rail:** ~150pt right rail inside the chart host. Slots adapt to chart
  type (bar/line/area/pie → Category + Value + Aggregate + optional Series;
  scatter → X + Y + optional Size/Color; gantt → Label + Start + End + optional
  Color). Dropdowns list only type-eligible columns.
- **Canvas:** Swift Charts view; hover tooltips and legend come free from the
  framework. Read-only in phase 1.

## Phasing

- **Phase 1 (this spec):** toggle + config rail + `ColumnClassifier` +
  `ChartAggregator` + Swift Charts rendering for bar/line/area/scatter/pie/gantt
  on loaded rows with client aggregation; loaded-rows banner + *Load all*;
  workspace persistence. Charts are read-only surfaces.
- **Phase 2:** heatmap; drill-down — click a bar/slice/point to filter the grid
  or spawn a follow-up query; selection/brushing. `ChartData` points already
  carry their source category/keys, so the seam exists in phase 1.
- **Phase 3:** reporting — export chart as PNG/PDF (extend the Export button in
  chart mode); optional SQL push-down aggregation for full-dataset accuracy on
  very large results.

## Testing

Per the repo's standalone-`swiftc` harness (no Xcode test target; see the
test-harness lesson):

- **`ColumnClassifier`:** pg type → kind for each family; sniff-fallback on
  ambiguous/`"char"` types.
- **`ChartAggregator`:** each aggregation fn; numeric/date coercion of
  `AnyCodable`; null bucketing; top-N + "Other" capping; scatter passthrough;
  gantt start/end parsing; empty/all-null degenerate cases produce the correct
  `ChartData` metadata flags.
- **`ChartConfig.infer(from:)`:** sensible defaults across column-kind mixes.
- **Rust:** `chart_config_json` round-trip through SQLite (in-file
  `#[cfg(test)]`, `now()`-based timestamps per the staticlib-tests lesson).
- **Manual verification:** run the app; chart a large real result; confirm banner
  counts; verify tab-switch and workspace reopen restore config and view mode.

## Risks / Open Questions

- **Swift Charts performance** past a few thousand marks — mitigated by
  client-side aggregation and the top-N cap; scatter (which doesn't aggregate)
  may need a point-sampling cap. Confirm thresholds during implementation.
- **Exact workspace result-upsert wiring** — `associateResult` /
  `updateResultMeta` exist; confirm the precise point to invoke
  `updateResultChartConfig` during planning.
- **SwiftUI ↔ AppKit theming** — ensure the hosted chart honors the app's
  native appearance / Liquid Glass context.
