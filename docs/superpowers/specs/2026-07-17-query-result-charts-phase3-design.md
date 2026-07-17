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
`executeQuery` FFI and adds one small backend change — a `source` tag column on
`query_history` so aggregation runs stay in the audit trail (kept, not suppressed)
and are labelled.

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
- Editing/round-tripping the generated SQL in the editor (but **copying** the
  generated SQL is in scope — see Provenance).
- Server-side numeric-`auto` bucket count from row count (uses a fixed default).
- Multi-statement or non-`SELECT` source queries under push-down.
- Server-side scatter sampling (`TABLESAMPLE`/`ORDER BY random()`) — a natural
  phase-4 seam, noted so the door stays marked.

## Provenance / auditability (first-class concern)

Because push-down is the mode used for big-data findings, its trail must be
**stronger**, not weaker, than client mode. `execute_query` already records every
run to `query_history` (SQL text, timing, row counts) plus a cached blob
([query.rs:206-249](../../../pharos-core/src/commands/query.rs)); client-mode
charts and drill-detail queries therefore already leave a solid, re-runnable
trail. The aggregation query must **keep** that trail:

1. **Keep (don't suppress) history for push-down runs**, and **tag** them so the
   history browser can label/filter "chart aggregation" rows. This adds a small
   `source TEXT` column to `query_history` (bends the "no new Rust/SQLite
   surface" claim — the cheapest possible bend). Debounce execution (config saves
   are already debounced) so a rail tweak doesn't spam history.
2. **Persist `lastServerRun { sql, executedAt, rowCount, truncated }`** inside
   `chart_view_state_json` — provenance that travels with the workspace even
   after 90-day history pruning / blob demotion.
3. **"View / Copy generated SQL"** action in chart mode — the forensic primitive:
   an auditor re-runs it verbatim to validate the chart. (This is the SQL-export
   half phase-2 deferred to phase 3.)
4. **Export provenance:** an optional caption footer rendered into the image
   (timestamp, connection, "server-aggregated" vs client, plotted-vs-total,
   truncation note), and the generated SQL + timestamp embedded in PNG `tEXt` /
   PDF metadata. An exported chart outlives everything else; it must carry lineage.
5. **Reopen is explicit, not auto-run:** a workspace with `serverAggregation` on
   reopens into a "Run server aggregation (last run &lt;executedAt&gt;)" state
   showing `lastServerRun` provenance — one click re-runs. This preserves the
   finding, avoids surprise DB load, and makes data drift visible instead of
   silently mutating the evidence.

## Decisions (from brainstorming + review)

| Decision | Choice |
|---|---|
| Scope | Both: chart export **and** SQL push-down. |
| Export formats | PNG (2× retina) + PDF (vector) + Copy-as-image; canvas only (no rail). |
| Export appearance | Default to **light** (dark exports look wrong in docs); offer match-appearance. |
| Export entry | The existing Export button's menu shows chart actions in Chart mode, data actions in Grid mode. |
| Push-down activation | **Manual per-chart toggle** ("Server aggregation"); grid still shows the user's original loaded rows. |
| Push-down drill | **Spawn a filtered detail query** (`SELECT * FROM (userSQL) WHERE <predicate>`) as a new result tab. |
| Temporal bin SQL | `date_trunc('unit', "col")`; timestamptz gets `AT TIME ZONE 'UTC'` to match the client's UTC binning; `.auto → 'day'` (matches client's hardcoded day default). |
| Numeric bin SQL | `LEAST(width_bucket(…, N), N)` over a range CTE, with a `lo = hi` single-bucket guard; fixed `10/20/50`; `.auto → 20`. |
| Top-N | `ORDER BY _val DESC LIMIT N` (re-sorted client-side for display) to mirror client's by-value top-N; no server "Other" bucket (banner the dropped count). Heatmap: documented per-axis divergence (single `LIMIT` can't express 25×25). |
| History | **Keep + tag** push-down runs (source column); debounced. |
| Provenance | `lastServerRun` in the config blob; copy-generated-SQL; export caption + metadata; explicit re-run on reopen. |
| Availability | Aggregating types only; single wrappable `SELECT`/`WITH` (detected via `SQLSegmentParser`); columns resolvable unambiguously by name. |
| Persistence | `serverAggregation: Bool` + `lastServerRun` on `ChartConfig` (additive, tolerant decoder). |

