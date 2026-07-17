# Query Result Charts — Phase 2 Design Spec

**Date:** 2026-07-17
**Status:** Approved for planning
**Builds on:** `docs/superpowers/specs/2026-07-17-query-result-charts-design.md` (phase 1, shipped)

## Summary

Extend the charting feature with the three phase-2 capabilities: a **heatmap**
chart type, **numeric/histogram binning** for numeric axes, and **chart
drill-down** — clicking (or brushing) a mark filters the result grid to the
underlying rows. All three build on the phase-1 architecture (pure aggregator →
renderer-agnostic `ChartData` → SwiftUI renderer hosted in AppKit) with no new
Rust/SQLite surface.

## Goals

- Add heatmap (two-axis, color-encoded matrix / frequency cross-tab).
- Add numeric binning so continuous columns produce readable histograms/binned
  aggregates, mirroring the shipped temporal binning.
- Make charts an active analysis surface: click a mark → filter the grid to those
  rows; brush a range → filter to that span.
- Keep new logic pure and unit-testable; keep interaction plumbing thin.

## Non-Goals (Phase 2)

- Per-axis independent bin granularity on heatmaps (both binnable axes share one
  bin setting).
- **Numeric binning of heatmap axes** (deferred): heatmap X/Y support temporal
  (Time Bucket) binning, but a numeric heatmap axis is treated as discrete
  values with per-axis top-N capping rather than range bins. Uncommon case;
  top-N keeps cell counts bounded. (Categorical/temporal heatmaps are fully
  supported.)
- Brushing on pie / heatmap / gantt (click only for those in v2).
- Spawning follow-up SQL queries from a drill (we filter the loaded rows, not the
  database).
- Persisting drill/selection state.
- Image/SQL export (phase 3).

## Decisions (from brainstorming)

| Decision | Choice |
|---|---|
| Scope | All three: heatmap + numeric binning + drill-down. |
| Drill action | Click a mark → filter the grid to those rows. |
| Post-click view | Switch to Grid, show filtered rows + a clearable "Filtered by … ✕" chip. |
| Brushing | Yes — drag to select a span (bar/line/area categories, scatter x/y region). |
| Drill mapping | Aggregator attaches a `DrillKey` (carrying a `ColumnRef`) to each mark; a pure `DrillTranslator` converts to `(columnId: "col_N", ColumnFilter)` pairs, given the result's `[ColumnDef]`. |
| Drill operator | Category drills use **`.isAnyOf`** (exact, case-sensitive match on `displayString`, null-aware), never `.equals`. |
| Same-column collision | Drill **snapshots** any manual filter it displaces on a column and **restores** it when the chip is cleared. |
| Scatter click | Chart-local callout overlay at the point (no Inspector coupling); brush filters. |
| Pie click | `chartAngleSelection(value:)` (not raw proxy geometry). |
| Heatmap value | Optional — unmapped ⇒ cell = row count (frequency cross-tab); mapped ⇒ aggregate. |
| Heatmap color | Sequential single-hue gradient + built-in legend; empty cells left blank. |
| Cardinality | Heatmap: top-N per axis (25 × 25). Numeric bins: no top-N (bounded). |
| Numeric bin default | `.auto` when a numeric column lands on a category axis **and** its distinct-value count exceeds 12; otherwise treated as discrete. |
| Persistence | Additive to `chart_view_state_json`; `ChartConfig` gains a tolerant custom decoder. Drill state ephemeral. |

## Architecture

### New / changed components

