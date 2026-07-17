# Query Result Charts (Phase 2) Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Add heatmap charts, numeric/histogram binning, and chart drill-down (click/brush a mark → filter the result grid to those rows) to the phase-1 charting feature.

**Architecture:** Extend the pure aggregator to bin numeric axes and produce heatmap cells, and to attach a `DrillKey` to every mark. A pure `DrillTranslator` turns drill keys into grid `ColumnFilter`s keyed by `col_N`. The SwiftUI layer renders heatmaps and reports gesture selections; `ContentViewController` applies the filters, switches to Grid, and shows a clearable chip. No new Rust/SQLite surface.

**Tech Stack:** Swift 5.10 / AppKit + SwiftUI (Swift Charts), macOS 15. Pure-logic tests via standalone `swiftc` harnesses in `PharosTests/`.

**Reference spec:** `docs/superpowers/specs/2026-07-17-query-result-charts-phase2-design.md`

---

## Key conventions (read before starting)

- **No Xcode test target.** Pure logic is tested by `swiftc` scripts under `scripts/` compiling the impl file(s) + one `PharosTests/XxxTests.swift` + `PharosTests/main.swift`. Each test file defines its own top-level `runTests()`/`failures`/`expect`; each script compiles exactly one test file.
- **Chart model + logic files import only `Foundation`** (so they compile in the harness) — EXCEPT the `DrillTranslator` test, which needs `ColumnFilter`/`PGTypeCategory` (both AppKit) and therefore `import AppKit` and includes those files; it still runs headless (value types only).
- **New app source files require `xcodegen generate`** before the app build sees them. `Pharos.xcodeproj/project.pbxproj` is TRACKED — stage it in the commit that adds files.
- **All query-result values arrive as JSON strings** (PG text). Coerce via `ValueCoercion`.
- **Grid filters are keyed by `"col_\(index)"`, NOT column name** (`colIndex(from:)` in `ResultsGridVC.swift`). A name-keyed filter is silently skipped. Every drill filter MUST be keyed `col_N`.
- **`ColumnFilter`** (`Pharos/Utilities/ColumnFilter.swift`) fields: `columnName, op: FilterOperator, value: String, value2: String?, values: [String]?, dataType: String`. Category drills use `.isAnyOf` (exact/case-sensitive on `displayString`, honors `ColumnFilter.blanksSentinel` for nulls). Ranges use `.between` (inclusive, lexicographic for temporal).
- **Build the app** with `xcodegen generate && xcodebuild -project Pharos.xcodeproj -scheme Pharos -configuration Debug build 2>&1 | tail -20`.
- Run all chart harnesses after changes: `scripts/test-chart-*.sh scripts/test-*coercion*.sh` etc.

---

## File Structure

**New (Foundation-only, `Pharos/Models/Charts/`):**
- `DrillKey.swift` — `DrillKey` enum + `RangeKind`.
- `DrillTranslator.swift` — `DrillKey` → `(columnId, ColumnFilter)` (uses `ColumnFilter`; see harness note).

**Modified (models/logic):**
- `ChartTypes.swift` — add `ChartType.heatmap`; add `NumericBin`.
- `ChartConfig.swift` — add `numericBin`; add tolerant `init(from:)`.
- `ChartData.swift` — add `drill: DrillKey?` to `ChartPoint`; add `HeatmapCell` + `heatmapCells`.
- `ChartAggregator.swift` — numeric binning, relaxed count guard, low-cardinality escape, `DrillKey` emission, week-label fix, heatmap aggregation.

**Modified (UI):**
- `ChartView.swift` — heatmap rendering; drill gesture overlay; pie `chartAngleSelection`; scatter callout.
- `ChartRootView.swift` — numeric Bins rail control; heatmap roles; chart-type-aware eligibility; `onDrill` wiring.
- `ChartHostingController.swift` — forward `onDrill`.
- `ContentViewController.swift` — apply drill filters (snapshot/restore), switch to Grid, drill chip.

**New tests + scripts:** `PharosTests/DrillKeyTests.swift`, `DrillTranslatorTests.swift`; extend `ChartConfigTests.swift`, `ChartAggregatorTests.swift`; `scripts/test-drill-key.sh`, `scripts/test-drill-translator.sh`.

---

# Phase 2A — Numeric binning + fixes + DrillKey model

## Task 1: DrillKey model

**Files:** Create `Pharos/Models/Charts/DrillKey.swift`, `PharosTests/DrillKeyTests.swift`, `scripts/test-drill-key.sh`.

- [ ] **Step 1: Write the failing test**

`PharosTests/DrillKeyTests.swift`:

```swift
// Standalone test for DrillKey. Compiled with ChartTypes.swift + DrillKey.swift.
import Foundation

var failures = 0
func expect(_ c: Bool, _ n: String) { if c { print("PASS \(n)") } else { failures += 1; print("FAIL \(n)") } }

func runTests() {
    let ref = ColumnRef(index: 2, name: "status")
    let a = DrillKey.anyOf(ref, ["done", "open"])
    let b = DrillKey.blank(ref)
    let r = DrillKey.range(ColumnRef(index: 0, name: "age"), 10, 20, .numeric)
    let c = DrillKey.compound([a, b])

    expect(a.columnRefs == [ref], "anyOf exposes its ref")
    expect(c.columnRefs.count == 2, "compound exposes child refs")
    if case .range(_, let lo, let hi, let kind) = r { expect(lo == 10 && hi == 20 && kind == .numeric, "range payload") }
    else { expect(false, "range payload") }

    if failures == 0 { print("\nAll tests passed.") } else { print("\n\(failures) failure(s)."); exit(1) }
}
```

- [ ] **Step 2: Script** — `scripts/test-drill-key.sh`:

```bash
#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")/.."
swiftc -o /tmp/drill-key-tests \
  Pharos/Models/Charts/ChartTypes.swift \
  Pharos/Models/Charts/DrillKey.swift \
  PharosTests/DrillKeyTests.swift \
  PharosTests/main.swift
/tmp/drill-key-tests
```
`chmod +x scripts/test-drill-key.sh`

- [ ] **Step 3: Run — expect FAIL** (`cannot find 'DrillKey'`).

- [ ] **Step 4: Implement `DrillKey.swift`:**

```swift
import Foundation

/// Whether a range drill is over numeric values or temporal instants (epoch seconds).
enum RangeKind: String, Codable, Equatable { case numeric, temporal }

/// How to filter the source rows a chart mark represents. Carries a ColumnRef
/// (index authoritative) so the translator can key grid filters by "col_<index>".
enum DrillKey: Equatable {
    /// Exact category match(es) on one column (case-sensitive displayString).
    case anyOf(ColumnRef, [String])
    /// The null / empty-cell mark on one column.
    case blank(ColumnRef)
    /// A numeric or temporal range on one column. For temporal, lo/hi are epoch seconds.
    case range(ColumnRef, Double, Double, RangeKind)
    /// Multiple keys ANDed across columns (e.g. a heatmap cell = X and Y).
    case compound([DrillKey])

    /// All column refs this key touches (for chip labels / dedup).
    var columnRefs: [ColumnRef] {
        switch self {
        case .anyOf(let r, _), .blank(let r): return [r]
        case .range(let r, _, _, _): return [r]
        case .compound(let keys): return keys.flatMap { $0.columnRefs }
        }
    }
}
```

- [ ] **Step 5: Run — expect PASS.**

- [ ] **Step 6: Commit:**
```bash
git add Pharos/Models/Charts/DrillKey.swift PharosTests/DrillKeyTests.swift scripts/test-drill-key.sh
git commit -m "feat(charts): DrillKey model for drill-down"
```

