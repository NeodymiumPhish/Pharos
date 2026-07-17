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
| Drill mapping | Aggregator attaches a `DrillKey` to each mark; a pure `DrillTranslator` converts to `ColumnFilter`. |
| Heatmap value | Optional — unmapped ⇒ cell = row count (frequency cross-tab); mapped ⇒ aggregate. |
| Heatmap color | Sequential single-hue gradient + built-in legend; empty cells left blank. |
| Cardinality | Heatmap: top-N per axis (25 × 25). Numeric bins: no top-N (bounded). |
| Numeric bin default | `.auto` when a numeric column lands on a category axis. |
| Persistence | Additive to `chart_view_state_json`; `ChartConfig` gains a tolerant custom decoder. Drill state ephemeral. |

## Architecture

### New / changed components

| Piece | Kind | Responsibility |
|---|---|---|
| `DrillKey` | Model (`Pharos/Models/Charts/DrillKey.swift`) | How to filter source rows for a mark: `.value(column, raw)`, `.anyOf(column, [raw])`, `.range(column, lo, hi, kind)`, `.compound([DrillKey])`. |
| `NumericBin` | enum (`ChartTypes.swift`) | `.off .auto .b10 .b20 .b50` — numeric axis binning, mirroring `TemporalBin`. |
| `HeatmapCell` | Model (`ChartData.swift`) | `{ x: String, y: String, value: Double, drill: DrillKey }`. |
| `ChartData` (extend) | Model | Add `heatmapCells: [HeatmapCell]`; add `drill: DrillKey?` to `ChartPoint`. |
| `ChartConfig` (extend) | Model | Add `numericBin: NumericBin`; add a tolerant `init(from:)` (decodeIfPresent + defaults). |
| `ChartType.heatmap` | enum case | Implement the reserved case. |
| `ColumnKind`-aware eligibility | logic (`ChartViewModel`) | For heatmap, X/Y accept any kind; scatter keeps numeric-only. |
| `ChartAggregator` (extend) | Pure logic | Numeric binning; heatmap cell aggregation; emit `DrillKey`s on points/cells. |
| `DrillTranslator` | Pure logic (`Pharos/Models/Charts/DrillTranslator.swift`) | `[DrillKey] → [ColumnFilter]`, coalescing same-column `.value`s into `.isAnyOf`. |
| `ChartView` / `ChartRootView` (extend) | SwiftUI | Heatmap `RectangleMark` + color scale/legend; numeric-bin rail control; `chartOverlay` tap/drag → resolve marks → `onDrill([DrillKey])`. |
| `ChartHostingController` (extend) | AppKit | Forward `onDrill` to the content VC. |
| `ContentViewController` (extend) | AppKit | Apply drill filters via `ResultsColumnFilterController`, switch to Grid, show/clear the drill chip. |

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
  (bins are bounded/ordered). Each bin carries `DrillKey.range(column, lo, hi,
  .numeric)`.
- Edge cases: `min == max` ⇒ single bin; all values unparseable/null ⇒ `.allNull`.
- Default: `.auto` when a numeric column is mapped to a category axis.

## Heatmap

- Roles: **X** (`.x`), **Y** (`.y`), optional **Value** (`.value`). Eligibility
  is chart-type-aware: for heatmap, X/Y accept categorical/temporal/numeric.
- Cell value: aggregate over rows where `X==xᵢ AND Y==yⱼ`. Unmapped Value ⇒
  count (frequency cross-tab); mapped Value ⇒ the Aggregate control applies.
- Axis binning: temporal axes use the Time Bucket control; numeric axes use the
  Bins control. A single bin setting applies to whichever axis is binnable (both
  binnable axes share it — documented limitation).
- Cardinality: top-N per axis (default 25 × 25 ⇒ ≤ 625 cells); dropped rows/cols
  are not drawn (no "Other" cell); truncation flagged.
- Color: sequential gradient scaled min→max via
  `RectangleMark(x:,y:).foregroundStyle(by: .value(...))` +
  `chartForegroundStyleScale`, with the built-in legend. Empty cells blank.
- Drill: cell click ⇒ `DrillKey.compound([xKey, yKey])`.

## Drill-down

### DrillKey → filter

`DrillTranslator` (pure) maps each `DrillKey` to a `ColumnFilter`
(`Pharos/Utilities/ColumnFilter.swift`):

- `.value(col, raw)` → `ColumnFilter(columnName: col, op: .equals, value: raw)`
- `.anyOf(col, vals)` → `op: .isAnyOf, values: vals`
- `.range(col, lo, hi, kind)` → `op: .between, value: fmt(lo), value2: fmt(hi)`
  (numeric: plain numbers; temporal: the string format the grid's
  `evaluateTemporal` expects — verify during implementation)
