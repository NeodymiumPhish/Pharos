# Query Result Charts — Design Spec

**Date:** 2026-07-17
**Status:** Approved for planning
**Scope:** Phase 1 (this spec) with phases 2–3 outlined for context.
**Revision:** v2 — incorporates codebase-validated review (persistence target,
string coercion, temporal binning, index-based mapping, macOS 15 floor).

## Summary

Add the ability to visualize a SQL query result as a chart. A `Grid` / `Chart`
toggle in the result action bar swaps the results grid for a Swift Charts canvas
with an adjacent config rail that maps result columns to chart roles. Phase 1
ships six chart types (bar, line, area, scatter, pie, gantt) plus temporal
binning for time-series, aggregates currently-loaded rows client-side, and
persists chart configuration with the workspace (on the `query_history` row that
backs each workspace result). Later phases add heatmaps, numeric/histogram
binning, chart-driven drill-down, and image/SQL export.

## Goals

- Turn any query result into a chart without leaving the result area.
- Zero new DB round-trips in the common case (chart the rows already loaded).
- Native look and feel — use Apple's Swift Charts, hosted in the existing AppKit
  UI.
- Configuration is durable: a chart's config is restored when its workspace
  reopens (subject to the data-availability limits in "Persistence").
- Keep the plotting logic pure and testable, isolated from the UI.

## Non-Goals (Phase 1)

- Heatmaps (phase 2).
- Numeric / histogram binning (phase 2).
- Chart-driven drill-down / filtering / query spawning (phase 2).
- Exporting charts as images or PDF (phase 3).
- Server-side (SQL `GROUP BY`) aggregation for full-dataset accuracy (phase 3).
- Charting across multiple result tabs at once.

## Decisions (from brainstorming + review)

| Decision | Choice | Rationale |
|---|---|---|
| Overall intent | All three (exploration → drill-down → reporting), **phased** | Build simple first, leave seams for later. |
| Renderer | **Swift Charts** via `NSHostingController` | Native macOS identity; precedent in `ConnectionsManagerVC`. |
| Placement | **View-mode toggle** in the result action bar | Lowest friction; charting is a lens on the existing result. |
| Data source | **Loaded rows + client-side aggregation** | No new round-trips; readable charts from large results via grouping. |
| Phase-1 chart types | bar, line, area, scatter, pie, **gantt** | Workhorse set plus a named target (gantt). Heatmap deferred. |
| Time series | **Temporal binning in phase 1** | Raw-timestamp grouping is unusable for the most common chart shape. |
| Persistence | **Persist with workspace** from day one | Config durable across reopen/restart. |
| Deployment target | **macOS 15.0** (`project.yml`, raised from 14.0) | No known macOS 14 users; a pure 15+ floor lets scatter use the vectorized `PointPlot` API directly (no gating, no sampling fallback). |

## Architecture

### New Swift components (`Pharos/`)

| Component | Kind | Responsibility |
|---|---|---|
| `ChartType` | enum | `.bar .line .area .scatter .pie .gantt` (+ `.heatmap` reserved for phase 2). |
| `ChartColumnRole` | enum | Mapping vocabulary: `category, value, series, x, y, size, color, label, start, end`. |
| `ColumnRef` | Model (Codable) | `{ index: Int, name: String }` — a stable reference to a result column (see "Column references"). |
| `AggregationFn` | enum | `.sum .avg .count .min .max`. |
| `TemporalBin` | enum | `.none .auto .hour .day .week .month .year`. |
| `ColumnKind` | enum | `.numeric .temporal .categorical`. |
| `ChartConfig` | Model (Codable) | Chart type + role→`ColumnRef` mappings + aggregation + temporal binning + display options. |
| `ChartDisplayOptions` | Model (Codable) | Title, legend on/off, stacked vs grouped, top-N cap. |
| `PersistedResultViewState` | Model (Codable) | `{ chartConfig: ChartConfig?, viewMode: ResultViewMode }` — the single JSON blob persisted per result. |
| `ColumnClassifier` | Pure logic | Classifies each `ColumnDef` → `ColumnKind` from pg `dataType` + value sniffing. Drives default mapping and per-role dropdown eligibility. |
| `ValueCoercion` | Pure logic | Parses PG **text-format** values (all values arrive as strings — see below) into numbers/dates/bools for the aggregator. |
| `ChartAggregator` | Pure logic | `(QueryResult, ChartConfig) → ChartData`. Coercion, temporal binning, grouping/aggregation, null handling, top-N capping, scatter sampling. |
| `ChartData` | Model | Plot-ready, renderer-agnostic series/points + metadata. |
| `ChartViewModel` | ObservableObject | Holds current `ChartConfig`, recomputes `ChartData` on change, writes state back for persistence. |
| `ChartRootView` / `ChartView` | SwiftUI | Config rail + Swift Charts canvas; marks switch on chart type. |
| `ChartHostingController` | AppKit | `NSHostingController` wrapping `ChartRootView`; shown/hidden by the toggle. |