---

## Task 2: NumericBin + tolerant ChartConfig decoder

**Files:** Modify `ChartTypes.swift`, `ChartConfig.swift`; extend `PharosTests/ChartConfigTests.swift`.

- [ ] **Step 1: Add failing tests to `ChartConfigTests.swift`**

Append inside `runTests()`:

```swift
    // numericBin round-trips.
    var nb = ChartConfig(chartType: .bar)
    nb.numericBin = .b20
    let nbData = try! JSONEncoder().encode(nb)
    expect(try! JSONDecoder().decode(ChartConfig.self, from: nbData).numericBin == .b20, "numericBin round-trips")

    // Backward compat: a phase-1 blob WITHOUT numericBin decodes with .auto default.
    let legacy = #"{"chartType":"bar","mappings":{},"aggregation":"sum","temporalBin":"auto","display":{"title":"","showLegend":true,"stacked":false,"topNCategories":25}}"#
    let old = try! JSONDecoder().decode(ChartConfig.self, from: Data(legacy.utf8))
    expect(old.numericBin == .auto, "legacy config defaults numericBin to .auto")
    expect(old.chartType == .bar, "legacy config still decodes chartType")

    // heatmap is a valid chart type.
    expect(ChartType(rawValue: "heatmap") == .heatmap, "heatmap chart type decodes")
```

- [ ] **Step 2: Run `scripts/test-chart-config.sh` — expect FAIL** (`numericBin` / `.heatmap` unknown).

- [ ] **Step 3: Add `ChartType.heatmap` + `NumericBin` in `ChartTypes.swift`**

In `ChartType`, add `heatmap` to the case list and `displayName`:
```swift
enum ChartType: String, Codable, CaseIterable {
    case bar, line, area, scatter, pie, gantt, heatmap
    var displayName: String {
        switch self {
        case .bar: return "Bar"
        case .line: return "Line"
        case .area: return "Area"
        case .scatter: return "Scatter"
        case .pie: return "Pie"
        case .gantt: return "Gantt"
        case .heatmap: return "Heatmap"
        }
    }
}
```
Add after `TemporalBin`:
```swift
/// Numeric-axis binning. `.off` = discrete categories; `.auto` = data-driven
/// count (subject to a low-cardinality escape); fixed counts otherwise.
/// (Uses `.off`, not `.none` like TemporalBin — see the phase-2 spec's naming note.)
enum NumericBin: String, Codable, CaseIterable {
    case off, auto, b10 = "10", b20 = "20", b50 = "50"
    var displayName: String {
        switch self { case .off: return "Off"; case .auto: return "Auto"; default: return rawValue }
    }
}
```

- [ ] **Step 4: Add `numericBin` + tolerant decoder to `ChartConfig.swift`**

Add the stored property and a custom `init(from:)`. Full struct head:
```swift
struct ChartConfig: Codable, Equatable {
    var chartType: ChartType
    var mappings: [ChartColumnRole: ColumnRef]
    var aggregation: AggregationFn
    var temporalBin: TemporalBin
    var numericBin: NumericBin
    var display: ChartDisplayOptions

    init(chartType: ChartType,
         mappings: [ChartColumnRole: ColumnRef] = [:],
         aggregation: AggregationFn = .sum,
         temporalBin: TemporalBin = .auto,
         numericBin: NumericBin = .auto,
         display: ChartDisplayOptions = ChartDisplayOptions()) {
        self.chartType = chartType
        self.mappings = mappings
        self.aggregation = aggregation
        self.temporalBin = temporalBin
        self.numericBin = numericBin
        self.display = display
    }

    // Tolerant decode: every field decodeIfPresent with a default, so phase-1
    // blobs (no numericBin) still decode and future additions stay compatible.
    enum CodingKeys: String, CodingKey { case chartType, mappings, aggregation, temporalBin, numericBin, display }
    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        chartType   = try c.decodeIfPresent(ChartType.self, forKey: .chartType) ?? .bar
        mappings    = try c.decodeIfPresent([ChartColumnRole: ColumnRef].self, forKey: .mappings) ?? [:]
        aggregation = try c.decodeIfPresent(AggregationFn.self, forKey: .aggregation) ?? .sum
        temporalBin = try c.decodeIfPresent(TemporalBin.self, forKey: .temporalBin) ?? .auto
        numericBin  = try c.decodeIfPresent(NumericBin.self, forKey: .numericBin) ?? .auto
        display     = try c.decodeIfPresent(ChartDisplayOptions.self, forKey: .display) ?? ChartDisplayOptions()
    }
}
```
Keep the existing `infer` and `validate` methods. Note: `ChartColumnRole` does **not** conform to `CodingKeyRepresentable`, so `[ChartColumnRole: ColumnRef]` encodes/decodes as a flat alternating **array** (`["category",{index,name},…]`), not a JSON object — this is the real phase-1 on-disk shape and round-trips correctly. (Correcting an inaccurate phase-1 note; the legacy-blob test literal must use `"mappings":[]`, not `{}`.)

- [ ] **Step 5: Run `scripts/test-chart-config.sh` — expect PASS** (incl. legacy-decode + numericBin + heatmap).

- [ ] **Step 6: Commit:**
```bash
git add Pharos/Models/Charts/ChartTypes.swift Pharos/Models/Charts/ChartConfig.swift PharosTests/ChartConfigTests.swift
git commit -m "feat(charts): NumericBin + heatmap type + backward-compatible ChartConfig decoder"
```

---

## Task 3: ChartData — drill on points, heatmap cells

**Files:** Modify `ChartData.swift`.

- [ ] **Step 1: Extend `ChartData.swift`**

Add `drill` to `ChartPoint`, and the heatmap types:
```swift
struct ChartPoint {
    var xLabel: String
    var xValue: Double?
    var y: Double
    var drill: DrillKey? = nil
}

struct HeatmapCell: Identifiable {
    var x: String
    var y: String
    var value: Double
    var drill: DrillKey?
    var id: String { x + "\u{1}" + y }   // stable per-cell id for Chart(_:) / ForEach
}
```
In `ChartData`, add: `var heatmapCells: [HeatmapCell] = []`.

- [ ] **Step 2: Build the aggregator harness to confirm it still compiles**

Run `scripts/test-chart-aggregator.sh`. Expected: still PASS (default `drill: nil` doesn't break existing points; add `Pharos/Models/Charts/DrillKey.swift` to the script's compile list since `ChartData` now references `DrillKey`).

Update `scripts/test-chart-aggregator.sh` to include `Pharos/Models/Charts/DrillKey.swift` in the `swiftc` list (before `ChartData.swift`).

- [ ] **Step 3: Commit:**
```bash
git add Pharos/Models/Charts/ChartData.swift scripts/test-chart-aggregator.sh
git commit -m "feat(charts): drill key on ChartPoint; HeatmapCell model"
```

---

## Task 4: Aggregator — numeric binning, count relax, low-card escape, week fix, drill keys

**Files:** Modify `ChartAggregator.swift`; extend `PharosTests/ChartAggregatorTests.swift`.

This reworks `aggregateCategorical` and its helpers. It is the correctness core; do it carefully and TDD each behavior.

- [ ] **Step 1: Add failing tests to `ChartAggregatorTests.swift`**

Append inside `runTests()` (helpers `makeResult`, `expect` already exist):