## Architecture

### New components

| Piece | Kind | Responsibility |
|---|---|---|
| `ChartExporter` | Logic (SwiftUI, `Pharos/ViewControllers/Charts/`) | Render a SwiftUI chart view (light appearance, + provenance caption) at a given size via `ImageRenderer` → `NSImage` (PNG, 2×, with `tEXt` metadata) and PDF `Data` (with metadata). |
| `SqlPushdownGenerator` | Pure logic (`Pharos/Models/Charts/`) | `(ChartConfig, userSQL, [ColumnDef]) → PushdownQuery?`. Emits the aggregation SQL (wrapped subquery, binning, aliases, ORDER/LIMIT) + output layout, or an `unavailableReason`. |
| `PushdownQuery` | Model | `{ sql: String, layout: PushdownLayout }` — the generated SQL + which output alias is category/series/x/y/value (+ numeric range flag). |
| `ServerChartDataBuilder` | Pure logic | `(QueryResult from generated SQL, PushdownLayout, ChartConfig) → ChartData` with `DrillKey`s (no re-aggregation). |
| `DrillSqlTranslator` | Pure logic (`Pharos/Models/Charts/`) | `(DrillKey, [ColumnDef]) → SQL WHERE predicate` (escaped), parallel to phase-2 `DrillTranslator`. |
| `ChartConfig.serverAggregation` + `lastServerRun` | Model fields | Bool drives the toggle + data path; `lastServerRun { sql, executedAt, rowCount, truncated }` carries provenance for reopen + copy-SQL. |
| `query_history.source` | Rust/SQLite column | Tags push-down aggregation runs so history keeps + labels them. |

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
  vector PDF. Include axes/legend/title (and the pinned gantt header for gantt).
- **Appearance:** default exports to **light** (dark-mode exports look wrong
  pasted into documents); offer a "match appearance" option. Opaque background.
- **Provenance in the artifact:** an optional **caption footer** rendered into the
  image — timestamp, connection name, "server-aggregated (full dataset)" vs
  "client-side (N of M loaded rows)", and truncation note — plus the generating
  **SQL + timestamp embedded in PNG `tEXt` / PDF metadata**. An exported chart is
  the artifact most likely to outlive the workspace; it must carry its lineage.
- Entry: the Export button menu (`ResultsCopyExport.showExportMenu`) branches on
  view mode — **Chart mode** → "Export Chart as PNG…", "Export Chart as PDF…",
  "Copy Chart as Image", and (push-down mode) "View / Copy Generated SQL";
  **Grid mode** → the existing data-export items.
- Save via `NSSavePanel`; default filename from the result-tab label.

## Push-down: generated SQL

Wrap the user's SQL as a subquery and group, with fixed output aliases so the
builder knows the layout:

```sql
SELECT <catExpr> AS _cat [, <seriesCol> AS _series], <agg> AS _val
FROM ( <userSQL> ) AS _pharos_src
GROUP BY <catExpr> [, <seriesCol>]
ORDER BY _val DESC          -- by-value, to mirror client top-N (NOT ORDER BY 1)
LIMIT <cap>
```
- **Top-N parity (#7):** client mode keeps the top-N categories **by aggregated
  value** and folds the rest into "Other"; `ORDER BY 1 LIMIT` would instead keep
  the first N **alphabetically** — different categories, looking like different
  data. Use `ORDER BY _val DESC LIMIT N` and re-sort client-side for display.
  There is **no server "Other" bucket**; surface the dropped-group count via a
  banner (optionally a cheap `count(DISTINCT <catExpr>)`). **Heatmap** can't
  express per-axis 25×25 with one `LIMIT` — chosen semantics: a single overall
  `LIMIT` on cells with a truncation banner (documented divergence from client's
  per-axis top-N; a `dense_rank()` per axis is deferred).
- **Heatmap:** `SELECT <xExpr> AS _x, <yExpr> AS _y, <agg> AS _val … GROUP BY _x,_y ORDER BY _val DESC LIMIT <cap>`.
- **`catExpr` binning:** discrete `"col"`; temporal `date_trunc('unit', "col")`,
  and for **`timestamptz`** columns `date_trunc('unit', "col" AT TIME ZONE 'UTC')`
  so bucket boundaries match the client's UTC calendar binning (#8; plain
  `timestamp`/`date` need no conversion); `.auto→'day'` (matches the client's
  hardcoded day default — they stay in sync; if client `.auto` ever becomes
  span-based, pass the resolved unit into the generator); `.none→"col"`.
