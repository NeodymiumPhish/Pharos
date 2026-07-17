# Query Result Charts (Phase 3) Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Add chart export (PNG/PDF/copy via `ImageRenderer`) and SQL push-down aggregation (a per-chart "Server aggregation" toggle that runs a generated `GROUP BY` over the full dataset; drill spawns a filtered detail query), with first-class provenance.

**Architecture:** Pure, testable SQL generation (`SqlPushdownGenerator`), result mapping (`ServerChartDataBuilder`), and drill predicates (`DrillSqlTranslator`) feed the same renderer-agnostic `ChartData`. Async execution, cancellation, `ImageRenderer`, and menus live in the VC/view layer. One small backend change: a `source` tag column on `query_history` so aggregation runs stay in the audit trail.

**Tech Stack:** Swift 5.10 / AppKit + SwiftUI (Swift Charts), macOS 15; Rust (`pharos-core`) + rusqlite over C FFI. Pure-logic tests via standalone `swiftc` harnesses.

**Reference spec:** `docs/superpowers/specs/2026-07-17-query-result-charts-phase3-design.md`

---

## Key conventions (read before starting)

- **No Xcode test target.** Pure logic tested by `swiftc` scripts (impl files + one `PharosTests/XxxTests.swift` + `PharosTests/main.swift`); each test file defines its own `runTests()`/`failures`/`expect`.
- **Chart model/logic files import only `Foundation`.** `SqlPushdownGenerator`, `ServerChartDataBuilder`, `DrillSqlTranslator` are Foundation-only (unlike phase-2's `DrillTranslator`, these don't touch `ColumnFilter`). `SQLSegmentParser` (`Pharos/Editor/`) is Foundation-only too.
- **`ResultTab.sql` is the substituted SQL** (post `{{var}}`, verified) — push-down wraps it directly.
- **Grid filters / phase-2 client drill are unchanged.** Push-down only changes how `ChartData` is produced and what a drill does when `serverAggregation` is on.
- **`executeQuery` records `query_history`** ([query.rs:206](../../pharos-core/src/commands/query.rs)) — keep that for push-down runs; tag via the new `source` column.
- **`project.pbxproj` is tracked** — stage it when `xcodegen` adds files. Build: `xcodegen generate && xcodebuild -project Pharos.xcodeproj -scheme Pharos -configuration Debug build 2>&1 | tail -20`. Rust: `cd pharos-core && cargo test`.
- Re-run all chart harnesses after changes.

---

## File Structure

**New (Foundation-only, `Pharos/Models/Charts/`):** `PushdownQuery.swift` (the `PushdownQuery`/`PushdownLayout` types — kept dependency-free so both the generator and the builder can include it without dragging in `SQLSegmentParser`), `SqlPushdownGenerator.swift`, `ServerChartDataBuilder.swift`, `DrillSqlTranslator.swift`.
**New (SwiftUI, `Pharos/ViewControllers/Charts/`):** `ChartExporter.swift`.
**Modified models/logic:** `ChartTypes.swift` (+`LastServerRun`), `ChartConfig.swift` (+`serverAggregation`, `lastServerRun`).
**Modified UI:** `ChartView.swift`/`ChartRootView.swift` (toggle, banner, loading/error, copy-SQL), `ChartHostingController.swift`, `ContentViewController.swift` (execution, drill, export menu, reopen).
**Modified export owner:** `ResultsCopyExport.swift` or `ContentViewController` (export-menu branch).
**Modified Rust:** `pharos-core/src/db/sqlite.rs`, `models/query_history.rs`, `commands/query.rs`, `ffi/query.rs`; Swift `PharosCore+Query.swift`.
**New tests + scripts:** `PharosTests/{SqlPushdownGeneratorTests,ServerChartDataBuilderTests,DrillSqlTranslatorTests}.swift`; extend `ChartConfigTests.swift`; `scripts/test-sql-pushdown.sh`, `test-server-chart-builder.sh`, `test-drill-sql.sh`.

---

# Phase A — Chart export

## Task 1: ChartExporter + export-menu integration

**Files:** Create `Pharos/ViewControllers/Charts/ChartExporter.swift`; modify the export-menu owner + `ContentViewController`.