- `.compound([keys])` → the translated filters of each child (one per column)

Same-column `.value`s from a brush are coalesced into one `.isAnyOf`.

### Plumbing

The chart overlays `chartOverlay { proxy in … }` with a unified tap/drag
gesture. On tap it hit-tests via the `ChartProxy` to the nearest mark and reads
that mark's `DrillKey` from `ChartData`; on drag it collects the marks within the
dragged span and emits their keys. Results flow up via `onDrill([DrillKey])` →
`ChartViewModel` → `ChartHostingController` → `ContentViewController`. One
proxy+gesture path is used (not the per-axis `chartXSelection`/
`chartAngleSelection` APIs) because it handles click + brush + heatmap uniformly.
This is the highest-iteration-risk piece; expect visual tuning.

### Per-chart behavior

| Type | Click | Brush |
|---|---|---|
| bar / line / area | filter to that category/bin | span of categories/bins → `.anyOf` / merged range |
| pie | filter to that slice's category | — |
| scatter | highlight nearest point + show (x,y) in Inspector (no filter) | rectangular region → x-range (+ y-range) filter |
| heatmap | compound filter (both axes) | — |
| gantt | filter to that row's label | — (time-range brush deferred) |

### Grid + chip

On drill, the VC calls `columnFilterController.setFilter(...)` for each produced
filter, refreshes through the existing `applyFilters` / `columnFilterControllerDidUpdate`
path, switches to Grid, and shows a **"Filtered by … ✕"** chip in the action bar.
The chip tracks the columns the drill set, so clearing removes only the drill
filters (manual grid filters are left intact; drill filters AND with them). Drill
state is ephemeral.

## Persistence

- `ChartType` adds `.heatmap` (new string value; old blobs unaffected).
- `ChartConfig` adds `numericBin`. Because synthesized `Decodable` rejects missing
  keys, `ChartConfig` gets a custom `init(from:)` using `decodeIfPresent` with
  defaults for every field, so **phase-1 blobs without `numericBin` still decode**
  (→ `.auto`) and future additions stay tolerant.
- No Rust/SQLite changes; heatmap config + `numericBin` ride
  `chart_view_state_json`.

## Testing

Per the repo's standalone-`swiftc` harnesses (no Xcode test target):

- **`ChartAggregator` numeric binning:** auto/fixed counts, range labels, count→histogram, aggregate-per-bin, `min==max`, `.off` → discrete+top-N, `DrillKey.range` per bin.
- **`ChartAggregator` heatmap:** count (no value) vs aggregate (with value), two-axis grouping, per-axis top-N, binned axes, compound `DrillKey`.
- **`DrillTranslator`:** every `DrillKey` case → correct `ColumnFilter`; same-column `.value` coalescing; temporal/numeric range formatting.
- **`ChartConfig` Codable:** round-trip with new fields **and** decode of a phase-1-style JSON lacking `numericBin`/heatmap → defaults applied (the compat guard).
- **Rust:** none required (no new FFI/SQLite); optionally re-run the existing chart-state round-trip.
- **Manual (GUI + live Postgres):** heatmap render + legend; numeric histogram; click→filter→Grid+chip+clear; brush; scatter highlight; drill coexists with manual filters; reopen a phase-1 workspace and confirm its saved chart config still restores.

## Phasing (within phase 2)

- **A — Numeric binning:** aggregator + `NumericBin` + rail Bins control + tolerant `ChartConfig` decoder. Self-contained, TDD.
- **B — Heatmap:** `ChartType.heatmap`, heatmap cell aggregation, chart-type-aware eligibility, `RectangleMark` + color scale/legend, rail roles. Uses A for binned axes.
- **C — Drill-down:** `DrillKey` on marks, `DrillTranslator`, chart overlay gesture/proxy, VC filter application + chip. Uses the marks from A/B.

## Risks / Open Questions

- **Drill interaction plumbing** (proxy + gesture hit-testing across chart types)
  is the highest-risk area — likely to need visual iteration; keep the pure
  translator/aggregator separate so only the thin gesture layer churns.
- **Temporal range filter formatting** must match the grid's `evaluateTemporal`
  parser — verify the exact string format during implementation.
- **Heatmap selection** via proxy (two axes) — confirm `ChartProxy.value(atX:)`
  + `value(atY:)` resolve category cells reliably on macOS 15.
- **Backward-compat decode** — the tolerant `ChartConfig` decoder must be covered
  by a test using a real phase-1 JSON string.