- **Numeric via a range CTE + `width_bucket`** — note the `LEAST(…, N)` clamp and
  the `lo = hi` guard (#6): `width_bucket` returns `N+1` for `v >= hi`, so the
  column max would otherwise land in a spurious extra bucket; and `width_bucket`
  errors when `lo = hi`:
  ```sql
  WITH _pharos_src AS ( <userSQL> ),
       _r AS (SELECT min("col") lo, max("col") hi FROM _pharos_src)
  SELECT CASE WHEN _r.lo = _r.hi THEN 1
              ELSE LEAST(width_bucket("col", _r.lo, _r.hi, <N>), <N>) END AS _bucket,
         _r.lo, _r.hi, <agg> AS _val
  FROM _pharos_src, _r GROUP BY _bucket, _r.lo, _r.hi ORDER BY _bucket
  ```
  (numeric axes order by bucket, ascending — the histogram case; top-N by value
  applies to discrete/temporal axes.)
- **`agg`:** `count(*)` when value unmapped or aggregation is count; else
  `sum/avg/min/max("valCol")`.
- **Quoting/escaping:** identifiers double-quoted (internal `"`→`""`); string
  literals in drill predicates single-quoted (internal `'`→`''`); temporal bounds
  formatted as ISO strings; numeric literals formatted **locale-independently**
  (no thousands separators). Mandatory for correctness and injection safety.
- **Cap:** `LIMIT` on group count; builder flags truncation → banner (see also
  the executeQuery row-limit note under Data flow).

## Push-down: data + drill

- `ServerChartDataBuilder` maps the aliased result rows to `ChartData`
  points/cells (server already grouped — no re-aggregation) and attaches a
  `DrillKey` per mark (`.anyOf`/`.blank`/`.range`/`.compound`, same as client).
  Numeric bucket labels/bounds come from the returned global `lo/hi` + `N`.
- Drilling in push-down mode: the VC runs `DrillSqlTranslator(DrillKey) →
  predicate`, builds `SELECT * FROM ( <substitutedUserSQL> ) AS _pharos_src WHERE
  <predicate>`, and executes it through the existing `executeQuery(_ sql:)` entry
  as a **new result tab** (which records it in history — a self-contained,
  re-runnable trail). (Client mode still uses phase-2 `DrillTranslator →
  ColumnFilter → grid`.) The VC picks the backend by `config.serverAggregation`.
- `DrillSqlTranslator` predicates: `.anyOf → "col" IN ('a','b')` (`''`-escaped),
  `.blank → "col" IS NULL`, `.range → "col" >= lo AND "col" < hi` (**half-open**,
  matching the aggregator's bins and avoiding the grid's inclusive-between issue;
  numeric literals locale-independent; temporal bounds as UTC ISO strings, and for
  `timestamptz` compared consistently with the `AT TIME ZONE 'UTC'` binning),
  `.compound → AND`.

## Push-down: availability & data flow

- Toggle shown only when: chart type ∈ {bar,line,area,pie,heatmap}; the user's
  SQL is a **single wrappable `SELECT`/`WITH`** — detected with the existing
  **`SQLSegmentParser`** (`Pharos/Editor/SQLSegmentParser.swift`), which already
  handles semicolons inside string literals, comments, and dollar-quoted bodies
  (`$$…;…$$`) — reject multi-statement / non-SELECT; mapped columns resolve
  unambiguously by name. Otherwise the toggle is hidden/disabled with a reason.
- **Wrap the substituted SQL (#12):** the wrapper and drill-spawn must wrap the
  **post-variable-substitution** text that actually executed (Pharos has `{{var}}`
  query variables). The result tab's stored `sql` should already be the
  substituted text — verify during planning. Wrapping the template would error or
  silently aggregate different data; the recorded drill SQL must be self-contained
  and re-runnable.
- Flow (async, VC-owned): config change with `serverAggregation` on & available →
  generate SQL → `PharosCore.executeQuery(connectionId:, sql:, limit:)` →
  `QueryResult` → `ServerChartDataBuilder` → `ChartData` → push into the chart. A
  loading state shows during the query; an error state shows the DB error. Toggle
  off → the synchronous client `ChartAggregator` path (unchanged). Grid unaffected.
- **Row-limit vs group-cap (#10):** `executeQuery` applies its own page
  `limit` (default 1000) and sets `hasMore` — orthogonal to the generated
  `LIMIT <cap>`. The VC must pass `limit ≥ cap` for chart queries so groups
  aren't silently paged off; the builder treats a returned `hasMore == true` as a
  truncation signal (banner), never as "there's more nobody fetched."
- **Real cancellation (#13):** a superseded config change (or toggle-off, or tab
  close) must **cancel** the in-flight query via `cancelQuery` (the
  `running_queries` / `pg_cancel_backend` infra exists) — not merely discard its
  result — so a superseded full-table `GROUP BY` stops burning server time.
  Combine with last-write-wins so stale results are ignored.
- **Debounce** push-down execution (config saves are already debounced) so a rail
  tweak doesn't spam the DB or the history log.
- **Banner** states the mode + as-of time ("Aggregated server-side over the full
  dataset, as of 14:32" vs the existing client-side banner) — on-screen provenance.

## Persistence

- `serverAggregation: Bool` and `lastServerRun { sql, executedAt, rowCount,
  truncated }` ride `chart_view_state_json` (tolerant decoder → `false` / `nil`).
  `lastServerRun` is provenance that survives history pruning and powers the
  reopen affordance + copy-SQL.
- **Reopen is explicit (not auto-run):** with `serverAggregation` on, reopen shows
  a "Run server aggregation (last run &lt;executedAt&gt;)" state with the
  `lastServerRun` summary; one click re-runs. Avoids surprise DB load and silent
  evidence mutation.
- **One small Rust/SQLite addition:** a `source TEXT` column on `query_history`
  so push-down aggregation runs are tagged (e.g. `"chart-aggregation"`) and the
  history browser can label/filter them. `execute_query` (or a thin wrapper) sets
  it for chart queries. This is the only backend surface in phase 3 — the
  aggregation query's history entry is **kept**, not suppressed.

## Testing

Per the repo's standalone-`swiftc` harnesses:
- **`SqlPushdownGenerator`:** discrete/temporal/numeric `catExpr`; series; heatmap;
  each agg; **`ORDER BY _val DESC LIMIT` top-N (not alphabetical)**; **`timestamptz
  → AT TIME ZONE 'UTC'`**; **numeric `LEAST(width_bucket,N)` clamp + `lo=hi`
  single-bucket guard**; identifier quoting + literal escaping (incl.
  locale-independent numbers); unavailable reasons (non-SELECT via
  `SQLSegmentParser`, multi-statement, dollar-quoted `;`, ambiguous name,
  scatter/gantt).
- **`ServerChartDataBuilder`:** aliased rows → points/cells + `DrillKey`s; numeric
  bucket label/bounds from global lo/hi + N; `hasMore == true` → truncation flag;
  null handling.
- **`DrillSqlTranslator`:** every `DrillKey` → correctly escaped predicate
  (`IN`, `IS NULL`, **half-open `>= lo AND < hi`**, `AND`, temporal/numeric
  formatting, `''` escaping, locale-independent numbers).
- **`ChartConfig` Codable:** `serverAggregation` + `lastServerRun` round-trip +
  legacy-blob decode (missing keys → defaults).
- **Export:** build-gated + manual (`ImageRenderer` doesn't run cleanly headless).
- **Rust:** the `source` column round-trips through `query_history` (in-file
  `#[cfg(test)]`); otherwise re-run existing suite.
- **Manual (GUI + Postgres):** export PNG/PDF/copy (content, light bg, retina,
  caption + embedded SQL metadata); copy-generated-SQL re-runs verbatim;
  push-down chart matches a hand-run GROUP BY (temporal boundary at UTC, numeric
  max not in a phantom bucket, top-N by value, heatmap, series); loading/error;
  superseded query is actually cancelled; toggle hidden for scatter/gantt/
  non-SELECT; push-down drill spawns the correct detail query and it appears in
  history; reopen shows the explicit "run (last run …)" state and re-runs;
  chart-aggregation rows are tagged in the history browser.

## Phasing (within phase 3)

- **A — Export:** `ChartExporter` (PNG/PDF/copy, light default) + provenance
  caption + PNG/PDF metadata + Export-menu branch + save panels. Self-contained;
  build-gated + manual.
- **B — Push-down pure logic:** `ChartConfig.serverAggregation` + `lastServerRun`,
  `SqlPushdownGenerator` (+ `PushdownQuery`/`PushdownLayout`) with the `width_bucket`
  clamp/`lo=hi` guard, top-N-by-value, `timestamptz` UTC binning, `SQLSegmentParser`
  availability check, `ServerChartDataBuilder`, `DrillSqlTranslator` (half-open).
  TDD harnesses.
- **B′ — History source tag (Rust/SQLite):** add the `source` column to
  `query_history` (migration + model/FFI passthrough) and set it for chart
  queries; in-file round-trip test. Small, isolated.
- **C — Push-down integration:** rail toggle + availability gating; async execute
  (`limit ≥ cap`) + loading/error + real cancellation of superseded queries;
  copy-generated-SQL; server-mode drill-spawn; explicit re-run on reopen with
  `lastServerRun`; mode/as-of banner. Build-gated + manual.

## Risks / Open Questions

- **Wrapping arbitrary user SQL** — CTEs and trailing `;`/`ORDER BY` are fine;
  multi-statement/non-SELECT rejected via `SQLSegmentParser` (dollar-quote/comment
  safe). Confirm the **result tab's stored `sql` is the substituted text** (post
  `{{var}}`), not the template — wrap that.
- **`executeQuery` records history — keep it.** Running the generated query DOES
  write a `query_history` row ([query.rs:206](../../../pharos-core/src/commands/query.rs));
  that is desirable provenance. Do NOT suppress it — tag it via the `source`
  column and debounce so it isn't noisy. (Resolved from the earlier "add a
  suppress variant" instinct.)
- **`executeQuery` row limit** — pass `limit ≥ cap`; treat `hasMore` as truncation
  (see Data flow).
- **`ImageRenderer` fidelity/threading** — must render on the main actor; confirm
  legend/axis/gantt-header + caption all capture; large charts' memory.
- **Ambiguous column names** under wrapping — disable push-down rather than emit
  ambiguous `GROUP BY`.
- **Async chart state** — the view model gains loading/error; a superseded query
  must be **cancelled** (`cancelQuery`), not just ignored (last-write-wins for the
  result, real cancel for the server work).
- **Heatmap top-N divergence** — a single `LIMIT` can't reproduce client per-axis
  25×25; shipped as documented divergence (banner), `dense_rank()` per axis
  deferred.
