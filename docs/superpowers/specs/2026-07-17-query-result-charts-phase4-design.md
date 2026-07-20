# Query Result Charts — Phase 4 Design Spec

**Date:** 2026-07-17
**Status:** Approved for planning
**Builds on:** phases 1–3 (all shipped/merged).

## Summary

Phase 4 closes the deferred edges from phases 1–3 — "chart completeness" — in
three cohesive sub-phases: **(A) push-down parity** (scatter under server
aggregation via sampling; heatmap per-axis top-N; row-count-based `.auto` bucket
count), **(B) heatmap axes** (numeric-axis binning + independent per-axis bin
granularity via a new `axisBins` model), and **(C) richer interaction** (gantt
overlap time-brush, heatmap rectangular brush, stacked series-precise drill, pie
⌘-click multi-select). All reuse the established pure/async boundaries; the only
new persisted state is `axisBins`, and there are no new Rust/SQLite changes.

## Goals

- Make server aggregation reach parity with client mode (scatter, heatmap top-N,
  auto bucketing).
- Let heatmap X/Y axes bin numerically and independently.
- Extend drill/brush to the remaining chart types with audit-useful semantics
  (gantt overlap).
- Keep SQL generation, result mapping, and drill translation pure and
  unit-tested; keep gesture/async work thin and in the UI layer.

## Non-Goals (Phase 4)

