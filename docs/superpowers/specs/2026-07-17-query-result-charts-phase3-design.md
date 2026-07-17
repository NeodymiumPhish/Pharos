# Query Result Charts — Phase 3 Design Spec

**Date:** 2026-07-17
**Status:** Approved for planning
**Builds on:** phase 1 (`…-charts-design.md`) and phase 2 (`…-charts-phase2-design.md`), both shipped.

## Summary

Add the two phase-3 "reporting" capabilities: **chart export** (PNG / PDF /
copy-as-image via SwiftUI `ImageRenderer`) and **SQL push-down aggregation** — a
per-chart "Server aggregation" toggle that runs a generated `GROUP BY` over the
full dataset (wrapping the user's SQL) instead of aggregating the loaded grid
rows client-side. In push-down mode, drilling a mark spawns a filtered detail
query as a new result tab. Export needs no backend; push-down reuses the existing
`executeQuery` FFI (no new Rust command required, pending planning confirmation).

## Goals

- Export the current chart as a shareable image (PNG/PDF) or to the clipboard.
- Chart the full dataset accurately for large results without loading all rows,
  via server-side aggregation generated from the chart config.
- Keep SQL generation and result mapping pure and unit-testable; keep async
  execution + image rendering thin and in the UI layer.
- Reuse the phase-2 `DrillKey` for both client filters and server predicates.

## Non-Goals (Phase 3)

- Automatic push-down (it's a manual per-chart toggle).
- Push-down for scatter / gantt (they don't aggregate).
- Editing/round-tripping the generated SQL in the editor.
- Server-side numeric-`auto` bucket count from row count (uses a fixed default).
- Multi-statement or non-`SELECT` source queries under push-down.

## Decisions (from brainstorming)

| Decision | Choice |
|---|---|
| Scope | Both: chart export **and** SQL push-down. |
| Export formats | PNG (2× retina) + PDF (vector) + Copy-as-image; canvas only (no rail); opaque background. |
| Export entry | The existing Export button's menu shows chart actions in Chart mode, data actions in Grid mode. |
| Push-down activation | **Manual per-chart toggle** ("Server aggregation"); grid still shows the user's original loaded rows. |
| Push-down drill | **Spawn a filtered detail query** (`SELECT * FROM (userSQL) WHERE <predicate>`) as a new result tab. |
| Temporal bin SQL | `date_trunc('unit', col)`; `.auto → 'day'`. |
| Numeric bin SQL | `width_bucket` over a range CTE; fixed `10/20/50`; `.auto → 20`. |
| Availability | Aggregating types only; single wrappable `SELECT`/`WITH`; columns resolvable unambiguously by name. |
| Persistence | `serverAggregation: Bool` on `ChartConfig` (additive, tolerant decoder); re-runs on reopen. |

## Architecture

### New components

| Piece | Kind | Responsibility |
|---|---|---|
| `ChartExporter` | Logic (SwiftUI, `Pharos/ViewControllers/Charts/`) | Render a SwiftUI chart view at a given size via `ImageRenderer` → `NSImage` (PNG, 2×) and PDF `Data`. |
| `SqlPushdownGenerator` | Pure logic (`Pharos/Models/Charts/`) | `(ChartConfig, userSQL, [ColumnDef]) → PushdownQuery?`. Emits the aggregation SQL (wrapped subquery, binning, aliases, ORDER/LIMIT) + output layout, or an `unavailableReason`. |
| `PushdownQuery` | Model | `{ sql: String, layout: PushdownLayout }` — the generated SQL + which output alias is category/series/x/y/value (+ numeric range flag). |
| `ServerChartDataBuilder` | Pure logic | `(QueryResult from generated SQL, PushdownLayout, ChartConfig) → ChartData` with `DrillKey`s (no re-aggregation). |
| `DrillSqlTranslator` | Pure logic (`Pharos/Models/Charts/`) | `(DrillKey, [ColumnDef]) → SQL WHERE predicate` (escaped), parallel to phase-2 `DrillTranslator`. |
| `ChartConfig.serverAggregation` | Model field | Bool; drives the toggle + the data path. |

### Touched components

- `ChartConfig` — add `serverAggregation` (+ tolerant decoder already covers it).
- `ChartRootView` — "Server aggregation" toggle (shown only when available); loading/error state display; pass availability in.
- `ChartViewModel` / `ChartHostingController` — expose an async "server data" injection point + loading/error state.
- `ContentViewController` — owns push-down execution (`executeQuery`), builds `ChartData` via the builder, pushes it into the chart; server-mode drill → `DrillSqlTranslator` → spawn detail query via `executeQuery(_ sql:)`; export menu wiring + save panels.
- `ResultsCopyExport` (or the export-menu owner) — in Chart mode, present chart export actions.

### Boundaries

`SqlPushdownGenerator`, `ServerChartDataBuilder`, and `DrillSqlTranslator` are
pure and unit-tested. The async DB execution, loading/error UI, `ImageRenderer`,
and save panels live in the view/VC layer (build-gated + manual). `ChartData`
stays the single renderer-agnostic currency — client-side and server-side both
produce it, and `ChartView` renders both identically.

## Export

- `ImageRenderer` over `ChartCanvas` (not the rail). `.nsImage` with `scale = 2`
  for PNG; `.render { size, ctx }` into a PDF `CGContext`/`NSMutableData` for
  vector PDF. Opaque, appearance-adaptive background; include axes/legend/title
  (and the pinned gantt header for gantt).
- Entry: the Export button menu (`ResultsCopyExport.showExportMenu`) branches on
  view mode — **Chart mode** → "Export Chart as PNG…", "Export Chart as PDF…",
  "Copy Chart as Image"; **Grid mode** → the existing data-export items.
- Save via `NSSavePanel`; default filename from the result-tab label.

## Push-down: generated SQL

Wrap the user's SQL as a subquery and group, with fixed output aliases so the
builder knows the layout:

```sql
SELECT <catExpr> AS _cat [, <seriesCol> AS _series], <agg> AS _val
FROM ( <userSQL> ) AS _pharos_src
GROUP BY <catExpr> [, <seriesCol>]
ORDER BY 1
LIMIT <cap>
```
- **Heatmap:** `SELECT <xExpr> AS _x, <yExpr> AS _y, <agg> AS _val … GROUP BY _x,_y`.
- **`catExpr` binning:** discrete `"col"`; temporal `date_trunc('unit',"col")`
  (`.auto→'day'`, `.none→"col"`); numeric via a range CTE + `width_bucket`:
  ```sql
  WITH _pharos_src AS ( <userSQL> ),
       _r AS (SELECT min("col") lo, max("col") hi FROM _pharos_src)
  SELECT width_bucket("col", _r.lo, _r.hi, <N>) AS _bucket, _r.lo, _r.hi, <agg> AS _val
  FROM _pharos_src, _r GROUP BY _bucket, _r.lo, _r.hi ORDER BY _bucket
  ```
- **`agg`:** `count(*)` when value unmapped or aggregation is count; else
  `sum/avg/min/max("valCol")`.
- **Quoting/escaping:** identifiers double-quoted (internal `"`→`""`); string
  literals in drill predicates single-quoted (internal `'`→`''`); temporal bounds
  formatted as ISO strings. Mandatory for correctness and injection safety.
- **Cap:** `LIMIT` on group count; builder flags truncation → UI note.

## Push-down: data + drill

- `ServerChartDataBuilder` maps the aliased result rows to `ChartData`
  points/cells (server already grouped — no re-aggregation) and attaches a
  `DrillKey` per mark (`.anyOf`/`.blank`/`.range`/`.compound`, same as client).
  Numeric bucket labels/bounds come from the returned global `lo/hi` + `N`.
- Drilling in push-down mode: the VC runs `DrillSqlTranslator(DrillKey) →
  predicate`, builds `SELECT * FROM ( <userSQL> ) AS _pharos_src WHERE
  <predicate>`, and executes it through the existing `executeQuery(_ sql:)` entry
  as a **new result tab**. (Client mode still uses phase-2 `DrillTranslator →
  ColumnFilter → grid`.) The VC picks the backend by `config.serverAggregation`.

## Push-down: availability & data flow

- Toggle shown only when: chart type ∈ {bar,line,area,pie,heatmap}; the user's
  SQL is a single wrappable `SELECT`/`WITH` (trim, strip trailing `;`, reject
  multi-statement/non-SELECT); mapped columns resolve unambiguously by name.
  Otherwise the toggle is hidden/disabled with a reason.
- Flow (async, VC-owned): config change with `serverAggregation` on & available →
  generate SQL → `PharosCore.executeQuery(connectionId:, sql:)` → `QueryResult` →
  `ServerChartDataBuilder` → `ChartData` → push into the chart. A loading state
  shows during the query; an error state shows the DB error. Toggle off → the
  synchronous client `ChartAggregator` path (unchanged). Grid unaffected in both.

## Persistence

- `serverAggregation` rides `chart_view_state_json` (tolerant decoder → `false`).
  On reopen with it on, the chart re-runs the generated query (source SQL +
  connection live on the result tab); if unavailable, `.noData` empty state.
- No new Rust/SQLite surface expected (reuses `executeQuery`); confirm the
  execute path doesn't force unwanted history/result-tab side effects during
  planning (if it does, add a lightweight "chart query" execute variant).

## Testing

Per the repo's standalone-`swiftc` harnesses:
- **`SqlPushdownGenerator`:** discrete/temporal/numeric `catExpr`; series; heatmap;
  each agg; ORDER/LIMIT; identifier quoting + literal escaping; unavailable
  reasons (non-SELECT, multi-statement, ambiguous name, scatter/gantt).
- **`ServerChartDataBuilder`:** aliased rows → points/cells + `DrillKey`s; numeric
  bucket label/bounds from global lo/hi + N; null handling.
- **`DrillSqlTranslator`:** every `DrillKey` → correctly escaped predicate
  (`IN`, `IS NULL`, `>=..<`, `AND`, temporal/numeric formatting, `''` escaping).
- **`ChartConfig` Codable:** `serverAggregation` round-trip + legacy-blob decode.
- **Export:** build-gated + manual (`ImageRenderer` doesn't run cleanly headless).
- **Rust:** none expected; re-run existing suite.
- **Manual (GUI + Postgres):** export PNG/PDF/copy (content, opaque bg, retina);
  push-down chart matches a hand-run GROUP BY (temporal, numeric, heatmap,
  series); loading/error; toggle hidden for scatter/gantt/non-SELECT; push-down
  drill spawns the correct detail query; reopen with the toggle on re-runs.

## Phasing (within phase 3)

- **A — Export:** `ChartExporter` + Export-menu branch (PNG/PDF/copy) + save panels. Self-contained; build-gated + manual.
- **B — Push-down pure logic:** `ChartConfig.serverAggregation`, `SqlPushdownGenerator` (+ `PushdownQuery`/`PushdownLayout`), `ServerChartDataBuilder`, `DrillSqlTranslator`. TDD harnesses.
- **C — Push-down integration:** rail toggle + availability gating; async execute + loading/error in the VC/host; server-mode drill-spawn; reopen re-run. Build-gated + manual.

## Risks / Open Questions

- **Wrapping arbitrary user SQL** as a subquery — CTEs and trailing `;`/`ORDER BY`
  are fine; multi-statement/non-SELECT are rejected. Confirm the single-statement
  detection is robust (semicolons inside string literals) during planning.
- **`executeQuery` side effects** — confirm running the generated query for the
  chart doesn't create an unwanted history entry / result tab; add a variant if
  it does.
- **`ImageRenderer` fidelity/threading** — must render on the main actor; confirm
  legend/axis/gantt-header all capture; large charts' memory.
- **Ambiguous column names** under wrapping — disable push-down rather than emit
  ambiguous `GROUP BY`.
- **Async chart state** — the view model gains loading/error; ensure config
  changes while a query is in flight cancel/supersede correctly (last-write-wins).