### Touched existing components

- **`ContentViewController`** — add a `Grid | Chart` `NSSegmentedControl` to the
  action bar's `actionStack` (alongside pin/export/copy/find). Add the chart host
  as a sibling of `resultsVC.view` in the result area, toggled visible. Wire the
  toggle to the view-mode swap and per-result-tab restore.
- **`ResultTab`** (`Pharos/Models/ResultTab.swift`) — add
  `var chartConfig: ChartConfig?` and `var resultViewMode: ResultViewMode`
  (`.grid` / `.chart`), restored on tab switch (same in-memory pattern as
  `gridState`).
- **Rust/SQLite/FFI** — persist the view state (see Persistence).

### Boundaries

`ColumnClassifier`, `ValueCoercion`, and `ChartAggregator` are pure and UI-free —
the real logic and the tests live there. The SwiftUI layer is a thin renderer
over `ChartData`. The AppKit layer only manages show/hide and feeds the result
in. Each unit can be understood and tested independently.

## Data Model

### Column references (why index, not name)

Query results can contain **duplicate column names** — `SELECT a.id, b.id FROM a
JOIN b …` yields two `ColumnDef`s both named `id`, and `ColumnDef` carries only
`{name, dataType}` with no disambiguation. Mappings therefore key on a
`ColumnRef { index, name }`: the **index** is authoritative for resolving the
column; the **name** is kept for display and for validation. When a result is
re-run after the SQL is edited (results are marked `isStale` on edit), the
config is validated against the new column shape — if a referenced index no
longer matches its stored name/kind, that role is cleared and the rail prompts
for re-selection rather than plotting the wrong column.

### ChartConfig

```
struct ChartConfig: Codable {
    var chartType: ChartType
    var mappings: [ChartColumnRole: ColumnRef]   // role → column reference
    var aggregation: AggregationFn               // ignored by scatter/gantt
    var temporalBin: TemporalBin                  // applies when category/x is temporal
    var display: ChartDisplayOptions
}
```

There is **no** separate `seriesColumn` field — series is expressed via the
`series` role in `mappings` (single source of truth). Codable uses plain
camelCase with no key strategy and no `CodingKeys`, matching the workspace JSON
convention. `[ChartColumnRole: ColumnRef]` with a `String`-raw-value enum key
encodes as a JSON object via `CodingKeyRepresentable` — no custom keys needed.

Role usage by chart type:

- **bar / line / area / pie** → `category` + `value` (+ optional `series`)
- **scatter** → `x` + `y` (+ optional `size`, `color`)
- **gantt** → `label` + `start` + `end` (+ optional `color`), no aggregation

### ValueCoercion — every value is a string

**Critical:** query results use the simple query protocol (`raw_sql`), so every
non-null value is serialized as a JSON **string** in PG text format
(`extract_value` in `commands/query.rs` returns `Value::String` for all types),
and `AnyCodable` decodes them all as `String`. Coercion is therefore central,
not a caveat:

- **Numeric:** string→`Double` parse for *all* numeric pg types (`int*`,
  `float*`, `numeric`/`decimal` — which cross as strings to preserve precision —
  `money`, `serial*`). Parse failures are treated as null.
- **Temporal:** parse PG text timestamp/date formats
  (`2024-01-01 12:00:00+00`, `2024-01-01`) → `Date`.
- **Boolean:** PG text bool is `"t"` / `"f"` (not `"true"`/`"false"`).

### ColumnClassifier

Maps `ColumnDef.dataType` (pg type string) to `ColumnKind`:

- **numeric**: `int2/4/8`, `float4/8`, `numeric`, `decimal`, `money`,
  `serial*`, `smallserial`, `bigserial`
- **temporal**: `date`, `timestamp`, `timestamptz`, `time`, `timetz`
- **categorical**: `text`, `varchar`, `bpchar`/`char`, `bool`, `uuid`, enum
  types, and everything not matched above

When the type string is ambiguous, sniff the first N non-null (string) values to
refine the kind. Output drives (a) the default `ChartConfig` inferred on first
entering Chart mode (`ChartConfig.infer(from: [ColumnDef])`), and (b) which
columns each rail dropdown offers (e.g. gantt Start/End list only
temporal/numeric columns; bar Value lists numeric columns). Note: pg internal
`"char"` columns decode as null unless `::text`-cast upstream (see the pg-char
lesson); an all-null value column is a degenerate case, not a crash.