```swift
    // --- week-label boundary fix: 2026-12-29 is ISO week 1 of 2027 ---
    let wk = makeResult([("ts","timestamptz"),("v","numeric")],
                        [["2026-12-29 00:00:00+00","1"]])
    var wkc = ChartConfig(chartType: .line, temporalBin: .week)
    wkc.mappings[.category] = ColumnRef(index: 0, name: "ts")
    wkc.mappings[.value] = ColumnRef(index: 1, name: "v")
    let wkOut = ChartAggregator.aggregate(wk, wkc)
    expect(wkOut.series[0].points.first?.xLabel == "2027-W01", "week label uses yearForWeekOfYear")

    // --- count histogram needs only a category (no value mapping) ---
    let ages = makeResult([("age","int4")], [["21"],["24"],["37"],["39"],["55"]])
    var hc = ChartConfig(chartType: .bar, numericBin: .b10)
    hc.mappings[.category] = ColumnRef(index: 0, name: "age")
    hc.aggregation = .count
    let hout = ChartAggregator.aggregate(ages, hc)
    expect(hout.emptyReason == nil, "count histogram works with no value mapping")
    expect(hout.series[0].points.allSatisfy { $0.drill != nil }, "each bin carries a drill key")
    if case .range(_, _, _, .numeric)? = hout.series[0].points.first?.drill {} else { expect(false, "numeric bin drill is a numeric range") }

    // --- numeric bins render ASCENDING by bin, regardless of row order ---
    let shuf = makeResult([("n","int4")], [["95"],["5"],["55"],["15"]])
    var shc = ChartConfig(chartType: .bar, numericBin: .b10); shc.aggregation = .count
    shc.mappings[.category] = ColumnRef(index: 0, name: "n")
    let shOut = ChartAggregator.aggregate(shuf, shc)
    let los = shOut.series[0].points.map { Double($0.xLabel.split(separator: "–").first.map(String.init) ?? "") ?? 0 }
    expect(los == los.sorted(), "numeric bins ascending by bin start")

    // --- low-cardinality numeric stays discrete under .auto ---
    let rating = makeResult([("r","int4"),("v","numeric")],
                            [["1","5"],["2","3"],["1","2"],["3","9"]])
    var rc = ChartConfig(chartType: .bar, numericBin: .auto)
    rc.mappings[.category] = ColumnRef(index: 0, name: "r")
    rc.mappings[.value] = ColumnRef(index: 1, name: "v")
    rc.aggregation = .sum
    let rout = ChartAggregator.aggregate(rating, rc)
    expect(rout.series[0].points.contains { $0.xLabel == "1" }, "low-cardinality numeric stays discrete (label '1', not a range)")

    // --- discrete category drill uses anyOf; null uses blank ---
    let cats = makeResult([("s","text"),("v","numeric")], [["done","1"],["open","2"],[nil,"3"]])
    var cc = ChartConfig(chartType: .bar); cc.aggregation = .count
    cc.mappings[.category] = ColumnRef(index: 0, name: "s")
    let cout = ChartAggregator.aggregate(cats, cc)
    let donePt = cout.series[0].points.first { $0.xLabel == "done" }
    if case .anyOf(_, let vals)? = donePt?.drill { expect(vals == ["done"], "discrete drill anyOf carries raw label") }
    else { expect(false, "discrete drill is anyOf") }
    let nullPt = cout.series[0].points.first { $0.xLabel.isEmpty || $0.xLabel == "(null)" }
    if case .blank? = nullPt?.drill {} else { expect(false, "null category drill is .blank") }

    // --- Other bar drills the dropped labels ---
    var many: [[String?]] = []
    for i in 0..<30 { many.append(["c\(i)","\(30-i)"]) }
    let big = makeResult([("c","text"),("v","numeric")], many)
    var bc = ChartConfig(chartType: .bar); bc.aggregation = .sum
    bc.mappings[.category] = ColumnRef(index: 0, name: "c"); bc.mappings[.value] = ColumnRef(index: 1, name: "v")
    bc.display.topNCategories = 5
    let bout = ChartAggregator.aggregate(big, bc)
    let otherPt = bout.series[0].points.first { $0.xLabel == "Other" }
    if case .anyOf(_, let dropped)? = otherPt?.drill { expect(dropped.count == 25, "Other drill lists the 25 dropped labels") }
    else { expect(false, "Other drill is anyOf of dropped labels") }
```

- [ ] **Step 2: Run `scripts/test-chart-aggregator.sh` — expect FAIL.**

- [ ] **Step 3: Fix the week label**

In `binLabel`, use `.yearForWeekOfYear` for the week case:
```swift
        let c = cal.dateComponents([.year, .yearForWeekOfYear, .month, .day, .hour, .weekOfYear], from: date)
        switch bin {
        ...
        case .week:  return String(format: "%04d-W%02d", c.yearForWeekOfYear ?? 0, c.weekOfYear ?? 0)
        ...
        }
```

- [ ] **Step 4: Add numeric-binning + drill helpers**

Add to `ChartAggregator` (Foundation only):

```swift
    /// Distinct-value threshold below which an .auto numeric axis stays discrete.
    private static let numericDiscreteThreshold = 12

    /// Resolve the effective numeric bin count for a column of coerced values,
    /// or nil if the axis should be treated as discrete categories.
    private static func numericBinCount(_ bin: NumericBin, distinct: Int, n: Int) -> Int? {
        switch bin {
        case .off: return nil
        case .b10: return 10
        case .b20: return 20
        case .b50: return 50
        case .auto:
            if distinct <= numericDiscreteThreshold { return nil }   // low-cardinality escape
            return max(1, min(50, Int(Double(n).squareRoot().rounded(.up))))
        }
    }

    /// Compact numeric bin label, e.g. "0–10".
    private static func binRangeLabel(_ lo: Double, _ hi: Double) -> String {
        func fmt(_ d: Double) -> String { d == d.rounded() ? String(Int(d)) : String(format: "%.2f", d) }
        return "\(fmt(lo))–\(fmt(hi))"
    }
```

- [ ] **Step 5: Rework `aggregateCategorical` to bin numeric axes, relax the count guard, and emit drill keys**

Replace `aggregateCategorical` with the version below. Key changes: value required only for non-count aggregations; numeric axis binning with range drill keys; each category label maps to a `DrillKey` (`.anyOf`/`.blank` for discrete, `.range` for numeric/temporal bins); Other carries dropped labels.