| Piece | Kind | Responsibility |
|---|---|---|
| `DrillKey` | Model (`Pharos/Models/Charts/DrillKey.swift`) | How to filter source rows for a mark, carrying a `ColumnRef` (index + name): `.anyOf(ref, [String])`, `.range(ref, lo, hi, kind)`, `.compound([DrillKey])`. (No `.value` case — single-category selection is `.anyOf` with one element; nulls use `ColumnFilter.blanksSentinel` as the string.) |
| `NumericBin` | enum (`ChartTypes.swift`) | `.off .auto .b10 .b20 .b50` — numeric axis binning, mirroring `TemporalBin` (naming differs from `TemporalBin.none` deliberately — see Persistence). |
| `HeatmapCell` | Model (`ChartData.swift`) | `{ x: String, y: String, value: Double, drill: DrillKey }`. |
| `ChartData` (extend) | Model | Add `heatmapCells: [HeatmapCell]`; add `drill: DrillKey?` to `ChartPoint`. |
| `ChartConfig` (extend) | Model | Add `numericBin: NumericBin`; add a tolerant `init(from:)` (decodeIfPresent + defaults). |
| `ChartType.heatmap` | enum case | Implement the reserved case. |
| `ColumnKind`-aware eligibility | logic (`ChartViewModel`) | For heatmap, X/Y accept any kind; scatter keeps numeric-only. |
| `ChartAggregator` (extend) | Pure logic | Numeric binning; heatmap cell aggregation; relaxed count guard; emit `DrillKey`s on points/cells (incl. the "Other" and null marks); week-label fix. |
| `DrillTranslator` | Pure logic (`Pharos/Models/Charts/DrillTranslator.swift`) | `([DrillKey], [ColumnDef]) → [(columnId: String, ColumnFilter)]` where `columnId = "col_\(ref.index)"` and `ColumnFilter.dataType` comes from the `ColumnDef`. Coalesces same-column `.anyOf`s into one. |
| `ChartView` / `ChartRootView` (extend) | SwiftUI | Heatmap `RectangleMark` + color scale/legend; numeric-bin rail control; unified `chartOverlay` tap/drag → `onDrill([DrillKey])` for bar/line/area/scatter/heatmap/gantt; `chartAngleSelection(value:)` for pie; a chart-local callout overlay for scatter clicks. |
| `ChartHostingController` (extend) | AppKit | Forward `onDrill` to the content VC. |
| `ContentViewController` (extend) | AppKit | Translate drill keys via `DrillTranslator`, apply filters keyed by `col_N` via `ResultsColumnFilterController` (snapshotting displaced manual filters), switch to Grid, show/clear the drill chip (restoring snapshots). |

### Boundaries

`ChartAggregator`, `DrillTranslator`, and the binning logic are pure and unit
tested. The SwiftUI layer only *identifies* which marks a gesture hit and reads
their pre-computed `DrillKey`s — it does not build filters or navigate. The
`ContentViewController` owns filter application, grid navigation, and the chip.

## Numeric / Histogram Binning

- `NumericBin` (String-raw, Codable): `.off` (discrete categories, top-N applies),
  `.auto` (count ≈ `min(50, ceil(√n))`, capped), `.b10 / .b20 / .b50` (fixed
  equal-width counts).
- In `ChartAggregator`, when a category/heatmap-axis column is numeric and
  `numericBin != .off`: compute `[min,max]`, `width = range/binCount`, assign each
  coerced value to a bin. Bin label = compact range (`"0–10"`). **Count**
  aggregation ⇒ histogram; other aggregations ⇒ binned aggregate. Skip top-N
  (bins are bounded/ordered). Each bin carries `DrillKey.range(ref, lo, hi,
  .numeric)`.
- **Relax the count guard (fix):** `aggregateCategorical` currently requires
  *both* `.category` and `.value` mappings even for `.count`. Phase 2A relaxes
  this so **`.count` needs only a `.category` mapping** — otherwise the marquee
  histogram gesture ("bin this numeric column and count rows") would force the
  user to map a meaningless Value column. Non-count aggregations still require
  `.value`.
- **Low-cardinality escape:** `.auto` engages only when the numeric column's
  distinct-value count exceeds **12**; at or below that, values are treated as
  discrete categories (so `status IN (1..5)` renders as `1,2,3,4,5`, not
  fractional-width ranges).
- Edge cases: `min == max` ⇒ single bin; all values unparseable/null ⇒ `.allNull`.
- Default: `.auto` (subject to the low-cardinality escape) when a numeric column
  is mapped to a category axis.

### Prerequisite fix (phase-1 code, folded into 2A)

`binLabel` builds week labels with `.year` + `.weekOfYear`, so dates near a
year boundary land in mislabeled, wrongly-merged buckets (e.g. `2026-12-29 →
"2026-W01"`). Change the year component to **`.yearForWeekOfYear`** for the
`.week` case. Phase-2 range drills inherit temporal bins, so correct bucketing is
a prerequisite. Add a boundary-week test.

## Heatmap

- Roles: **X** (`.x`), **Y** (`.y`), optional **Value** (`.value`). Eligibility
  is chart-type-aware: for heatmap, X/Y accept categorical/temporal/numeric.
- Cell value: aggregate over rows where `X==xᵢ AND Y==yⱼ`. Unmapped Value ⇒
  count (frequency cross-tab); mapped Value ⇒ the Aggregate control applies.
- Axis binning: temporal axes use the Time Bucket control; numeric axes use the
  Bins control. A single bin setting applies to whichever axis is binnable (both
  binnable axes share it — documented limitation).
- Cardinality: top-N per axis (default 25 × 25 ⇒ ≤ 625 cells); dropped rows/cols
  are simply **not drawn** (no "Other" cell — that keeps the color scale honest;
  consistent with there being no drillable "Other" on either axis); truncation
  flagged.
- Color: sequential gradient scaled min→max via
  `RectangleMark(x:,y:).foregroundStyle(by: .value(...))` +
  `chartForegroundStyleScale`, with the built-in legend. Empty cells blank.