### ChartAggregator

Pure transform `(QueryResult, ChartConfig) → ChartData`:

1. **Project** the mapped columns (by `ColumnRef.index`) out of each loaded row.
2. **Coerce** via `ValueCoercion` per column kind.
3. **Temporal binning** (pre-grouping step): when the `category`/`x` column is
   temporal and `temporalBin != .none`, bucket each date to the bin boundary.
   `.auto` chooses hour/day/week/month/year from the data's span. This runs
   *before* grouping so a `timestamptz` series collapses into readable buckets
   rather than one-per-microsecond.
4. **Group** by `category` (and `series` if set); apply `aggregation` to
   `value`. Scatter emits raw `(x, y)` points; gantt emits `(label, start, end)`
   bars — neither aggregates.
5. **Cap cardinality** — keep top-N categories by aggregated value (default
   N = 25, configurable), roll the remainder into an `"Other"` bucket. Not
   applied to temporal-binned axes (buckets are already bounded and ordered).
6. **Scatter rendering** — scatter does not aggregate. It renders via the
   vectorized `PointPlot` API (macOS 15+, the app's floor), which handles 100k+
   points, so no per-point sampling is needed. A high safety cap (~100k) bounds
   worst-case memory and, if it ever trips, sets `wasSampled` on `ChartData`.

### ChartData

```
struct ChartData {
    var series: [ChartSeries]        // ordered; one for non-grouped charts
    var plottedRowCount: Int
    var totalLoadedRowCount: Int
    var wasTruncated: Bool           // top-N cap applied
    var wasSampled: Bool             // scatter sampling applied
    var otherBucketCount: Int
    var emptyReason: EmptyReason?    // set when nothing plottable
}

enum EmptyReason { case noColumns, allNull, noData }  // noData = restored w/o rows
```

Holds no `AnyCodable` and no `ChartConfig` — trivial to snapshot in tests. The
banner and the Swift Charts marks read directly from this.

### Degenerate handling

- No type-compatible columns for the chosen chart type → `.noColumns` empty
  state ("pick columns to chart").
- All-null value column → `.allNull` empty state with the reason surfaced.
- Restored result whose cached rows were demoted (see Persistence) → `.noData`
  empty state ("re-run the query to chart").

## Data Flow

1. User runs a query → `QueryResult` on the `ResultTab` (existing path).
2. User clicks the **Chart** toggle → `ChartHostingController` appears. If
   `ResultTab.chartConfig` is nil, `ChartConfig.infer(from:)` builds a default
   from the column kinds.
3. `ChartAggregator` transforms the currently-loaded rows → `ChartData`.
4. Swift Charts renders `ChartData`. A banner shows plotted-vs-total when the
   chart covers a subset (see UI Details).
5. User edits type/columns/aggregation/binning in the rail → `ChartViewModel`
   recomputes `ChartData` and re-renders; the updated state is written back to
   the `ResultTab`.
6. State changes are persisted (debounced) to the workspace; on reopen the
   config and view mode are restored subject to data availability.

## Persistence (Phase 1)

Workspace results are **`query_history` rows** (the workspace feature added
`workspace_id, result_order, color_index, custom_label` and `result_columns`/
`result_rows` blobs to `query_history`) — there is no `workspace_results` table.

- Add a `chart_view_state_json TEXT NULL` column to `query_history` via the
  existing `pragma_table_info(...)` guarded-`ALTER` migration pattern
  (additive, no backfill). The single blob holds `PersistedResultViewState`
  (`{ chartConfig, viewMode }`) — one column, one FFI call, and it captures the
  view mode too (which is otherwise unpersisted).
- Add FFI call `updateResultChartState(resultId:, json:)`
  (`commands/workspace.rs`, `ffi/workspace.rs`, Swift
  `PharosCore+Workspaces.swift`), a sibling to `update_result_meta`. This
  requires **net-new debounced-persist machinery** on the Swift side — grid
  state today is in-memory only, so there is nothing to reuse; the debounce is
  part of this work.
- Surface `chartViewStateJson: String?` on `WorkspaceResultMeta` so
  `loadWorkspace` returns it. On reopen, decode → `ResultTab.chartConfig` +
  `resultViewMode`; if `.chart`, open directly into the chart.
- All round-trips honor the existing casing rules (camelCase, no key strategy).

**Data-availability limits (why "config restored", not "chart restored"):**
- `enforce_workspace_budget` nulls the cached `result_columns`/`result_rows`
  blobs on the oldest results when a workspace exceeds its byte budget (rows are
  dropped, SQL kept). A charted result can reopen with **no rows** → `.noData`
  empty state, "re-run to chart". The config still restores.
- Restored results are reconstructed with `hasMore: false` from the stored,
  row-capped blob. See the banner condition in UI Details for how a restored
  partial is detected without `hasMore`.

**Accepted inconsistency:** chart config/view-mode persist across restart, but
sort/filter/column-width (`gridState`) do not. This is a conscious phase-1
decision; unifying grid-state persistence is out of scope here.

## UI Details

- **Toggle:** `NSSegmentedControl` (`Grid` | `Chart`) at the left of
  `actionStack`. Per result tab; restored on tab switch.
- **Banner:** amber, between the action bar and the canvas, shown when the chart
  covers a subset of the query's rows. Trigger condition is
  `hasMore || (WorkspaceResultMeta.rowCount > loadedRowCount) || wasTruncated ||
  wasSampled` — the `rowCount` comparison catches **restored partials** where
  `hasMore` is forced false. Shows plotted vs total counts and, when more rows
  are fetchable, a *Load all rows* link.
- **Load all rows:** loops `fetchMoreRows` to completion (respecting a safety
  cap) and re-aggregates. Fetched rows stay **in-memory only** — they are not
  written back into the `query_history` result blob, to avoid tripping
  `enforce_workspace_budget` and demoting other cached results in the workspace.
- **Config rail:** ~150pt right rail inside the chart host. Slots adapt to chart
  type (bar/line/area/pie → Category + Value + Aggregate + optional Series;
  temporal category adds a Bin selector; scatter → X + Y + optional Size/Color;
  gantt → Label + Start + End + optional Color). Dropdowns list only
  type-eligible columns.
- **Canvas:** Swift Charts view; hover tooltips and legend come free. Gantt with
  many rows uses `chartScrollableAxes(.vertical)` with a fixed row height rather
  than compressing lanes into the canvas. Read-only in phase 1.

## Phasing

- **Phase 1 (this spec):** toggle + config rail + `ColumnClassifier` +
  `ValueCoercion` + `ChartAggregator` (incl. temporal binning) + Swift Charts
  rendering (vectorized `PointPlot` scatter) for bar/line/area/scatter/pie/gantt on
  loaded rows with client aggregation; loaded/restored-partial banner + *Load
  all*; workspace persistence of config + view mode. Charts are read-only.
- **Phase 2:** heatmap; numeric/histogram binning; drill-down — click a
  bar/slice/point to filter the grid or spawn a follow-up query;
  selection/brushing. `ChartData` points carry their source category/keys, so
  the seam exists in phase 1.
- **Phase 3:** reporting — export chart as PNG/PDF via SwiftUI `ImageRenderer`
  (renders the existing chart view nearly for free — further validates the
  renderer choice); optional SQL push-down aggregation for full-dataset accuracy
  on very large results.

## Testing

Per the repo's standalone-`swiftc` harness (no Xcode test target; see the
test-harness lesson):