```swift
    private static func aggregateCategorical(_ result: QueryResult, _ config: ChartConfig) -> ChartData {
        guard let catRef = config.mappings[.category], catRef.index < result.columns.count else {
            return .empty(.noColumns)
        }
        let valRef = config.mappings[.value]
        let isCount = config.aggregation == .count
        // Non-count aggregations require a value column.
        if !isCount, valRef == nil || (valRef!.index >= result.columns.count) { return .empty(.noColumns) }

        let seriesRef = config.mappings[.series]
        let catKind = ColumnClassifier.kind(forDataType: result.columns[catRef.index].dataType)

        // Decide numeric binning up front (needs a first pass for range + distinct).
        var numericBins: [(lo: Double, hi: Double)] = []
        var numericBinOf: ((Double) -> Int)? = nil
        if catKind == .numeric {
            var vals: [Double] = []
            var distinct = Set<Double>()
            for row in result.rows where catRef.index < row.count {
                if let d = ValueCoercion.double(from: row[catRef.index]) { vals.append(d); distinct.insert(d) }
            }
            if let count = numericBinCount(config.numericBin, distinct: distinct.count, n: vals.count),
               let lo = vals.min(), let hi = vals.max(), hi > lo {
                let width = (hi - lo) / Double(count)
                numericBins = (0..<count).map { (lo + Double($0) * width, lo + Double($0 + 1) * width) }
                numericBinOf = { v in min(count - 1, max(0, Int((v - lo) / width))) }
            }
            // else: falls through to discrete handling (low-cardinality / min==max).
        }

        struct Key: Hashable { let series: String; let cat: String }
        var sums: [Key: Double] = [:]; var counts: [Key: Int] = [:]
        var mins: [Key: Double] = [:]; var maxs: [Key: Double] = [:]
        var order: [String] = []; var seen = Set<String>()
        var seriesOrder: [String] = []; var seriesSeen = Set<String>()
        var drillOf: [String: DrillKey] = [:]      // category label → drill key
        var rawOf: [String: String] = [:]          // discrete label → raw displayString (for Other fold + anyOf)
        var labelIsNull: [String: Bool] = [:]
        var sawAnyValue = false; var plotted = 0

        for row in result.rows {
            guard catRef.index < row.count else { continue }
            let rawCat = row[catRef.index]
            let isNull = rawCat.isNull || rawCat.displayString.isEmpty

            // Determine the category label + its drill key.
            let label: String
            if let binOf = numericBinOf, let d = ValueCoercion.double(from: rawCat) {
                let i = binOf(d); let b = numericBins[i]
                label = binRangeLabel(b.lo, b.hi)
                drillOf[label] = .range(catRef, b.lo, b.hi, .numeric)
            } else if catKind == .temporal, config.temporalBin != .none, case let s as String = rawCat.value,
                      let date = ValueCoercion.date(from: s) {
                label = binLabel(date, bin: config.temporalBin)
                if let (lo, hi) = temporalBinBounds(date, bin: config.temporalBin) {
                    drillOf[label] = .range(catRef, lo, hi, .temporal)
                }
            } else {
                label = rawCat.displayString
                if isNull { drillOf[label] = .blank(catRef); labelIsNull[label] = true }
                else { rawOf[label] = rawCat.displayString }   // discrete drill built at emit (anyOf)
            }

            let seriesName = seriesRef.map { row[$0.index].displayString } ?? ""
            let key = Key(series: seriesName, cat: label)
            if !seen.contains(label) { seen.insert(label); order.append(label) }
            if !seriesSeen.contains(seriesName) { seriesSeen.insert(seriesName); seriesOrder.append(seriesName) }

            if isCount {
                counts[key, default: 0] += 1; sawAnyValue = true; plotted += 1; continue
            }
            guard let vr = valRef, vr.index < row.count, let y = ValueCoercion.double(from: row[vr.index]) else { continue }
            sawAnyValue = true; plotted += 1
            sums[key, default: 0] += y; counts[key, default: 0] += 1
            mins[key] = mins[key].map { Swift.min($0, y) } ?? y
            maxs[key] = maxs[key].map { Swift.max($0, y) } ?? y
        }

        if !sawAnyValue { return .empty(.allNull) }

        func value(_ k: Key) -> Double {
            switch config.aggregation {
            case .sum: return sums[k] ?? 0
            case .count: return Double(counts[k] ?? 0)
            case .avg: return (counts[k] ?? 0) > 0 ? (sums[k] ?? 0) / Double(counts[k]!) : 0
            case .min: return mins[k] ?? 0
            case .max: return maxs[k] ?? 0
            }
        }

        // Top-N — skip for binned numeric/temporal axes (bounded/ordered).
        var categories = order; var truncated = false; var otherCount = 0
        // Numeric bins must render ascending by bin (bar/line/area set no
        // chartXScale domain, so emit order IS the axis order). order[] is
        // first-appearance, which is arbitrary for an unsorted numeric column.
        if numericBinOf != nil {
            categories = numericBins.map { binRangeLabel($0.lo, $0.hi) }.filter { seen.contains($0) }
        }
        let axisIsBinned = (numericBinOf != nil) || (catKind == .temporal && config.temporalBin != .none)
        if !axisIsBinned && categories.count > config.display.topNCategories {
            let keys = sums.keys.isEmpty ? Array(counts.keys) : Array(sums.keys)
            let totals = Dictionary(grouping: keys) { $0.cat }
            func catTotal(_ c: String) -> Double { totals[c]?.reduce(0) { $0 + value($1) } ?? 0 }
            let ranked = categories.sorted { catTotal($0) > catTotal($1) }
            let kept = Array(ranked.prefix(config.display.topNCategories)); let keptSet = Set(kept)
            let dropped = ranked.filter { !keptSet.contains($0) }
            otherCount = dropped.count; truncated = otherCount > 0
            categories = kept
            if truncated {
                categories.append("Other")
                // Other drill = the dropped RAW labels; if the null bucket was
                // among the dropped, include it via .blank so clicking "Other"
                // also selects the null rows folded into the bar.
                let droppedRaw = dropped.compactMap { rawOf[$0] }
                let droppedNull = dropped.contains { labelIsNull[$0] == true }
                drillOf["Other"] = droppedNull
                    ? .compound([.anyOf(catRef, droppedRaw), .blank(catRef)])
                    : .anyOf(catRef, droppedRaw)
            }
            let foldSeries = Set(sums.keys.map { $0.series }).union(counts.keys.map { $0.series })
            for s in foldSeries {
                let otherKey = Key(series: s, cat: "Other")
                for c in dropped {
                    let src = Key(series: s, cat: c)
                    if let v = sums[src] { sums[otherKey, default: 0] += v }
                    if let n = counts[src] { counts[otherKey, default: 0] += n }
                    if let mn = mins[src] { mins[otherKey] = mins[otherKey].map { Swift.min($0, mn) } ?? mn }
                    if let mx = maxs[src] { maxs[otherKey] = maxs[otherKey].map { Swift.max($0, mx) } ?? mx }
                }
            }
        }

        // Build discrete anyOf drill keys now (label → [rawLabel]).
        for (label, raw) in rawOf where drillOf[label] == nil {
            drillOf[label] = .anyOf(catRef, [raw])
        }

        let seriesNames = seriesRef == nil ? [""] : seriesOrder
        var out = ChartData()
        for s in seriesNames {
            var pts: [ChartPoint] = []
            for c in categories {
                let k = Key(series: s, cat: c)
                let hasData = sums[k] != nil || counts[k] != nil || c == "Other"
                if hasData { pts.append(ChartPoint(xLabel: c, xValue: nil, y: value(k), drill: drillOf[c])) }
            }
            out.series.append(ChartSeries(name: s, points: pts))
        }
        out.plottedRowCount = plotted
        out.totalLoadedRowCount = result.rows.count
        out.wasTruncated = truncated
        out.otherBucketCount = otherCount
        return out
    }
```

- [ ] **Step 6: Add `temporalBinBounds` helper** (epoch bounds for a temporal bin; used by drill range keys)

```swift
    /// [startEpoch, lastInstantEpoch] (epoch seconds) for the temporal bin
    /// containing `date`. lastInstant = next bin start minus one microsecond;
    /// the drill translator formats these so an inclusive between over the grid's
    /// display strings includes the whole bucket.
    private static func temporalBinBounds(_ date: Date, bin: TemporalBin) -> (Double, Double)? {
        var cal = Calendar(identifier: .gregorian); cal.timeZone = TimeZone(identifier: "UTC")!
        let comp: Calendar.Component
        switch bin {
        case .hour: comp = .hour
        case .day, .auto: comp = .day
        case .week: comp = .weekOfYear
        case .month: comp = .month
        case .year: comp = .year
        case .none: return nil
        }
        guard let start = cal.dateInterval(of: comp, for: date)?.start,
              let next = cal.date(byAdding: comp, value: 1, to: start) else { return nil }
        return (start.timeIntervalSince1970, next.timeIntervalSince1970 - 0.000001)
    }
```