- Drill: cell click ⇒ `DrillKey.compound([.anyOf(xRef,[x]), .anyOf(yRef,[y])])`
  (null axis value ⇒ `blanksSentinel`).

## Drill-down

### DrillKey → filter

**Critical:** the grid's `activeFilters` is keyed by the table-column identifier
`"col_N"` (resolved via `colIndex(from:)`), **not** the column name — a
name-keyed filter is silently skipped (`continue`), so the drill would appear to
work (chip shows, count increments) but filter nothing. `DrillKey` therefore
carries a `ColumnRef` (index + name), and `DrillTranslator` is:

```
DrillTranslator.filters(for keys: [DrillKey], columns: [ColumnDef])
    -> [(columnId: String, filter: ColumnFilter)]
```

where `columnId = "col_\(ref.index)"` and `ColumnFilter.dataType` is taken from
`columns[ref.index].dataType` (required — the interval branch of
`evaluateTemporal` reads it). Mapping:

- `.anyOf(ref, vals)` → `ColumnFilter(op: .isAnyOf, values: vals, …)`. Category
  drills always use `.isAnyOf`, because text `.equals` is **case-insensitive**
  (so "Foo" and "foo" — distinct marks — would both match) whereas `.isAnyOf`
  matches `displayString` **exactly** and understands `blanksSentinel` for
  null/empty cells. A single-category click is `.anyOf(ref, [label])`; the null
  mark is `.anyOf(ref, [ColumnFilter.blanksSentinel])`.
- `.range(ref, lo, hi, kind)` → `op: .between, value: fmt(lo), value2: fmt(hi)`.
  Numeric: plain number strings. **Temporal: bounds are computed from the actual
  `Date` at aggregation time (never re-parsed from the lossy bin label), and `hi`
  is formatted as the bucket's *last-instant* string** (e.g.
  `"2026-07-31 23:59:59.999999999"`) so the inclusive lexicographic `.between`
  includes `+00`-suffixed cell strings; `lo` is the bucket's first-instant.
- `.compound([keys])` → the translated pairs of each child (one per column).

Same-column `.anyOf`s from a brush are coalesced into one `.isAnyOf`.

The **"Other"** bar is drillable: the aggregator knows the dropped category
labels at fold time and attaches `.anyOf(ref, droppedLabels)` to it (an in-memory
set; accepted even when large). Clicking "Other" thus filters to exactly the
rolled-up rows — not to rows containing the literal text "Other".

### Plumbing

For bar/line/area/scatter/heatmap/gantt the chart overlays
`chartOverlay { proxy in … }` with a unified tap/drag gesture: on tap it
hit-tests via the `ChartProxy` to the nearest mark and reads that mark's
pre-computed `DrillKey` from `ChartData`; on drag it collects the marks within
the dragged span and emits their keys. **Pie uses `chartAngleSelection(value:)`**
instead — raw-proxy angle-from-center geometry for `SectorMark` is the most
error-prone math for the least payoff, and the native API exists for exactly
this. Results flow up via `onDrill([DrillKey])` → `ChartViewModel` →
`ChartHostingController` → `ContentViewController`. This gesture layer is the
highest-iteration-risk piece; the pure translator/aggregator stay separate so
only the thin gesture layer churns.

### Per-chart behavior

| Type | Click | Brush |
|---|---|---|
| bar / line / area | filter to that category/bin (+ series, see below) | span of categories/bins → coalesced `.anyOf` / merged range |
| pie | filter to that slice's category (`chartAngleSelection`) | — |
| scatter | chart-local callout showing (x,y) at the point (no filter) | rectangular region → x-range (+ y-range) filter |
| heatmap | compound filter (both axes) | — |
| gantt | filter to that row's label | — (time-range brush deferred) |

**Multi-series:** the aggregator attaches a `.compound([categoryKey, seriesKey])`
to each point (nearly free — it knows the series ref + name). However, resolving
*which series segment* a gesture hit from its y-position is fiddly, so **v2 drills
by category only** (all series for the clicked category); the compound key is
carried for a later series-precise pass. Stated choice, not a silent omission.

### Grid + chip

On drill, the VC runs `DrillTranslator`, then for each `(columnId, filter)`:
**snapshots** any existing filter on that column (there is exactly one filter per
column — `setFilter` *replaces*), calls `columnFilterController.setFilter(filter,
forColumn: columnId)`, and refreshes through the existing `applyFilters` /
`columnFilterControllerDidUpdate` path. It then switches to Grid and shows a
**"Filtered by … ✕"** chip. Clearing the chip **restores the snapshotted manual
filters** (and removes drill-only columns), so a drill onto a column the user had
manually filtered doesn't destroy their filter. Drill filters otherwise AND with
manual filters. Drill state is ephemeral (not persisted).

