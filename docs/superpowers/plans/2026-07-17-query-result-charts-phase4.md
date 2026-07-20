# Query Result Charts (Phase 4) Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Close the deferred edges from phases 1–3 — (A) push-down parity (scatter via deterministic sampling, heatmap per-axis `dense_rank()` top-N, row-count `.auto` bucketing), (B) heatmap numeric-axis binning with independent per-axis granularity (`axisBins`), and (C) richer interaction (gantt overlap time-brush, heatmap rectangular brush, stacked/line/area series-precise drill, pie ⌘-click multi-select).

**Architecture:** Same pure/UI split as phases 1–3. SQL generation (`SqlPushdownGenerator`), result mapping (`ServerChartDataBuilder`), drill predicates (`DrillTranslator`/`DrillSqlTranslator`), a new pure key-merge (`DrillMerge`), and the client aggregator (`ChartAggregator`) are Foundation-only and unit-tested via standalone `swiftc` harnesses. Gesture/async work stays thin in `ChartView`/`ChartRootView`/`ContentViewController` (build-gated + manually verified). The only new persisted state is `axisBins` (additive, tolerant decoder). **No Rust/SQLite/FFI changes.**

**Tech Stack:** Swift 5.10 / AppKit + SwiftUI (Swift Charts), macOS 15; pure-logic tests via standalone `swiftc` harnesses.

**Reference spec:** `docs/superpowers/specs/2026-07-17-query-result-charts-phase4-design.md`

---

## Key conventions (read before starting)

- **No Xcode test target.** Pure logic is tested by `swiftc` scripts (impl files + one `PharosTests/XxxTests.swift` + `PharosTests/main.swift`). Each test file defines its own `runTests()`/`failures`/`expect`; `main.swift` just calls `runTests()`.
- **Chart model/logic files import only `Foundation`.** `SqlPushdownGenerator`, `ServerChartDataBuilder`, `DrillSqlTranslator`, `ChartAggregator`, `ChartConfig` are Foundation-only. `DrillTranslator` additionally touches `ColumnFilter`.
- **`ResultTab.sql` is the substituted SQL** (post `{{var}}`, verified) — push-down wraps it directly.
- **All result cell values cross the FFI as text strings** — `ValueCoercion` parses them; never assume numeric/date types on `AnyCodable`.
- **`[ChartColumnRole: X]` dictionaries encode as a flat alternating array** (String-raw enum key), not a JSON object — this is why `ChartConfigTests` writes `"mappings":[]`. `axisBins` rides the same way.
- **Grid filters are keyed by `col_<index>`** (`DrillTranslator` emits `col_<idx>`); a name-keyed filter silently no-ops.
- **`project.pbxproj` is tracked** — stage it when `xcodegen` adds files. Build: `xcodegen generate && xcodebuild -project Pharos.xcodeproj -scheme Pharos -configuration Debug build 2>&1 | tail -20`.
- **Re-run all chart harnesses after changes** (see Task V1).
- **`FilterOperator` already has `.lessOrEqual`/`.greaterOrEqual`/`.between`/`.isAnyOf`** and `ColumnFilter.blanksSentinel = "\u{0}__pharos_blanks__"`.

---

## File Structure