- [ ] **Step 7: Run `scripts/test-chart-aggregator.sh` — expect PASS** (all existing + new). Fix until green.

- [ ] **Step 8: Commit:**
```bash
git add Pharos/Models/Charts/ChartAggregator.swift PharosTests/ChartAggregatorTests.swift
git commit -m "feat(charts): numeric binning, count-only histograms, low-card escape, drill keys, week-label fix"
```

---

## Task 5: Rail — numeric Bins control

**Files:** Modify `ChartRootView.swift`.

- [ ] **Step 1: Add the Bins control to the config rail**

In `configRail`, after the Time Bucket block, add a numeric Bins block:
```swift
                if showNumericBins {
                    railLabel("Bins")
                    Picker("", selection: Binding(get: { model.config.numericBin },
                                                  set: { b in model.update { $0.numericBin = b } })) {
                        ForEach(NumericBin.allCases, id: \.self) { Text($0.displayName).tag($0) }
                    }.labelsHidden()
                }
```

- [ ] **Step 2: Add `showNumericBins`** next to `showTimeBucket`:
```swift
    private var showNumericBins: Bool {
        let ref = model.config.chartType == .heatmap ? model.config.mappings[.x] : model.config.mappings[.category]
        return model.kind(ref) == .numeric
    }
```
(`showTimeBucket` should already gate on `.temporal`; the two are mutually exclusive per column kind.)

- [ ] **Step 3: Build** — `xcodegen generate && xcodebuild … build` → BUILD SUCCEEDED.

- [ ] **Step 4: Commit:**
```bash
git add Pharos/ViewControllers/Charts/ChartRootView.swift
git commit -m "feat(charts): numeric Bins rail control"
```

---

# Phase 2B — Heatmap

## Task 6: Aggregator — heatmap cells

**Files:** Modify `ChartAggregator.swift`; extend `PharosTests/ChartAggregatorTests.swift`.

- [ ] **Step 1: Add failing heatmap tests**

```swift
    // --- heatmap: count cross-tab (no value) ---
    let hm = makeResult([("region","text"),("tier","text")],
                        [["us","a"],["us","a"],["us","b"],["eu","a"]])
    var hmc = ChartConfig(chartType: .heatmap); hmc.aggregation = .count
    hmc.mappings[.x] = ColumnRef(index: 0, name: "region")
    hmc.mappings[.y] = ColumnRef(index: 1, name: "tier")
    let hmo = ChartAggregator.aggregate(hm, hmc)
    let usa = hmo.heatmapCells.first { $0.x == "us" && $0.y == "a" }
    expect(usa?.value == 2, "heatmap us/a count = 2")
    if case .compound(let keys)? = usa?.drill { expect(keys.count == 2, "heatmap cell drill is compound (x and y)") }
    else { expect(false, "heatmap cell drill is compound") }

    // --- heatmap: aggregate a value ---
    let hm2 = makeResult([("region","text"),("tier","text"),("amt","numeric")],
                         [["us","a","10"],["us","a","5"]])
    var hm2c = ChartConfig(chartType: .heatmap); hm2c.aggregation = .sum
    hm2c.mappings[.x] = ColumnRef(index: 0, name: "region")
    hm2c.mappings[.y] = ColumnRef(index: 1, name: "tier")
    hm2c.mappings[.value] = ColumnRef(index: 2, name: "amt")
    expect(ChartAggregator.aggregate(hm2, hm2c).heatmapCells.first?.value == 15, "heatmap sum = 15")
```

- [ ] **Step 2: Run — expect FAIL.**

- [ ] **Step 3: Route heatmap in `aggregate` and implement `aggregateHeatmap`**

In `aggregate(_:_:)`:
```swift
        case .heatmap: return aggregateHeatmap(result, config)
```
Add:
```swift
    private static func aggregateHeatmap(_ result: QueryResult, _ config: ChartConfig) -> ChartData {
        guard let xRef = config.mappings[.x], let yRef = config.mappings[.y],
              xRef.index < result.columns.count, yRef.index < result.columns.count else {
            return .empty(.noColumns)
        }
        let valRef = config.mappings[.value]
        let isCount = config.aggregation == .count || valRef == nil
        struct Key: Hashable { let x: String; let y: String }
        var sums: [Key: Double] = [:]; var counts: [Key: Int] = [:]
        var mins: [Key: Double] = [:]; var maxs: [Key: Double] = [:]
        var xOrder: [String] = []; var xSeen = Set<String>()
        var yOrder: [String] = []; var ySeen = Set<String>()
        var drillOf: [Key: DrillKey] = [:]
        var saw = false

        // Axis label + per-axis drill sub-key (reuse categorical binning rules).
        func axis(_ v: AnyCodable, _ ref: ColumnRef, _ kind: ColumnKind) -> (String, DrillKey) {
            if kind == .temporal, config.temporalBin != .none, case let s as String = v.value, let d = ValueCoercion.date(from: s) {
                let label = binLabel(d, bin: config.temporalBin)
                if let (lo, hi) = temporalBinBounds(d, bin: config.temporalBin) { return (label, .range(ref, lo, hi, .temporal)) }
                return (label, .anyOf(ref, [label]))
            }
            if v.isNull || v.displayString.isEmpty { return ("(null)", .blank(ref)) }
            return (v.displayString, .anyOf(ref, [v.displayString]))
        }
        let xKind = ColumnClassifier.kind(forDataType: result.columns[xRef.index].dataType)
        let yKind = ColumnClassifier.kind(forDataType: result.columns[yRef.index].dataType)

        for row in result.rows {
            guard xRef.index < row.count, yRef.index < row.count else { continue }
            let (xl, xk) = axis(row[xRef.index], xRef, xKind)
            let (yl, yk) = axis(row[yRef.index], yRef, yKind)
            let key = Key(x: xl, y: yl)
            if !xSeen.contains(xl) { xSeen.insert(xl); xOrder.append(xl) }
            if !ySeen.contains(yl) { ySeen.insert(yl); yOrder.append(yl) }
            drillOf[key] = .compound([xk, yk])
            if isCount { counts[key, default: 0] += 1; saw = true; continue }
            guard let vr = valRef, vr.index < row.count, let val = ValueCoercion.double(from: row[vr.index]) else { continue }
            saw = true
            sums[key, default: 0] += val; counts[key, default: 0] += 1
            mins[key] = mins[key].map { Swift.min($0, val) } ?? val
            maxs[key] = maxs[key].map { Swift.max($0, val) } ?? val
        }
        if !saw { return .empty(.allNull) }

        func value(_ k: Key) -> Double {
            switch config.aggregation {
            case .sum: return sums[k] ?? 0
            case .count: return Double(counts[k] ?? 0)
            case .avg: return (counts[k] ?? 0) > 0 ? (sums[k] ?? 0) / Double(counts[k]!) : 0
            case .min: return mins[k] ?? 0
            case .max: return maxs[k] ?? 0
            }
        }

        // Top-N per axis by marginal total.
        func topN(_ labels: [String], axisIsX: Bool) -> [String] {
            let cap = config.display.topNCategories
            guard labels.count > cap else { return labels }
            func total(_ l: String) -> Double {
                labels.isEmpty ? 0 : (axisIsX ? yOrder : xOrder).reduce(0) { acc, other in
                    acc + value(axisIsX ? Key(x: l, y: other) : Key(x: other, y: l))
                }
            }
            return Array(labels.sorted { total($0) > total($1) }.prefix(cap))
        }
        let xs = topN(xOrder, axisIsX: true); let ys = topN(yOrder, axisIsX: false)
        let xsSet = Set(xs); let ysSet = Set(ys)
        let truncated = xs.count < xOrder.count || ys.count < yOrder.count

        var out = ChartData()
        for x in xs { for y in ys {
            let key = Key(x: x, y: y)
            guard sums[key] != nil || counts[key] != nil else { continue }   // blank cells not drawn
            out.heatmapCells.append(HeatmapCell(x: x, y: y, value: value(key), drill: drillOf[key]))
        } }
        _ = (xsSet, ysSet)
        out.plottedRowCount = out.heatmapCells.count
        out.totalLoadedRowCount = result.rows.count
        out.wasTruncated = truncated
        return out
    }
```