## Persistence

- `ChartType` adds `.heatmap` (new string value; old blobs unaffected).
- `ChartConfig` adds `numericBin`. Because synthesized `Decodable` rejects missing
  keys, `ChartConfig` gets a custom `init(from:)` using `decodeIfPresent` with
  defaults for every field, so **phase-1 blobs without `numericBin` still decode**
  (→ `.auto`) and future additions stay tolerant.
- No Rust/SQLite changes; heatmap config + `numericBin` ride
  `chart_view_state_json`.
- **Naming:** `NumericBin` uses `.off` while `TemporalBin` uses `.none`. This
  divergence is deliberate — `TemporalBin.none` is already persisted as the
  string `"none"` in phase-1 blobs, so renaming it would break decode; `.off` is
  the better token for the new enum (avoids `Optional.none` ambiguity in
  switches). The inconsistency is documented rather than "fixed" at compat cost.

## Testing

Per the repo's standalone-`swiftc` harnesses (no Xcode test target):

- **`ChartAggregator` numeric binning:** auto/fixed counts, range labels, count→histogram, aggregate-per-bin, `min==max`, `.off` → discrete+top-N, low-cardinality escape (≤12 distinct → discrete even on `.auto`), **`.count` with only a category mapping (no Value)**, `DrillKey.range` per bin.
- **`ChartAggregator` heatmap:** count (no value) vs aggregate (with value), two-axis grouping, per-axis top-N, binned axes, compound `DrillKey`.
- **`ChartAggregator` drill keys:** the "Other" bar carries `.anyOf(ref, droppedLabels)`; the null-category mark carries `.anyOf(ref, [blanksSentinel])`; week bins label boundary dates correctly (`.yearForWeekOfYear`).
- **`DrillTranslator`:** every `DrillKey` case → correct `(columnId: "col_N", ColumnFilter)` incl. `dataType` populated; same-column `.anyOf` coalescing; numeric range → `.between`; temporal range → inclusive last-instant `hi` that dominates `+00`-suffixed cell strings.
- **End-to-end translator → controller:** apply a translated filter to `ResultsColumnFilterController` and assert it actually filters rows (would catch the `col_N` keying bug); case-sensitive category match ("Foo" vs "foo"); null-bucket and "Other"-bucket drills; temporal `.between` boundary instants.
- **`ChartConfig` Codable:** round-trip with new fields **and** decode of a phase-1-style JSON lacking `numericBin`/heatmap → defaults applied (the compat guard).
- **Rust:** none required (no new FFI/SQLite); optionally re-run the existing chart-state round-trip.
- **Manual (GUI + live Postgres):** heatmap render + legend; numeric histogram (count, no Value); click→filter→Grid+chip+clear; brush; scatter callout; **drill onto a manually-filtered column then clear restores the manual filter**; reopen a phase-1 workspace and confirm its saved chart config still restores.

## Phasing (within phase 2)

- **A — Numeric binning:** aggregator numeric binning + `NumericBin` + low-cardinality escape + rail Bins control + tolerant `ChartConfig` decoder + relaxed count guard + the `.yearForWeekOfYear` week-label fix. Self-contained, TDD.
- **B — Heatmap:** `ChartType.heatmap`, heatmap cell aggregation, chart-type-aware eligibility, `RectangleMark` + color scale/legend, rail roles. Uses A for binned axes.
- **C — Drill-down:** `DrillKey` (with `ColumnRef`) on marks incl. "Other"/null, `DrillTranslator` (`col_N` + `dataType`), chart overlay gesture/proxy + `chartAngleSelection` for pie, scatter callout, VC filter application with snapshot/restore + chip. Uses the marks from A/B.

## Risks / Open Questions

- **Drill interaction plumbing** (proxy + gesture hit-testing across chart types)
  is the highest-risk area — likely to need visual iteration; keep the pure
  translator/aggregator separate so only the thin gesture layer churns.
- **Temporal range filter formatting** — the last-instant `hi` rule
  (`"…23:59:59.999999999"`) is derived from `evaluateTemporal`'s inclusive
  lexicographic compare; confirm against real `timestamptz`/`date`/`timestamp`
  cell strings (incl. `+00` suffixes and bare dates) during 2C.
- **Heatmap selection** via proxy (two axes) — confirm `ChartProxy.value(atX:)`
  + `value(atY:)` resolve category cells reliably on macOS 15.
- **Backward-compat decode** — the tolerant `ChartConfig` decoder must be covered
  by a test using a real phase-1 JSON string.
- **"Other" drill list size** — attaching all dropped labels is an in-memory set;
  accepted even for high-cardinality columns. Revisit only if it proves heavy.