**New (Foundation-only):**
- `Pharos/Utilities/BlanksSentinel.swift` — the canonical blanks-sentinel constant, shared by `ColumnFilter`, `DrillMerge`, and `DrillSqlTranslator` (single source of truth so grid↔SQL null handling can't drift).
- `Pharos/Models/Charts/DrillMerge.swift` — pure `DrillMerge.merge([DrillKey]) -> [DrillKey]` (heatmap rect-brush + pie multi-select).

**Modified models/logic:**
- `Pharos/Models/Charts/ChartTypes.swift` (+`AxisBin`, `LastServerRun.sampled`).
- `Pharos/Models/Charts/ChartConfig.swift` (+`axisBins`, `resolvedBin(for:)`).
- `Pharos/Models/Charts/PushdownQuery.swift` (+`.scatter` kind, `sampleCap`, per-axis numeric metadata for heatmap).
- `Pharos/Models/Charts/SqlPushdownGenerator.swift` (scatter sampling; heatmap `dense_rank()` top-N; `.auto` count subquery; heatmap numeric width_bucket; `axisExpr` reads a resolved `AxisBin`).
- `Pharos/Models/Charts/ServerChartDataBuilder.swift` (scatter path; heatmap numeric bucket labels/bounds).
- `Pharos/Models/Charts/ChartAggregator.swift` (heatmap per-axis numeric binning; multi-series compound drill).
- `Pharos/Models/Charts/DrillKey.swift` (+`.overlap` case + `columnRefs`).
- `Pharos/Models/Charts/DrillTranslator.swift` (+`.overlap` → two filters).
- `Pharos/Models/Charts/DrillSqlTranslator.swift` (+`.overlap`; `.anyOf` sentinel→`IS NULL` split; uses `PharosBlanks.sentinel`).
- `Pharos/Utilities/ColumnFilter.swift` (`blanksSentinel = PharosBlanks.sentinel`).

**Modified UI (build-gated + manual):**
- `Pharos/ViewControllers/Charts/ChartView.swift` (gantt overlap brush; heatmap rect brush; series-precise category tap; pie ⌘-click multi-select).
- `Pharos/ViewControllers/Charts/ChartRootView.swift` (per-axis heatmap bin controls; `chartTypeSupportsServer`; "sampled" banner note).
- `Pharos/ViewControllers/ContentViewController.swift` (scatter under server mode: `chartTypeSupportsServer` gating; scatter-aware `limit`; `applyServerDrill` wraps each predicate in parens; `pushdownUnavailableReason` drops scatter).

**Tests + scripts:** extend `PharosTests/{ChartConfigTests,SqlPushdownGeneratorTests,ServerChartDataBuilderTests,ChartAggregatorTests,DrillKeyTests,DrillTranslatorTests,DrillSqlTranslatorTests}.swift`; new `PharosTests/DrillMergeTests.swift` + `scripts/test-drill-merge.sh`; update `scripts/test-drill-sql.sh` (add `BlanksSentinel.swift`) and any script that compiles `ColumnFilter.swift` or `DrillKey.swift` to add `BlanksSentinel.swift` where referenced.

---

# Phase A — Push-down parity

> **Generator compile-order (important):** the tasks are grouped A→B→C to match the spec, but `axisExpr`'s signature changes in Task A5 (`(config, col, bin:) -> (String, Bool)`) and `config.resolvedBin` is introduced in Task B1. To keep every commit compiling, execute in this order: **A1 → B1 → A2 → A3 → A5 → A4 → B2 → B3 → B4 → C…**. In particular, **do B1 and A5 before A4** — A4's heatmap rewrite calls the post-A5 `axisExpr` signature. Each task below is written in its *final* form assuming this order.

## Task A1: PushdownQuery — scatter layout + per-axis numeric metadata

**Files:** Modify `Pharos/Models/Charts/PushdownQuery.swift`.

No test of its own (a plain data struct); exercised by A2/A4/B3 generator tests and A3/B4 builder tests.

- [ ] **Step 1: Extend the layout type**

Replace the body of `PushdownQuery.swift` with:
```swift
import Foundation

/// Per-axis numeric-bin metadata carried when a heatmap axis is width-bucketed,
/// so `ServerChartDataBuilder` can turn returned bucket ints into range labels +
/// `.range` drill sub-keys. The bounds/count come back as result columns
/// (`_xlo/_xhi/_xn`, `_ylo/_yhi/_yn`); this flag just says "this axis is binned".
struct PushdownLayout {
    enum Kind { case categorical, heatmap, scatter }
    var kind: Kind
    var hasSeries: Bool
    /// Set when the categorical category axis is width_bucketed (the count is
    /// nominal; the actual server-chosen count rides the `_n` result column).
    var numericBins: Int?
    /// Cap requested for a sampled scatter query (nil for non-scatter). The
    /// builder flags `wasSampled` when the row count reaches it or `hasMore`.
    var sampleCap: Int? = nil
    /// Heatmap: whether the X / Y axis is numeric-binned (width_bucketed).
    var xNumericBinned: Bool = false
    var yNumericBinned: Bool = false
}
struct PushdownQuery { var sql: String; var layout: PushdownLayout }
```

- [ ] **Step 2: Commit**
```bash
git add Pharos/Models/Charts/PushdownQuery.swift
git commit -m "feat(charts): PushdownLayout gains scatter kind + per-axis numeric metadata"
```

---

## Task A2: SqlPushdownGenerator — deterministic scatter sample

**Files:** Modify `Pharos/Models/Charts/SqlPushdownGenerator.swift`; extend `PharosTests/SqlPushdownGeneratorTests.swift`.

- [ ] **Step 1: Failing tests** — append to `runTests()` in `SqlPushdownGeneratorTests.swift` (replace the old `"scatter → nil"` assertion):
```swift
    // Scatter is now available under push-down: a deterministic, non-aggregating
    // sampled query (not random(), not TABLESAMPLE).
    let sc = SqlPushdownGenerator.generate(cfg(.scatter, [.x: 1, .y: 3]), userSQL: src, columns: cols)
    contains(sc?.sql, #""amt" AS _x"#, "scatter selects x as _x")
    contains(sc?.sql, #""age" AS _y"#, "scatter selects y as _y")
    contains(sc?.sql, "IS NOT NULL", "scatter filters null x/y")
    contains(sc?.sql, "hashtext", "scatter orders by a stable hash (deterministic)")
    expect(sc?.sql.contains("random()") == false, "scatter does NOT use random()")
    contains(sc?.sql, "LIMIT", "scatter caps the sample")
    expect(sc?.layout.kind == .scatter, "scatter layout kind")
    expect(sc?.layout.sampleCap == SqlPushdownGenerator.scatterSampleCap, "scatter carries sampleCap")
    // gantt stays unavailable (never aggregates / samples via push-down).
    expect(SqlPushdownGenerator.generate(cfg(.gantt, [.label: 0, .start: 2, .end: 2]), userSQL: src, columns: cols) == nil, "gantt → nil")
    // scatter still needs both x and y.
    expect(SqlPushdownGenerator.generate(cfg(.scatter, [.x: 1]), userSQL: src, columns: cols) == nil, "scatter without y → nil")
    // non-SELECT scatter still nil.
    expect(SqlPushdownGenerator.generate(cfg(.scatter, [.x: 1, .y: 3]), userSQL: "UPDATE t SET x=1", columns: cols) == nil, "scatter non-SELECT → nil")
```

- [ ] **Step 2: Run → FAIL.** `scripts/test-sql-pushdown.sh`

- [ ] **Step 3: Implement** — in `SqlPushdownGenerator.swift`:

Add the cap constant near `groupCap`:
```swift
    static let scatterSampleCap = 5000
```
Change the early type guard + dispatch in `generate(...)`:
```swift
        // Only gantt is unavailable (never aggregates; can't push down). Scatter
        // is available as a deterministic sample (handled below).
        if config.chartType == .gantt { return nil }
        guard isSingleSelect(userSQL) else { return nil }
        if config.chartType == .scatter {
            return scatter(config, userSQL: userSQL, columns: columns)
        }
        let agg = aggExpr(config, columns: columns)
        guard let agg else { return nil }   // non-count needs a value col
        switch config.chartType {
        case .heatmap: return heatmap(config, userSQL: userSQL, columns: columns, agg: agg)
        default:       return categorical(config, userSQL: userSQL, columns: columns, agg: agg)
        }
```
Add the `scatter` builder:
```swift
    private static func scatter(_ config: ChartConfig, userSQL: String, columns: [ColumnDef]) -> PushdownQuery? {
        guard let xCol = resolve(config, .x, columns), let yCol = resolve(config, .y, columns) else { return nil }
        let x = quoteIdent(xCol.name), y = quoteIdent(yCol.name)
        // Deterministic pseudo-random order so a re-run of the recorded SQL
        // reproduces the same sample (audit). ORDER BY random() would not.
        let sql = """
        SELECT \(x) AS _x, \(y) AS _y
        FROM ( \(userSQL) ) AS _pharos_src
        WHERE \(x) IS NOT NULL AND \(y) IS NOT NULL
        ORDER BY hashtext((_pharos_src.*)::text)
        LIMIT \(scatterSampleCap)
        """
        return PushdownQuery(sql: sql,
                             layout: PushdownLayout(kind: .scatter, hasSeries: false,
                                                    numericBins: nil, sampleCap: scatterSampleCap))
    }
```

- [ ] **Step 4: Run → PASS.**

- [ ] **Step 5: Commit**
```bash
git add Pharos/Models/Charts/SqlPushdownGenerator.swift PharosTests/SqlPushdownGeneratorTests.swift
git commit -m "feat(charts): scatter push-down via deterministic hash-sampled query"
```

---

## Task A3: ServerChartDataBuilder — scatter path

**Files:** Modify `Pharos/Models/Charts/ServerChartDataBuilder.swift`; extend `PharosTests/ServerChartDataBuilderTests.swift`.

- [ ] **Step 1: Failing test** — append to `runTests()` in `ServerChartDataBuilderTests.swift`:
```swift
    // Scatter: raw _x/_y points, wasSampled when the row count hits the cap.
    let scLayout = PushdownLayout(kind: .scatter, hasSeries: false, numericBins: nil, sampleCap: 3)
    var scCfg = ChartConfig(chartType: .scatter)
    scCfg.mappings[.x] = ColumnRef(index: 0, name: "amt")
    scCfg.mappings[.y] = ColumnRef(index: 1, name: "age")
    let scRes = QueryResult(
        columns: [ColumnDef(name: "_x", dataType: "numeric"), ColumnDef(name: "_y", dataType: "numeric")],
        rows: [[AnyCodable("1.5"), AnyCodable("10")], [AnyCodable("2.0"), AnyCodable("20")], [AnyCodable("3.0"), AnyCodable("30")]],
        rowCount: 3, executionTimeMs: 1, hasMore: false, historyEntryId: nil)
    let scData = ServerChartDataBuilder.build(scRes, layout: scLayout, config: scCfg)
    expect(scData.series.first?.points.count == 3, "scatter maps 3 points")
    expect(scData.series.first?.points.first?.xValue == 1.5, "scatter reads _x as xValue")
    expect(scData.series.first?.points.first?.y == 10, "scatter reads _y as y")
    expect(scData.wasSampled == true, "row count == sampleCap → wasSampled")
```

- [ ] **Step 2: Run → FAIL.** `scripts/test-server-chart-builder.sh`

- [ ] **Step 3: Implement** — in `ServerChartDataBuilder.swift`:

Add the `.scatter` branch to the `switch layout.kind` in `build(...)`:
```swift
        case .scatter:
            return buildScatter(result, layout: layout)
```
Add:
```swift
    // MARK: - Scatter (`_x, _y` raw points)

    private static func buildScatter(_ result: QueryResult, layout: PushdownLayout) -> ChartData {
        guard let xIdx = colIndex(result, "_x"), let yIdx = colIndex(result, "_y") else {
            return .empty(.noColumns)
        }
        var pts: [ChartPoint] = []
        for row in result.rows {
            guard let xCell = cell(row, xIdx), let yCell = cell(row, yIdx),
                  let x = ValueCoercion.double(from: xCell), let y = ValueCoercion.double(from: yCell) else { continue }
            pts.append(ChartPoint(xLabel: "", xValue: x, y: y))
        }
        if pts.isEmpty { return .empty(.allNull) }
        var out = ChartData()
        out.series = [ChartSeries(name: "", points: pts)]
        out.plottedRowCount = pts.count
        out.totalLoadedRowCount = result.rowCount
        // Sampled when the DB paged more rows off, or the sample filled the cap.
        if let cap = layout.sampleCap { out.wasSampled = result.hasMore || pts.count >= cap }
        return out
    }
```

- [ ] **Step 4: Run → PASS.**

- [ ] **Step 5: Commit**
```bash
git add Pharos/Models/Charts/ServerChartDataBuilder.swift PharosTests/ServerChartDataBuilderTests.swift
git commit -m "feat(charts): ServerChartDataBuilder scatter path (raw points + wasSampled)"
```

---

## Task A4: SqlPushdownGenerator — heatmap per-axis `dense_rank()` top-N

**Files:** Modify `Pharos/Models/Charts/SqlPushdownGenerator.swift`; extend `PharosTests/SqlPushdownGeneratorTests.swift`.

- [ ] **Step 1: Failing tests** — append to `runTests()`:
```swift
    // Heatmap top-N is now per-axis dense_rank windows, not a flat LIMIT.
    let hm2 = SqlPushdownGenerator.generate(cfg(.heatmap, [.x: 0, .y: 2], .count), userSQL: src, columns: cols)
    contains(hm2?.sql, "dense_rank()", "heatmap ranks per axis")
    contains(hm2?.sql, "_xr", "heatmap x-rank CTE")
    contains(hm2?.sql, "_yr", "heatmap y-rank CTE")
    contains(hm2?.sql, "rk <=", "heatmap keeps top-N per axis")
```

- [ ] **Step 2: Run → FAIL.**

- [ ] **Step 3: Implement** — replace `heatmap(...)` in `SqlPushdownGenerator.swift`.

For this task the heatmap axes stay discrete/temporal (numeric binning is added in Task B3, which extends this same method). Emit an `_agg` CTE, then two `dense_rank()` window CTEs, and join keeping `rk <= N`:
```swift
    private static func heatmap(_ config: ChartConfig, userSQL: String, columns: [ColumnDef], agg: String) -> PushdownQuery? {
        guard let xCol = resolve(config, .x, columns), let yCol = resolve(config, .y, columns) else { return nil }
        let (xExpr, _) = axisExpr(config, xCol, bin: config.resolvedBin(for: .x))
        let (yExpr, _) = axisExpr(config, yCol, bin: config.resolvedBin(for: .y))
        let n = config.display.topNCategories
        // Per-axis dense_rank top-N (matches the client's 25×25 marginal ranking):
        // rank X values by their total, Y values by theirs, keep top-N of each,
        // select only cells in (topX)×(topY). Ties may slightly overshoot N.
        let sql = """
        WITH _agg AS (
          SELECT \(xExpr) AS _x, \(yExpr) AS _y, \(agg) AS _val
          FROM ( \(userSQL) ) AS _pharos_src
          GROUP BY 1, 2
        ),
        _xr AS ( SELECT _x, dense_rank() OVER (ORDER BY sum(_val) DESC) AS rk FROM _agg GROUP BY _x ),
        _yr AS ( SELECT _y, dense_rank() OVER (ORDER BY sum(_val) DESC) AS rk FROM _agg GROUP BY _y )
        SELECT a._x, a._y, a._val
        FROM _agg a
          JOIN _xr ON _xr._x IS NOT DISTINCT FROM a._x AND _xr.rk <= \(n)
          JOIN _yr ON _yr._y IS NOT DISTINCT FROM a._y AND _yr.rk <= \(n)
        ORDER BY a._val DESC
        LIMIT \(groupCap)
        """
        return PushdownQuery(sql: sql, layout: PushdownLayout(kind: .heatmap, hasSeries: false, numericBins: nil))
    }
```
Note `IS NOT DISTINCT FROM` (not `=`) in the joins so a NULL axis value still joins to its own rank row.

This task assumes **B1 and A5 have already landed** (per the Phase-A compile-order note), so `config.resolvedBin(for:)` exists and `axisExpr` has its final `(config, col, bin:) -> (String, Bool)` signature. Write `heatmap(...)` exactly as shown above — it destructures `(expr, _)` from `axisExpr` and no longer sets a `numericBins` layout field (that's B3's concern).

- [ ] **Step 4: Run → PASS.**

- [ ] **Step 5: Commit**
```bash
git add Pharos/Models/Charts/SqlPushdownGenerator.swift PharosTests/SqlPushdownGeneratorTests.swift
git commit -m "feat(charts): heatmap push-down per-axis dense_rank() top-N"
```

---

## Task A5: SqlPushdownGenerator — row-count `.auto` bucket count + `_n` projection

**Files:** Modify `Pharos/Models/Charts/SqlPushdownGenerator.swift` and `Pharos/Models/Charts/ServerChartDataBuilder.swift`; extend both test files.

The numeric range CTE must (a) pick `~√n` buckets server-side for `.auto` (matching the client), and (b) return the resolved bucket count as `_n` so the builder computes correct bucket bounds regardless of whether the count was literal or data-driven.

- [ ] **Step 1: Failing generator test** — append to `SqlPushdownGeneratorTests.runTests()`:
```swift
    // .auto numeric bucket count → scalar subquery folded into the range CTE.
    let auto = SqlPushdownGenerator.generate(cfg(.bar, [.category: 3, .value: 1], .sum, nb: .auto), userSQL: src, columns: cols)
    contains(auto?.sql, "CEIL(SQRT(", "auto derives ~sqrt(n) buckets")
    contains(auto?.sql, "AS _n", "range CTE projects the resolved bucket count as _n")
    // fixed counts stay literal (no sqrt).
    let fixed = SqlPushdownGenerator.generate(cfg(.bar, [.category: 3, .value: 1], .sum, nb: .b20), userSQL: src, columns: cols)
    expect(fixed?.sql.contains("SQRT") == false, "fixed bin count is literal")
    contains(fixed?.sql, "AS _n", "fixed range CTE also projects _n")
```

- [ ] **Step 2: Run → FAIL.**

- [ ] **Step 3: Implement** — in `SqlPushdownGenerator.swift`.

Change `binCount` to distinguish `.auto` and return a **SQL count expression** rather than an Int. Add a helper that yields the count expression string, and thread the numeric count into `_r` as `n`:
```swift
    /// The SQL expression for a numeric axis's bucket count: a literal for fixed
    /// bins, or a scalar over the source for `.auto` (~√n, clamped 1…50 — mirrors
    /// the client's `numericBinCount`). Returns nil when binning is off.
    private static func binCountExpr(_ b: NumericBin) -> String? {
        switch b {
        case .off: return nil
        case .b10: return "10"
        case .b20: return "20"
        case .b50: return "50"
        case .auto: return "LEAST(50, GREATEST(1, CEIL(SQRT(COUNT(*)))::int))"
        }
    }
    /// Nominal count for the layout (the builder prefers the returned `_n`); nil
    /// means "not numeric-binned". `.auto` reports 0 as a placeholder.
    private static func binCountNominal(_ b: NumericBin) -> Int? {
        switch b { case .off: return nil; case .b10: return 10; case .b20: return 20; case .b50: return 50; case .auto: return 0 }
    }
```
Rewrite the numeric branch of `categorical(...)` (the `if let n = nbins` block) so `_r` carries `n` and the query projects `_n`. Since `axisExpr` returns the nominal count today, replace its numeric-bin detection to use `binCountExpr`. Concretely, in `categorical`:
```swift
        let bin = config.resolvedBin(for: .category)   // B1; global fallback baked in
        let (catExpr, numericBinned) = axisExpr(config, catCol, bin: bin)
        let series = numericBinned ? nil : resolve(config, .series, columns)
        let layout = PushdownLayout(kind: .categorical,
                                    hasSeries: !numericBinned && series != nil,
                                    numericBins: numericBinned ? binCountNominal(bin.numeric) : nil)

        if numericBinned, let countExpr = binCountExpr(bin.numeric) {
            let id = quoteIdent(catCol.name)
            let sql = """
            WITH _pharos_src AS ( \(userSQL) ),
                 _r AS (SELECT min(\(id)) AS lo, max(\(id)) AS hi, \(countExpr) AS n FROM _pharos_src)
            SELECT CASE WHEN _r.lo = _r.hi THEN 1
                        ELSE LEAST(width_bucket(\(id), _r.lo, _r.hi, _r.n), _r.n) END AS _bucket,
                   _r.lo AS _lo, _r.hi AS _hi, _r.n AS _n, \(agg) AS _val
            FROM _pharos_src, _r
            GROUP BY _bucket, _r.lo, _r.hi, _r.n
            ORDER BY _bucket LIMIT \(groupCap)
            """
            return PushdownQuery(sql: sql, layout: layout)
        }
```
Change `axisExpr` to return `(expr: String, numericBinned: Bool)` and take a resolved `AxisBin`:
```swift
    private static func axisExpr(_ config: ChartConfig, _ col: ColumnDef, bin: AxisBin) -> (expr: String, numericBinned: Bool) {
        let kind = ColumnClassifier.kind(forDataType: col.dataType)
        let id = quoteIdent(col.name)
        let dt = col.dataType.lowercased()
        let isDateTruncable = dt.hasPrefix("date") || dt.hasPrefix("timestamp")
        if kind == .temporal, bin.temporal != .none, isDateTruncable {
            let unit = truncUnit(bin.temporal)
            let tz = dt.hasPrefix("timestamptz") || dt.contains("with time zone")
            let colExpr = tz ? "\(id) AT TIME ZONE 'UTC'" : id
            return ("date_trunc('\(unit)', \(colExpr))", false)
        }
        if kind == .numeric, binCountExpr(bin.numeric) != nil {
            return (id, true)   // width_bucket handled at query assembly
        }
        return (id, false)
    }
```
**Also update the existing `heatmap(...)`'s two `axisExpr` calls** to the new signature so the generator still compiles after this task (A4 rewrites `heatmap` next; this just keeps it green in between):
```swift
        let (xExpr, _) = axisExpr(config, xCol, bin: config.resolvedBin(for: .x))
        let (yExpr, _) = axisExpr(config, yCol, bin: config.resolvedBin(for: .y))
```
The heatmap stays discrete/flat-LIMIT here — A4 adds the `dense_rank()` top-N, B3 adds numeric binning.

- [ ] **Step 4: Failing builder test** — append to `ServerChartDataBuilderTests.runTests()`:
```swift
    // Numeric builder reads the server-chosen bucket count from `_n`, not layout.
    var numCfg = ChartConfig(chartType: .bar)
    numCfg.mappings[.category] = ColumnRef(index: 0, name: "age")
    let numRes = QueryResult(
        columns: [ColumnDef(name: "_bucket", dataType: "int4"), ColumnDef(name: "_lo", dataType: "numeric"),
                  ColumnDef(name: "_hi", dataType: "numeric"), ColumnDef(name: "_n", dataType: "int4"),
                  ColumnDef(name: "_val", dataType: "numeric")],
        rows: [[AnyCodable("1"), AnyCodable("0"), AnyCodable("10"), AnyCodable("2"), AnyCodable("5")],
               [AnyCodable("2"), AnyCodable("0"), AnyCodable("10"), AnyCodable("2"), AnyCodable("7")]],
        rowCount: 2, executionTimeMs: 1, hasMore: false, historyEntryId: nil)
    let numData = ServerChartDataBuilder.build(numRes, layout: PushdownLayout(kind: .categorical, hasSeries: false, numericBins: 0), config: numCfg)
    let numPts = numData.series.first?.points ?? []
    expect(numPts.count == 2, "two numeric buckets")
    expect(numPts.first?.xLabel == "0–5", "bucket width from _n (10/2=5) → first bucket 0–5")
    if case .range(_, let lo, let hi, _)? = numPts.first?.drill { expect(lo == 0 && hi == 5, "range drill uses _n width") }
    else { expect(false, "numeric point carries a range drill") }
```

- [ ] **Step 5: Implement builder** — in `ServerChartDataBuilder.buildNumeric(...)`, prefer the `_n` column when present:
```swift
        // Server-chosen bucket count rides `_n`; fall back to the layout nominal.
        let nFromCol = colIndex(result, "_n").flatMap { i in result.rows.first.flatMap { cell($0, i) }.flatMap { intValue($0) } }
        let effectiveBins = (nFromCol ?? 0) > 0 ? nFromCol! : binCount
        let width = (hi - lo) / Double(effectiveBins)
```
(Keep the rest of `buildNumeric` unchanged — it already sorts by `_bucket` and emits `.range` drills; `binCount` is the `layout.numericBins` argument.)

- [ ] **Step 6: Run both → PASS.** `scripts/test-sql-pushdown.sh` and `scripts/test-server-chart-builder.sh`.

- [ ] **Step 7: Commit**
```bash
git add Pharos/Models/Charts/SqlPushdownGenerator.swift Pharos/Models/Charts/ServerChartDataBuilder.swift PharosTests/SqlPushdownGeneratorTests.swift PharosTests/ServerChartDataBuilderTests.swift
git commit -m "feat(charts): row-count .auto bucket count via scalar subquery + _n readback"
```

---

# Phase B — Heatmap axes

> **Do Task B1 first** — A4/A5 above reference `config.resolvedBin(for:)`. If you executed Phase A before B1, ensure B1 lands before running the A4/A5 harnesses in final form.

## Task B1: ChartConfig — `AxisBin` + `axisBins` + `resolvedBin`

**Files:** Modify `Pharos/Models/Charts/ChartTypes.swift`, `Pharos/Models/Charts/ChartConfig.swift`; extend `PharosTests/ChartConfigTests.swift`.

- [ ] **Step 1: Failing tests** — append to `ChartConfigTests.runTests()` (before the final `if failures`):
```swift
    // axisBins: per-axis granularity round-trips; resolvedBin falls back to globals.
    var ab = ChartConfig(chartType: .heatmap, temporalBin: .month, numericBin: .b20)
    ab.axisBins[.x] = AxisBin(temporal: .day, numeric: .auto)
    let abData = try! JSONEncoder().encode(ab)
    let abBack = try! JSONDecoder().decode(ChartConfig.self, from: abData)
    expect(abBack.axisBins[.x]?.temporal == .day, "axisBins[.x] round-trips")
    expect(abBack.resolvedBin(for: .x).temporal == .day, "resolvedBin(.x) uses axisBins override")
    expect(abBack.resolvedBin(for: .y).temporal == .month, "resolvedBin(.y) falls back to global temporalBin")
    expect(abBack.resolvedBin(for: .y).numeric == .b20, "resolvedBin(.y) falls back to global numericBin")
    // legacy blob (no axisBins) → empty, global behavior preserved.
    let legacy4 = #"{"chartType":"heatmap","mappings":[],"aggregation":"count","temporalBin":"month","numericBin":"b20","display":{"title":"","showLegend":true,"stacked":false,"topNCategories":25}}"#
    let old4 = try! JSONDecoder().decode(ChartConfig.self, from: Data(legacy4.utf8))
    expect(old4.axisBins.isEmpty, "legacy config has empty axisBins")
    expect(old4.resolvedBin(for: .x).temporal == .month, "legacy resolvedBin uses globals")
```
Note: `"numericBin":"b20"` — `NumericBin.b20` has raw value `"20"`, so the legacy blob must use `"numericBin":"20"`. Fix the literal to `"numericBin":"20"` when writing the test.

- [ ] **Step 2: Run → FAIL.** `scripts/test-chart-config.sh`

- [ ] **Step 3: Implement** — in `ChartTypes.swift` add:
```swift
/// Independent per-axis bin granularity (heatmap X/Y). Absent ⇒ the chart's
/// global `temporalBin`/`numericBin` apply (see `ChartConfig.resolvedBin`).
struct AxisBin: Codable, Equatable {
    var temporal: TemporalBin = .auto
    var numeric: NumericBin = .auto
    init(temporal: TemporalBin = .auto, numeric: NumericBin = .auto) {
        self.temporal = temporal; self.numeric = numeric
    }
}
```
In `ChartConfig.swift`:
- Add stored property `var axisBins: [ChartColumnRole: AxisBin] = [:]`.
- Add it to the memberwise `init` (param `axisBins: [ChartColumnRole: AxisBin] = [:]` + assignment).
- Add `case axisBins` to `CodingKeys`.
- In `init(from:)`: `axisBins = try c.decodeIfPresent([ChartColumnRole: AxisBin].self, forKey: .axisBins) ?? [:]`.
- Add the resolver:
```swift
    /// The effective bin granularity for a role: the per-axis override if set,
    /// else the chart's global temporal/numeric bins. Centralizes the fallback so
    /// the aggregator and generator never sprinkle it.
    func resolvedBin(for role: ChartColumnRole) -> AxisBin {
        axisBins[role] ?? AxisBin(temporal: temporalBin, numeric: numericBin)
    }
```

- [ ] **Step 4: Run → PASS.**

- [ ] **Step 5: Commit**
```bash
git add Pharos/Models/Charts/ChartTypes.swift Pharos/Models/Charts/ChartConfig.swift PharosTests/ChartConfigTests.swift
git commit -m "feat(charts): AxisBin + axisBins + resolvedBin(for:) on ChartConfig"
```

---

## Task B2: ChartAggregator — heatmap per-axis numeric binning

**Files:** Modify `Pharos/Models/Charts/ChartAggregator.swift`; extend `PharosTests/ChartAggregatorTests.swift`.

Mirror the categorical numeric path on each heatmap axis independently, driven by `resolvedBin(for: .x/.y)`.

- [ ] **Step 1: Failing test** — append to `ChartAggregatorTests.runTests()` a heatmap with a numeric X axis and enough distinct values to bin:
```swift
    // Heatmap numeric X-axis binning (per-axis): 20 distinct x values, .b10 → 10 bins.
    do {
        let cols = [ColumnDef(name: "x", dataType: "numeric"), ColumnDef(name: "y", dataType: "text")]
        var rows: [[AnyCodable]] = []
        for i in 0..<20 { rows.append([AnyCodable(String(i)), AnyCodable(i % 2 == 0 ? "a" : "b")]) }
        let res = QueryResult(columns: cols, rows: rows, rowCount: 20, executionTimeMs: 1, hasMore: false, historyEntryId: nil)
        var cfg = ChartConfig(chartType: .heatmap, aggregation: .count)
        cfg.mappings[.x] = ColumnRef(index: 0, name: "x")
        cfg.mappings[.y] = ColumnRef(index: 1, name: "y")
        cfg.axisBins[.x] = AxisBin(numeric: .b10)
        let d = ChartAggregator.aggregate(res, cfg)
        let xLabels = Set(d.heatmapCells.map { $0.x })
        expect(xLabels.contains { $0.contains("–") }, "heatmap numeric X produces range labels")
        expect(xLabels.count <= 10, "heatmap numeric X capped at 10 bins")
        // Cells carry a compound whose X sub-key is a numeric .range.
        if let cell = d.heatmapCells.first, case .compound(let ks)? = cell.drill, case .range(_, _, _, .numeric) = ks[0] {
            expect(true, "heatmap numeric X cell drill is a .range")
        } else { expect(false, "heatmap numeric X cell drill is a .range") }
    }
```

- [ ] **Step 2: Run → FAIL.** `scripts/test-chart-aggregator.sh`

- [ ] **Step 3: Implement** — rewrite the axis-labelling part of `aggregateHeatmap`.

Replace the single generic `axis(_:_:_:)` closure with **per-axis** label/drill closures that each capture their own binning (numeric bins via a first pass, or temporal via `resolvedBin`). Add, before the main row loop, a helper that builds a per-axis labeller:
```swift
        // Build a per-axis labeller: numeric binning (first pass for range +
        // distinct, with the low-cardinality escape) mirrors the categorical
        // path; temporal binning uses the axis's resolved TemporalBin; otherwise
        // discrete. Returns (label, drill sub-key) for a raw cell.
        func makeAxisLabeller(_ ref: ColumnRef, _ kind: ColumnKind, _ bin: AxisBin) -> (AnyCodable) -> (String, DrillKey) {
            if kind == .numeric {
                var vals: [Double] = []; var distinct = Set<Double>()
                for row in result.rows where ref.index < row.count {
                    if let d = ValueCoercion.double(from: row[ref.index]) { vals.append(d); distinct.insert(d) }
                }
                if let count = numericBinCount(bin.numeric, distinct: distinct.count, n: vals.count),
                   let lo = vals.min(), let hi = vals.max(), hi > lo {
                    let width = (hi - lo) / Double(count)
                    let bins = (0..<count).map { (lo + Double($0) * width, lo + Double($0 + 1) * width) }
                    let binOf: (Double) -> Int = { v in Swift.min(count - 1, Swift.max(0, Int((v - lo) / width))) }
                    return { v in
                        guard let d = ValueCoercion.double(from: v) else {
                            if v.isNull || v.displayString.isEmpty { return ("(null)", .blank(ref)) }
                            return (v.displayString, .anyOf(ref, [v.displayString]))
                        }
                        let b = bins[binOf(d)]
                        return (binRangeLabel(b.lo, b.hi), .range(ref, b.lo, b.hi, .numeric))
                    }
                }
                // else: fall through to discrete handling below.
            }
            return { v in
                if kind == .temporal, bin.temporal != .none, case let s as String = v.value, let d = ValueCoercion.date(from: s) {
                    let label = self.binLabel(d, bin: bin.temporal)
                    if let (blo, bhi) = self.temporalBinBounds(d, bin: bin.temporal) { return (label, .range(ref, blo, bhi, .temporal)) }
                    return (label, .anyOf(ref, [label]))
                }
                if v.isNull || v.displayString.isEmpty { return ("(null)", .blank(ref)) }
                return (v.displayString, .anyOf(ref, [v.displayString]))
            }
        }
        let xLabeller = makeAxisLabeller(xRef, xKind, config.resolvedBin(for: .x))
        let yLabeller = makeAxisLabeller(yRef, yKind, config.resolvedBin(for: .y))
```
Then in the row loop replace:
```swift
            let (xl, xk) = axis(row[xRef.index], xRef, xKind)
            let (yl, yk) = axis(row[yRef.index], yRef, yKind)
```
with:
```swift
            let (xl, xk) = xLabeller(row[xRef.index])
            let (yl, yk) = yLabeller(row[yRef.index])
```
Delete the old inline `func axis(...)`. **Make `binLabel`, `temporalBinBounds`, `binRangeLabel`, `numericBinCount` reachable** — they are `private static` on `ChartAggregator`; the closures reference them via `self.`-free static context (inside a `static func`, call them bare: `binLabel(...)`, `temporalBinBounds(...)`). Remove the `self.` prefixes shown above — this method is `static`, so call them unqualified (`binLabel(d, bin:)`, `temporalBinBounds(d, bin:)`).

- [ ] **Step 4: Run → PASS.** Also re-run to confirm the existing heatmap temporal/discrete tests still pass.

- [ ] **Step 5: Commit**
```bash
git add Pharos/Models/Charts/ChartAggregator.swift PharosTests/ChartAggregatorTests.swift
git commit -m "feat(charts): heatmap per-axis numeric binning (client)"
```

---

## Task B3: SqlPushdownGenerator — heatmap numeric width_bucket per axis

**Files:** Modify `Pharos/Models/Charts/SqlPushdownGenerator.swift` and `Pharos/Models/Charts/ServerChartDataBuilder.swift`; extend both test files.

Extend the A4 heatmap method so a numeric axis is width-bucketed (composing with the `dense_rank()` top-N), and set `xNumericBinned`/`yNumericBinned` on the layout. The `_agg` CTE gains a per-axis range CTE and carries the axis bounds/count as extra columns for the builder.

- [ ] **Step 1: Failing generator test** — append to `SqlPushdownGeneratorTests.runTests()`:
```swift
    // Heatmap numeric X axis → width_bucket + range CTE; layout flags it.
    let hmn = SqlPushdownGenerator.generate(cfg(.heatmap, [.x: 3, .y: 0], .count, nb: .b20), userSQL: src, columns: cols)
    contains(hmn?.sql, "width_bucket", "heatmap numeric axis uses width_bucket")
    contains(hmn?.sql, "_rx", "heatmap x range CTE")
    contains(hmn?.sql, "_xlo", "heatmap x carries lo bound for the builder")
    expect(hmn?.layout.xNumericBinned == true, "layout marks x numeric-binned")
    expect(hmn?.layout.yNumericBinned == false, "y stays discrete")
```
Note `cfg(...)` sets `numericBin` globally; heatmap X reads `resolvedBin(for: .x).numeric`, which falls back to the global `numericBin` when `axisBins[.x]` is unset — so `nb: .b20` binds X here.

- [ ] **Step 2: Run → FAIL.**

- [ ] **Step 3: Implement** — replace `heatmap(...)` with a version that builds each axis's SQL fragments. Per numeric axis, emit a range CTE `_rx`/`_ry` (`min/max/count`), a `width_bucket` expression, and carry `lo/hi/n` as `_xlo/_xhi/_xn` (resp. `_y…`). Discrete/temporal axes select the raw `axisExpr` and carry nothing extra:
```swift
    private static func heatmap(_ config: ChartConfig, userSQL: String, columns: [ColumnDef], agg: String) -> PushdownQuery? {
        guard let xCol = resolve(config, .x, columns), let yCol = resolve(config, .y, columns) else { return nil }
        let xBin = config.resolvedBin(for: .x), yBin = config.resolvedBin(for: .y)
        let (_, xNumeric) = axisExpr(config, xCol, bin: xBin)
        let (_, yNumeric) = axisExpr(config, yCol, bin: yBin)
        let n = config.display.topNCategories

        // Per-axis fragments: (selectExpr for _x/_y, extra select cols, range CTE, group-by extras).
        struct Axis { let sel: String; let extraSel: String; let cte: String; let groupExtra: String }
        func axisFragments(_ col: ColumnDef, _ bin: AxisBin, numeric: Bool, tag: String) -> Axis {
            let id = quoteIdent(col.name)
            if numeric, let countExpr = binCountExpr(bin.numeric) {
                let r = "_r\(tag)"
                let sel = "CASE WHEN \(r).lo = \(r).hi THEN 1 ELSE LEAST(width_bucket(\(id), \(r).lo, \(r).hi, \(r).n), \(r).n) END"
                let extraSel = ", \(r).lo AS _\(tag)lo, \(r).hi AS _\(tag)hi, \(r).n AS _\(tag)n"
                let cte = "\(r) AS (SELECT min(\(id)) AS lo, max(\(id)) AS hi, \(countExpr) AS n FROM _pharos_src)"
                let groupExtra = ", \(r).lo, \(r).hi, \(r).n"
                return Axis(sel: sel, extraSel: extraSel, cte: cte, groupExtra: groupExtra)
            }
            let (expr, _) = axisExpr(config, col, bin: bin)
            return Axis(sel: expr, extraSel: "", cte: "", groupExtra: "")
        }
        let ax = axisFragments(xCol, xBin, numeric: xNumeric, tag: "x")
        let ay = axisFragments(yCol, yBin, numeric: yNumeric, tag: "y")
        let extraCTEs = [ax.cte, ay.cte].filter { !$0.isEmpty }.joined(separator: ",\n     ")
        let cteBlock = extraCTEs.isEmpty ? "" : ",\n     \(extraCTEs)"
        let fromExtra = [xNumeric ? ", _rx" : "", yNumeric ? ", _ry" : ""].joined()
        // Bounds columns pass straight through _agg; the ranking joins ignore them.
        let sql = """
        WITH _pharos_src AS ( \(userSQL) )\(cteBlock),
        _agg AS (
          SELECT \(ax.sel) AS _x, \(ay.sel) AS _y\(ax.extraSel)\(ay.extraSel), \(agg) AS _val
          FROM _pharos_src\(fromExtra)
          GROUP BY _x, _y\(ax.groupExtra)\(ay.groupExtra)
        ),
        _xr AS ( SELECT _x, dense_rank() OVER (ORDER BY sum(_val) DESC) AS rk FROM _agg GROUP BY _x ),
        _yr AS ( SELECT _y, dense_rank() OVER (ORDER BY sum(_val) DESC) AS rk FROM _agg GROUP BY _y )
        SELECT a.*
        FROM _agg a
          JOIN _xr ON _xr._x IS NOT DISTINCT FROM a._x AND _xr.rk <= \(n)
          JOIN _yr ON _yr._y IS NOT DISTINCT FROM a._y AND _yr.rk <= \(n)
        ORDER BY a._val DESC
        LIMIT \(groupCap)
        """
        return PushdownQuery(sql: sql, layout: PushdownLayout(kind: .heatmap, hasSeries: false, numericBins: nil,
                                                              xNumericBinned: xNumeric, yNumericBinned: yNumeric))
    }
```
(This supersedes the A4 heatmap body — A4 established the dense_rank shape; B3 generalizes it. If executing strictly in order, this is the final form.)

- [ ] **Step 4: Failing builder test** — append to `ServerChartDataBuilderTests.runTests()`:
```swift
    // Heatmap numeric X axis: builder turns bucket ints + _xlo/_xhi/_xn into range
    // labels and a numeric .range X sub-key, discrete Y stays .anyOf.
    var hmCfg = ChartConfig(chartType: .heatmap, aggregation: .count)
    hmCfg.mappings[.x] = ColumnRef(index: 0, name: "age")
    hmCfg.mappings[.y] = ColumnRef(index: 1, name: "status")
    let hmRes = QueryResult(
        columns: [ColumnDef(name: "_x", dataType: "int4"), ColumnDef(name: "_y", dataType: "text"),
                  ColumnDef(name: "_xlo", dataType: "numeric"), ColumnDef(name: "_xhi", dataType: "numeric"),
                  ColumnDef(name: "_xn", dataType: "int4"), ColumnDef(name: "_val", dataType: "numeric")],
        rows: [[AnyCodable("1"), AnyCodable("open"), AnyCodable("0"), AnyCodable("10"), AnyCodable("2"), AnyCodable("4")]],
        rowCount: 1, executionTimeMs: 1, hasMore: false, historyEntryId: nil)
    let hmData = ServerChartDataBuilder.build(hmRes, layout: PushdownLayout(kind: .heatmap, hasSeries: false, numericBins: nil, xNumericBinned: true, yNumericBinned: false), config: hmCfg)
    expect(hmData.heatmapCells.first?.x == "0–5", "heatmap numeric X labelled from _xlo/_xhi/_xn")
    if case .compound(let ks)? = hmData.heatmapCells.first?.drill, case .range(_, let lo, let hi, .numeric) = ks[0] {
        expect(lo == 0 && hi == 5, "heatmap X range drill from bucket bounds")
    } else { expect(false, "heatmap X drill is a numeric range") }
```

- [ ] **Step 5: Implement builder** — rewrite `buildHeatmap` to handle numeric-binned axes. When `layout.xNumericBinned` (resp. y), read `_xlo/_xhi/_xn` (resp. `_y…`) and the `_x` bucket int, compute the bucket `[lo+(b-1)*w, lo+b*w)`, label via the local `rangeLabel`, and set the X sub-key to `.range(xRef, blo, bhi, .numeric)`. Otherwise keep the existing discrete/`.blank` logic:
```swift
    private static func buildHeatmap(_ result: QueryResult, layout: PushdownLayout, config: ChartConfig) -> ChartData {
        guard let xRef = config.mappings[.x], let yRef = config.mappings[.y],
              let xIdx = colIndex(result, "_x"), let yIdx = colIndex(result, "_y"),
              let valIdx = colIndex(result, "_val") else { return .empty(.noColumns) }

        // Optional per-axis numeric bound columns.
        func bounds(_ tag: String) -> (lo: Int?, hi: Int?, n: Int?) {
            (colIndex(result, "_\(tag)lo"), colIndex(result, "_\(tag)hi"), colIndex(result, "_\(tag)n"))
        }
        let xb = bounds("x"), yb = bounds("y")

        func axisLabelDrill(_ raw: AnyCodable, _ row: [AnyCodable], numeric: Bool,
                            _ bnd: (lo: Int?, hi: Int?, n: Int?), _ ref: ColumnRef) -> (String, DrillKey) {
            if numeric, let bucket = intValue(raw),
               let loC = bnd.lo.flatMap({ cell(row, $0) }).flatMap({ ValueCoercion.double(from: $0) }),
               let hiC = bnd.hi.flatMap({ cell(row, $0) }).flatMap({ ValueCoercion.double(from: $0) }),
               let nC = bnd.n.flatMap({ cell(row, $0) }).flatMap({ intValue($0) }), nC > 0 {
                let width = (hiC - loC) / Double(nC)
                let blo = loC + Double(bucket - 1) * width, bhi = loC + Double(bucket) * width
                return (rangeLabel(blo, bhi), .range(ref, blo, bhi, .numeric))
            }
            if raw.isNull || raw.displayString.isEmpty { return ("(null)", .blank(ref)) }
            return (raw.displayString, .anyOf(ref, [raw.displayString]))
        }

        var cells: [HeatmapCell] = []
        for row in result.rows {
            guard let xCell = cell(row, xIdx), let yCell = cell(row, yIdx), let vCell = cell(row, valIdx),
                  let v = ValueCoercion.double(from: vCell) else { continue }
            let (xl, xk) = axisLabelDrill(xCell, row, numeric: layout.xNumericBinned, xb, xRef)
            let (yl, yk) = axisLabelDrill(yCell, row, numeric: layout.yNumericBinned, yb, yRef)
            cells.append(HeatmapCell(x: xl, y: yl, value: v, drill: .compound([xk, yk])))
        }
        if cells.isEmpty { return .empty(.allNull) }
        var out = ChartData()
        out.heatmapCells = cells
        out.plottedRowCount = cells.count
        out.totalLoadedRowCount = result.rowCount
        out.wasTruncated = result.hasMore
        return out
    }
```
Update the `build(...)` dispatcher's heatmap branch to pass the layout: `case .heatmap: return buildHeatmap(result, layout: layout, config: config)`.

- [ ] **Step 6: Run both → PASS.**

- [ ] **Step 7: Commit**
```bash
git add Pharos/Models/Charts/SqlPushdownGenerator.swift Pharos/Models/Charts/ServerChartDataBuilder.swift PharosTests/SqlPushdownGeneratorTests.swift PharosTests/ServerChartDataBuilderTests.swift
git commit -m "feat(charts): heatmap numeric-axis width_bucket push-down + builder bounds"
```

---

## Task B4: Rail — per-axis heatmap bin controls

**Files:** Modify `Pharos/Models/Charts/ChartTypes.swift` (add `LastServerRun.sampled`, see Task C-integration note) and `Pharos/ViewControllers/Charts/ChartRootView.swift`. Build-gated.

- [ ] **Step 1: Per-axis controls** — in `ChartRootView.configRail`, replace the single `showTimeBucket`/`showNumericBins` block so that **for heatmap** it renders independent X and Y controls writing `axisBins[.x]`/`[.y]`, and for other charts keeps the global controls.

Add axis-scoped helpers to `ChartRootView`:
```swift
    // For heatmap, the bin control for a given axis role, keyed on the mapped
    // column's kind, writing to config.axisBins[role].
    @ViewBuilder private func axisBinControls(_ role: ChartColumnRole, _ title: String) -> some View {
        let k = model.kind(model.config.mappings[role])
        if k == .temporal {
            railLabel("\(title) time bucket")
            Picker("", selection: Binding(
                get: { model.config.resolvedBin(for: role).temporal },
                set: { b in model.update { var ab = $0.axisBins[role] ?? AxisBin(temporal: $0.temporalBin, numeric: $0.numericBin); ab.temporal = b; $0.axisBins[role] = ab } })) {
                ForEach(TemporalBin.allCases, id: \.self) { Text($0.rawValue.capitalized).tag($0) }
            }.labelsHidden()
        } else if k == .numeric {
            railLabel("\(title) bins")
            Picker("", selection: Binding(
                get: { model.config.resolvedBin(for: role).numeric },
                set: { b in model.update { var ab = $0.axisBins[role] ?? AxisBin(temporal: $0.temporalBin, numeric: $0.numericBin); ab.numeric = b; $0.axisBins[role] = ab } })) {
                ForEach(NumericBin.allCases, id: \.self) { Text($0.displayName).tag($0) }
            }.labelsHidden()
        }
    }
```
In `configRail`, wrap the existing `showTimeBucket`/`showNumericBins` pickers so heatmap uses the per-axis controls instead:
```swift
                if model.config.chartType == .heatmap {
                    axisBinControls(.x, "X")
                    axisBinControls(.y, "Y")
                } else {
                    if showTimeBucket { /* existing global Time bucket picker */ }
                    if showNumericBins { /* existing global Bins picker */ }
                }
```
(Keep the existing global picker code verbatim inside the `else` branch.)

- [ ] **Step 2: Build** → `xcodegen generate && xcodebuild … build` → BUILD SUCCEEDED.

- [ ] **Step 3: Commit**
```bash
git add Pharos/ViewControllers/Charts/ChartRootView.swift
git commit -m "feat(charts): independent per-axis bin controls on the heatmap rail"
```

---

# Phase C — Richer interaction

## Task C1: BlanksSentinel + DrillKey.overlap + DrillMerge

**Files:** Create `Pharos/Utilities/BlanksSentinel.swift`, `Pharos/Models/Charts/DrillMerge.swift`, `PharosTests/DrillMergeTests.swift`, `scripts/test-drill-merge.sh`; modify `Pharos/Utilities/ColumnFilter.swift`, `Pharos/Models/Charts/DrillKey.swift`; extend `PharosTests/DrillKeyTests.swift`; update scripts that compile `ColumnFilter.swift`.

- [ ] **Step 1: Shared sentinel** — create `Pharos/Utilities/BlanksSentinel.swift`:
```swift
import Foundation

/// The single canonical "match null / empty cells" sentinel, shared by the grid
/// filter (`ColumnFilter`), the pure drill-key merge (`DrillMerge`), and the SQL
/// translator (`DrillSqlTranslator`). Kept in one Foundation-only place so grid
/// and SQL null handling can never drift apart. NUL-prefixed so it cannot
/// collide with any rendered cell value.
enum PharosBlanks {
    static let sentinel = "\u{0}__pharos_blanks__"
}
```
In `ColumnFilter.swift`, change the constant to reference it:
```swift
    static let blanksSentinel = PharosBlanks.sentinel
```

- [ ] **Step 2: DrillKey.overlap** — in `DrillKey.swift`, add the case and extend `columnRefs`:
```swift
    /// A gantt time-brush: rows whose [startRef, endRef] span overlaps [lo, hi].
    /// RangeKind is REQUIRED — a gantt start/end axis may be numeric, not just
    /// temporal, so bounds must be formatted per kind (like `.range`).
    case overlap(ColumnRef, ColumnRef, Double, Double, RangeKind)
```
In `columnRefs`:
```swift
        case .overlap(let s, let e, _, _, _): return [s, e]
```

- [ ] **Step 3: Failing DrillKey test** — append to `DrillKeyTests.runTests()`:
```swift
    let ov = DrillKey.overlap(ColumnRef(index: 1, name: "start"), ColumnRef(index: 2, name: "end"), 100, 200, .temporal)
    expect(ov.columnRefs.map { $0.name } == ["start", "end"], "overlap exposes both refs")
    if case .overlap(_, _, let lo, let hi, let kind) = ov { expect(lo == 100 && hi == 200 && kind == .temporal, "overlap payload") }
    else { expect(false, "overlap payload") }
```

- [ ] **Step 4: DrillMerge** — create `Pharos/Models/Charts/DrillMerge.swift`:
```swift
import Foundation

/// Pure merge of drill sub-keys, grouped by column, for multi-mark selections
/// (heatmap rectangular brush, pie ⌘-click). Flattens compounds, then per column:
/// unions `.anyOf` value-lists, coalesces overlapping/adjacent `.range`s into one,
/// and folds `.blank` into the `.anyOf` list as `PharosBlanks.sentinel` (so a
/// single key carries "these values OR null"; the translators split it back out —
/// grid via the existing sentinel handling, SQL via the `.anyOf` → `IS NULL`
/// branch). A column with only a blank stays a `.blank`.
enum DrillMerge {
    static func merge(_ keys: [DrillKey]) -> [DrillKey] {
        var flat: [DrillKey] = []
        func walk(_ k: DrillKey) { if case .compound(let ks) = k { ks.forEach(walk) } else { flat.append(k) } }
        keys.forEach(walk)

        struct AnyAcc { var ref: ColumnRef; var vals: [String]; var blank: Bool }
        var anyOf: [Int: AnyAcc] = [:]
        var ranges: [Int: (ref: ColumnRef, lo: Double, hi: Double, kind: RangeKind)] = [:]
        var order: [Int] = []
        func note(_ i: Int) { if !order.contains(i) { order.append(i) } }

        for k in flat {
            switch k {
            case .anyOf(let r, let vs):
                note(r.index); anyOf[r.index, default: AnyAcc(ref: r, vals: [], blank: false)].vals += vs
            case .blank(let r):
                note(r.index); anyOf[r.index, default: AnyAcc(ref: r, vals: [], blank: false)].blank = true
            case .range(let r, let lo, let hi, let kind):
                note(r.index)
                if let ex = ranges[r.index] { ranges[r.index] = (r, Swift.min(ex.lo, lo), Swift.max(ex.hi, hi), kind) }
                else { ranges[r.index] = (r, lo, hi, kind) }
            case .overlap, .compound:
                break   // not produced as a per-axis sub-key
            }
        }

        var out: [DrillKey] = []
        for i in order {
            if let a = anyOf[i] {
                if a.vals.isEmpty && a.blank { out.append(.blank(a.ref)) }
                else {
                    var vals = dedup(a.vals)
                    if a.blank { vals.append(PharosBlanks.sentinel) }
                    out.append(.anyOf(a.ref, vals))
                }
            }
            if let r = ranges[i] { out.append(.range(r.ref, r.lo, r.hi, r.kind)) }
        }
        return out
    }

    private static func dedup(_ xs: [String]) -> [String] {
        var seen = Set<String>(); var r: [String] = []
        for x in xs where !seen.contains(x) { seen.insert(x); r.append(x) }
        return r
    }
}
```

- [ ] **Step 5: DrillMerge tests** — create `PharosTests/DrillMergeTests.swift`:
```swift
import Foundation

var failures = 0
func expect(_ c: Bool, _ n: String) { if c { print("PASS \(n)") } else { failures += 1; print("FAIL \(n)") } }

func runTests() {
    let x = ColumnRef(index: 0, name: "x"); let y = ColumnRef(index: 1, name: "y")

    // Union anyOf on the same column.
    let m1 = DrillMerge.merge([.anyOf(x, ["a"]), .anyOf(x, ["b", "a"])])
    if case .anyOf(_, let vs) = m1.first { expect(vs == ["a", "b"], "anyOf unioned + deduped") } else { expect(false, "anyOf unioned") }

    // Blank folds into anyOf as the sentinel.
    let m2 = DrillMerge.merge([.anyOf(x, ["a"]), .blank(x)])
    if case .anyOf(_, let vs) = m2.first { expect(vs.contains(PharosBlanks.sentinel) && vs.contains("a"), "blank folds to sentinel in anyOf") }
    else { expect(false, "blank folds to sentinel") }

    // Only-blank stays a .blank.
    let m3 = DrillMerge.merge([.blank(x)])
    if case .blank = m3.first { expect(true, "lone blank stays blank") } else { expect(false, "lone blank stays blank") }

    // Adjacent ranges coalesce.
    let m4 = DrillMerge.merge([.range(x, 0, 10, .numeric), .range(x, 10, 20, .numeric)])
    if case .range(_, let lo, let hi, _) = m4.first { expect(lo == 0 && hi == 20, "ranges coalesced") } else { expect(false, "ranges coalesced") }

    // Two columns → two keys (heatmap compound children flattened).
    let m5 = DrillMerge.merge([.compound([.anyOf(x, ["a"]), .anyOf(y, ["p"])]), .compound([.anyOf(x, ["b"]), .anyOf(y, ["q"])])])
    expect(m5.count == 2, "two columns yield two merged keys")

    if failures == 0 { print("\nAll tests passed.") } else { print("\n\(failures) failure(s)."); exit(1) }
}
```

- [ ] **Step 6: Scripts** — create `scripts/test-drill-merge.sh`:
```bash
#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")/.."
swiftc -o /tmp/drill-merge-tests \
  Pharos/Models/QueryResult.swift \
  Pharos/Models/Charts/ChartTypes.swift \
  Pharos/Models/Charts/DrillKey.swift \
  Pharos/Utilities/BlanksSentinel.swift \
  Pharos/Models/Charts/DrillMerge.swift \
  PharosTests/DrillMergeTests.swift \
  PharosTests/main.swift
/tmp/drill-merge-tests
```
`chmod +x scripts/test-drill-merge.sh`. Then add `Pharos/Utilities/BlanksSentinel.swift` to every script that compiles `ColumnFilter.swift`: `scripts/test-drill-translator.sh`, `scripts/test-filter-popover-sizing.sh`, `scripts/test-filter-value-counts.sh` (insert the line right before `Pharos/Utilities/ColumnFilter.swift`).

- [ ] **Step 7: Run → PASS.** `scripts/test-drill-merge.sh`, `scripts/test-drill-key.sh`, and each ColumnFilter script (must still pass after adding the sentinel file).

- [ ] **Step 8: Commit**
```bash
git add Pharos/Utilities/BlanksSentinel.swift Pharos/Utilities/ColumnFilter.swift Pharos/Models/Charts/DrillKey.swift Pharos/Models/Charts/DrillMerge.swift PharosTests/DrillKeyTests.swift PharosTests/DrillMergeTests.swift scripts/test-drill-merge.sh scripts/test-drill-translator.sh scripts/test-filter-popover-sizing.sh scripts/test-filter-value-counts.sh Pharos.xcodeproj/project.pbxproj
git commit -m "feat(charts): shared blanks sentinel, DrillKey.overlap, pure DrillMerge"
```
(Run `xcodegen generate` first so the two new files land in `project.pbxproj`, then stage it.)

---

## Task C2: DrillTranslator — `.overlap` → two grid filters

**Files:** Modify `Pharos/Models/Charts/DrillTranslator.swift`; extend `PharosTests/DrillTranslatorTests.swift`.

- [ ] **Step 1: Failing test** — append to `DrillTranslatorTests.runTests()`:
```swift
    // overlap (temporal): start ≤ hi (lessOrEqual) AND end ≥ lo (greaterOrEqual).
    let cols2 = [ColumnDef(name: "id", dataType: "int4"), ColumnDef(name: "start", dataType: "timestamptz"), ColumnDef(name: "end", dataType: "timestamptz")]
    let ovT = DrillTranslator.filters(for: [.overlap(ColumnRef(index: 1, name: "start"), ColumnRef(index: 2, name: "end"), 0, 86400, .temporal)], columns: cols2)
    expect(ovT.count == 2, "overlap yields two filters")
    expect(ovT.contains { $0.columnId == "col_1" && $0.filter.op == .lessOrEqual }, "start ≤ hi")
    expect(ovT.contains { $0.columnId == "col_2" && $0.filter.op == .greaterOrEqual }, "end ≥ lo")
    // overlap (numeric): bounds are numeric literals, not ISO.
    let cols3 = [ColumnDef(name: "id", dataType: "int4"), ColumnDef(name: "s", dataType: "int8"), ColumnDef(name: "e", dataType: "int8")]
    let ovN = DrillTranslator.filters(for: [.overlap(ColumnRef(index: 1, name: "s"), ColumnRef(index: 2, name: "e"), 10, 20, .numeric)], columns: cols3)
    expect(ovN.first(where: { $0.columnId == "col_1" })?.filter.value == "20", "numeric hi literal on start ≤ hi")
    expect(ovN.first(where: { $0.columnId == "col_2" })?.filter.value == "10", "numeric lo literal on end ≥ lo")
```

- [ ] **Step 2: Run → FAIL.** `scripts/test-drill-translator.sh`

- [ ] **Step 3: Implement** — in `DrillTranslator.filters(...)`, handle `.overlap` in the flatten/collect switch. Since `.overlap` touches two columns with different ops, emit its two `Applied` filters directly (don't fold into `anyOfByCol`). Add an `overlaps` accumulator and a single-bound formatter that reuses the existing `formatRange` bound logic:
```swift
        var overlaps: [(startRef: ColumnRef, endRef: ColumnRef, lo: Double, hi: Double, kind: RangeKind)] = []
```
In the `for k in flat` switch, add:
```swift
            case .overlap(let s, let e, let lo, let hi, let kind):
                overlaps.append((s, e, lo, hi, kind))
```
After the existing `ranges` loop, add:
```swift
        for o in overlaps {
            guard o.startRef.index < columns.count, o.endRef.index < columns.count else { continue }
            // A bar overlaps [lo,hi] iff it started at/before hi AND ended at/after lo.
            let sDT = columns[o.startRef.index].dataType
            let eDT = columns[o.endRef.index].dataType
            let (_, hiOnStart) = formatRange(o.lo, o.hi, kind: o.kind, dataType: sDT)
            let (loOnEnd, _) = formatRange(o.lo, o.hi, kind: o.kind, dataType: eDT)
            out.append(Applied(columnId: "col_\(o.startRef.index)",
                               filter: ColumnFilter(columnName: o.startRef.name, op: .lessOrEqual, value: hiOnStart, value2: nil, values: nil, dataType: sDT)))
            out.append(Applied(columnId: "col_\(o.endRef.index)",
                               filter: ColumnFilter(columnName: o.endRef.name, op: .greaterOrEqual, value: loOnEnd, value2: nil, values: nil, dataType: eDT)))
        }
```
(`formatRange` already returns `(loString, hiString)` per kind/dataType — take `.1` for the hi bound applied to start, `.0` for the lo bound applied to end.)

- [ ] **Step 4: Run → PASS.**

- [ ] **Step 5: Commit**
```bash
git add Pharos/Models/Charts/DrillTranslator.swift PharosTests/DrillTranslatorTests.swift
git commit -m "feat(charts): DrillTranslator overlap → start≤hi AND end≥lo grid filters"
```

---

## Task C3: DrillSqlTranslator — `.overlap` + `.anyOf` sentinel→`IS NULL`

**Files:** Modify `Pharos/Models/Charts/DrillSqlTranslator.swift`; extend `PharosTests/DrillSqlTranslatorTests.swift`; update `scripts/test-drill-sql.sh`.

- [ ] **Step 1: Failing tests** — append to `DrillSqlTranslatorTests.runTests()`:
```swift
    // anyOf with the blanks sentinel → IN (…) OR IS NULL (grid↔SQL parity).
    let mixed = DrillSqlTranslator.predicate(for: .anyOf(ColumnRef(index: 0, name: "status"), ["a", PharosBlanks.sentinel, "b"]), columns: [])
    expect(mixed.contains("IN ('a', 'b')"), "sentinel excluded from IN list")
    expect(mixed.contains(#""status" IS NULL"#), "sentinel adds IS NULL")
    expect(mixed.contains(" OR "), "IN and IS NULL joined by OR")
    // pure-sentinel anyOf → IS NULL only.
    let onlyNull = DrillSqlTranslator.predicate(for: .anyOf(ColumnRef(index: 0, name: "status"), [PharosBlanks.sentinel]), columns: [])
    expect(onlyNull == #""status" IS NULL"#, "pure-sentinel → IS NULL only")
    // overlap (temporal): start ≤ hi AND end ≥ lo, UTC ISO bounds.
    let ovSql = DrillSqlTranslator.predicate(for: .overlap(ColumnRef(index: 0, name: "s"), ColumnRef(index: 1, name: "e"), 0, 86400, .temporal), columns: [])
    expect(ovSql.contains(#""s" <="#) && ovSql.contains(#""e" >="#), "overlap emits start≤hi AND end≥lo")
    expect(ovSql.contains("1970-01-02"), "temporal overlap bound is UTC ISO")
    // overlap (numeric): numeric literals.
    let ovNum = DrillSqlTranslator.predicate(for: .overlap(ColumnRef(index: 0, name: "s"), ColumnRef(index: 1, name: "e"), 10, 20, .numeric), columns: [])
    expect(ovNum == #""s" <= 20 AND "e" >= 10"#, "numeric overlap literals")
```

- [ ] **Step 2: Update script** — in `scripts/test-drill-sql.sh`, add `Pharos/Utilities/BlanksSentinel.swift` before `Pharos/Models/Charts/DrillSqlTranslator.swift`.

- [ ] **Step 3: Run → FAIL.** `scripts/test-drill-sql.sh`

- [ ] **Step 4: Implement** — in `DrillSqlTranslator.predicate(...)`, rewrite `.anyOf` and add `.overlap`:
```swift
        case .anyOf(let ref, let vals):
            // Split the blanks sentinel out so a null-inclusive selection matches
            // NULLs too — mirrors the grid's sentinel handling (grid↔SQL parity).
            let reals = vals.filter { $0 != PharosBlanks.sentinel }
            let hasNull = vals.contains(PharosBlanks.sentinel)
            var parts: [String] = []
            if !reals.isEmpty {
                let list = reals.map { "'" + $0.replacingOccurrences(of: "'", with: "''") + "'" }.joined(separator: ", ")
                parts.append("\(ident(ref)) IN (\(list))")
            }
            if hasNull { parts.append("\(ident(ref)) IS NULL") }
            if parts.isEmpty { return "false" }   // empty selection matches nothing
            return parts.joined(separator: " OR ")
        case .overlap(let s, let e, let lo, let hi, let kind):
            let (l, h) = bounds(lo, hi, kind)
            return "\(ident(s)) <= \(h) AND \(ident(e)) >= \(l)"
```
(Keep `.blank`, `.range`, `.compound`, `ident`, `bounds` as-is. The `.compound` case already wraps each child in `( )`, so an OR-bearing `.anyOf` inside a compound is correctly parenthesized. Top-level composition is fixed in Task C7.)

- [ ] **Step 5: Run → PASS.**

- [ ] **Step 6: Commit**
```bash
git add Pharos/Models/Charts/DrillSqlTranslator.swift PharosTests/DrillSqlTranslatorTests.swift scripts/test-drill-sql.sh
git commit -m "feat(charts): DrillSqlTranslator overlap + anyOf sentinel→IS NULL parity"
```

---

## Task C4: ChartAggregator — multi-series compound drill

**Files:** Modify `Pharos/Models/Charts/ChartAggregator.swift`; extend `PharosTests/ChartAggregatorTests.swift`.

Attach `.compound([categoryKey, seriesKey])` to each multi-series categorical point so a series-precise gesture (Task C5) can filter both columns; single-series charts are unchanged.

- [ ] **Step 1: Failing test** — append to `ChartAggregatorTests.runTests()`:
```swift
    // Multi-series bar points carry compound(category + series) drill keys.
    do {
        let cols = [ColumnDef(name: "cat", dataType: "text"), ColumnDef(name: "val", dataType: "numeric"), ColumnDef(name: "ser", dataType: "text")]
        let rows: [[AnyCodable]] = [[AnyCodable("a"), AnyCodable("1"), AnyCodable("s1")],
                                    [AnyCodable("a"), AnyCodable("2"), AnyCodable("s2")]]
        let res = QueryResult(columns: cols, rows: rows, rowCount: 2, executionTimeMs: 1, hasMore: false, historyEntryId: nil)
        var cfg = ChartConfig(chartType: .bar, aggregation: .sum)
        cfg.mappings[.category] = ColumnRef(index: 0, name: "cat")
        cfg.mappings[.value] = ColumnRef(index: 1, name: "val")
        cfg.mappings[.series] = ColumnRef(index: 2, name: "ser")
        let d = ChartAggregator.aggregate(res, cfg)
        let s1pt = d.series.first(where: { $0.name == "s1" })?.points.first
        if case .compound(let ks)? = s1pt?.drill, ks.count == 2, case .anyOf(let sref, let sv) = ks[1] {
            expect(sref.name == "ser" && sv == ["s1"], "series point drills category AND its series")
        } else { expect(false, "series point carries compound(cat, series)") }
    }
```

- [ ] **Step 2: Run → FAIL.**

- [ ] **Step 3: Implement** — in `aggregateCategorical`, when a `series` role is mapped, wrap each emitted point's drill in a compound with the series sub-key. In the final emit loop (where `pts.append(ChartPoint(...))`), compute the series sub-key and combine:
```swift
        for s in seriesNames {
            var pts: [ChartPoint] = []
            for c in categories {
                let k = Key(series: s, cat: c)
                let hasData = sums[k] != nil || counts[k] != nil || c == "Other"
                guard hasData else { continue }
                var drill = drillOf[c]
                if seriesRef != nil, let base = drill {
                    // Null/empty series name → .blank on the series column.
                    let seriesKey: DrillKey = s.isEmpty ? .blank(seriesRef!) : .anyOf(seriesRef!, [s])
                    drill = .compound([base, seriesKey])
                }
                pts.append(ChartPoint(xLabel: c, xValue: nil, y: value(k), drill: drill))
            }
            out.series.append(ChartSeries(name: s, points: pts))
        }
```
(Single-series charts have `seriesRef == nil` → drill stays the category key, unchanged.)

- [ ] **Step 4: Run → PASS.** Confirm existing single-series drill tests still pass.

- [ ] **Step 5: Commit**
```bash
git add Pharos/Models/Charts/ChartAggregator.swift PharosTests/ChartAggregatorTests.swift
git commit -m "feat(charts): multi-series points carry compound(category, series) drill"
```

---

## Task C5: ChartView — series-precise category tap + gantt/heatmap/pie gestures

**Files:** Modify `Pharos/ViewControllers/Charts/ChartView.swift` and `Pharos/Models/Charts/ChartData.swift` (add `ganttAxisKind`) and `Pharos/Models/Charts/ChartAggregator.swift` (set it). Build-gated + manual.

This bundles all four interaction gestures. No new pure logic beyond the tiny `firstChild` helper (covered by manual verification; the drill-key mechanics are already unit-tested in C1–C4).

- [ ] **Step 1: Gantt axis kind on ChartData** — in `ChartData.swift` add `var ganttAxisKind: RangeKind = .temporal`. In `ChartAggregator.aggregateGantt`, after resolving `startRef`, set it from the start column's classification:
```swift
        let startKind = ColumnClassifier.kind(forDataType: result.columns[startRef.index].dataType)
        // ... after building `out`:
        out.ganttAxisKind = startKind == .temporal ? .temporal : .numeric
```

- [ ] **Step 2: Series-precise category tap** — in `ChartView.swift`, extend `categoryOverlay` to pass the tap's y and replace `categoryTap(label)` with a series-aware resolver.

Change the tap branch in `categoryOverlay`:
```swift
                            if abs(value.translation.width) < 6 {
                                if let label = proxy.value(atX: ex, as: String.self) {
                                    categoryTap(label, atY: value.location.y - origin.y, proxy: proxy)
                                }
                            } else {
                                categoryBrush(min(sx, ex), max(sx, ex), proxy)
                            }
```
Replace `categoryTap` + add helpers:
```swift
    // Resolve which series (if any) the tap hit, then drill that series' point
    // (category AND series). Stacked bars: map the tapped y-value to the
    // cumulative series band. Line/area: nearest series by value. Single-series
    // or grouped/ambiguous: category-only.
    private func categoryTap(_ label: String, atY py: CGFloat, proxy: ChartProxy) {
        let seriesWithLabel = data.series.filter { $0.points.contains { $0.xLabel == label } }
        guard let first = seriesWithLabel.first?.points.first(where: { $0.xLabel == label }), let firstDrill = first.drill else { return }

        // Single series → drill its point directly.
        if data.series.count <= 1 { onDrill([firstDrill]); return }

        // Resolve the tapped value on the y-axis.
        let tappedValue = proxy.value(atY: py, as: Double.self)

        let resolved: ChartPoint? = {
            guard let tv = tappedValue else { return nil }
            switch chartType {
            case .bar where config.display.stacked:
                // Cumulative band: series in order; first whose running sum ≥ tv.
                var acc = 0.0
                for s in data.series {
                    if let pt = s.points.first(where: { $0.xLabel == label }) {
                        acc += pt.y
                        if tv <= acc { return pt }
                    }
                }
                return nil
            case .line, .area:
                // Nearest series by |value - tapped|.
                return data.series.compactMap { $0.points.first(where: { $0.xLabel == label }) }
                    .min(by: { abs($0.y - tv) < abs($1.y - tv) })
            default:
                return nil   // grouped bar / ambiguous → category-only
            }
        }()

        if let pt = resolved, let d = pt.drill { onDrill([d]) }
        else { onDrill([firstChild(firstDrill)]) }   // category-only fallback
    }

    /// The category sub-key of a series point's compound drill (or the key itself
    /// for single-series points).
    private func firstChild(_ key: DrillKey) -> DrillKey {
        if case .compound(let ks) = key, let first = ks.first { return first }
        return key
    }
```
Update `categoryBrush` to be category-only (extract the first child so a brush never accidentally pins a series):
```swift
                    seen.insert(pt.xLabel); keys.append(firstChild(drill))
```

- [ ] **Step 3: Gantt overlap time-brush** — add a drag overlay to the pinned header chart in `ganttChart`. After the header `Chart { … }.chartXScale(domain:).chartXAxis(…).chartYAxis(.hidden)`, add `.chartOverlay`:
```swift
                .chartOverlay { proxy in
                    GeometryReader { g in
                        let ox = proxy.plotFrame.map { g[$0].origin.x } ?? 0
                        Rectangle().fill(Color.clear).contentShape(Rectangle())
                            .gesture(DragGesture(minimumDistance: 6).onEnded { v in
                                ganttBrush(v.startLocation.x - ox, v.location.x - ox, proxy: proxy, bars: bars)
                            })
                    }
                }
```
Add the handler:
```swift
    private func ganttBrush(_ ax: CGFloat, _ bx: CGFloat, proxy: ChartProxy, bars: [GanttBar]) {
        guard let startRef = config.mappings[.start], let endRef = config.mappings[.end],
              let d0 = proxy.value(atX: min(ax, bx), as: Date.self),
              let d1 = proxy.value(atX: max(ax, bx), as: Date.self) else { return }
        // Domain is epoch-seconds-as-Date for both temporal and numeric axes;
        // .timeIntervalSince1970 recovers the epoch/raw value. Kind picks formatting.
        onDrill([.overlap(startRef, endRef, d0.timeIntervalSince1970, d1.timeIntervalSince1970, data.ganttAxisKind)])
    }
```

- [ ] **Step 4: Heatmap rectangular brush** — replace `heatmapOverlay`'s `onTapGesture` with a `DragGesture(minimumDistance: 0)` that taps (small travel → single cell) or brushes (collect covered cells → merge sub-keys):
```swift
    @ViewBuilder private func heatmapOverlay(_ proxy: ChartProxy) -> some View {
        GeometryReader { geo in
            let origin = proxy.plotFrame.map { geo[$0].origin } ?? .zero
            Rectangle().fill(Color.clear).contentShape(Rectangle())
                .gesture(DragGesture(minimumDistance: 0).onEnded { v in
                    let sx = v.startLocation.x - origin.x, ex = v.location.x - origin.x
                    let sy = v.startLocation.y - origin.y, ey = v.location.y - origin.y
                    if abs(v.translation.width) < 6 && abs(v.translation.height) < 6 {
                        heatmapTap(ex, ey, proxy)
                    } else {
                        heatmapBrush(min(sx, ex), max(sx, ex), min(sy, ey), max(sy, ey), proxy)
                    }
                })
        }
    }

    private func heatmapTap(_ px: CGFloat, _ py: CGFloat, _ proxy: ChartProxy) {
        guard let xl = proxy.value(atX: px, as: String.self), let yl = proxy.value(atY: py, as: String.self),
              let cell = data.heatmapCells.first(where: { $0.x == xl && $0.y == yl }), let drill = cell.drill else { return }
        onDrill([drill])
    }

    // Collect covered cells, flatten their pre-computed compound sub-keys, and
    // merge per axis (union anyOf / coalesce range / fold blank) — never rebuilt
    // from labels (binned-axis labels are range strings that match nothing).
    private func heatmapBrush(_ xlo: CGFloat, _ xhi: CGFloat, _ ylo: CGFloat, _ yhi: CGFloat, _ proxy: ChartProxy) {
        var subKeys: [DrillKey] = []
        for cell in data.heatmapCells {
            guard let cx = proxy.position(forX: cell.x), let cy = proxy.position(forY: cell.y), let drill = cell.drill else { continue }
            if cx >= xlo, cx <= xhi, cy >= ylo, cy <= yhi { subKeys.append(drill) }
        }
        let merged = DrillMerge.merge(subKeys)
        if !merged.isEmpty { onDrill(merged) }
    }
```

- [ ] **Step 5: Pie ⌘-click multi-select** — track an accumulated selection; ⌘/⇧-click adds to it, a plain click resets to one. Drill the merged selection each time. `NSEvent.modifierFlags` needs AppKit — add `import AppKit` to `ChartView.swift` if it isn't already transitively available (build will tell you). In `pieChart`'s `onChange(of: pieSelection)`:
```swift
    @State private var pieSelected: [String] = []
    // ...
        .onChange(of: pieSelection) { _, newValue in
            guard let label = newValue else { return }
            let mods = NSEvent.modifierFlags
            if mods.contains(.command) || mods.contains(.shift) {
                if !pieSelected.contains(label) { pieSelected.append(label) }
            } else {
                pieSelected = [label]
            }
            let subKeys = pieSelected.compactMap { l in (data.series.first?.points ?? []).first(where: { $0.xLabel == l })?.drill }
            let merged = DrillMerge.merge(subKeys)
            if !merged.isEmpty { onDrill(merged) }
        }
```
(Pie point drills are single-column category keys, so `DrillMerge` unions them into one `.anyOf` — possibly with the sentinel if the null slice is included. Known limitation: in server-aggregation mode each ⌘-click spawns a fresh detail tab with the growing selection; note this in manual verification.)

- [ ] **Step 6: Build + manual verify** — `xcodegen generate && xcodebuild … build` → BUILD SUCCEEDED. Manually (Task V4) verify each gesture.

- [ ] **Step 7: Commit**
```bash
git add Pharos/ViewControllers/Charts/ChartView.swift Pharos/Models/Charts/ChartData.swift Pharos/Models/Charts/ChartAggregator.swift
git commit -m "feat(charts): series-precise tap, gantt overlap brush, heatmap rect brush, pie multi-select"
```

---

## Task C6: VC — scatter under server mode + server-drill parenthesization

**Files:** Modify `Pharos/ViewControllers/ContentViewController.swift` and `Pharos/ViewControllers/Charts/ChartRootView.swift`. Build-gated + manual.

Scatter now generates a push-down query, but the phase-3 gating (`chartTypeAggregates`) excludes scatter from server mode. Introduce a broader "supports server mode" notion (aggregating types **plus scatter**; gantt still excluded), request a large enough `limit` for the sample, and parenthesize each server-drill predicate.

- [ ] **Step 1: `chartTypeSupportsServer`** — add to `ChartViewModel` (in `ChartRootView.swift`) alongside `chartTypeAggregates`:
```swift
    /// Whether the chart type can use server mode: aggregating types, plus
    /// scatter (a deterministic sample). Gantt never pushes down.
    var chartTypeSupportsServer: Bool {
        config.chartType != .gantt
    }
```
Change `recompute()`'s server-skip guard and the `serverBanner` gate to use `chartTypeSupportsServer` instead of `chartTypeAggregates`:
```swift
        if config.serverAggregation && chartTypeSupportsServer { return }
```
and in `ChartRootView.body`/`serverBanner` guard: `if model.config.serverAggregation && model.chartTypeSupportsServer { serverBanner }`.

- [ ] **Step 2: VC gating** — in `ContentViewController.swift`, add a mirror helper and use it where `chartTypeAggregates(...)` gated server behavior:
```swift
    private func chartTypeSupportsServer(_ type: ChartType) -> Bool { type != .gantt }
```
In `applyDrill`, change the server branch condition from `chartTypeAggregates(cfg.chartType)` to `chartTypeSupportsServer(cfg.chartType)`. In `pushdownUnavailableReason`, drop `.scatter` from the "Not available for this chart type" case (leave only `.gantt`):
```swift
        switch cfg.chartType {
        case .gantt: return "Not available for this chart type."
        default: break
        }
```

- [ ] **Step 3: Scatter-aware limit** — in `performServerAggregation`, raise the requested limit to cover a scatter sample:
```swift
        let cap = max(SqlPushdownGenerator.groupCap, SqlPushdownGenerator.scatterSampleCap)
        let limit = max(Int32(stateManager.settings.query.defaultLimit), Int32(cap))
```

- [ ] **Step 4: Parenthesize server-drill predicates** — in `applyServerDrill`, wrap each predicate in parens so an OR-bearing `.anyOf` (sentinel split) composes correctly under `AND`:
```swift
        let predicate = keys
            .map { "(" + DrillSqlTranslator.predicate(for: $0, columns: columns) + ")" }
            .joined(separator: " AND ")
```

- [ ] **Step 5: "Sampled" provenance** — add `var sampled: Bool = false` to `LastServerRun` (in `ChartTypes.swift`) with a **tolerant** decoder (a phase-3 persisted `lastServerRun` blob lacks the key):
```swift
struct LastServerRun: Codable, Equatable {
    var sql: String
    var executedAt: String
    var rowCount: Int
    var truncated: Bool
    var sampled: Bool = false
    init(sql: String, executedAt: String, rowCount: Int, truncated: Bool, sampled: Bool = false) {
        self.sql = sql; self.executedAt = executedAt; self.rowCount = rowCount; self.truncated = truncated; self.sampled = sampled
    }
    enum CodingKeys: String, CodingKey { case sql, executedAt, rowCount, truncated, sampled }
    init(from d: Decoder) throws {
        let c = try d.container(keyedBy: CodingKeys.self)
        sql = try c.decodeIfPresent(String.self, forKey: .sql) ?? ""
        executedAt = try c.decodeIfPresent(String.self, forKey: .executedAt) ?? ""
        rowCount = try c.decodeIfPresent(Int.self, forKey: .rowCount) ?? 0
        truncated = try c.decodeIfPresent(Bool.self, forKey: .truncated) ?? false
        sampled = try c.decodeIfPresent(Bool.self, forKey: .sampled) ?? false
    }
}
```
In `performServerAggregation`, set `sampled` from the built data and show it in the banner. After `let data = ServerChartDataBuilder.build(...)`:
```swift
                    let lastRun = LastServerRun(
                        sql: sql,
                        executedAt: ISO8601DateFormatter().string(from: Date()),
                        rowCount: qr.rowCount,
                        truncated: qr.hasMore,
                        sampled: data.wasSampled
                    )
```
In `ChartRootView.ranSummary`, append the sampled note:
```swift
        if model.config.lastServerRun?.sampled == true { s += " \u{00B7} sampled" }
```

- [ ] **Step 6: Extend the ChartConfig legacy test** — append to `ChartConfigTests.runTests()` to lock the `LastServerRun.sampled` tolerant decode:
```swift
    // A phase-3 lastServerRun blob (no "sampled") still decodes (defaults false).
    let p3 = #"{"chartType":"bar","mappings":[],"aggregation":"count","temporalBin":"auto","numericBin":"auto","serverAggregation":true,"lastServerRun":{"sql":"SELECT 1","executedAt":"x","rowCount":3,"truncated":false},"display":{"title":"","showLegend":true,"stacked":false,"topNCategories":25}}"#
    let p3c = try! JSONDecoder().decode(ChartConfig.self, from: Data(p3.utf8))
    expect(p3c.lastServerRun?.sampled == false, "phase-3 lastServerRun defaults sampled=false")
```
Run `scripts/test-chart-config.sh` → PASS.

- [ ] **Step 7: Build + manual verify.** `xcodegen generate && xcodebuild … build` → BUILD SUCCEEDED.

- [ ] **Step 8: Commit**
```bash
git add Pharos/ViewControllers/ContentViewController.swift Pharos/ViewControllers/Charts/ChartRootView.swift Pharos/Models/Charts/ChartTypes.swift PharosTests/ChartConfigTests.swift
git commit -m "feat(charts): scatter under server mode (sampled), server-drill parens, sampled provenance"
```

---

# Phase V — Verification

## Task V1: All pure-logic harnesses green

- [ ] **Step 1: Run every chart harness**
```bash
for s in chart-config chart-aggregator column-classifier value-coercion drill-key drill-translator drill-sql drill-merge sql-pushdown server-chart-builder; do
  echo "== $s =="; scripts/test-$s.sh 2>&1 | tail -1
done
```
Expected: each prints `All tests passed.`

## Task V2: Clean app build

- [ ] **Step 1:** `xcodegen generate && xcodebuild -project Pharos.xcodeproj -scheme Pharos -configuration Debug build 2>&1 | tail -20` → `** BUILD SUCCEEDED **`. Confirm `BlanksSentinel.swift`, `DrillMerge.swift`, `DrillMergeTests.swift` (test files are not app targets, but `project.pbxproj` should include the two new app sources) are present.

## Task V3: Push-down SQL against real Postgres

- [ ] **Step 1:** Use the `verify` skill. For each generated query, run it by hand and compare:
  - **Scatter sample**: run the generated `ORDER BY hashtext(...) LIMIT` twice → identical point set (deterministic). If `(_pharos_src.*)::text` errors over the subquery alias, fall back to hashing the projected `_x||_y` (noted in the spec's risks) and re-verify.
  - **Heatmap per-axis top-N**: distinct X/Y each capped at `topNCategories`; ties don't materially overshoot; cells only from `(topX)×(topY)`.
  - **`.auto` bucket count**: `_n` ≈ `√rowcount` clamped 1…50; bucket bounds match the client for the same data.
  - **Heatmap numeric axis**: `width_bucket` bounds correct; both-axes-numeric (two range CTEs) parses and returns `_xlo/_xhi/_xn` + `_ylo/_yhi/_yn`; max value not in a phantom bucket (LEAST clamp); single-value axis → one bucket (lo=hi guard).

## Task V4: Manual GUI verification

- [ ] **Step 1:** Use the `verify` skill (GUI + Postgres):
  - **Scatter under push-down**: toggle on for a scatter chart → sampled points render; banner says "· sampled"; re-run reproduces the same points; brush → filtered detail tab with `WHERE "x" >= … AND "x" < …`.
  - **Heatmap numeric bins**: map a numeric X (and/or Y); independent X/Y bin controls on the rail change each axis separately; range labels render; rectangular brush over a **binned** axis filters the right ranges (not literal `"0–10"` labels); brush over a null bucket includes NULL rows.
  - **Gantt overlap brush**: drag across the pinned time axis on a **temporal** start/end gantt → detail includes bars that started *before* the window but were still active; repeat on a **numeric** start/end gantt → numeric literals, correct rows.
  - **Series-precise drill**: stacked-bar tap hits the correct series band (category AND series filtered); line/area tap picks the nearest series; grouped bar falls back to category-only.
  - **Pie ⌘-click**: ⌘/⇧-click accumulates slices (including the null slice) → merged selection drills all; plain click resets to one.
  - **Backward compat**: reopen a phase-1/2/3 workspace chart → config restores (empty `axisBins`, `sampled=false`), server-mode reopen still shows the explicit "Run…" state.

- [ ] **Step 2:** Commit any fixes; ready for `finishing-a-development-branch`.

---

## Notes for the implementer

- **Execution order:** B1 (`AxisBin`/`resolvedBin`) is a prerequisite for A4/A5/B2/B3 — do it first, then A2/A3 (scatter), then A4/A5 (heatmap top-N + `.auto`), then B2/B3/B4 (heatmap axes), then C1–C6 (interaction), then V1–V4. C6 (scatter under server mode) depends on A2/A3.
- **Pure vs UI boundary:** generators/builders/translators/merge/aggregator are Foundation-only, fully TDD'd; gestures, rail, async execution are build-gated + manually verified.
- **`project.pbxproj` is tracked** — run `xcodegen generate` and stage it whenever a task adds an app source file (`BlanksSentinel.swift`, `DrillMerge.swift`).
- **Single sentinel source of truth:** `PharosBlanks.sentinel`. `ColumnFilter`, `DrillMerge`, `DrillSqlTranslator` all reference it; never re-inline the literal.
- **The audit thesis holds:** scatter sampling is deterministic + labelled; every push-down run still records history (`source = "chart-aggregation"`) and persists `lastServerRun`; the generated SQL is copy-able and re-runnable.
- **Verify during implementation:** the `hashtext((_pharos_src.*)::text)` cast, the two-range-CTE heatmap SQL, and `dense_rank()` tie behavior against real Postgres — these are the spec's flagged risks.