Export is build-gated + manually verified (`ImageRenderer` doesn't run headless). Keep the *caption text* in a pure helper so it's testable.

- [ ] **Step 1: Pure caption helper + its test**

In `ChartExporter.swift` (top), a pure function; add a tiny harness test.
```swift
import SwiftUI

enum ChartExporter {
    /// Provenance caption rendered into exports (also embedded in metadata).
    static func caption(mode: String, connection: String, plotted: Int, total: Int,
                        truncated: Bool, timestamp: String) -> String {
        var s = "\(mode) · \(connection) · \(plotted) of \(total) rows · \(timestamp)"
        if truncated { s += " · truncated" }
        return s
    }
}
```
Add `PharosTests/ChartExporterTests.swift` + `scripts/test-chart-exporter.sh` (compile `ChartExporter.swift` alone — but note it `import SwiftUI`; if SwiftUI-in-harness is problematic, move `caption` to a Foundation-only `ChartExportCaption.swift` and test that). Assert caption format for client/server, truncated/not.

- [ ] **Step 2: Rendering API (build-gated)**

Add to `ChartExporter`:
```swift
    @MainActor static func png(of view: some View, size: CGSize, scale: CGFloat = 2) -> Data? {
        let r = ImageRenderer(content: view.frame(width: size.width, height: size.height))
        r.scale = scale
        guard let img = r.nsImage, let tiff = img.tiffRepresentation,
              let rep = NSBitmapImageRep(data: tiff) else { return nil }
        return rep.representation(using: .png, properties: [:])
    }

    @MainActor static func pdf(of view: some View, size: CGSize) -> Data? {
        let r = ImageRenderer(content: view.frame(width: size.width, height: size.height))
        let data = NSMutableData()
        r.render { sz, renderInContext in
            var box = CGRect(origin: .zero, size: sz)
            guard let consumer = CGDataConsumer(data: data as CFMutableData),
                  let ctx = CGContext(consumer: &box, mediaBox: &box, nil) else { return }
            ctx.beginPDFPage(nil); renderInContext(ctx); ctx.endPDFPage(); ctx.closePDF()
        }
        return data as Data
    }
```
(Embed the SQL/timestamp in PNG `tEXt` via `NSBitmapImageRep` properties or an `PNGProperties` dict, and in PDF `kCGPDFContextTitle`/keywords — adapt to what the SDK accepts; document the exact form used.)

- [ ] **Step 3: Export-menu branch + save panels (build-gated)**

In the export-menu owner (`ResultsCopyExport.showExportMenu` or a chart-aware wrapper in `ContentViewController`), when the active result is in **Chart mode**, present: "Export Chart as PNG…", "Export Chart as PDF…", "Copy Chart as Image", and (push-down only, added in Task 10) "View / Copy Generated SQL". Each renders `chartHost`'s current chart view (force **light** appearance via `.environment(\.colorScheme, .light)`; opaque background; include the caption footer) through `ChartExporter`, then `NSSavePanel` (default name from the result-tab label) or `NSPasteboard`. In Grid mode the menu is unchanged.
The chart host must expose the SwiftUI view (or a snapshot builder) + current size to the exporter.

- [ ] **Step 4: Build + manual verify**

`xcodegen generate && xcodebuild … build` → BUILD SUCCEEDED. Manually: export PNG/PDF/copy from a chart; confirm content, light background, retina, caption footer, and embedded metadata (open PNG `tEXt` / PDF properties).

- [ ] **Step 5: Commit**
```bash
git add Pharos/ViewControllers/Charts/ChartExporter.swift PharosTests/ChartExporterTests.swift scripts/test-chart-exporter.sh Pharos/ViewControllers/ContentViewController.swift Pharos/ViewControllers/ResultsGrid/ResultsCopyExport.swift Pharos.xcodeproj/project.pbxproj
git commit -m "feat(charts): chart export (PNG/PDF/copy) with provenance caption + metadata"
```

---

# Phase B — Push-down pure logic

## Task 2: ChartConfig — serverAggregation + lastServerRun

**Files:** Modify `Pharos/Models/Charts/ChartConfig.swift`; extend `PharosTests/ChartConfigTests.swift`.

- [ ] **Step 1: Failing tests**

Append to `ChartConfigTests.runTests()`:
```swift
    var sa = ChartConfig(chartType: .bar)
    sa.serverAggregation = true
    sa.lastServerRun = LastServerRun(sql: "SELECT 1", executedAt: "2026-07-17T00:00:00Z", rowCount: 5, truncated: false)
    let saData = try! JSONEncoder().encode(sa)
    let saBack = try! JSONDecoder().decode(ChartConfig.self, from: saData)
    expect(saBack.serverAggregation == true, "serverAggregation round-trips")
    expect(saBack.lastServerRun?.rowCount == 5, "lastServerRun round-trips")
    // legacy blob (no phase-3 keys) still decodes.
    let legacy = #"{"chartType":"bar","mappings":[],"aggregation":"sum","temporalBin":"auto","numericBin":"auto","display":{"title":"","showLegend":true,"stacked":false,"topNCategories":25}}"#
    let old = try! JSONDecoder().decode(ChartConfig.self, from: Data(legacy.utf8))
    expect(old.serverAggregation == false && old.lastServerRun == nil, "legacy config defaults phase-3 fields")
```

- [ ] **Step 2: Run `scripts/test-chart-config.sh` → FAIL.**

- [ ] **Step 3: Implement**

In `ChartTypes.swift` (or `ChartConfig.swift`) add:
```swift
struct LastServerRun: Codable, Equatable {
    var sql: String
    var executedAt: String
    var rowCount: Int
    var truncated: Bool
}
```
In `ChartConfig`: add `var serverAggregation: Bool` and `var lastServerRun: LastServerRun?`; extend the memberwise init (defaults `false`/`nil`); add both to `CodingKeys` and the tolerant `init(from:)` (`decodeIfPresent … ?? false` / `?? nil`).

- [ ] **Step 4: Run → PASS. Commit.**
```bash
git add Pharos/Models/Charts/ChartTypes.swift Pharos/Models/Charts/ChartConfig.swift PharosTests/ChartConfigTests.swift
git commit -m "feat(charts): serverAggregation + lastServerRun on ChartConfig"
```

---

## Task 3: SqlPushdownGenerator

**Files:** Create `Pharos/Models/Charts/SqlPushdownGenerator.swift`, `PharosTests/SqlPushdownGeneratorTests.swift`, `scripts/test-sql-pushdown.sh`.

- [ ] **Step 1: Failing tests** (`PharosTests/SqlPushdownGeneratorTests.swift`)

```swift
import Foundation

var failures = 0
func expect(_ c: Bool, _ n: String) { if c { print("PASS \(n)") } else { failures += 1; print("FAIL \(n)") } }
func contains(_ hay: String?, _ needle: String, _ n: String) { expect(hay?.contains(needle) == true, n + "  [\(hay ?? "nil")]") }

func runTests() {
    let cols = [ColumnDef(name: "status", dataType: "text"),
                ColumnDef(name: "amt", dataType: "numeric"),
                ColumnDef(name: "ts", dataType: "timestamptz"),
                ColumnDef(name: "age", dataType: "int4")]
    func cfg(_ t: ChartType, _ m: [ChartColumnRole: Int], _ agg: AggregationFn = .sum,
             tb: TemporalBin = .auto, nb: NumericBin = .auto) -> ChartConfig {
        var c = ChartConfig(chartType: t, aggregation: agg, temporalBin: tb); c.numericBin = nb
        for (r, i) in m { c.mappings[r] = ColumnRef(index: i, name: cols[i].name) }
        return c
    }
    let src = "SELECT status, amt, ts, age FROM t"

    // discrete bar, sum
    let bar = SqlPushdownGenerator.generate(cfg(.bar, [.category: 0, .value: 1], .sum), userSQL: src, columns: cols)
    contains(bar?.sql, #"GROUP BY "status""#, "bar groups by status")
    contains(bar?.sql, #"sum("amt")"#, "bar sum(amt)")
    contains(bar?.sql, "ORDER BY _val DESC", "top-N by value, not alphabetical")
    contains(bar?.sql, "LIMIT", "has LIMIT cap")

    // count needs no value
    let cnt = SqlPushdownGenerator.generate(cfg(.bar, [.category: 0], .count), userSQL: src, columns: cols)
    contains(cnt?.sql, "count(*)", "count(*) with no value mapping")

    // temporal timestamptz → date_trunc AT TIME ZONE UTC
    let ts = SqlPushdownGenerator.generate(cfg(.line, [.category: 2, .value: 1], .sum, tb: .month), userSQL: src, columns: cols)
    contains(ts?.sql, #"date_trunc('month', "ts" AT TIME ZONE 'UTC')"#, "timestamptz binned in UTC")

    // numeric width_bucket with clamp + lo=hi guard
    let num = SqlPushdownGenerator.generate(cfg(.bar, [.category: 3, .value: 1], .sum, nb: .b20), userSQL: src, columns: cols)
    contains(num?.sql, "width_bucket", "numeric uses width_bucket")
    contains(num?.sql, "LEAST(", "width_bucket clamped with LEAST")
    contains(num?.sql, "_r.lo = _r.hi", "single-bucket lo=hi guard")

    // heatmap groups by x,y
    let hm = SqlPushdownGenerator.generate(cfg(.heatmap, [.x: 0, .y: 2], .count), userSQL: src, columns: cols)
    contains(hm?.sql, "GROUP BY", "heatmap groups")
    contains(hm?.sql, "_x", "heatmap x alias")

    // identifier with a quote is escaped
    let weird = [ColumnDef(name: #"a"b"#, dataType: "text"), ColumnDef(name: "v", dataType: "numeric")]
    let esc = SqlPushdownGenerator.generate(cfg(.bar, [.category: 0, .value: 1]), userSQL: "SELECT 1", columns: weird)
    contains(esc?.sql, #""a""b""#, "identifier quote doubled")

    // unavailable: scatter, non-select, multi-statement
    expect(SqlPushdownGenerator.generate(cfg(.scatter, [.x: 1, .y: 3]), userSQL: src, columns: cols) == nil, "scatter → nil")
    expect(SqlPushdownGenerator.generate(cfg(.bar, [.category: 0, .value: 1]), userSQL: "UPDATE t SET x=1", columns: cols) == nil, "non-SELECT → nil")
    expect(SqlPushdownGenerator.generate(cfg(.bar, [.category: 0, .value: 1]), userSQL: "SELECT 1; SELECT 2", columns: cols) == nil, "multi-statement → nil")

    if failures == 0 { print("\nAll tests passed.") } else { print("\n\(failures) failure(s)."); exit(1) }
}
```

- [ ] **Step 2: Script** (`scripts/test-sql-pushdown.sh`)
```bash
#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")/.."
swiftc -o /tmp/sql-pushdown-tests \
  Pharos/Models/QueryResult.swift \
  Pharos/Models/Charts/ChartTypes.swift \
  Pharos/Models/Charts/ChartConfig.swift \
  Pharos/Models/Charts/ColumnClassifier.swift \
  Pharos/Models/Charts/ValueCoercion.swift \
  Pharos/Editor/SQLSegmentParser.swift \
  Pharos/Models/Charts/PushdownQuery.swift \
  Pharos/Models/Charts/SqlPushdownGenerator.swift \
  PharosTests/SqlPushdownGeneratorTests.swift \
  PharosTests/main.swift
/tmp/sql-pushdown-tests
```
`chmod +x`. (All Foundation-only.)

- [ ] **Step 3: Run → FAIL.**

- [ ] **Step 4: Create `PushdownQuery.swift` (shared types, Foundation-only, no deps)**

```swift
import Foundation

struct PushdownLayout {
    enum Kind { case categorical, heatmap }
    var kind: Kind
    var hasSeries: Bool
    var numericBins: Int?     // set when the category/x axis is width_bucketed
    // aliases are fixed: categorical → _cat[, _series], _val (+ _lo,_hi for numeric)
    //                    heatmap     → _x, _y, _val
}
struct PushdownQuery { var sql: String; var layout: PushdownLayout }
```

- [ ] **Step 5: Implement `SqlPushdownGenerator.swift`**

```swift
import Foundation

enum SqlPushdownGenerator {
    static let groupCap = 1000

    static func generate(_ config: ChartConfig, userSQL: String, columns: [ColumnDef]) -> PushdownQuery? {
        // Only aggregating types.
        switch config.chartType { case .scatter, .gantt: return nil; default: break }
        guard isSingleSelect(userSQL) else { return nil }
        let agg = aggExpr(config, columns: columns)
        guard agg != nil else { return nil }   // non-count needs a value col

        switch config.chartType {
        case .heatmap: return heatmap(config, userSQL: userSQL, columns: columns, agg: agg!)
        default:       return categorical(config, userSQL: userSQL, columns: columns, agg: agg!)
        }
    }

    // MARK: helpers
    static func quoteIdent(_ s: String) -> String { "\"" + s.replacingOccurrences(of: "\"", with: "\"\"") + "\"" }

    private static func isSingleSelect(_ sql: String) -> Bool {
        let segs = SQLSegmentParser.parse(sql).filter { !$0.text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }
        guard segs.count == 1 else { return false }
        let t = segs[0].text.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        return t.hasPrefix("select") || t.hasPrefix("with")
    }

    private static func resolve(_ config: ChartConfig, _ role: ChartColumnRole, _ columns: [ColumnDef]) -> ColumnDef? {
        guard let ref = config.mappings[role], ref.index < columns.count else { return nil }
        // Ambiguity guard: the mapped name must be unique in the projection.
        if columns.filter({ $0.name == ref.name }).count > 1 { return nil }
        return columns[ref.index]
    }

    private static func aggExpr(_ config: ChartConfig, columns: [ColumnDef]) -> String? {
        if config.aggregation == .count || config.mappings[.value] == nil { return "count(*)" }
        guard let v = resolve(config, .value, columns) else { return nil }
        let c = quoteIdent(v.name)
        switch config.aggregation {
        case .sum: return "sum(\(c))"; case .avg: return "avg(\(c))"
        case .min: return "min(\(c))"; case .max: return "max(\(c))"; case .count: return "count(*)"
        }
    }

    /// Binning expression for an axis column + the numeric bin count if applied.
    private static func axisExpr(_ config: ChartConfig, _ col: ColumnDef) -> (expr: String, numericBins: Int?) {
        let kind = ColumnClassifier.kind(forDataType: col.dataType)
        let id = quoteIdent(col.name)
        if kind == .temporal, config.temporalBin != .none {
            let unit = truncUnit(config.temporalBin)
            let tz = col.dataType.lowercased().hasPrefix("timestamptz") || col.dataType.lowercased().contains("with time zone")
            let colExpr = tz ? "\(id) AT TIME ZONE 'UTC'" : id
            return ("date_trunc('\(unit)', \(colExpr))", nil)
        }
        if kind == .numeric, let n = binCount(config.numericBin) {
            return (id, n)   // width_bucket handled at query assembly (needs the range CTE)
        }
        return (id, nil)
    }
    private static func truncUnit(_ b: TemporalBin) -> String {
        switch b { case .hour: return "hour"; case .day, .auto: return "day"; case .week: return "week"
                   case .month: return "month"; case .year: return "year"; case .none: return "day" }
    }
    private static func binCount(_ b: NumericBin) -> Int? {
        switch b { case .off: return nil; case .b10: return 10; case .b20: return 20; case .b50: return 50; case .auto: return 20 }
    }

    private static func categorical(_ config: ChartConfig, userSQL: String, columns: [ColumnDef], agg: String) -> PushdownQuery? {
        guard let catCol = resolve(config, .category, columns) else { return nil }
        let series = resolve(config, .series, columns)
        let (catExpr, nbins) = axisExpr(config, catCol)
        let layout = PushdownLayout(kind: .categorical, hasSeries: series != nil, numericBins: nbins)

        if let n = nbins {   // numeric width_bucket needs the range CTE
            let id = quoteIdent(catCol.name)
            let sql = """
            WITH _pharos_src AS ( \(userSQL) ),
                 _r AS (SELECT min(\(id)) lo, max(\(id)) hi FROM _pharos_src)
            SELECT CASE WHEN _r.lo = _r.hi THEN 1
                        ELSE LEAST(width_bucket(\(id), _r.lo, _r.hi, \(n)), \(n)) END AS _bucket,
                   _r.lo AS _lo, _r.hi AS _hi, \(agg) AS _val
            FROM _pharos_src, _r GROUP BY _bucket, _r.lo, _r.hi ORDER BY _bucket LIMIT \(groupCap)
            """
            return PushdownQuery(sql: sql, layout: layout)
        }
        let seriesSel = series.map { ", \(quoteIdent($0.name)) AS _series" } ?? ""
        let seriesGrp = series.map { ", \(quoteIdent($0.name))" } ?? ""
        let sql = """
        SELECT \(catExpr) AS _cat\(seriesSel), \(agg) AS _val
        FROM ( \(userSQL) ) AS _pharos_src
        GROUP BY \(catExpr)\(seriesGrp)
        ORDER BY _val DESC LIMIT \(groupCap)
        """
        return PushdownQuery(sql: sql, layout: layout)
    }

    private static func heatmap(_ config: ChartConfig, userSQL: String, columns: [ColumnDef], agg: String) -> PushdownQuery? {
        guard let xCol = resolve(config, .x, columns), let yCol = resolve(config, .y, columns) else { return nil }
        let (xExpr, _) = axisExpr(config, xCol)     // heatmap numeric-axis binning deferred (phase-2 parity)
        let (yExpr, _) = axisExpr(config, yCol)
        let sql = """
        SELECT \(xExpr) AS _x, \(yExpr) AS _y, \(agg) AS _val
        FROM ( \(userSQL) ) AS _pharos_src
        GROUP BY \(xExpr), \(yExpr)
        ORDER BY _val DESC LIMIT \(groupCap)
        """
        return PushdownQuery(sql: sql, layout: PushdownLayout(kind: .heatmap, hasSeries: false, numericBins: nil))
    }
}
```
Note the heatmap axis binning: temporal via `date_trunc`, numeric axis stays discrete (consistent with phase 2's deferred heatmap numeric binning). Adjust if a test demands otherwise.

- [ ] **Step 6: Run → PASS.** Fix until green.

- [ ] **Step 7: Commit**
```bash
git add Pharos/Models/Charts/PushdownQuery.swift Pharos/Models/Charts/SqlPushdownGenerator.swift PharosTests/SqlPushdownGeneratorTests.swift scripts/test-sql-pushdown.sh
git commit -m "feat(charts): SqlPushdownGenerator (GROUP BY wrap, binning, top-N, safety)"
```

---

## Task 4: ServerChartDataBuilder

**Files:** Create `Pharos/Models/Charts/ServerChartDataBuilder.swift`, `PharosTests/ServerChartDataBuilderTests.swift`, `scripts/test-server-chart-builder.sh`.

- [ ] **Step 1: Failing test** — build `ChartData` from a synthetic aggregated `QueryResult` (all cells strings, as from the FFI).

Cover: categorical `_cat,_val` → one series of points with `.anyOf` drill keys; series `_cat,_series,_val` → multi-series; numeric `_bucket,_lo,_hi,_val` → range-labelled points with `.range` drill + ascending order; heatmap `_x,_y,_val` → cells with `.compound` drill; `hasMore == true` → `wasTruncated`. (Mirror the aggregator's `ChartData` shape.)

- [ ] **Step 2: Script** — compile `QueryResult.swift`, `ChartTypes.swift`, `ChartConfig.swift`, `ColumnClassifier.swift`, `ChartData.swift`, `DrillKey.swift`, `ValueCoercion.swift`, `PushdownQuery.swift`, `ServerChartDataBuilder.swift`, the test, `main.swift`. `chmod +x`. (All Foundation-only; `PushdownQuery.swift` supplies `PushdownLayout`; `ChartConfig`/`ColumnClassifier` support the `config` arg.)

- [ ] **Step 3: Run → FAIL.**

- [ ] **Step 4: Implement** `ServerChartDataBuilder.build(_ result: QueryResult, layout: PushdownLayout, config: ChartConfig) -> ChartData`:
  - Locate output columns by the fixed aliases (`_cat/_series/_val`, `_bucket/_lo/_hi/_val`, `_x/_y/_val`).
  - Categorical (non-numeric): each row → `ChartPoint(xLabel: displayString(_cat), y: double(_val), drill: .anyOf(catRef,[raw]))` (null `_cat` → `.blank`); group by `_series` into `ChartSeries` when present.
  - Numeric: from `_bucket`, `_lo`, `_hi`, `N` (= `layout.numericBins`) compute width = `(_hi-_lo)/N`, bucket range `[lo+(_bucket-1)*w, lo+_bucket*w)`, `drill: .range(catRef, lo, hi, .numeric)`; emit in `_bucket` order. Label with a **local** `"\(fmt(lo))–\(fmt(hi))"` helper (en-dash, Int-or-2dp) — replicate the format rather than call `ChartAggregator`'s `private binRangeLabel` (keep the builder self-contained; the format is trivial and asserted by the test).
  - Heatmap: each row → `HeatmapCell(x,y,value, drill: .compound([.anyOf(xRef,[x]), .anyOf(yRef,[y])]))` (null axis → `.blank`).
  - Set `plottedRowCount`, `totalLoadedRowCount = result.rowCount`, `wasTruncated = result.hasMore`.
  - The `catRef`/`xRef`/`yRef` come from `config.mappings` (index+name) so drill keys carry the real column.

- [ ] **Step 5: Run → PASS. Commit.**
```bash
git add Pharos/Models/Charts/ServerChartDataBuilder.swift PharosTests/ServerChartDataBuilderTests.swift scripts/test-server-chart-builder.sh
git commit -m "feat(charts): ServerChartDataBuilder (aggregated rows -> ChartData + drill keys)"
```

---

## Task 5: DrillSqlTranslator

**Files:** Create `Pharos/Models/Charts/DrillSqlTranslator.swift`, `PharosTests/DrillSqlTranslatorTests.swift`, `scripts/test-drill-sql.sh`.

- [ ] **Step 1: Failing test** — Foundation-only (produces SQL strings, not `ColumnFilter`).

Assert: `.anyOf(status,["a","b"]) → "status" IN ('a', 'b')`; escaping `.anyOf(status,["O'Brien"]) → 'O''Brien'`; `.blank → "status" IS NULL`; numeric `.range(age,10,20) → "age" >= 10 AND "age" < 20` (half-open, locale-independent); temporal `.range` → UTC ISO bounds with `>=`/`<`; `.compound → (p1) AND (p2)`.

- [ ] **Step 2: Script** — compile `QueryResult.swift`, `ChartTypes.swift`, `DrillKey.swift`, `DrillSqlTranslator.swift`, test, `main.swift`. `chmod +x`.

- [ ] **Step 3: Run → FAIL.**

- [ ] **Step 4: Implement**
```swift
import Foundation

enum DrillSqlTranslator {
    static func predicate(for key: DrillKey, columns: [ColumnDef]) -> String {
        switch key {
        case .anyOf(let ref, let vals):
            let list = vals.map { "'" + $0.replacingOccurrences(of: "'", with: "''") + "'" }.joined(separator: ", ")
            return "\(ident(ref)) IN (\(list))"
        case .blank(let ref):
            return "\(ident(ref)) IS NULL"
        case .range(let ref, let lo, let hi, let kind):
            let (l, h) = bounds(lo, hi, kind)
            return "\(ident(ref)) >= \(l) AND \(ident(ref)) < \(h)"
        case .compound(let keys):
            return keys.map { "(" + predicate(for: $0, columns: columns) + ")" }.joined(separator: " AND ")
        }
    }
    private static func ident(_ ref: ColumnRef) -> String { "\"" + ref.name.replacingOccurrences(of: "\"", with: "\"\"") + "\"" }
    private static func bounds(_ lo: Double, _ hi: Double, _ kind: RangeKind) -> (String, String) {
        switch kind {
        case .numeric:
            func n(_ d: Double) -> String { d == d.rounded() ? String(Int(d)) : String(d) }
            return (n(lo), n(hi))
        case .temporal:
            let f = DateFormatter(); f.locale = Locale(identifier: "en_US_POSIX"); f.timeZone = TimeZone(identifier: "UTC")
            f.dateFormat = "yyyy-MM-dd HH:mm:ss"
            func t(_ e: Double) -> String { "'" + f.string(from: Date(timeIntervalSince1970: e)) + "'" }
            return (t(lo), t(hi))
        }
    }
}
```

- [ ] **Step 5: Run → PASS. Commit.**
```bash
git add Pharos/Models/Charts/DrillSqlTranslator.swift PharosTests/DrillSqlTranslatorTests.swift scripts/test-drill-sql.sh
git commit -m "feat(charts): DrillSqlTranslator (drill keys -> SQL WHERE predicates)"
```

---

# Phase B′ — History source tag (Rust/SQLite)

## Task 6: `source` column on query_history + threaded through execute

**Files:** `pharos-core/src/db/sqlite.rs`, `models/query_history.rs`, `commands/query.rs`, `ffi/query.rs`; `Pharos/Core/PharosCore+Query.swift`.

- [ ] **Step 1: Failing in-file Rust test**

In `sqlite.rs`, add a `#[cfg(test)]` test that inserts a `QueryHistoryEntry` with `source = Some("chart-aggregation")` via `save_query_history`, reads it back, asserts the column round-trips. Use `chrono::Utc::now()` timestamps.

- [ ] **Step 2: Run `cd pharos-core && cargo test` → FAIL (no `source`).**

- [ ] **Step 3: Migration + model + save**
- `sqlite.rs`: add a guarded migration `ALTER TABLE query_history ADD COLUMN source TEXT;` (pragma_table_info pattern, near the other history migrations). Include `source` in the `INSERT` in `save_query_history` and in the `QueryHistoryEntry` read path(s) / load queries (select it, default NULL).
- `models/query_history.rs`: add `#[serde(skip_serializing_if = "Option::is_none")] pub source: Option<String>,`.
- `commands/query.rs`: `execute_query` accepts an optional `source: Option<String>` and sets it on the `QueryHistoryEntry` it saves (default `None` for normal queries).

- [ ] **Step 4: FFI + Swift param**
- `ffi/query.rs`: add a `source` `*const c_char` param to `pharos_execute_query` (optional; NULL = none), pass through to `execute_query`. `cargo build --release` regenerates the header.
- `Pharos/Core/PharosCore+Query.swift`: add `source: String? = nil` to `executeQuery(...)`, thread it through `withOptionalCString`.

- [ ] **Step 5: Run `cargo test` → PASS; `cargo build --release` clean. Commit.**
```bash
git add pharos-core/src/db/sqlite.rs pharos-core/src/models/query_history.rs pharos-core/src/commands/query.rs pharos-core/src/ffi/query.rs Pharos/Core/PharosCore+Query.swift
git add -A pharos-core   # regenerated header if tracked
git commit -m "feat(charts): query_history.source tag + executeQuery source param"
```

---

# Phase C — Push-down integration

## Task 7: Rail toggle, availability, banner, loading/error, copy-SQL

**Files:** `ChartRootView.swift`, `ChartView.swift`, `ChartHostingController.swift`.

- [ ] **Step 1: View-model state + toggle**
- `ChartViewModel`: add `@Published var serverLoading = false`, `@Published var serverError: String?`, and a way to inject server-built `ChartData` (`func setServerData(_ d: ChartData)`), plus `var pushdownAvailable: Bool` + `var pushdownUnavailableReason: String?` (computed by the host/VC and set in).
- `ChartRootView` rail: a **"Server aggregation"** `Toggle` bound to `config.serverAggregation` via `model.update`, shown only when `pushdownAvailable` (else a disabled row with the reason). Aggregating types only.
- Banner: when `serverAggregation` on, show "Aggregated server-side over the full dataset, as of &lt;lastServerRun.executedAt&gt;" (+ truncation note); loading spinner while `serverLoading`; error text on `serverError`.
- Add a **"Copy Generated SQL"** button (enabled when a pushdown query exists) calling back to the host.

- [ ] **Step 2: Build** → BUILD SUCCEEDED (wiring the callbacks is Task 8/9).

- [ ] **Step 3: Commit** (`feat(charts): server-aggregation rail toggle, banner, loading/error, copy-SQL`).

## Task 8: VC push-down execution (async, debounced, cancel, source, lastServerRun, reopen)

**Files:** `ContentViewController.swift`, `ChartHostingController.swift`.

- [ ] **Step 1: Availability + generation**
- Compute pushdown availability for the active result: chart type aggregating; `SqlPushdownGenerator.generate(config, userSQL: resultTab.sql, columns:)` returns non-nil. Push availability + reason into the view model.

- [ ] **Step 2: Execution path**
- When `serverAggregation` is on and available, on (debounced) config change: generate the query, set `serverLoading`, run `PharosCore.executeQuery(connectionId:, sql: pushdown.sql, queryId: <new>, limit: max(defaultLimit, SqlPushdownGenerator.groupCap), source: "chart-aggregation")`. On success: `ServerChartDataBuilder.build(...)` → `model.setServerData(...)`, set `lastServerRun`, persist config (debounced, via the phase-1 `updateResultChartState` path). On error: `serverError`.
- **Cancellation:** track the in-flight `queryId`; on a new config change / toggle-off / tab switch / close, call `PharosCore.cancelQuery(...)` for the superseded id and ignore its result (last-write-wins).
- Toggle-off restores the client-side path (existing `presentChart` recompute).

- [ ] **Step 3: Reopen = explicit run**
- On workspace reopen with `serverAggregation` on: do NOT auto-run. Show the "Run server aggregation (last run &lt;lastServerRun.executedAt&gt;)" state (a button in the banner) that triggers Step 2. If `lastServerRun` exists, show its summary.

- [ ] **Step 4: Copy Generated SQL**
- Wire the rail's copy-SQL callback to put `pushdown.sql` on the pasteboard.

- [ ] **Step 5: Build + manual verify.** Commit (`feat(charts): push-down execution with cancellation, source tag, lastServerRun, explicit reopen`).

## Task 9: VC push-down drill → spawn detail query

**Files:** `ContentViewController.swift`.

- [ ] **Step 1:** In the drill handler (`applyDrill` from phase 2), branch on `config.serverAggregation`:
  - **off** → phase-2 path (`DrillTranslator` → grid filter + chip).
  - **on** → `DrillSqlTranslator.predicate(for: key, columns:)` for each key, `AND`-join, build `SELECT * FROM ( <resultTab.sql> ) AS _pharos_src WHERE <predicate>`, and run it through the existing `executeQuery(_ sql:)` entry as a **new result tab** (records history for the trail).
- [ ] **Step 2: Build + manual verify.** Commit (`feat(charts): push-down drill spawns filtered detail query`).

## Task 10: Export menu — push-down "View/Copy Generated SQL"

- [ ] Add the "View / Copy Generated SQL" item to the chart export menu (Task 1 Step 3) when `serverAggregation` is on. Build + commit (may fold into Task 8's copy-SQL if simpler).

---

## Task 11: Full verification

- [ ] **Step 1: All harnesses**
```bash
for s in chart-config chart-aggregator column-classifier value-coercion drill-key drill-translator sql-pushdown server-chart-builder drill-sql chart-exporter; do scripts/test-$s.sh 2>&1 | tail -1; done
```
Expected: each "All tests passed."

- [ ] **Step 2: Rust** — `cd pharos-core && cargo test` (incl. the `source` round-trip) → all pass.

- [ ] **Step 3: Clean app build** → `** BUILD SUCCEEDED **`.

- [ ] **Step 4: Manual (GUI + Postgres)** — use the `verify` skill:
  - Export PNG/PDF/copy (content, light bg, retina, caption + embedded metadata); copy-generated-SQL re-runs verbatim.
  - Push-down chart matches a hand-run GROUP BY: temporal boundary at UTC; numeric max not in a phantom bucket; single-value column single bucket; top-N by value; heatmap; series; count-only (no value).
  - Loading/error states; superseded config change actually cancels the prior query (watch server / no stale result).
  - Toggle hidden/disabled for scatter/gantt and non-SELECT/multi-statement SQL.
  - Push-down drill spawns the correct `SELECT * … WHERE …` as a new result tab and it appears in history.
  - History browser shows chart-aggregation rows tagged (`source`).
  - Reopen a workspace with the toggle on → explicit "Run (last run …)" state, one click re-runs; `lastServerRun` shown.
  - Backward compat: reopen a phase-1/2 workspace chart config → still restores.

- [ ] **Step 5:** Commit any fixes; ready for `finishing-a-development-branch`.

---

## Notes for the implementer

- **Execution order:** A (export) → B (Tasks 2–5 pure logic, TDD) → B′ (Task 6 Rust) → C (Tasks 7–10 integration). Task 6 must land before Task 8 uses the `source` param.
- **Pure vs UI boundary:** generator/builder/translator are Foundation-only and fully unit-tested; async execution/cancel/`ImageRenderer`/menus are build-gated + manually verified.
- **`project.pbxproj` is tracked** — stage it whenever `xcodegen` adds source files (Tasks 1, 3, 4, 5 add files).
- **Provenance is the point of this phase** — do NOT suppress push-down history; keep + tag it, persist `lastServerRun`, embed export metadata, and keep reopen explicit. These were the review's central asks.
- **Verify during implementation:** `ResultTab.sql` is substituted (confirmed); `executeQuery` with a large `limit` returns all groups (`hasMore` = truncation); PNG `tEXt` / PDF metadata embedding form against the SDK.