- **`ValueCoercion`:** string→Double for every numeric pg type incl.
  `numeric`/`decimal` and `int8` beyond 2^53 (arrive as strings); PG text
  timestamp/date parsing; bool `"t"`/`"f"`; parse-failure → null.
- **`ColumnClassifier`:** pg type → kind for each family; sniff-fallback on
  ambiguous/`"char"` types.
- **`ChartAggregator`:** each aggregation fn; temporal binning (auto span
  selection + each explicit bin); null bucketing; top-N + "Other" capping;
  scatter passthrough + safety-cap flag; gantt start/end parsing; `ColumnRef`
  index resolution incl. duplicate names; empty/all-null/no-data degenerate
  cases produce the correct `ChartData` metadata + `EmptyReason`.
- **`ChartConfig.infer(from:)`:** sensible defaults across column-kind mixes;
  validation clears roles when a re-run changes column shape.
- **Rust:** `chart_view_state_json` round-trip through SQLite (in-file
  `#[cfg(test)]`, `now()`-based timestamps per the staticlib-tests lesson).
- **Manual verification:** run the app; chart a large real result; confirm
  banner counts (fresh + restored-partial); verify tab-switch and workspace
  reopen restore config + view mode; confirm demoted-blob reopen shows the
  re-run empty state.

## Risks / Open Questions

- **Swift Charts performance** — mitigated by client aggregation, top-N cap, and
  the vectorized `PointPlot` API for scatter. Confirm the safety cap during
  implementation.
- **`ImageRenderer` fidelity** for phase-3 export of interactive charts —
  validate when phase 3 is scoped.
- **SwiftUI ↔ AppKit theming** — ensure the hosted chart honors the app's native
  appearance; `ConnectionsManagerVC`'s `NSHostingView` usage is the reference.
- **`fetchMoreRows` safety cap** for *Load all* on very large results — pick a
  concrete cap during implementation.