- [ ] **Step 4: Run `scripts/test-chart-aggregator.sh` — expect PASS.**

- [ ] **Step 5: Commit:**
```bash
git add Pharos/Models/Charts/ChartAggregator.swift PharosTests/ChartAggregatorTests.swift
git commit -m "feat(charts): heatmap cell aggregation with compound drill keys"
```

---

## Task 7: Heatmap roles, eligibility, and rendering

**Files:** Modify `ChartRootView.swift`, `ChartView.swift`.

- [ ] **Step 1: Heatmap roles + chart-type-aware eligibility (`ChartRootView.swift`)**

In `rolesForCurrentType()` add:
```swift
        case .heatmap: return [.x, .y, .value]
```
In `roleLabel`, ensure `.x`/`.y`/`.value` read sensibly for heatmap (e.g. return "X (columns)", "Y (rows)", "Value (color, optional)" when `chartType == .heatmap`). Since `roleLabel` currently ignores chart type, add a heatmap branch or pass the type.

In `ChartViewModel.eligible(for:)`, make X/Y accept any kind for heatmap:
```swift
    func eligible(for role: ChartColumnRole, chartType: ChartType) -> [ColumnRef] {
        let refs = columns.enumerated().map { ColumnRef(index: $0.offset, name: $0.element.name) }
        if chartType == .heatmap, role == .x || role == .y { return refs }   // any kind
        switch role {
        case .value, .y, .x, .size, .start, .end:
            return refs.filter { r in
                let k = ColumnClassifier.kind(forDataType: columns[r.index].dataType)
                return k == .numeric || ((role == .start || role == .end || role == .x) ? k == .temporal : false)
            }
        default: return refs
        }
    }
```
Update the `rolePicker` call site to pass `model.config.chartType`. `usesAggregation` already returns `true` for heatmap (it only excludes `.scatter`/`.gantt`), so heatmap shows the Aggregate control with no change needed.

- [ ] **Step 2: Heatmap rendering in `ChartView.swift`**

Add a `heatmapChart` and route `.heatmap` in `chart`:
```swift
        case .heatmap: heatmapChart
```
```swift
    @ViewBuilder private var heatmapChart: some View {
        Chart(data.heatmapCells) { cell in     // HeatmapCell is Identifiable (Task 3)
            RectangleMark(
                x: .value("X", cell.x),
                y: .value("Y", cell.y)
            )
            .foregroundStyle(by: .value("Value", cell.value))
        }
        .chartForegroundStyleScale(range: Gradient(colors: [Color.blue.opacity(0.15), Color.blue]))
    }
```
(`HeatmapCell` is `Identifiable` from Task 3, so `Chart(data.heatmapCells)` needs no explicit `id:`.)

- [ ] **Step 3: Build** → BUILD SUCCEEDED. Iterate on the color scale/legend until it renders (manual visual check later).

- [ ] **Step 4: Commit:**
```bash
git add Pharos/ViewControllers/Charts/ChartRootView.swift Pharos/ViewControllers/Charts/ChartView.swift Pharos/Models/Charts/ChartData.swift scripts/test-chart-aggregator.sh
git commit -m "feat(charts): heatmap roles, eligibility, and RectangleMark rendering"
```

---

# Phase 2C — Drill-down

## Task 8: DrillTranslator

**Files:** Create `Pharos/Models/Charts/DrillTranslator.swift`, `PharosTests/DrillTranslatorTests.swift`, `scripts/test-drill-translator.sh`.

- [ ] **Step 1: Write the failing test** (`import AppKit`; includes `ColumnFilter`/`PGTypeCategory`)

`PharosTests/DrillTranslatorTests.swift`:
```swift
import AppKit

var failures = 0
func expect(_ c: Bool, _ n: String) { if c { print("PASS \(n)") } else { failures += 1; print("FAIL \(n)") } }

func runTests() {
    let cols = [ColumnDef(name: "status", dataType: "text"),
                ColumnDef(name: "age", dataType: "int4"),
                ColumnDef(name: "ts", dataType: "timestamptz")]

    // anyOf → col_N + isAnyOf + dataType.
    let a = DrillTranslator.filters(for: [.anyOf(ColumnRef(index: 0, name: "status"), ["done","open"])], columns: cols)
    expect(a.count == 1 && a[0].columnId == "col_0", "anyOf keyed col_0")
    expect(a[0].filter.op == .isAnyOf && a[0].filter.values == ["done","open"], "anyOf → isAnyOf values")
    expect(a[0].filter.dataType == "text", "dataType populated from ColumnDef")

    // blank → isAnyOf [blanksSentinel].
    let b = DrillTranslator.filters(for: [.blank(ColumnRef(index: 0, name: "status"))], columns: cols)
    expect(b[0].filter.op == .isAnyOf && b[0].filter.values == [ColumnFilter.blanksSentinel], "blank → sentinel")

    // numeric range → between.
    let r = DrillTranslator.filters(for: [.range(ColumnRef(index: 1, name: "age"), 10, 20, .numeric)], columns: cols)
    expect(r[0].columnId == "col_1" && r[0].filter.op == .between && r[0].filter.value == "10" && r[0].filter.value2 == "20", "numeric range → between 10..20")

    // temporal range → between with last-instant hi that dominates +00 strings.
    let t = DrillTranslator.filters(for: [.range(ColumnRef(index: 2, name: "ts"),
        DrillTranslatorTestsDate("2026-07-01T00:00:00Z"), DrillTranslatorTestsDate("2026-08-01T00:00:00Z") - 0.000001, .temporal)], columns: cols)
    expect(t[0].filter.op == .between, "temporal → between")
    expect(t[0].filter.value2! > "2026-07-31 12:00:00+00", "hi dominates a mid-bucket +00 cell string")
    expect(t[0].filter.value2! < "2026-08-01", "hi excludes the next bucket")

    // compound → one filter per column.
    let c = DrillTranslator.filters(for: [.compound([.anyOf(ColumnRef(index:0,name:"status"),["x"]), .anyOf(ColumnRef(index:1,name:"age"),["9"])])], columns: cols)
    expect(Set(c.map { $0.columnId }) == ["col_0","col_1"], "compound → two column filters")

    // same-column anyOf coalesced.
    let m = DrillTranslator.filters(for: [.anyOf(ColumnRef(index:0,name:"status"),["a"]), .anyOf(ColumnRef(index:0,name:"status"),["b"])], columns: cols)
    expect(m.count == 1 && Set(m[0].filter.values ?? []) == ["a","b"], "same-column anyOf coalesced")

    if failures == 0 { print("\nAll tests passed.") } else { print("\n\(failures) failure(s)."); exit(1) }
}

// Helper: epoch for an ISO string (test only).
func DrillTranslatorTestsDate(_ iso: String) -> Double {
    let f = ISO8601DateFormatter(); return f.date(from: iso)!.timeIntervalSince1970
}
```