- `TABLESAMPLE` (a base-table clause; can't apply to the wrapped subquery).
- Grouped-bar series-precise drill (stacked only; grouped falls back to
  category-only).
- Pie drag-brushing (radial layout — ⌘-click multi-select instead).
- New chart types, annotations/thresholds, or saved chart presets.

## Decisions (from brainstorming)

| Decision | Choice |
|---|---|
| Scope | All three deferral clusters (push-down parity, heatmap axes, interaction). |
| Scatter push-down | Non-aggregating sampled query, **deterministic** order (`ORDER BY hashtext((_x,_y)::text) LIMIT <sampleCap>`) so a re-run reproduces the chart (not `TABLESAMPLE`, not `random()`); banner + `lastServerRun` mark it "sampled". |
| Heatmap top-N (push-down) | Per-axis `dense_rank()` windows (matches client 25×25), replacing the flat `LIMIT`. |
| `.auto` bucket count (push-down) | Scalar subquery `LEAST(50, GREATEST(1, CEIL(SQRT(COUNT(*)))::int))` folded into the range CTE. |
| Per-axis bin model | `axisBins: [ChartColumnRole: AxisBin]` with fallback to the global `temporalBin`/`numericBin` (recommended (a)). |
| Heatmap numeric binning | `width_bucket` (push-down, per numeric axis) + mirrored client binning in `aggregateHeatmap`. |
| Series-precise drill | Stacked bars via y-band resolution; line/area via nearest-series; grouped/ambiguous → category-only (documented). |
| Gantt time-brush | **Overlap** via a new `DrillKey.overlap(startRef, endRef, lo, hi, RangeKind)` (temporal *or* numeric gantt axes). |
| Heatmap brush | Rectangular selection → **merge the covered cells' pre-computed per-axis drill sub-keys** (union `.anyOf`, coalesce `.range`, carry `.blank`), then compound the two axes — never rebuilt from labels. |
| Pie multi-select | ⌘/⇧-click accumulates slices' drill sub-keys → merged per column (may include the null slice). No drag-brush. |
| SQL `.anyOf` null | `DrillSqlTranslator.anyOf` splits the blanks sentinel out → `"col" IN (…) OR "col" IS NULL` (parity with the grid). |
| Persistence | Only `axisBins` is new (additive, tolerant decoder). No backend changes. |

## A — Push-down parity

### Scatter under push-down (#1)

`SqlPushdownGenerator` currently returns nil for `.scatter`. Extend it so
scatter + `serverAggregation` produces a **non-aggregating sampled** query:

```sql
SELECT <xExpr> AS _x, <yExpr> AS _y
FROM ( <userSQL> ) AS _pharos_src
WHERE <xExpr> IS NOT NULL AND <yExpr> IS NOT NULL
ORDER BY hashtext((_pharos_src.*)::text)   -- deterministic pseudo-random; re-run reproduces
LIMIT <sampleCap>
```

- `TABLESAMPLE` is rejected — it's a base-table clause and can't wrap our
  subquery.
- **Deterministic order (audit):** `ORDER BY random()` would mean a re-run of the
  recorded SQL never reproduces the chart — the one regression against phase-3
  provenance. Instead order by a stable hash of the row
  (`hashtext((_pharos_src.*)::text)`, similar cost) so identical data yields the
  same sample. The banner and `lastServerRun` still mark the chart **"sampled"**
  (it's not the full set). (If the exact `.*::text` cast is awkward in practice,
  hash the projected `_x||_y` values — a plan detail; the requirement is
  *deterministic + labelled*.)
- `PushdownQuery.layout` gains a `.scatter` kind (a `ScatterLayout` reading
  `_x/_y` as raw points). `ServerChartDataBuilder` maps those to `ChartPoint`s
  (xValue/y), sets `wasSampled = result.hasMore || rows == sampleCap`.
- **Row-limit lesson (phase 3):** the VC must request `executeQuery(limit:) ≥
  sampleCap`, or the sample silently truncates with `hasMore`.
- Scatter push-down drill = brush → x/y-range detail query (see C).
- Availability: scatter is now available under push-down when the SQL is
  wrappable and x/y resolve.

### Heatmap per-axis top-N via `dense_rank()` (#6)

Replace the flat `LIMIT` for heatmap with two ranking CTEs — rank X values by
their marginal aggregate and Y values by theirs, keep the top-N of each, and
select only cells in `(topX) × (topY)`:

```sql
WITH _agg AS ( SELECT <xExpr> _x, <yExpr> _y, <agg> _val FROM (<userSQL>) s GROUP BY 1,2 ),
     _xr AS ( SELECT _x, dense_rank() OVER (ORDER BY sum(_val) DESC) rk FROM _agg GROUP BY _x ),
     _yr AS ( SELECT _y, dense_rank() OVER (ORDER BY sum(_val) DESC) rk FROM _agg GROUP BY _y )
SELECT a._x, a._y, a._val FROM _agg a
  JOIN _xr ON _xr._x = a._x AND _xr.rk <= <N>
  JOIN _yr ON _yr._y = a._y AND _yr.rk <= <N>
```

Matches the client's per-axis 25×25 semantics. Truncation flagged when either
axis is capped (compare distinct counts to N).

### Row-count `.auto` bucket count (#7)

Fold the count into the existing numeric range CTE — `width_bucket`'s count
argument becomes a scalar subquery so `.auto` picks `~√n` buckets server-side in
one query (matching the client), no extra round-trip:

```sql
width_bucket("col", _r.lo, _r.hi, (SELECT LEAST(50, GREATEST(1, CEIL(SQRT(COUNT(*)))::int)) FROM _pharos_src))
```

(Fixed counts 10/20/50 stay literal.)

## B — Heatmap axes

### Per-axis bin model (#3)

Add to `ChartConfig`:
```
struct AxisBin: Codable, Equatable { var temporal: TemporalBin = .auto; var numeric: NumericBin = .auto }
var axisBins: [ChartColumnRole: AxisBin] = [:]
```
A single resolver centralizes reads:
```
func resolvedBin(for role: ChartColumnRole) -> AxisBin
// returns axisBins[role] if present, else AxisBin(temporal: temporalBin, numeric: numericBin)
```
- Backward-compatible: empty `axisBins` ⇒ existing global-bin behavior for all
  charts. Single-axis charts keep writing the global `temporalBin`/`numericBin`;
  heatmap writes `axisBins[.x]`/`[.y]`.
- `[ChartColumnRole: AxisBin]` encodes as a flat array (String-raw enum key, like
  `mappings`) and rides `chart_view_state_json` under the tolerant decoder.
- The aggregator and generator read binning via `resolvedBin(for:)` — no
  sprinkled fallback logic.

### Numeric-axis binning (#2)

- **Client (`aggregateHeatmap.axis()`):** currently bins only temporal. Add
  numeric binning per axis, mirroring the categorical path (per-axis first-pass
  min/max/distinct, low-cardinality escape, `[lo,hi)` labels, `.range` drill
  sub-key), driven by `resolvedBin(for: .x/.y)`.
- **Push-down (`SqlPushdownGenerator.heatmap`):** emit `width_bucket` per numeric
  axis with the `LEAST(…,N)` clamp + `lo=hi` guard. **Both** axes numeric ⇒ two
  range CTEs (`_rx`, `_ry`); the builder derives each axis's bucket
  labels/bounds from the returned per-axis `lo/hi/N`. Composes with the per-axis
  top-N (A #6) so cells stay bounded.

### Rail

For heatmap, show an **independent** bin control per axis — Time Bucket *or* Bins
by the column's kind — for X and for Y, writing to `axisBins[.x]`/`[.y]`.
Non-heatmap charts are unchanged (global bin controls).

## C — Richer interaction

### Series-precise drill (#5)

- The aggregator attaches `.compound([categoryKey, seriesKey])` to each
  multi-series point (today they carry only the category drill).
- **Stacked** bars: the gesture resolves the hit series by mapping the tap's y
  (via the chart proxy) to the cumulative series band at that category → filter
  category **and** that series. **Line/area:** resolve the **nearest series** to
  the tap (by proximity to each series' value at that x). **Grouped/ambiguous**
  taps fall back to category-only (documented). Both backends already handle
  `.compound` (grid: two column filters; SQL: `AND`).

### Gantt overlap time-brush (#4)

- Drag horizontally across the time axis → `[t0, t1]`; select rows whose bar was
  **active during** the window.
- New `DrillKey.overlap(startRef, endRef, lo, hi, RangeKind)` (epoch/numeric
  bounds). **The `RangeKind` is required** — gantt start/end may be **numeric**,
  not just temporal (`ChartAggregator.epoch` handles a "numeric gantt axis"); the
  translators must branch on it exactly like `.range` does, or a numeric gantt
  brush emits temporal literals that match nothing/error. Expressible in both
  backends:
  - **Grid** (`DrillTranslator`): two column filters — `startRef ≤ hi`
    (`lessOrEqual`) **and** `endRef ≥ lo` (`greaterOrEqual`), bounds formatted per
    `RangeKind` — ANDed by the existing per-column engine.
  - **SQL** (`DrillSqlTranslator`): `"start" <= <hi> AND "end" >= <lo>`, bounds
    formatted per `RangeKind` (numeric literal or UTC ISO), escaped.
- `DrillKey.overlap.columnRefs` returns both refs (for chip/label + the two-column
  grid application). Push-down gantt isn't a thing (gantt never aggregates), so
  gantt overlap-brush drills the loaded grid (client) — consistent with phase 2.

### Heatmap rectangular brush (#4)

Drag a box over cells → collect the **covered cells** and **merge their
pre-computed per-axis drill sub-keys** (each cell already carries
`.compound([xSubKey, ySubKey])` from aggregation, where a sub-key is `.range`
for a binned axis, `.anyOf`/`.blank` for a discrete one). Merge **per axis**:
union `.anyOf` value-lists, coalesce adjacent `.range`s, carry any `.blank`; then
compound the two merged axis keys. **Do NOT rebuild keys from cell labels** — on a
binned axis (Part B) the labels are range strings like `"0–10"` that match
nothing, and a null-bucket label isn't a valid literal. A shared pure
`mergeDrillKeys([DrillKey]) -> [DrillKey]` helper (group by column ref; union
anyOf/coalesce range/keep blank) serves both this and pie multi-select.

### Pie ⌘-click multi-select (#4)

⌘/⇧-click accumulates the clicked slices' **drill sub-keys** (`.anyOf` for real
slices, `.blank` for the null slice) into a selection; the combined selection is
merged via `mergeDrillKeys` and drilled as one per-column key. A plain click
single-selects. No drag-brush for pie.

### SQL `.anyOf` null parity (fix)

`DrillSqlTranslator.anyOf` currently emits a bare `"col" IN (…)` with no
null handling, while the grid's `DrillTranslator` already folds `blanksSentinel`
into an `.isAnyOf` that the evaluator treats as null-matching. Merged selections
(heatmap brush / pie ⌘-click) can put the blanks sentinel into an `.anyOf`
value-list alongside real values, so `DrillSqlTranslator.anyOf` must split it out:
non-sentinel values → `"col" IN (…)`, and if the sentinel is present →
`OR "col" IS NULL` — i.e. `"col" IN ('a','b') OR "col" IS NULL`. Restores
grid↔SQL parity for null-inclusive selections.

## Persistence

- Only `axisBins` is new — additive on `ChartConfig`, tolerant decoder → empty
  (⇒ phases 1–3 behavior). Rides `chart_view_state_json`.
- No new Rust/SQLite/FFI surface. Brush/drill/selection state and scatter
  sampling are ephemeral/runtime.

## Testing

Per the repo's standalone-`swiftc` harnesses:
- **`SqlPushdownGenerator`:** scatter sampled query (**deterministic**
  `ORDER BY hashtext(…) LIMIT`, non-agg, `_x/_y`, null filter, `.scatter` layout);
  heatmap per-axis `dense_rank()` top-N; `.auto` count scalar-subquery; heatmap
  numeric `width_bucket` per axis (two range CTEs when both numeric);
  `resolvedBin` precedence (`axisBins` over globals).
- **`ServerChartDataBuilder`:** scatter `ScatterLayout` → raw points +
  `wasSampled`; per-axis numeric bucket labels/bounds.
- **`ChartAggregator`:** heatmap per-axis numeric binning (low-card escape,
  labels, `.range` drill); multi-series points carry `.compound(category+series)`.
- **`mergeDrillKeys`:** union same-column `.anyOf`; coalesce adjacent `.range`;
  keep `.blank`; group by column ref (covers heatmap brush + pie multi-select).
- **`DrillTranslator`:** `.overlap` (temporal **and** numeric `RangeKind`) →
  `startRef ≤ hi` + `endRef ≥ lo` two-column filters; heatmap rect-brush compound
  from merged sub-keys; ⌘-click `.anyOf`/`.blank` coalescing.
- **`DrillSqlTranslator`:** `.overlap` → `"start" <= … AND "end" >= …` formatted
  per `RangeKind` (numeric literal vs UTC ISO), escaped; **`.anyOf` with the
  blanks sentinel → `IN (…) OR "col" IS NULL`** (the parity fix).
- **`DrillKey`:** `.overlap.columnRefs` returns both refs; `RangeKind` carried.
- **`ChartConfig` Codable:** `axisBins` round-trip + legacy-blob decode (empty).
- **Manual (GUI + Postgres):** scatter under push-down (sampled, capped,
  **re-run reproduces the same points**); heatmap numeric bins with independent
  X/Y controls; heatmap rectangular brush over a **binned** axis (filters the
  right ranges, not literal labels) and over a null bucket; gantt overlap brush on
  a **numeric** start/end axis and a temporal one (catches bars that started
  *before* the window); stacked-bar + line/area series-precise drill; pie ⌘-click
  multi-select including the null slice; push-down heatmap per-axis top-N and
  `.auto` count.

## Phasing (within phase 4)

- **A — Push-down parity:** `SqlPushdownGenerator` scatter sampling (+ `.scatter`
  layout) + heatmap `dense_rank()` top-N + `.auto` count subquery;
  `ServerChartDataBuilder` scatter path. Pure (TDD) + build + manual.
- **B — Heatmap axes:** `AxisBin` + `axisBins` + `resolvedBin` on `ChartConfig`
  (tolerant decode); client `aggregateHeatmap` numeric binning; push-down heatmap
  per-axis numeric; rail per-axis bin controls. Pure (TDD) + UI.
- **C — Interaction:** `DrillKey.overlap(…, RangeKind)` + both translators (+ the
  `DrillSqlTranslator.anyOf` sentinel→`IS NULL` parity fix); a pure
  `mergeDrillKeys`; gantt overlap time-brush (temporal + numeric axes); heatmap
  rectangular brush (merged cell sub-keys); stacked + line/area series-precise
  drill; pie ⌘-click multi-select. Pure (translators/DrillKey/merge, TDD) +
  gesture/VC (build-gated + manual).

## Risks / Open Questions

- **Deterministic sample cost/shape** — `ORDER BY hashtext((_pharos_src.*)::text)`
  is a full scan+sort (like `random()`) but reproducible; verify the `.*::text`
  cast works over the subquery alias (fall back to hashing projected `_x||_y` if
  not). A cheaper approximate sample (`WHERE hashtext(...) % k = 0`) is a future
  option if the sort bites; keep the "sampled" label either way.
- **Null-inclusive selections** — merged heatmap/pie selections that include the
  null bucket must round-trip: grid via `blanksSentinel` in `.isAnyOf` (existing),
  SQL via the new `.anyOf` sentinel→`IS NULL` split. Cover both in the translator
  tests.
- **Stacked series y-band resolution** — the fiddliest gesture; grouped-bar
  fallback to category-only is the safety valve. Expect iteration (like prior
  gesture work).
- **`dense_rank()` heatmap SQL** — verify the two-window + join shape parses/runs
  and that ties don't overshoot N materially.
- **Two range CTEs** (both heatmap axes numeric) — confirm the combined
  CTE + width_bucket SQL is valid and the builder reads both axes' `lo/hi/N`.
- **`axisBins` rail UX** — two bin controls on the heatmap rail must stay legible;
  keep them compact and clearly X/Y-labelled.