- [ ] **Step 2: Script** (`scripts/test-drill-translator.sh`) — includes AppKit deps:
```bash
#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")/.."
swiftc -o /tmp/drill-translator-tests \
  Pharos/Models/QueryResult.swift \
  Pharos/Models/Charts/ChartTypes.swift \
  Pharos/Models/Charts/DrillKey.swift \
  Pharos/Utilities/PGTypeCategory.swift \
  Pharos/Utilities/ColumnFilter.swift \
  Pharos/Models/Charts/DrillTranslator.swift \
  PharosTests/DrillTranslatorTests.swift \
  PharosTests/main.swift
/tmp/drill-translator-tests
```
`chmod +x`. Note: links AppKit (via ColumnFilter/PGTypeCategory) but runs headless.

- [ ] **Step 3: Run — expect FAIL.**

- [ ] **Step 4: Implement `DrillTranslator.swift`**

```swift
import Foundation

/// Converts drill keys (from chart marks) into grid column filters.
/// Output is keyed by "col_<index>" — the identifier the grid's filter engine
/// resolves via colIndex(from:). A name-keyed filter would silently no-op.
enum DrillTranslator {
    struct Applied { let columnId: String; let filter: ColumnFilter }

    static func filters(for keys: [DrillKey], columns: [ColumnDef]) -> [Applied] {
        // Flatten compounds, then group by column index.
        var flat: [DrillKey] = []
        func walk(_ k: DrillKey) { if case .compound(let ks) = k { ks.forEach(walk) } else { flat.append(k) } }
        keys.forEach(walk)

        // Coalesce anyOf/blank per column into one value set; ranges pass through.
        var anyOfByCol: [Int: (ref: ColumnRef, vals: [String])] = [:]
        var ranges: [(ref: ColumnRef, lo: Double, hi: Double, kind: RangeKind)] = []
        for k in flat {
            switch k {
            case .anyOf(let ref, let vals):
                anyOfByCol[ref.index, default: (ref, [])].vals.append(contentsOf: vals)
            case .blank(let ref):
                anyOfByCol[ref.index, default: (ref, [])].vals.append(ColumnFilter.blanksSentinel)
            case .range(let ref, let lo, let hi, let kind):
                ranges.append((ref, lo, hi, kind))
            case .compound: break
            }
        }

        var out: [Applied] = []
        for (idx, entry) in anyOfByCol {
            guard idx < columns.count else { continue }
            let dt = columns[idx].dataType
            let f = ColumnFilter(columnName: entry.ref.name, op: .isAnyOf, value: "", value2: nil,
                                 values: dedupPreservingOrder(entry.vals), dataType: dt)
            out.append(Applied(columnId: "col_\(idx)", filter: f))
        }
        for r in ranges where r.ref.index < columns.count {
            let dt = columns[r.ref.index].dataType
            let (loS, hiS) = formatRange(r.lo, r.hi, kind: r.kind, dataType: dt)
            let f = ColumnFilter(columnName: r.ref.name, op: .between, value: loS, value2: hiS, values: nil, dataType: dt)
            out.append(Applied(columnId: "col_\(r.ref.index)", filter: f))
        }
        return out
    }

    private static func dedupPreservingOrder(_ xs: [String]) -> [String] {
        var seen = Set<String>(); var r: [String] = []
        for x in xs where !seen.contains(x) { seen.insert(x); r.append(x) }
        return r
    }

    private static func formatRange(_ lo: Double, _ hi: Double, kind: RangeKind, dataType: String) -> (String, String) {
        switch kind {
        case .numeric:
            func n(_ d: Double) -> String { d == d.rounded() ? String(Int(d)) : String(d) }
            return (n(lo), n(hi))
        case .temporal:
            // Match the grid's lexicographic, inclusive .between over display strings.
            // Bare `date` columns render "yyyy-MM-dd"; timestamps carry time (+ tz).
            let bare = dataType.lowercased().hasPrefix("date")
            let f = DateFormatter(); f.locale = Locale(identifier: "en_US_POSIX"); f.timeZone = TimeZone(identifier: "UTC")
            f.dateFormat = bare ? "yyyy-MM-dd" : "yyyy-MM-dd HH:mm:ss.SSSSSS"
            return (f.string(from: Date(timeIntervalSince1970: lo)), f.string(from: Date(timeIntervalSince1970: hi)))
        }
    }
}
```

Note the temporal `hi` uses the passed `hi` epoch (the aggregator already set it to next-bucket-start − 1µs), formatted with sub-second precision so it lexicographically dominates `+00`-suffixed cell strings within the bucket. **Verify against real cell strings during manual testing** (Risk in the spec).

- [ ] **Step 5: Run — expect PASS.** Adjust the temporal format until the boundary assertions pass.

- [ ] **Step 6: Commit:**
```bash
git add Pharos/Models/Charts/DrillTranslator.swift PharosTests/DrillTranslatorTests.swift scripts/test-drill-translator.sh
git commit -m "feat(charts): DrillTranslator (drill keys -> col_N grid filters)"
```

---

## Task 9: Chart gesture plumbing → onDrill

**Files:** Modify `ChartView.swift`, `ChartRootView.swift`, `ChartHostingController.swift`.

This is the highest-iteration-risk task (like gantt). Build is the gate; behavior is verified manually.

- [ ] **Step 1: `ChartViewModel` + `ChartRootView` expose an `onDrill` closure**

In `ChartViewModel`, add: `var onDrill: (([DrillKey]) -> Void)?`.
In `ChartRootView`, pass a callback into `ChartCanvas` (add `onDrill: ([DrillKey]) -> Void` to `ChartCanvas`), forwarding to `model.onDrill`.

- [ ] **Step 2: Bar/line/area/heatmap/gantt — overlay tap; scatter/bar brush**

In `ChartCanvas`, wrap the plotting charts with a `chartOverlay { proxy in … }` that:
- on tap: reads `proxy.value(atX:)` (and `atY:` for heatmap) → find the matching `ChartData` point/cell (by `xLabel` / cell x,y) → if it has a `drill`, call `onDrill([drill])`.
- on drag (bar/line/area, scatter): collect points whose x falls within the dragged x-range → for categories emit their `.anyOf` keys (translator coalesces); for scatter emit a `.range(xRef, x0, x1, .numeric)` (+ optional y-range). Scatter needs the `xRef`/`yRef` — pass the resolved `ColumnRef`s (or the whole config) into `ChartCanvas`.

Provide the `xRef`/`yRef`/category `ColumnRef` to `ChartCanvas` (add parameters) so scatter/brush can build range keys (points don't carry per-point drill for scatter).

- [ ] **Step 3: Pie — `chartAngleSelection`**

For pie, use `.chartAngleSelection(value: $selectedAngleLabel)` (a `@State String?`) and, on change, map the selected category label → its point's `drill` → `onDrill`.

- [ ] **Step 4: Scatter click — chart-local callout**

For scatter, a tap selects the nearest point (via proxy) and shows a small overlay callout (`annotation`/overlay `Text`) with its `(x, y)`; dismiss on next tap. No `onDrill` for scatter click (brush filters).

- [ ] **Step 5: `ChartHostingController` forwards `onDrill`**

Add `var onDrill: (([DrillKey]) -> Void)?`; in `present(...)`, set `vm.onDrill = { [weak self] keys in self?.onDrill?(keys) }`.

- [ ] **Step 6: Build** → BUILD SUCCEEDED. (Manual behavior verification in Task 11.) If proxy hit-testing for a given chart type won't resolve, report and iterate — do not gut other types.

- [ ] **Step 7: Commit:**
```bash
git add Pharos/ViewControllers/Charts/ChartView.swift Pharos/ViewControllers/Charts/ChartRootView.swift Pharos/ViewControllers/Charts/ChartHostingController.swift
git commit -m "feat(charts): chart gesture -> onDrill (tap/brush, pie angle selection, scatter callout)"
```

---

## Task 10: ContentViewController — apply drill, chip, restore

**Files:** Modify `ContentViewController.swift`.

- [ ] **Step 1: Wire `chartHost.onDrill` in `presentChart`**

Where `chartHost.onConfigChanged`/`onLoadAll` are set, add:
```swift
        chartHost.onDrill = { [weak self] keys in self?.applyDrill(keys) }
```

- [ ] **Step 2: Implement `applyDrill`, the chip, and clear**

Add stored state: `private var drillColumns: [String] = []` (drill-set col ids) and `private var displacedFilters: [String: ColumnFilter] = [:]` (snapshots).

```swift
    private func applyDrill(_ keys: [DrillKey]) {
        // Resolve the active result via activeResultTabId (same pattern as elsewhere).
        guard let id = activeResultTabId,
              let result = resultTabs.first(where: { $0.id == id })?.queryResult else { return }
        let applied = DrillTranslator.filters(for: keys, columns: result.columns)
        guard !applied.isEmpty else { return }
        let fc = resultsVC.columnFilterController!
        for a in applied {
            if drillColumns.contains(a.columnId) == false, let existing = fc.filter(forColumn: a.columnId) {
                displacedFilters[a.columnId] = existing        // snapshot a manual filter once
            }
            fc.setFilter(a.filter, forColumn: a.columnId)
            if !drillColumns.contains(a.columnId) { drillColumns.append(a.columnId) }
        }
        resultsVC.refreshColumnFilters()   // mirror the grid's existing setFilter refresh (see below)
        setResultViewMode(.grid)
        updateDrillChip()
    }

    @objc private func clearDrill() {
        let fc = resultsVC.columnFilterController!
        for colId in drillColumns {
            if let restore = displacedFilters[colId] { fc.setFilter(restore, forColumn: colId) }
            else { fc.clearFilter(forColumn: colId) }
        }
        drillColumns.removeAll(); displacedFilters.removeAll()
        resultsVC.refreshColumnFilters()
        updateDrillChip()
    }
```

- [ ] **Step 3: Add `refreshColumnFilters()` to `ResultsGridVC`** (or reuse the existing refresh)

Find the method that recomputes `columnFilteredDisplayRows = columnFilterController.applyFilters(...)` and reloads the table + updates `filterableHeaderView.activeFilterColumns` / `resetFiltersButton` (around `ResultsGridVC.swift:284`/`:476`). Expose a public `refreshColumnFilters()` that runs that sequence, and call it from both the existing header-filter path and `applyDrill`/`clearDrill` (DRY).

- [ ] **Step 4: Drill chip UI**

Add a small chip view to the action bar (near the Grid/Chart toggle), hidden unless `!drillColumns.isEmpty`, showing e.g. "Filtered by chart ✕" with the ✕ calling `clearDrill`. `updateDrillChip()` toggles its visibility/label. Keep it minimal (an `NSButton` with an SF Symbol + title is fine).

- [ ] **Step 4b: Tear down the drill BEFORE capturing outgoing grid state**

A drill is a **transient overlay** on the shared `columnFilterController`. On any result-tab transition, `captureGridState()` snapshots `activeFilters` into the outgoing tab's `gridState` — so if a drill is still applied, the drill filter leaks into the saved state AND the displaced manual filter is lost (the snapshot in `displacedFilters` is cleared without being restored). Fix the invariant: **restore displaced manual filters (undo the drill) before `captureGridState` runs.**

Add `tearDownDrill(restoreManual: Bool)`: for each `colId` in `drillColumns`, if `restoreManual` and `displacedFilters[colId]` exists → `fc.setFilter(restore, forColumn: colId)` else `fc.clearFilter(forColumn: colId)`; then clear `drillColumns` + `displacedFilters` and `updateDrillChip()`. Call `tearDownDrill(restoreManual: true)` at the START of every outgoing-tab path (`selectResultTab`/`addResultTab`/`closeResultTab`) **before** their `captureGridState()` call, so the captured `gridState` reflects the user's real manual filters, not the drill. (`clearDrill()` — the explicit chip ✕ — is just `tearDownDrill(restoreManual: true)` + `refreshColumnFilters()` in-tab.) Verify: manual filter M on col X → drill X → switch tab → switch back ⇒ M is restored, no phantom drill filter, no orphaned chip.

- [ ] **Step 4c: Guard the filter-controller access**

Use `guard let fc = resultsVC.columnFilterController else { return }` in `applyDrill`/`clearDrill` rather than force-unwrapping.

- [ ] **Step 5: Build** → BUILD SUCCEEDED.

- [ ] **Step 6: Commit:**
```bash
git add Pharos/ViewControllers/ContentViewController.swift Pharos/ViewControllers/ResultsGridVC.swift
git commit -m "feat(charts): apply chart drill to grid filters with chip + snapshot/restore"
```

---

## Task 11: Full verification

**Files:** none.

- [ ] **Step 1: Run all chart harnesses**
```bash
scripts/test-chart-config.sh
scripts/test-chart-aggregator.sh
scripts/test-column-classifier.sh
scripts/test-value-coercion.sh
scripts/test-drill-key.sh
scripts/test-drill-translator.sh
```
Expected: each ends with "All tests passed."

- [ ] **Step 2: Rust unchanged** — `cd pharos-core && cargo test` (should still be green; no phase-2 Rust changes).

- [ ] **Step 3: Clean app build** — `xcodegen generate && xcodebuild … build` → `** BUILD SUCCEEDED **`.

- [ ] **Step 4: Manual (GUI + live Postgres)** — use the `verify` skill:
  - Numeric histogram: numeric column + Bins Auto/10/20/50, aggregation Count (no Value mapped) → histogram; low-cardinality numeric stays discrete.
  - Heatmap: two categoricals → count cross-tab + legend; with a Value + Sum; a temporal axis with Time Bucket.
  - Drill: click a bar/pie slice/heatmap cell → grid filters to those rows, view switches to Grid, chip shows; ✕ clears. Brush a span of bars / a scatter region → range filter. Scatter click → callout, no filter.
  - Collision: manually filter a column, then drill that same column, then clear → the manual filter is restored.
  - Nulls/Other: drill the null bucket and the "Other" bar → correct rows.
  - Backward compat: reopen a phase-1 workspace with a saved chart config → still restores.

- [ ] **Step 5: Commit any fixes**, then this phase is ready for `finishing-a-development-branch`.

---

## Notes for the implementer

- **Execution order:** 2A (Tasks 1–5) → 2B (6–7) → 2C (8–10) → verify (11). The pure-logic tasks (1–4, 6, 8) are TDD with harnesses; UI tasks (5, 7, 9, 10) are build-gated + manually verified.
- **Aggregator rework (Task 4)** is the biggest correctness change — keep every existing aggregator test green while adding the new ones.
- **Gesture plumbing (Task 9)** will likely need visual iteration; the pure translator/aggregator are already tested, so only the thin gesture layer should churn.
- **`project.pbxproj` is tracked** — stage it whenever `xcodegen` adds files (Tasks 1, 8 add new source files; 7/9/10 modify existing).
- **Temporal drill formatting (Task 8)** — confirm the last-instant `hi` against real `timestamptz`/`date` cell strings during manual verification; adjust `formatRange` if a boundary row is wrongly included/excluded.
