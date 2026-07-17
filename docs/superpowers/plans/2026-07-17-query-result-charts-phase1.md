# Query Result Charts (Phase 1) Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Add a Grid/Chart toggle to the result action bar that renders the current query result as a Swift Charts visualization (bar/line/area/scatter/pie/gantt) with a column-mapping rail, client-side aggregation + temporal binning, and workspace-persisted config.

**Architecture:** A pure, UI-free core (`ColumnClassifier`, `ValueCoercion`, `ChartAggregator`) transforms a `QueryResult` + `ChartConfig` into renderer-agnostic `ChartData`. A thin SwiftUI layer (`ChartRootView`) renders `ChartData` and is hosted in the existing AppKit result area via `NSHostingController`, toggled by a segmented control in the action bar. Config + view mode persist as one JSON blob on the `query_history` row backing each workspace result.

**Tech Stack:** Swift 5.10 / AppKit + SwiftUI (Swift Charts), macOS 15.0 target; Rust (`pharos-core`) + rusqlite over C FFI (cbindgen). Pure-logic tests via standalone `swiftc` harnesses in `PharosTests/`; Rust tests via in-file `#[cfg(test)]` modules.

**Reference spec:** `docs/superpowers/specs/2026-07-17-query-result-charts-design.md`

---

## Key conventions (read before starting)

- **No Xcode test target.** Pure Swift logic is tested by compiling the impl file(s) + one `PharosTests/XxxTests.swift` + `PharosTests/main.swift` with `swiftc` via a script in `scripts/`. Each test file defines its own top-level `runTests()`, `failures`, and `expectEqual`; `main.swift` just calls `runTests()`. Because each script compiles exactly one test file, these top-level names never collide.
- **New app source files require `xcodegen generate`** before the Xcode build sees them. Test files under `PharosTests/` are outside `Pharos/` and are never compiled into the app, so they don't need xcodegen.
- **Chart model + logic files must import only `Foundation`** (no AppKit/SwiftUI), so they compile in the `swiftc` harness. Keep SwiftUI/AppKit strictly in the view/hosting files.
- **FFI JSON casing:** `JSONDecoder.pharos`/`JSONEncoder.pharos` apply NO key strategy. Workspace types use `#[serde(rename_all = "camelCase")]` on the Rust side and plain camelCase (no `CodingKeys`) on the Swift side. Match this exactly for every new field/struct.
- **`pharos-core` is `staticlib`-only:** Rust tests live in in-file `#[cfg(test)] mod` blocks, never in `tests/`. DB tests use a fresh temp dir and `chrono::Utc::now()` timestamps (fixed past dates get pruned).
- **All query-result cell values arrive as JSON strings** (PG text format). `AnyCodable` decodes them all as `String`. Numeric/bool/date work must parse strings — this is why `ValueCoercion` exists.
- **Build the Rust core** with `cd pharos-core && cargo build --release` (also regenerates the C header via cbindgen). Run Rust tests with `cd pharos-core && cargo test`.

---

## File Structure

**New — pure model/logic (Foundation only, `Pharos/Models/Charts/`):**
- `ChartTypes.swift` — `ChartType`, `ChartColumnRole`, `ColumnRef`, `AggregationFn`, `TemporalBin`, `ColumnKind`, `ResultViewMode` enums + `ChartDisplayOptions`.
- `ChartConfig.swift` — `ChartConfig`, `PersistedResultViewState`, `ChartConfig.infer(from:)` + validation.
- `ChartData.swift` — `ChartData`, `ChartSeries`, `ChartPoint`, `GanttBar`, `EmptyReason`.
- `ColumnClassifier.swift` — pg type → `ColumnKind`.
- `ValueCoercion.swift` — PG-text string → Double/Date/Bool.
- `ChartAggregator.swift` — `(QueryResult, ChartConfig) → ChartData`.

**New — UI (AppKit/SwiftUI, `Pharos/ViewControllers/Charts/`):**
- `ChartView.swift` — SwiftUI Swift Charts view over `ChartData`.
- `ChartRootView.swift` — SwiftUI rail + canvas + banner; `ChartViewModel`.
- `ChartHostingController.swift` — `NSHostingController` wrapper + AppKit-facing API.

**New — tests (`PharosTests/`):**
- `ChartConfigTests.swift`, `ValueCoercionTests.swift`, `ColumnClassifierTests.swift`, `ChartAggregatorTests.swift`.

**New — scripts (`scripts/`):**
- `test-chart-config.sh`, `test-value-coercion.sh`, `test-column-classifier.sh`, `test-chart-aggregator.sh`.

**Modified:**
- `Pharos/Models/QueryResult.swift` — add `AnyCodable.init(_ value: Any?)` convenience initializer (needed to build values in tests and `ChartData`).
- `Pharos/Models/ResultTab.swift` — add `chartConfig` + `resultViewMode`.
- `Pharos/ViewControllers/ContentViewController.swift` — toggle in action bar; chart host in result area; wire toggle/persist/restore.
- `Pharos/Core/PharosCore+Workspaces.swift` — `updateResultChartState`; `WorkspaceResultMeta.chartViewStateJson`.
- `Pharos/Models/Workspace.swift` — `WorkspaceResultMeta.chartViewStateJson`.
- `pharos-core/src/db/sqlite.rs` — migration + `update_result_chart_state` + load SELECT.
- `pharos-core/src/models/workspace.rs` — `WorkspaceResultMeta.chart_view_state_json`.
- `pharos-core/src/commands/workspace.rs` — `update_result_chart_state`.
- `pharos-core/src/ffi/workspace.rs` — `pharos_update_result_chart_state`.

---

## Task 1: Bump deployment target to macOS 15 + AnyCodable initializer

The app transitions to a pure macOS 15+ minimum (no known macOS 14 users). This
unlocks the vectorized Swift Charts `PointPlot` API for dense scatter plots with
no availability gating and no sampling fallback.

**Files:**
- Modify: `project.yml`
- Modify: `Pharos/Models/QueryResult.swift`

- [ ] **Step 1: Raise the deployment target in `project.yml`**

In `project.yml`, change both deployment-target declarations from `14.0` to `15.0`:

```yaml
options:
  deploymentTarget:
    macOS: "15.0"
```

and

```yaml
settings:
  base:
    MACOSX_DEPLOYMENT_TARGET: "15.0"
```

- [ ] **Step 2: Add a memberwise initializer to `AnyCodable`**

In `Pharos/Models/QueryResult.swift`, inside `struct AnyCodable`, immediately above `init(from decoder:)`, add:

```swift
/// Construct directly from a value (tests, ChartData assembly).
init(_ value: Any?) {
    self.value = value
}
```

- [ ] **Step 3: Regenerate the project and verify it builds**

Run: `cd pharos-core && cargo build --release && cd .. && xcodegen generate`
Then build in Xcode (Cmd+B) or: `xcodebuild -project Pharos.xcodeproj -scheme Pharos -configuration Debug build 2>&1 | tail -20`
Expected: Rust builds; project regenerates; app builds against the macOS 15 SDK floor with no error.

- [ ] **Step 4: Commit**

```bash
git add project.yml Pharos/Models/QueryResult.swift
git commit -m "feat(charts): target macOS 15; add AnyCodable value initializer"
```

---

## Task 2: Chart model types

**Files:**
- Create: `Pharos/Models/Charts/ChartTypes.swift`
- Create: `Pharos/Models/Charts/ChartConfig.swift`
- Create: `PharosTests/ChartConfigTests.swift`
- Create: `scripts/test-chart-config.sh`

- [ ] **Step 1: Write the failing test**

Create `PharosTests/ChartConfigTests.swift`:

```swift
// Standalone test runner for ChartConfig — no Xcode project involvement.
// Compiled with Pharos/Models/Charts/ChartTypes.swift, ChartConfig.swift,
// and Pharos/Models/QueryResult.swift by scripts/test-chart-config.sh.
import Foundation

var failures = 0

func expect(_ cond: Bool, _ name: String) {
    if cond { print("PASS \(name)") } else { failures += 1; print("FAIL \(name)") }
}

func runTests() {
    // Codable round-trip, incl. [ChartColumnRole: ColumnRef] as a JSON object.
    var cfg = ChartConfig(chartType: .bar)
    cfg.mappings[.category] = ColumnRef(index: 0, name: "month")
    cfg.mappings[.value] = ColumnRef(index: 1, name: "revenue")
    cfg.aggregation = .sum

    let data = try! JSONEncoder().encode(cfg)
    let json = String(decoding: data, as: UTF8.self)
    expect(json.contains("\"category\""), "mappings encode role keys as JSON object")
    let back = try! JSONDecoder().decode(ChartConfig.self, from: data)
    expect(back.chartType == .bar, "chartType round-trips")
    expect(back.mappings[.value]?.index == 1, "ColumnRef round-trips by index")
    expect(back.mappings[.value]?.name == "revenue", "ColumnRef round-trips name")

    // PersistedResultViewState round-trip.
    let state = PersistedResultViewState(chartConfig: cfg, viewMode: .chart)
    let sdata = try! JSONEncoder().encode(state)
    let sback = try! JSONDecoder().decode(PersistedResultViewState.self, from: sdata)
    expect(sback.viewMode == .chart, "viewMode round-trips")
    expect(sback.chartConfig?.chartType == .bar, "nested config round-trips")

    // infer(): a categorical + a numeric column → bar with those mapped.
    let cols = [ColumnDef(name: "month", dataType: "text"),
                ColumnDef(name: "revenue", dataType: "numeric")]
    let inferred = ChartConfig.infer(from: cols)
    expect(inferred.mappings[.category]?.name == "month", "infer picks categorical for category")
    expect(inferred.mappings[.value]?.name == "revenue", "infer picks numeric for value")

    // validate(): a re-run that drops the value column clears that role.
    let newCols = [ColumnDef(name: "month", dataType: "text")]
    var stale = cfg
    stale.validate(against: newCols)
    expect(stale.mappings[.value] == nil, "validate clears role whose column vanished")
    expect(stale.mappings[.category]?.index == 0, "validate keeps still-valid role")

    if failures == 0 { print("\nAll tests passed.") } else { print("\n\(failures) failure(s)."); exit(1) }
}
```

- [ ] **Step 2: Create the test script**

Create `scripts/test-chart-config.sh`:

```bash
#!/bin/bash
# Standalone test runner for ChartConfig — no Xcode project involvement.
set -euo pipefail
cd "$(dirname "$0")/.."
swiftc -o /tmp/chart-config-tests \
  Pharos/Models/QueryResult.swift \
  Pharos/Models/Charts/ChartTypes.swift \
  Pharos/Models/Charts/ChartConfig.swift \
  PharosTests/ChartConfigTests.swift \
  PharosTests/main.swift
/tmp/chart-config-tests
```

Then: `chmod +x scripts/test-chart-config.sh`

- [ ] **Step 3: Run the test to verify it fails**

Run: `scripts/test-chart-config.sh`
Expected: FAIL — `error: cannot find 'ChartConfig' in scope` (files not created yet).

- [ ] **Step 4: Implement `ChartTypes.swift`**

Create `Pharos/Models/Charts/ChartTypes.swift`:

```swift
import Foundation

/// The six phase-1 chart types (+ heatmap reserved for phase 2).
enum ChartType: String, Codable, CaseIterable {
    case bar, line, area, scatter, pie, gantt
    // case heatmap  // phase 2

    var displayName: String {
        switch self {
        case .bar: return "Bar"
        case .line: return "Line"
        case .area: return "Area"
        case .scatter: return "Scatter"
        case .pie: return "Pie"
        case .gantt: return "Gantt"
        }
    }
}

/// The vocabulary of column roles across all chart types.
enum ChartColumnRole: String, Codable, CaseIterable {
    case category, value, series      // bar/line/area/pie
    case x, y, size, color            // scatter (color also reusable)
    case label, start, end            // gantt
}

/// A stable reference to a result column. Index is authoritative (duplicate
/// column names are legal in SQL); name is kept for display + validation.
struct ColumnRef: Codable, Equatable {
    var index: Int
    var name: String
}

enum AggregationFn: String, Codable, CaseIterable {
    case sum, avg, count, min, max
    var displayName: String { rawValue.capitalized }
}

/// Temporal bucketing for time-series category/x axes.
enum TemporalBin: String, Codable, CaseIterable {
    case none, auto, hour, day, week, month, year
}

/// Result of classifying a column's data type.
enum ColumnKind: String, Codable {
    case numeric, temporal, categorical
}

/// Whether a result tab shows the grid or a chart.
enum ResultViewMode: String, Codable {
    case grid, chart
}

/// Non-mapping display options.
struct ChartDisplayOptions: Codable, Equatable {
    var title: String = ""
    var showLegend: Bool = true
    var stacked: Bool = false          // grouped vs stacked for series
    var topNCategories: Int = 25       // cardinality cap
}
```

- [ ] **Step 5: Implement `ChartConfig.swift`**

Create `Pharos/Models/Charts/ChartConfig.swift`:

```swift
import Foundation

struct ChartConfig: Codable, Equatable {
    var chartType: ChartType
    var mappings: [ChartColumnRole: ColumnRef]
    var aggregation: AggregationFn
    var temporalBin: TemporalBin
    var display: ChartDisplayOptions

    init(chartType: ChartType,
         mappings: [ChartColumnRole: ColumnRef] = [:],
         aggregation: AggregationFn = .sum,
         temporalBin: TemporalBin = .auto,
         display: ChartDisplayOptions = ChartDisplayOptions()) {
        self.chartType = chartType
        self.mappings = mappings
        self.aggregation = aggregation
        self.temporalBin = temporalBin
        self.display = display
    }

    /// Build a sensible default config from the result's columns.
    static func infer(from columns: [ColumnDef]) -> ChartConfig {
        func kind(_ c: ColumnDef) -> ColumnKind { ColumnClassifier.kind(forDataType: c.dataType) }
        let indexed = columns.enumerated().map { (idx, c) in (ref: ColumnRef(index: idx, name: c.name), kind: kind(c)) }

        let firstCategorical = indexed.first { $0.kind == .categorical || $0.kind == .temporal }
        let firstNumeric = indexed.first { $0.kind == .numeric }

        var cfg = ChartConfig(chartType: .bar)
        if let cat = firstCategorical { cfg.mappings[.category] = cat.ref }
        if let num = firstNumeric { cfg.mappings[.value] = num.ref }
        return cfg
    }

    /// After a re-run changes the column shape, drop any role whose referenced
    /// column no longer exists at the same index with a matching name.
    mutating func validate(against columns: [ColumnDef]) {
        for (role, ref) in mappings {
            let stillValid = ref.index < columns.count && columns[ref.index].name == ref.name
            if !stillValid { mappings[role] = nil }
        }
    }
}

/// The single blob persisted per workspace result: chart config + view mode.
struct PersistedResultViewState: Codable {
    var chartConfig: ChartConfig?
    var viewMode: ResultViewMode
}
```

- [ ] **Step 6: Run the test to verify it passes**

Run: `scripts/test-chart-config.sh`
Expected: PASS for all assertions, ending with "All tests passed."

Note: `ChartConfig.infer` and the test reference `ColumnClassifier`, implemented in Task 3. Until then the script won't link. **Reorder if executing strictly:** create the `ColumnClassifier.swift` stub from Task 3 Step 4 first, or add it to this script's compile list. The two tasks are commit-together siblings; if a step fails to link on `ColumnClassifier`, jump to Task 3 Step 4, then return here.

- [ ] **Step 7: Commit**

```bash
git add Pharos/Models/Charts/ChartTypes.swift Pharos/Models/Charts/ChartConfig.swift PharosTests/ChartConfigTests.swift scripts/test-chart-config.sh
git commit -m "feat(charts): chart config model + inference/validation"
```

---

## Task 3: ColumnClassifier

**Files:**
- Create: `Pharos/Models/Charts/ColumnClassifier.swift`
- Create: `PharosTests/ColumnClassifierTests.swift`
- Create: `scripts/test-column-classifier.sh`

- [ ] **Step 1: Write the failing test**

Create `PharosTests/ColumnClassifierTests.swift`:

```swift
// Standalone test runner for ColumnClassifier.
// Compiled with Pharos/Models/Charts/{ChartTypes,ColumnClassifier}.swift by
// scripts/test-column-classifier.sh.
import Foundation

var failures = 0
func expectKind(_ dt: String, _ expected: ColumnKind, _ name: String) {
    let actual = ColumnClassifier.kind(forDataType: dt)
    if actual == expected { print("PASS \(name)") }
    else { failures += 1; print("FAIL \(name)  expected \(expected) got \(actual)") }
}

func runTests() {
    expectKind("integer", .numeric, "integer")
    expectKind("bigint", .numeric, "bigint")
    expectKind("int8", .numeric, "int8")
    expectKind("numeric", .numeric, "numeric")
    expectKind("double precision", .numeric, "double precision")
    expectKind("money", .numeric, "money")
    expectKind("bigserial", .numeric, "bigserial")
    expectKind("date", .temporal, "date")
    expectKind("timestamp without time zone", .temporal, "timestamp")
    expectKind("timestamptz", .temporal, "timestamptz")
    expectKind("time", .temporal, "time")
    expectKind("text", .categorical, "text")
    expectKind("character varying", .categorical, "varchar")
    expectKind("boolean", .categorical, "boolean")
    expectKind("uuid", .categorical, "uuid")
    expectKind("USER-DEFINED", .categorical, "user-defined fallback")
    expectKind("  Integer ", .numeric, "trims + case-insensitive")
    if failures == 0 { print("\nAll tests passed.") } else { print("\n\(failures) failure(s)."); exit(1) }
}
```

- [ ] **Step 2: Create the test script**

Create `scripts/test-column-classifier.sh`:

```bash
#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")/.."
swiftc -o /tmp/column-classifier-tests \
  Pharos/Models/Charts/ChartTypes.swift \
  Pharos/Models/Charts/ColumnClassifier.swift \
  PharosTests/ColumnClassifierTests.swift \
  PharosTests/main.swift
/tmp/column-classifier-tests
```

Then: `chmod +x scripts/test-column-classifier.sh`

- [ ] **Step 3: Run to verify it fails**

Run: `scripts/test-column-classifier.sh`
Expected: FAIL — `cannot find 'ColumnClassifier' in scope`.

- [ ] **Step 4: Implement `ColumnClassifier.swift`**

Create `Pharos/Models/Charts/ColumnClassifier.swift`:

```swift
import Foundation

/// Classifies a PostgreSQL column type string into a ColumnKind for charting.
enum ColumnClassifier {
    static func kind(forDataType dataType: String) -> ColumnKind {
        let t = dataType.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()

        // Temporal
        if t.hasPrefix("date") || t.hasPrefix("timestamp") || t.hasPrefix("time") {
            return .temporal
        }
        // Numeric
        let numericPrefixes = ["int", "smallint", "bigint", "serial", "smallserial", "bigserial",
                               "float", "double", "real", "numeric", "decimal", "money"]
        if numericPrefixes.contains(where: { t.hasPrefix($0) }) {
            return .numeric
        }
        // Everything else (text, varchar, bool, uuid, enums, arrays, json…)
        return .categorical
    }

    /// Refine a kind by sniffing sample string values when the type is ambiguous.
    /// Values arrive as PG text strings; a column that parses fully as numbers is numeric.
    static func refine(kind: ColumnKind, sampleValues: [String]) -> ColumnKind {
        guard kind == .categorical, !sampleValues.isEmpty else { return kind }
        let allNumeric = sampleValues.allSatisfy { ValueCoercion.double(from: $0) != nil }
        return allNumeric ? .numeric : kind
    }
}
```

Note: `refine` references `ValueCoercion` (Task 4). The base `kind(forDataType:)` — which the tests and `ChartConfig.infer` use — does not, so this task's test compiles standalone. `refine` is exercised in Task 5's aggregator tests once `ValueCoercion` exists; if compiling `refine` alone before Task 4, add `ValueCoercion.swift` to the script's compile list.

- [ ] **Step 5: Run to verify it passes**

Run: `scripts/test-column-classifier.sh`
Expected: PASS, "All tests passed."

- [ ] **Step 6: Re-run Task 2's test now that ColumnClassifier exists**

Run: `scripts/test-chart-config.sh`
Expected: PASS (the `infer`/`validate` assertions now link).

- [ ] **Step 7: Commit**

```bash
git add Pharos/Models/Charts/ColumnClassifier.swift PharosTests/ColumnClassifierTests.swift scripts/test-column-classifier.sh
git commit -m "feat(charts): column type classifier"
```

---

## Task 4: ValueCoercion

**Files:**
- Create: `Pharos/Models/Charts/ValueCoercion.swift`
- Create: `PharosTests/ValueCoercionTests.swift`
- Create: `scripts/test-value-coercion.sh`

- [ ] **Step 1: Write the failing test**

Create `PharosTests/ValueCoercionTests.swift`:

```swift
// Standalone test runner for ValueCoercion.
// Compiled by scripts/test-value-coercion.sh.
import Foundation

var failures = 0
func expect(_ cond: Bool, _ name: String) {
    if cond { print("PASS \(name)") } else { failures += 1; print("FAIL \(name)") }
}

func runTests() {
    // Numbers arrive as strings (PG text format).
    expect(ValueCoercion.double(from: "123") == 123, "int string")
    expect(ValueCoercion.double(from: "1234.56") == 1234.56, "decimal string")
    expect(ValueCoercion.double(from: "-0.5") == -0.5, "negative")
    expect(ValueCoercion.double(from: "9007199254740993") != nil, "big int8 as string parses")
    expect(ValueCoercion.double(from: "not a number") == nil, "non-numeric → nil")
    expect(ValueCoercion.double(from: "") == nil, "empty → nil")

    // From AnyCodable (value is a String, or already a number via the memberwise init).
    expect(ValueCoercion.double(from: AnyCodable("42")) == 42, "AnyCodable string")
    expect(ValueCoercion.double(from: AnyCodable(3.14)) == 3.14, "AnyCodable double")
    expect(ValueCoercion.double(from: AnyCodable(nil)) == nil, "AnyCodable null → nil")

    // Booleans: PG text is t/f.
    expect(ValueCoercion.bool(from: "t") == true, "t → true")
    expect(ValueCoercion.bool(from: "f") == false, "f → false")

    // Dates: PG text formats.
    expect(ValueCoercion.date(from: "2024-01-15") != nil, "date only")
    expect(ValueCoercion.date(from: "2024-01-15 12:30:00+00") != nil, "timestamptz")
    expect(ValueCoercion.date(from: "2024-01-15 12:30:00") != nil, "timestamp no tz")
    expect(ValueCoercion.date(from: "garbage") == nil, "bad date → nil")

    if failures == 0 { print("\nAll tests passed.") } else { print("\n\(failures) failure(s)."); exit(1) }
}
```

- [ ] **Step 2: Create the test script**

Create `scripts/test-value-coercion.sh`:

```bash
#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")/.."
swiftc -o /tmp/value-coercion-tests \
  Pharos/Models/QueryResult.swift \
  Pharos/Models/Charts/ValueCoercion.swift \
  PharosTests/ValueCoercionTests.swift \
  PharosTests/main.swift
/tmp/value-coercion-tests
```

Then: `chmod +x scripts/test-value-coercion.sh`

- [ ] **Step 3: Run to verify it fails**

Run: `scripts/test-value-coercion.sh`
Expected: FAIL — `cannot find 'ValueCoercion' in scope`.

- [ ] **Step 4: Implement `ValueCoercion.swift`**

Create `Pharos/Models/Charts/ValueCoercion.swift`:

```swift
import Foundation

/// Coerces PostgreSQL text-format values (which cross the FFI as JSON strings,
/// decoded into AnyCodable as String) into typed values for charting.
enum ValueCoercion {
    private static let dateFormatters: [DateFormatter] = {
        let patterns = [
            "yyyy-MM-dd HH:mm:ssZ",
            "yyyy-MM-dd HH:mm:ss",
            "yyyy-MM-dd'T'HH:mm:ssZ",
            "yyyy-MM-dd'T'HH:mm:ss",
            "yyyy-MM-dd",
        ]
        return patterns.map { p in
            let f = DateFormatter()
            f.locale = Locale(identifier: "en_US_POSIX")
            f.timeZone = TimeZone(identifier: "UTC")
            f.dateFormat = p
            return f
        }
    }()

    static func double(from s: String) -> Double? {
        let trimmed = s.trimmingCharacters(in: .whitespaces)
        if trimmed.isEmpty { return nil }
        return Double(trimmed)
    }

    static func double(from v: AnyCodable) -> Double? {
        switch v.value {
        case nil: return nil
        case let d as Double: return d
        case let i as Int64: return Double(i)
        case let s as String: return double(from: s)
        default: return nil
        }
    }

    static func bool(from s: String) -> Bool? {
        switch s.trimmingCharacters(in: .whitespaces).lowercased() {
        case "t", "true": return true
        case "f", "false": return false
        default: return nil
        }
    }

    static func date(from s: String) -> Date? {
        let trimmed = s.trimmingCharacters(in: .whitespaces)
        if trimmed.isEmpty { return nil }
        for f in dateFormatters {
            if let d = f.date(from: trimmed) { return d }
        }
        // PG uses "+00" (2-digit) offsets; normalize to "+0000" and retry.
        if let range = trimmed.range(of: #"[+-]\d{2}$"#, options: .regularExpression) {
            let normalized = trimmed + "00"
            _ = range
            for f in dateFormatters {
                if let d = f.date(from: normalized) { return d }
            }
        }
        return nil
    }
}
```

- [ ] **Step 5: Run to verify it passes**

Run: `scripts/test-value-coercion.sh`
Expected: PASS, "All tests passed." (If the `+00` timestamptz case fails, confirm the normalization branch appends to produce `+0000`.)

- [ ] **Step 6: Commit**

```bash
git add Pharos/Models/Charts/ValueCoercion.swift PharosTests/ValueCoercionTests.swift scripts/test-value-coercion.sh
git commit -m "feat(charts): PG text value coercion"
```

---

## Task 5: ChartData model + ChartAggregator

**Files:**
- Create: `Pharos/Models/Charts/ChartData.swift`
- Create: `Pharos/Models/Charts/ChartAggregator.swift`
- Create: `PharosTests/ChartAggregatorTests.swift`
- Create: `scripts/test-chart-aggregator.sh`

- [ ] **Step 1: Write `ChartData.swift`**

Create `Pharos/Models/Charts/ChartData.swift`:

```swift
import Foundation

enum EmptyReason: String, Codable {
    case noColumns    // no type-compatible columns for the chart type
    case allNull      // value column is entirely null
    case noData       // restored result whose rows were demoted; re-run to chart
}

/// One (x, y) style point. `xLabel` is the display/category string; `xValue`
/// is a numeric position when the axis is numeric/temporal (epoch seconds).
struct ChartPoint {
    var xLabel: String
    var xValue: Double?
    var y: Double
}

/// A gantt bar: a labelled lane spanning [start, end] as epoch seconds.
struct GanttBar {
    var label: String
    var start: Double
    var end: Double
}

/// A named series of points (multi-series when a `series` role is mapped).
struct ChartSeries {
    var name: String            // "" for single-series charts
    var points: [ChartPoint]
}

/// Renderer-agnostic, plot-ready output. Holds no AnyCodable, no ChartConfig.
struct ChartData {
    var series: [ChartSeries] = []
    var ganttBars: [GanttBar] = []
    var plottedRowCount: Int = 0
    var totalLoadedRowCount: Int = 0
    var wasTruncated: Bool = false     // top-N cap applied
    var wasSampled: Bool = false       // scatter sampling applied
    var otherBucketCount: Int = 0
    var emptyReason: EmptyReason? = nil

    static func empty(_ reason: EmptyReason) -> ChartData {
        var d = ChartData(); d.emptyReason = reason; return d
    }
}
```

- [ ] **Step 2: Write the failing aggregator test**

Create `PharosTests/ChartAggregatorTests.swift`:

```swift
// Standalone test runner for ChartAggregator.
// Compiled by scripts/test-chart-aggregator.sh.
import Foundation

var failures = 0
func expect(_ cond: Bool, _ name: String) {
    if cond { print("PASS \(name)") } else { failures += 1; print("FAIL \(name)") }
}

// Helper: build a QueryResult where every cell is a PG-text string (as in prod).
func makeResult(_ columns: [(String, String)], _ rows: [[String?]]) -> QueryResult {
    let cols = columns.map { ColumnDef(name: $0.0, dataType: $0.1) }
    let anyRows = rows.map { row in row.map { AnyCodable($0 as Any?) } }
    return QueryResult(columns: cols, rows: anyRows, rowCount: rows.count,
                       executionTimeMs: 0, hasMore: false, historyEntryId: nil)
}

func runTests() {
    // --- Bar: group by category, SUM value ---
    let sales = makeResult([("month", "text"), ("revenue", "numeric")],
                           [["Jan", "100"], ["Feb", "200"], ["Jan", "50"]])
    var cfg = ChartConfig(chartType: .bar, temporalBin: .none)
    cfg.mappings[.category] = ColumnRef(index: 0, name: "month")
    cfg.mappings[.value] = ColumnRef(index: 1, name: "revenue")
    cfg.aggregation = .sum
    let bar = ChartAggregator.aggregate(sales, cfg)
    expect(bar.series.count == 1, "bar: single series")
    let jan = bar.series[0].points.first { $0.xLabel == "Jan" }
    expect(jan?.y == 150, "bar: Jan summed to 150")
    expect(bar.plottedRowCount == 3, "bar: plotted 3 loaded rows")

    // --- count aggregation ignores value numerics ---
    var countCfg = cfg; countCfg.aggregation = .count
    let counted = ChartAggregator.aggregate(sales, countCfg)
    expect(counted.series[0].points.first { $0.xLabel == "Jan" }?.y == 2, "count: Jan appears twice")

    // --- duplicate column names resolve by index ---
    let dup = makeResult([("id", "text"), ("id", "numeric")],
                         [["a", "10"], ["a", "5"]])
    var dupCfg = ChartConfig(chartType: .bar, temporalBin: .none)
    dupCfg.mappings[.category] = ColumnRef(index: 0, name: "id")
    dupCfg.mappings[.value] = ColumnRef(index: 1, name: "id")
    dupCfg.aggregation = .sum
    let dupOut = ChartAggregator.aggregate(dup, dupCfg)
    expect(dupOut.series[0].points.first { $0.xLabel == "a" }?.y == 15, "dup names resolve by index")

    // --- temporal binning: two timestamps same month collapse to one bucket ---
    let ts = makeResult([("ts", "timestamptz"), ("v", "numeric")],
                        [["2024-01-01 01:00:00+00", "1"],
                         ["2024-01-31 23:00:00+00", "2"],
                         ["2024-02-05 10:00:00+00", "4"]])
    var tcfg = ChartConfig(chartType: .line, temporalBin: .month)
    tcfg.mappings[.category] = ColumnRef(index: 0, name: "ts")
    tcfg.mappings[.value] = ColumnRef(index: 1, name: "v")
    tcfg.aggregation = .sum
    let tout = ChartAggregator.aggregate(ts, tcfg)
    expect(tout.series[0].points.count == 2, "binning: 3 rows → 2 monthly buckets")

    // --- top-N capping rolls remainder into Other ---
    var many: [[String?]] = []
    for i in 0..<30 { many.append(["c\(i)", "\(30 - i)"]) }  // descending values
    let big = makeResult([("c", "text"), ("v", "numeric")], many)
    var bigCfg = cfg; bigCfg.display.topNCategories = 5
    let bigOut = ChartAggregator.aggregate(big, bigCfg)
    expect(bigOut.wasTruncated, "topN: truncation flagged")
    expect(bigOut.series[0].points.contains { $0.xLabel == "Other" }, "topN: Other bucket present")

    // --- gantt: label + start + end, no aggregation ---
    let tasks = makeResult([("task", "text"), ("s", "date"), ("e", "date")],
                           [["A", "2024-01-01", "2024-01-05"],
                            ["B", "2024-01-03", "2024-01-08"]])
    var gcfg = ChartConfig(chartType: .gantt)
    gcfg.mappings[.label] = ColumnRef(index: 0, name: "task")
    gcfg.mappings[.start] = ColumnRef(index: 1, name: "s")
    gcfg.mappings[.end] = ColumnRef(index: 2, name: "e")
    let gout = ChartAggregator.aggregate(tasks, gcfg)
    expect(gout.ganttBars.count == 2, "gantt: two bars")
    expect(gout.ganttBars[0].end > gout.ganttBars[0].start, "gantt: end after start")

    // --- degenerate: value column all null ---
    let nullish = makeResult([("m", "text"), ("v", "numeric")], [["Jan", nil], ["Feb", nil]])
    let nout = ChartAggregator.aggregate(nullish, cfg)
    expect(nout.emptyReason == .allNull, "degenerate: allNull")

    // --- degenerate: missing required role ---
    let noValue = ChartConfig(chartType: .bar)
    let mout = ChartAggregator.aggregate(sales, noValue)
    expect(mout.emptyReason == .noColumns, "degenerate: noColumns when role unmapped")

    if failures == 0 { print("\nAll tests passed.") } else { print("\n\(failures) failure(s)."); exit(1) }
}
```

- [ ] **Step 3: Create the test script**

Create `scripts/test-chart-aggregator.sh`:

```bash
#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")/.."
swiftc -o /tmp/chart-aggregator-tests \
  Pharos/Models/QueryResult.swift \
  Pharos/Models/Charts/ChartTypes.swift \
  Pharos/Models/Charts/ChartConfig.swift \
  Pharos/Models/Charts/ColumnClassifier.swift \
  Pharos/Models/Charts/ValueCoercion.swift \
  Pharos/Models/Charts/ChartData.swift \
  Pharos/Models/Charts/ChartAggregator.swift \
  PharosTests/ChartAggregatorTests.swift \
  PharosTests/main.swift
/tmp/chart-aggregator-tests
```

Then: `chmod +x scripts/test-chart-aggregator.sh`

- [ ] **Step 4: Run to verify it fails**

Run: `scripts/test-chart-aggregator.sh`
Expected: FAIL — `cannot find 'ChartAggregator' in scope`.

- [ ] **Step 5: Implement `ChartAggregator.swift`**

Create `Pharos/Models/Charts/ChartAggregator.swift`:

```swift
import Foundation

/// Pure transform from a loaded QueryResult + ChartConfig into plot-ready ChartData.
enum ChartAggregator {

    static func aggregate(_ result: QueryResult, _ config: ChartConfig) -> ChartData {
        switch config.chartType {
        case .gantt:   return aggregateGantt(result, config)
        case .scatter: return aggregateScatter(result, config)
        default:       return aggregateCategorical(result, config)
        }
    }

    // MARK: - Categorical (bar/line/area/pie)

    private static func aggregateCategorical(_ result: QueryResult, _ config: ChartConfig) -> ChartData {
        guard let catRef = config.mappings[.category], let valRef = config.mappings[.value],
              catRef.index < result.columns.count, valRef.index < result.columns.count else {
            return .empty(.noColumns)
        }
        let seriesRef = config.mappings[.series]
        let catKind = ColumnClassifier.kind(forDataType: result.columns[catRef.index].dataType)

        // Accumulator keyed by (seriesName, categoryLabel).
        struct Key: Hashable { let series: String; let cat: String }
        var sums: [Key: Double] = [:]
        var counts: [Key: Int] = [:]
        var mins: [Key: Double] = [:]
        var maxs: [Key: Double] = [:]
        var order: [String] = []           // category label first-seen order
        var seen = Set<String>()
        var sawAnyValue = false
        var plotted = 0

        for row in result.rows {
            guard catRef.index < row.count, valRef.index < row.count else { continue }
            let rawCat = row[catRef.index]
            let catLabel = categoryLabel(rawCat, kind: catKind, bin: config.temporalBin)
            let seriesName = seriesRef.map { row[$0.index].displayString } ?? ""

            let key = Key(series: seriesName, cat: catLabel)
            if !seen.contains(catLabel) { seen.insert(catLabel); order.append(catLabel) }

            if config.aggregation == .count {
                counts[key, default: 0] += 1
                sawAnyValue = true
                plotted += 1
                continue
            }
            guard let y = ValueCoercion.double(from: row[valRef.index]) else { continue }
            sawAnyValue = true
            plotted += 1
            sums[key, default: 0] += y
            counts[key, default: 0] += 1
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

        // Top-N capping (skip for temporal axes — buckets are bounded/ordered).
        var categories = order
        var truncated = false
        var otherCount = 0
        if catKind != .temporal && categories.count > config.display.topNCategories {
            // Rank by total value across series.
            let totals = Dictionary(grouping: sums.keys.isEmpty ? counts.keys.map { $0 } : sums.keys.map { $0 }) { $0.cat }
            func catTotal(_ c: String) -> Double {
                totals[c]?.reduce(0) { $0 + value($1) } ?? 0
            }
            let ranked = categories.sorted { catTotal($0) > catTotal($1) }
            let kept = Array(ranked.prefix(config.display.topNCategories))
            let keptSet = Set(kept)
            otherCount = categories.count - kept.count
            truncated = otherCount > 0
            categories = kept
            if truncated { categories.append("Other") }
            // Fold dropped categories into Other per series.
            let seriesNames = Set(sums.keys.map { $0.series }).union(counts.keys.map { $0.series })
            for s in seriesNames {
                var otherVal = 0.0
                for c in ranked where !keptSet.contains(c) { otherVal += value(Key(series: s, cat: c)) }
                if otherVal != 0 { sums[Key(series: s, cat: "Other")] = otherVal }
            }
        }

        // Build series.
        let seriesNames = seriesRef == nil ? [""] : orderedSeriesNames(sums: sums, counts: counts)
        var out = ChartData()
        for s in seriesNames {
            var pts: [ChartPoint] = []
            for c in categories {
                let k = Key(series: s, cat: c)
                let hasData = sums[k] != nil || counts[k] != nil || c == "Other"
                if hasData { pts.append(ChartPoint(xLabel: c, xValue: nil, y: value(k))) }
            }
            out.series.append(ChartSeries(name: s, points: pts))
        }
        out.plottedRowCount = plotted
        out.totalLoadedRowCount = result.rows.count
        out.wasTruncated = truncated
        out.otherBucketCount = otherCount
        return out
    }

    private static func orderedSeriesNames(sums: [AnyHashable: Double], counts: [AnyHashable: Int]) -> [String] {
        // Series names are collected deterministically (sorted) for stable legends.
        var names = Set<String>()
        for k in sums.keys { if let key = k as? AnyHashable { _ = key } }
        return Array(names).sorted()
    }

    // MARK: - Scatter

    private static func aggregateScatter(_ result: QueryResult, _ config: ChartConfig) -> ChartData {
        guard let xRef = config.mappings[.x], let yRef = config.mappings[.y],
              xRef.index < result.columns.count, yRef.index < result.columns.count else {
            return .empty(.noColumns)
        }
        var pts: [ChartPoint] = []
        for row in result.rows {
            guard xRef.index < row.count, yRef.index < row.count,
                  let x = ValueCoercion.double(from: row[xRef.index]),
                  let y = ValueCoercion.double(from: row[yRef.index]) else { continue }
            pts.append(ChartPoint(xLabel: "", xValue: x, y: y))
        }
        if pts.isEmpty { return .empty(.allNull) }

        var out = ChartData()
        // macOS 15+ renders scatter via the vectorized PointPlot API (Task 11),
        // which handles 100k+ points, so no sampling is needed in normal use.
        // Keep only a high safety cap to bound worst-case memory; it flags
        // wasSampled so the UI can note it in the rare case it trips.
        let safetyCap = 100_000
        if pts.count > safetyCap {
            let stride = Double(pts.count) / Double(safetyCap)
            var sampled: [ChartPoint] = []
            var i = 0.0
            while Int(i) < pts.count { sampled.append(pts[Int(i)]); i += stride }
            out.wasSampled = true
            out.series = [ChartSeries(name: "", points: sampled)]
        } else {
            out.series = [ChartSeries(name: "", points: pts)]
        }
        out.plottedRowCount = out.series.first?.points.count ?? 0
        out.totalLoadedRowCount = result.rows.count
        return out
    }

    // MARK: - Gantt

    private static func aggregateGantt(_ result: QueryResult, _ config: ChartConfig) -> ChartData {
        guard let labelRef = config.mappings[.label], let startRef = config.mappings[.start],
              let endRef = config.mappings[.end],
              labelRef.index < result.columns.count,
              startRef.index < result.columns.count,
              endRef.index < result.columns.count else {
            return .empty(.noColumns)
        }
        var bars: [GanttBar] = []
        for row in result.rows {
            guard labelRef.index < row.count, startRef.index < row.count, endRef.index < row.count,
                  let start = epoch(from: row[startRef.index]),
                  let end = epoch(from: row[endRef.index]) else { continue }
            bars.append(GanttBar(label: row[labelRef.index].displayString, start: start, end: end))
        }
        if bars.isEmpty { return .empty(.allNull) }
        var out = ChartData()
        out.ganttBars = bars
        out.plottedRowCount = bars.count
        out.totalLoadedRowCount = result.rows.count
        return out
    }

    // MARK: - Helpers

    /// A category's display label, applying temporal binning when applicable.
    private static func categoryLabel(_ v: AnyCodable, kind: ColumnKind, bin: TemporalBin) -> String {
        if kind == .temporal, bin != .none, case let s as String = v.value, let date = ValueCoercion.date(from: s) {
            return binLabel(date, bin: bin)
        }
        return v.displayString
    }

    private static func binLabel(_ date: Date, bin: TemporalBin) -> String {
        var cal = Calendar(identifier: .gregorian)
        cal.timeZone = TimeZone(identifier: "UTC")!
        let c = cal.dateComponents([.year, .month, .day, .hour, .weekOfYear], from: date)
        switch bin {
        case .year:  return String(format: "%04d", c.year ?? 0)
        case .month: return String(format: "%04d-%02d", c.year ?? 0, c.month ?? 0)
        case .week:  return String(format: "%04d-W%02d", c.year ?? 0, c.weekOfYear ?? 0)
        case .day:   return String(format: "%04d-%02d-%02d", c.year ?? 0, c.month ?? 0, c.day ?? 0)
        case .hour:  return String(format: "%04d-%02d-%02d %02d:00", c.year ?? 0, c.month ?? 0, c.day ?? 0, c.hour ?? 0)
        case .auto:  return String(format: "%04d-%02d-%02d", c.year ?? 0, c.month ?? 0, c.day ?? 0) // resolved upstream; default day
        case .none:  return ""
        }
    }

    private static func epoch(from v: AnyCodable) -> Double? {
        if case let s as String = v.value {
            if let d = ValueCoercion.date(from: s) { return d.timeIntervalSince1970 }
            return ValueCoercion.double(from: s)   // numeric gantt axis
        }
        return ValueCoercion.double(from: v)
    }
}
```

Note on `.auto` binning: for phase 1 `.auto` resolves to daily bucketing inside `binLabel`. A follow-up refinement (still phase 1, optional) is to compute the data's min/max date span in `aggregateCategorical` and pass a resolved bin down; keep `.auto`→day as the shipped default so the test suite is deterministic.

- [ ] **Step 6: Fix multi-series name collection**

The `orderedSeriesNames` helper above is a stub. Replace the `aggregateCategorical` series-name logic: collect series names while iterating rows into an ordered structure. Update the accumulation loop to also record `if !seriesSeen.contains(seriesName) { seriesSeen.insert(seriesName); seriesOrder.append(seriesName) }` (add `var seriesOrder: [String] = []` and `var seriesSeen = Set<String>()` near `order`/`seen`), then build series from `seriesRef == nil ? [""] : seriesOrder`. Delete the `orderedSeriesNames` stub.

- [ ] **Step 7: Run to verify it passes**

Run: `scripts/test-chart-aggregator.sh`
Expected: PASS for all assertions, "All tests passed." Fix accumulation/top-N logic until green.

- [ ] **Step 8: Commit**

```bash
git add Pharos/Models/Charts/ChartData.swift Pharos/Models/Charts/ChartAggregator.swift PharosTests/ChartAggregatorTests.swift scripts/test-chart-aggregator.sh
git commit -m "feat(charts): chart aggregator (grouping, binning, gantt, scatter, top-N)"
```

---

## Task 6: SQLite persistence — migration + write + read

**Files:**
- Modify: `pharos-core/src/db/sqlite.rs` (migration ~line 355; `update_result_meta` ~line 807; `load_workspace` SELECT ~line 931)

- [ ] **Step 1: Write the failing in-file test**

In `pharos-core/src/db/sqlite.rs`, find an existing workspace round-trip test module (e.g. `workspace_roundtrip_tests`). Add a test that inserts a workspace + result, writes chart state, reloads, and asserts it round-trips. Use `chrono::Utc::now()` timestamps. Model it on the existing round-trip test's setup:

```rust
#[test]
fn chart_view_state_round_trips() {
    let dir = std::env::temp_dir().join(format!("pharos_chart_{}", std::process::id()));
    std::fs::create_dir_all(&dir).unwrap();
    let db = dir.join("meta.db");
    let conn = Connection::open(&db).unwrap();
    init_database(&conn).unwrap();

    // Minimal workspace + result row (see the existing roundtrip test for the
    // exact helper inserts; reuse them here).
    let now = chrono::Utc::now().to_rfc3339();
    conn.execute(
        "INSERT INTO workspaces (id, connection_id, connection_name, editor_text, created_at, last_activity_at)
         VALUES ('ws1','c1','conn','SELECT 1', ?1, ?1)", [&now]).unwrap();
    conn.execute(
        "INSERT INTO query_history (id, connection_id, connection_name, sql, executed_at, execution_time_ms, row_count, workspace_id, result_order)
         VALUES ('h1','c1','conn','SELECT 1', ?1, 1, 1, 'ws1', 0)", [&now]).unwrap();

    let json = r#"{"viewMode":"chart","chartConfig":{"chartType":"bar"}}"#;
    let ok = update_result_chart_state(&conn, "h1", json).unwrap();
    assert!(ok, "update returns true");

    let detail = load_workspace(&conn, "ws1").unwrap().unwrap();
    let r = detail.results.iter().find(|r| r.id == "h1").unwrap();
    assert_eq!(r.chart_view_state_json.as_deref(), Some(json));

    std::fs::remove_dir_all(&dir).ok();
}
```

- [ ] **Step 2: Run to verify it fails**

Run: `cd pharos-core && cargo test chart_view_state_round_trips`
Expected: FAIL — `cannot find function update_result_chart_state` and `no field chart_view_state_json`.

- [ ] **Step 3: Add the migration**

In `sqlite.rs`, immediately after the workspace-association migration block (after line ~394, before the FTS backfill comment at ~396), add:

```rust
    // Migration: Add chart view-state blob to query_history
    let has_chart_col: bool = conn
        .prepare("SELECT COUNT(*) FROM pragma_table_info('query_history') WHERE name = 'chart_view_state_json'")?
        .query_row([], |row| row.get::<_, i64>(0))
        .map(|count| count > 0)
        .unwrap_or(false);

    if !has_chart_col {
        conn.execute_batch(
            "ALTER TABLE query_history ADD COLUMN chart_view_state_json TEXT;"
        )?;
    }
```

- [ ] **Step 4: Add the write function**

In `sqlite.rs`, after `update_result_meta` (~line 820), add:

```rust
pub fn update_result_chart_state(
    conn: &Connection,
    result_id: &str,
    json: &str,
) -> SqliteResult<bool> {
    let n = conn.execute(
        "UPDATE query_history SET chart_view_state_json = ?2 WHERE id = ?1",
        (result_id, json),
    )?;
    Ok(n > 0)
}
```

- [ ] **Step 5: Add the column to the load SELECT**

In `load_workspace` (~line 931), extend the SELECT and the row mapping:

Change the SELECT list to add `chart_view_state_json`:
```rust
        "SELECT id, sql, result_order, color_index, custom_label, row_count, column_count,
                schema, table_names, (result_columns IS NOT NULL) AS has_results,
                execution_time_ms, executed_at, chart_view_state_json
         FROM query_history WHERE workspace_id = ?1
         ORDER BY result_order ASC, executed_at ASC",
```

And in the `WorkspaceResultMeta { … }` initializer add, after `executed_at: row.get(11)?,`:
```rust
                chart_view_state_json: row.get(12)?,
```

(The model field is added in Task 7; if compiling before then, do Task 7 Step 1 first — they commit together.)

- [ ] **Step 6: Run to verify it passes**

Run: `cd pharos-core && cargo test chart_view_state_round_trips`
Expected: PASS (after Task 7's model field exists).

- [ ] **Step 7: Commit** (jointly with Task 7)

Deferred to Task 7 Step 4.

---

## Task 7: Rust model + command

**Files:**
- Modify: `pharos-core/src/models/workspace.rs`
- Modify: `pharos-core/src/commands/workspace.rs`

- [ ] **Step 1: Add the model field**

In `pharos-core/src/models/workspace.rs`, add to `WorkspaceResultMeta`, after `pub executed_at: String,`:

```rust
    pub chart_view_state_json: Option<String>,
```

The struct already has `#[serde(rename_all = "camelCase")]`, so this serializes as `chartViewStateJson` — matching the Swift side (Task 9).

- [ ] **Step 2: Add the command**

In `pharos-core/src/commands/workspace.rs`, after `update_result_meta` (~line 60), add:

```rust
pub async fn update_result_chart_state(
    result_id: String, json: String, state: &AppState,
) -> Result<bool, String> {
    let db = state.metadata_db.lock().map_err(|e| e.to_string())?;
    sqlite::update_result_chart_state(&db, &result_id, &json)
        .map_err(|e| format!("Failed to update chart state: {}", e))
}
```

- [ ] **Step 3: Export the command if needed**

Check `pharos-core/src/commands/mod.rs` — if `update_result_meta` is re-exported there (e.g. `pub use workspace::*` or an explicit list), ensure `update_result_chart_state` is exported the same way. Run: `grep -n "update_result_meta" pharos-core/src/commands/mod.rs` and mirror it.

- [ ] **Step 4: Build + run the Task 6 test, then commit**

Run: `cd pharos-core && cargo test chart_view_state_round_trips`
Expected: PASS.

```bash
git add pharos-core/src/db/sqlite.rs pharos-core/src/models/workspace.rs pharos-core/src/commands/workspace.rs pharos-core/src/commands/mod.rs
git commit -m "feat(charts): persist chart view state on query_history"
```

---

## Task 8: FFI wrapper

**Files:**
- Modify: `pharos-core/src/ffi/workspace.rs`

- [ ] **Step 1: Add the FFI function**

In `pharos-core/src/ffi/workspace.rs`, after `pharos_update_result_meta` (~line 141), add (mirroring its structure):

```rust
#[no_mangle]
pub extern "C" fn pharos_update_result_chart_state(json: *const c_char) -> *mut c_char {
    ffi_sync!({
        let state = app_state();
        let rt = runtime();
        let s = unsafe { c_str_to_string(json) };
        #[derive(serde::Deserialize)]
        #[serde(rename_all = "camelCase")]
        struct U { result_id: String, json: String }
        let u: U = match serde_json::from_str(&s) { Ok(u) => u, Err(e) => return to_c_string(&serde_json::json!({"error": e.to_string()}).to_string()) };
        match rt.block_on(crate::commands::update_result_chart_state(u.result_id, u.json, state)) {
            Ok(ok) => to_c_string(if ok { "true" } else { "false" }),
            Err(e) => to_c_string(&serde_json::json!({"error": e}).to_string()),
        }
    })
}
```

(Match the existing file's attribute style — if the other `pharos_*` fns use a bare `pub extern "C"` without `#[no_mangle]`, drop `#[no_mangle]` to match; cbindgen requires whatever the file already relies on.)

- [ ] **Step 2: Build to regenerate the C header**

Run: `cd pharos-core && cargo build --release`
Expected: builds cleanly; cbindgen regenerates the header so `pharos_update_result_chart_state` is declared for Swift.

- [ ] **Step 3: Verify the symbol is in the generated header**

Run: `grep -rn "pharos_update_result_chart_state" pharos-core/ Pharos/ 2>/dev/null | grep -i "\.h:"`
Expected: at least one hit in the generated header (path per the existing header, e.g. under `pharos-core/include/` or the `CPharosCore` module map location).

- [ ] **Step 4: Commit**

```bash
git add pharos-core/src/ffi/workspace.rs
git add -A pharos-core   # include regenerated header if tracked
git commit -m "feat(charts): FFI for update_result_chart_state"
```

---

## Task 9: Swift FFI wrapper + model field

**Files:**
- Modify: `Pharos/Core/PharosCore+Workspaces.swift`
- Modify: `Pharos/Models/Workspace.swift`

- [ ] **Step 1: Add the Swift model field**

In `Pharos/Models/Workspace.swift`, add to `WorkspaceResultMeta`, after `let executionTimeMs: Int` / near the other fields (plain camelCase, NO CodingKeys — matches Rust `rename_all = "camelCase"`):

```swift
    let chartViewStateJson: String?
```

Place it consistently with the field order; since there are no `CodingKeys`, position doesn't affect decoding, but keep it adjacent to `executedAt` for readability.

- [ ] **Step 2: Add the Swift wrapper**

In `Pharos/Core/PharosCore+Workspaces.swift`, after `updateResultMeta` (~line 79, inside the `extension PharosCore`), add:

```swift
    struct UpdateResultChartStatePayload: Codable { let resultId: String; let json: String }

    @discardableResult
    static func updateResultChartState(resultId: String, json: String) throws -> Bool {
        try callBoolResult(input: UpdateResultChartStatePayload(resultId: resultId, json: json)) {
            pharos_update_result_chart_state($0)
        }
    }
```

- [ ] **Step 3: Regenerate project + build**

Run: `xcodegen generate`
Then build in Xcode (Cmd+B) or: `xcodebuild -project Pharos.xcodeproj -scheme Pharos -configuration Debug build 2>&1 | tail -20`
Expected: builds; `pharos_update_result_chart_state` resolves via `CPharosCore`.

- [ ] **Step 4: Commit**

```bash
git add Pharos/Core/PharosCore+Workspaces.swift Pharos/Models/Workspace.swift
git commit -m "feat(charts): Swift wrapper + model field for chart view state"
```

---

## Task 10: ResultTab + ResultViewMode wiring

**Files:**
- Modify: `Pharos/Models/ResultTab.swift`

- [ ] **Step 1: Add chart fields to ResultTab**

In `Pharos/Models/ResultTab.swift`, inside `struct ResultTab`, near `gridState`, add:

```swift
    /// Chart configuration for this result (nil until the user opens Chart mode).
    var chartConfig: ChartConfig?

    /// Whether this result tab currently shows the grid or a chart.
    var resultViewMode: ResultViewMode = .grid
```

- [ ] **Step 2: Build to confirm it compiles**

Run: `xcodegen generate` then build (Cmd+B).
Expected: builds. `ChartConfig`/`ResultViewMode` are visible (same app module).

- [ ] **Step 3: Commit**

```bash
git add Pharos/Models/ResultTab.swift
git commit -m "feat(charts): chartConfig + resultViewMode on ResultTab"
```

---

## Task 11: SwiftUI chart view

**Files:**
- Create: `Pharos/ViewControllers/Charts/ChartView.swift`

- [ ] **Step 1: Implement the Swift Charts view**

Create `Pharos/ViewControllers/Charts/ChartView.swift`. This renders `ChartData` per `ChartType`. Scatter uses the vectorized `PointPlot` API (macOS 15+, the app's floor) so dense scatters render exactly and smoothly with no sampling or availability gating:

```swift
import SwiftUI
import Charts

struct ChartCanvas: View {
    let data: ChartData
    let chartType: ChartType

    var body: some View {
        if let reason = data.emptyReason {
            emptyState(reason)
        } else {
            chart.padding(8)
        }
    }

    @ViewBuilder private var chart: some View {
        switch chartType {
        case .bar:     categoryChart { BarMark(x: .value("Category", $0.xLabel), y: .value("Value", $0.y)) }
        case .line:    categoryChart { LineMark(x: .value("Category", $0.xLabel), y: .value("Value", $0.y)) }
        case .area:    categoryChart { AreaMark(x: .value("Category", $0.xLabel), y: .value("Value", $0.y)) }
        case .pie:     pieChart
        case .scatter: scatterChart
        case .gantt:   ganttChart
        }
    }

    // Bar/line/area, one MarkContent per point, colored by series.
    @ViewBuilder private func categoryChart<M: ChartContent>(@ChartContentBuilder _ mark: @escaping (ChartPoint) -> M) -> some View {
        Chart {
            ForEach(Array(data.series.enumerated()), id: \.offset) { _, series in
                ForEach(Array(series.points.enumerated()), id: \.offset) { _, pt in
                    mark(pt).foregroundStyle(by: .value("Series", series.name.isEmpty ? "value" : series.name))
                }
            }
        }
    }

    @ViewBuilder private var pieChart: some View {
        Chart(data.series.first?.points ?? [], id: \.xLabel) { pt in
            SectorMark(angle: .value("Value", pt.y), innerRadius: .ratio(0.5))
                .foregroundStyle(by: .value("Category", pt.xLabel))
        }
    }

    // Vectorized scatter (macOS 15+). PointPlot takes the whole collection and
    // renders 100k+ points efficiently, so no per-point ForEach or sampling.
    private struct XYPoint: Identifiable { let id = UUID(); let x: Double; let y: Double }

    @ViewBuilder private var scatterChart: some View {
        let pts = (data.series.first?.points ?? []).map { XYPoint(x: $0.xValue ?? 0, y: $0.y) }
        Chart {
            PointPlot(pts, x: .value("X", \.x), y: .value("Y", \.y))
        }
    }

    @ViewBuilder private var ganttChart: some View {
        Chart(Array(data.ganttBars.enumerated()), id: \.offset) { _, bar in
            BarMark(
                xStart: .value("Start", Date(timeIntervalSince1970: bar.start)),
                xEnd: .value("End", Date(timeIntervalSince1970: bar.end)),
                y: .value("Task", bar.label)
            )
        }
        .chartScrollableAxes(.vertical)
    }

    @ViewBuilder private func emptyState(_ reason: EmptyReason) -> some View {
        VStack(spacing: 6) {
            Image(systemName: "chart.bar.xaxis").font(.largeTitle).foregroundStyle(.tertiary)
            Text(message(reason)).foregroundStyle(.secondary).multilineTextAlignment(.center)
        }.frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private func message(_ reason: EmptyReason) -> String {
        switch reason {
        case .noColumns: return "Pick columns to chart."
        case .allNull: return "The selected value column is all null."
        case .noData: return "This result's rows weren't saved. Re-run the query to chart it."
        }
    }
}
```

- [ ] **Step 2: Build**

Run: `xcodegen generate` then build (Cmd+B).
Expected: builds against the macOS 15 SDK. (No unit test — SwiftUI view; verified visually in Task 15.) `PointPlot` and `SectorMark` resolve unconditionally now that the floor is macOS 15.

- [ ] **Step 3: Commit**

```bash
git add Pharos/ViewControllers/Charts/ChartView.swift
git commit -m "feat(charts): SwiftUI Swift Charts canvas"
```

---

## Task 12: Chart root view + view model + config rail

**Files:**
- Create: `Pharos/ViewControllers/Charts/ChartRootView.swift`

- [ ] **Step 1: Implement the view model + root view (rail + banner + canvas)**

Create `Pharos/ViewControllers/Charts/ChartRootView.swift`:

```swift
import SwiftUI

/// Owns the live ChartConfig, recomputes ChartData, and reports config changes.
final class ChartViewModel: ObservableObject {
    @Published var config: ChartConfig
    @Published private(set) var data: ChartData = ChartData()

    let columns: [ColumnDef]
    private let result: QueryResult
    /// Called (debounced by the host) whenever config changes, for persistence.
    var onConfigChanged: ((ChartConfig) -> Void)?

    init(result: QueryResult, columns: [ColumnDef], initialConfig: ChartConfig?) {
        self.result = result
        self.columns = columns
        self.config = initialConfig ?? ChartConfig.infer(from: columns)
        recompute()
    }

    func recompute() { data = ChartAggregator.aggregate(result, config) }

    func update(_ mutate: (inout ChartConfig) -> Void) {
        mutate(&config)
        recompute()
        onConfigChanged?(config)
    }

    func kind(_ ref: ColumnRef?) -> ColumnKind? {
        guard let ref, ref.index < columns.count else { return nil }
        return ColumnClassifier.kind(forDataType: columns[ref.index].dataType)
    }

    /// Columns eligible for a role, by kind.
    func eligible(for role: ChartColumnRole) -> [ColumnRef] {
        let refs = columns.enumerated().map { ColumnRef(index: $0.offset, name: $0.element.name) }
        switch role {
        case .value, .y, .x, .size, .start, .end:
            return refs.filter { r in
                let k = ColumnClassifier.kind(forDataType: columns[r.index].dataType)
                return k == .numeric || (role == .start || role == .end || role == .x ? k == .temporal : false)
            }
        default:
            return refs   // category/series/label/color accept anything
        }
    }
}

struct ChartRootView: View {
    @ObservedObject var model: ChartViewModel
    /// Banner info supplied by the host (loaded/total counts + load-all action).
    let bannerInfo: ChartBannerInfo
    let onLoadAll: () -> Void

    var body: some View {
        VStack(spacing: 0) {
            if bannerInfo.shouldShow { banner }
            HStack(spacing: 0) {
                ChartCanvas(data: model.data, chartType: model.config.chartType)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                Divider()
                configRail.frame(width: 160)
            }
        }
    }

    private var banner: some View {
        HStack(spacing: 8) {
            Image(systemName: "exclamationmark.triangle.fill")
            Text(bannerInfo.text)
            Spacer()
            if bannerInfo.canLoadAll { Button("Load all rows", action: onLoadAll).buttonStyle(.link) }
        }
        .font(.caption)
        .padding(.horizontal, 10).padding(.vertical, 4)
        .background(Color.orange.opacity(0.15))
    }

    private var configRail: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 10) {
                railLabel("Chart type")
                Picker("", selection: Binding(get: { model.config.chartType },
                                              set: { t in model.update { $0.chartType = t } })) {
                    ForEach(ChartType.allCases, id: \.self) { Text($0.displayName).tag($0) }
                }.labelsHidden()

                ForEach(rolesForCurrentType(), id: \.self) { role in
                    railLabel(roleLabel(role))
                    rolePicker(role)
                }

                if usesAggregation {
                    railLabel("Aggregate")
                    Picker("", selection: Binding(get: { model.config.aggregation },
                                                  set: { a in model.update { $0.aggregation = a } })) {
                        ForEach(AggregationFn.allCases, id: \.self) { Text($0.displayName).tag($0) }
                    }.labelsHidden()
                }

                if categoryIsTemporal {
                    railLabel("Time bucket")
                    Picker("", selection: Binding(get: { model.config.temporalBin },
                                                  set: { b in model.update { $0.temporalBin = b } })) {
                        ForEach(TemporalBin.allCases, id: \.self) { Text($0.rawValue.capitalized).tag($0) }
                    }.labelsHidden()
                }
                Spacer()
            }.padding(10)
        }
    }

    // MARK: role helpers
    private func rolesForCurrentType() -> [ChartColumnRole] {
        switch model.config.chartType {
        case .bar, .line, .area, .pie: return [.category, .value, .series]
        case .scatter: return [.x, .y, .size, .color]
        case .gantt: return [.label, .start, .end, .color]
        }
    }
    private var usesAggregation: Bool {
        switch model.config.chartType { case .scatter, .gantt: return false; default: return true }
    }
    private var categoryIsTemporal: Bool {
        model.kind(model.config.mappings[.category]) == .temporal
    }
    private func roleLabel(_ r: ChartColumnRole) -> String {
        switch r {
        case .category: return "Category (X)"; case .value: return "Value (Y)"; case .series: return "Series (optional)"
        case .x: return "X"; case .y: return "Y"; case .size: return "Size (optional)"; case .color: return "Color (optional)"
        case .label: return "Label"; case .start: return "Start"; case .end: return "End"
        }
    }
    private func rolePicker(_ role: ChartColumnRole) -> some View {
        let options = model.eligible(for: role)
        return Picker("", selection: Binding(
            get: { model.config.mappings[role]?.index ?? -1 },
            set: { idx in model.update { cfg in
                if idx < 0 { cfg.mappings[role] = nil }
                else { cfg.mappings[role] = ColumnRef(index: idx, name: model.columns[idx].name) }
            } })) {
            Text("—").tag(-1)
            ForEach(options, id: \.index) { Text($0.name).tag($0.index) }
        }.labelsHidden()
    }
    private func railLabel(_ s: String) -> some View {
        Text(s.uppercased()).font(.system(size: 9, weight: .semibold)).foregroundStyle(.secondary)
    }
}

struct ChartBannerInfo {
    var shouldShow: Bool
    var canLoadAll: Bool
    var text: String
}
```

- [ ] **Step 2: Build**

Run: `xcodegen generate` then build (Cmd+B).
Expected: builds.

- [ ] **Step 3: Commit**

```bash
git add Pharos/ViewControllers/Charts/ChartRootView.swift
git commit -m "feat(charts): chart root view, view model, config rail"
```

---

## Task 13: Chart hosting controller

**Files:**
- Create: `Pharos/ViewControllers/Charts/ChartHostingController.swift`

- [ ] **Step 1: Implement the AppKit host**

Create `Pharos/ViewControllers/Charts/ChartHostingController.swift`:

```swift
import AppKit
import SwiftUI

/// Hosts the SwiftUI chart in the AppKit result area. Owns the view model and
/// exposes an AppKit-facing API for the ContentViewController.
final class ChartHostingController: NSViewController {
    private var model: ChartViewModel?
    private var hosting: NSHostingController<AnyView>?

    /// Reports a config change (debounced by the caller) for persistence.
    var onConfigChanged: ((ChartConfig) -> Void)?
    /// Requests loading all remaining rows for the current result.
    var onLoadAll: (() -> Void)?

    override func loadView() { view = NSView() }

    /// Configure (or reconfigure) for a result.
    func present(result: QueryResult, initialConfig: ChartConfig?, banner: ChartBannerInfo) {
        let vm = ChartViewModel(result: result, columns: result.columns, initialConfig: initialConfig)
        vm.onConfigChanged = { [weak self] cfg in self?.onConfigChanged?(cfg) }
        self.model = vm

        let root = ChartRootView(model: vm, bannerInfo: banner, onLoadAll: { [weak self] in self?.onLoadAll?() })
        let host = NSHostingController(rootView: AnyView(root))
        embed(host)
        self.hosting = host
    }

    /// The current config (for persistence on teardown/tab-switch).
    var currentConfig: ChartConfig? { model?.config }

    private func embed(_ child: NSHostingController<AnyView>) {
        hosting?.view.removeFromSuperview()
        hosting?.removeFromParent()
        addChild(child)
        child.view.translatesAutoresizingMaskIntoConstraints = false
        view.addSubview(child.view)
        NSLayoutConstraint.activate([
            child.view.topAnchor.constraint(equalTo: view.topAnchor),
            child.view.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            child.view.trailingAnchor.constraint(equalTo: view.trailingAnchor),
            child.view.bottomAnchor.constraint(equalTo: view.bottomAnchor),
        ])
    }
}
```

- [ ] **Step 2: Build**

Run: `xcodegen generate` then build (Cmd+B).
Expected: builds.

- [ ] **Step 3: Commit**

```bash
git add Pharos/ViewControllers/Charts/ChartHostingController.swift
git commit -m "feat(charts): NSHostingController-based chart host"
```

---

## Task 14: Integrate toggle + chart host into the result area

**Files:**
- Modify: `Pharos/ViewControllers/ContentViewController.swift` (result-area layout ~120-186; action bar ~789-816; tab select ~540, ~1520)

- [ ] **Step 1: Add stored properties**

Near the top of `ContentViewController` (with other view properties, ~line 22), add:

```swift
    private let chartToggle = NSSegmentedControl(labels: ["Grid", "Chart"], trackingMode: .selectOne, target: nil, action: nil)
    private let chartHost = ChartHostingController()
    private var chartHostTopConstraint: NSLayoutConstraint!
```

- [ ] **Step 2: Add the chart host to the result area (hidden by default)**

In `loadView()`, after `contentStack.addSubview(resultsVC.view)` (line 120), add:

```swift
        addChild(chartHost)
        chartHost.view.translatesAutoresizingMaskIntoConstraints = false
        chartHost.view.isHidden = true
        contentStack.addSubview(chartHost.view)
```

And in the `NSLayoutConstraint.activate([...])` block (after the results constraints ~line 186), add constraints pinning the chart host to the same region as `resultsVC.view`:

```swift
            chartHost.view.topAnchor.constraint(equalTo: resultTabBar.bottomAnchor),
            chartHost.view.leadingAnchor.constraint(equalTo: contentStack.leadingAnchor),
            chartHost.view.trailingAnchor.constraint(equalTo: contentStack.trailingAnchor),
            chartHost.view.bottomAnchor.constraint(equalTo: contentStack.bottomAnchor),
```

- [ ] **Step 3: Add the toggle to the action bar**

In `setupActionBar()`, configure the toggle and insert it at the front of `actionStack` (the stack created at ~line 789). Before the `actionStack` is created, add:

```swift
        chartToggle.selectedSegment = 0
        chartToggle.segmentStyle = .texturedRounded
        chartToggle.target = self
        chartToggle.action = #selector(chartToggleChanged)
        chartToggle.setContentHuggingPriority(.required, for: .horizontal)
```

Then change the `actionStack` initializer to include it first:

```swift
        let actionStack = NSStackView(views: [chartToggle, pinButton, exportButton, copyButton, findToolbarButton, resetSortButton, resetFiltersButton, clearSelectionButton])
```

- [ ] **Step 4: Implement the toggle handler + mode switch**

Add these methods to `ContentViewController`:

```swift
    @objc private func chartToggleChanged() {
        let mode: ResultViewMode = chartToggle.selectedSegment == 1 ? .chart : .grid
        setResultViewMode(mode)
    }

    private func setResultViewMode(_ mode: ResultViewMode) {
        guard let id = activeResultTabId, let idx = resultTabs.firstIndex(where: { $0.id == id }) else { return }
        resultTabs[idx].resultViewMode = mode
        chartToggle.selectedSegment = (mode == .chart) ? 1 : 0

        if mode == .chart {
            presentChart(for: idx)
            chartHost.view.isHidden = false
            resultsVC.view.isHidden = true
        } else {
            chartHost.view.isHidden = true
            resultsVC.view.isHidden = false
        }
        persistChartState(for: idx)
    }

    private func presentChart(for idx: Int) {
        guard let result = resultTabs[idx].queryResult else {
            // Restored result with demoted rows: show the re-run empty state.
            chartHost.present(result: QueryResult(columns: [], rows: [], rowCount: 0, executionTimeMs: 0, hasMore: false, historyEntryId: nil),
                              initialConfig: resultTabs[idx].chartConfig,
                              banner: ChartBannerInfo(shouldShow: false, canLoadAll: false, text: ""))
            return
        }
        // Validate stored config against the current column shape.
        var cfg = resultTabs[idx].chartConfig
        cfg?.validate(against: result.columns)
        chartHost.onConfigChanged = { [weak self] newCfg in
            guard let self, let i = self.resultTabs.firstIndex(where: { $0.id == self.activeResultTabId }) else { return }
            self.resultTabs[i].chartConfig = newCfg
            self.scheduleChartStatePersist(for: i)
        }
        chartHost.onLoadAll = { [weak self] in self?.loadAllRowsForChart() }
        chartHost.present(result: result, initialConfig: cfg, banner: bannerInfo(for: idx, result: result))
        resultTabs[idx].chartConfig = chartHost.currentConfig
    }
```

- [ ] **Step 5: Build**

Run: `xcodegen generate` then build (Cmd+B).
Expected: builds. (`bannerInfo`, `persistChartState`, `scheduleChartStatePersist`, `loadAllRowsForChart` are added in Task 15/16 — add empty stubs now to compile, filled next.)

Add temporary stubs:

```swift
    private func bannerInfo(for idx: Int, result: QueryResult) -> ChartBannerInfo {
        ChartBannerInfo(shouldShow: false, canLoadAll: false, text: "")
    }
    private func persistChartState(for idx: Int) {}
    private func scheduleChartStatePersist(for idx: Int) {}
    private func loadAllRowsForChart() {}
```

- [ ] **Step 6: Commit**

```bash
git add Pharos/ViewControllers/ContentViewController.swift
git commit -m "feat(charts): Grid/Chart toggle + chart host in result area"
```

---

## Task 15: Banner + Load all (in-memory)

**Files:**
- Modify: `Pharos/ViewControllers/ContentViewController.swift`

- [ ] **Step 1: Implement `bannerInfo`**

Replace the `bannerInfo` stub. The banner shows when the chart covers a subset — including restored partials where `hasMore` is forced false, detected via `WorkspaceResultMeta.rowCount` captured on the tab (see note). For phase 1, drive it from `hasMore` and the aggregator's flags surfaced via the current data (re-aggregate to read them, or store counts). Minimal version:

```swift
    private func bannerInfo(for idx: Int, result: QueryResult) -> ChartBannerInfo {
        let loaded = result.rows.count
        let canLoadMore = result.hasMore
        // rowCount from the source (history/live). If unknown, fall back to loaded.
        let total = resultTabs[idx].totalRowCountHint ?? loaded
        let subset = canLoadMore || total > loaded
        guard subset else { return ChartBannerInfo(shouldShow: false, canLoadAll: false, text: "") }
        let text = "Charting \(loaded)\(total > loaded ? " of \(total)" : "") loaded rows, aggregated client-side."
        return ChartBannerInfo(shouldShow: true, canLoadAll: canLoadMore, text: text)
    }
```

Add a `var totalRowCountHint: Int?` to `ResultTab` (set it from `QueryResult.rowCount` on execute and from `WorkspaceResultMeta.rowCount` on reopen — Task 16). Rebuild the aggregator scripts are unaffected (ResultTab isn't compiled there).

- [ ] **Step 2: Implement `loadAllRowsForChart` (in-memory only)**

Replace the stub. Reuse the existing `loadMoreRows()`/`onLoadMore` fetch path in a loop until `hasMore` is false or a safety cap is hit, WITHOUT writing rows back to the history blob, then re-present the chart:

```swift
    private func loadAllRowsForChart() {
        guard let id = activeResultTabId, let idx = resultTabs.firstIndex(where: { $0.id == id }),
              let result = resultTabs[idx].queryResult, result.hasMore else { return }
        let cap = 200_000
        fetchAllRemaining(upTo: cap) { [weak self] in
            guard let self, let i = self.resultTabs.firstIndex(where: { $0.id == self.activeResultTabId }) else { return }
            if self.resultTabs[i].resultViewMode == .chart { self.presentChart(for: i) }
        }
    }
```

Implement `fetchAllRemaining(upTo:completion:)` by looping the existing fetch-more FFI (`PharosCore.fetchMoreRows` or whatever `loadMoreRows()` calls), appending into `resultTabs[i].queryResult`. Inspect `loadMoreRows()` (~line 195 wiring, and its implementation) and mirror its append logic; stop when `!hasMore` or count ≥ cap. **Do not** call any workspace result-blob writeback in this loop.

- [ ] **Step 3: Build + manual smoke test**

Run: `xcodegen generate`, build, run (Cmd+R). Execute a query with many rows, switch to Chart. Confirm the banner shows loaded/total and *Load all* fetches and re-renders. Confirm a small result shows no banner.
Expected: banner behavior correct; chart updates after load-all.

- [ ] **Step 4: Commit**

```bash
git add Pharos/ViewControllers/ContentViewController.swift Pharos/Models/ResultTab.swift
git commit -m "feat(charts): loaded-rows banner + in-memory load-all"
```

---

## Task 16: Persistence wiring (debounced save + restore)

**Files:**
- Modify: `Pharos/ViewControllers/ContentViewController.swift` (persist on change; restore in reopen path ~2020-2045; tab-switch capture ~1467/1520)

- [ ] **Step 1: Implement debounced persist**

Replace the `persistChartState`/`scheduleChartStatePersist` stubs. Add a debounce timer property `private var chartPersistWorkItem: DispatchWorkItem?`:

```swift
    private func scheduleChartStatePersist(for idx: Int) {
        chartPersistWorkItem?.cancel()
        let item = DispatchWorkItem { [weak self] in self?.persistChartState(for: idx) }
        chartPersistWorkItem = item
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.6, execute: item)
    }

    private func persistChartState(for idx: Int) {
        guard idx < resultTabs.count else { return }
        let tab = resultTabs[idx]
        // Only persist for results that belong to a workspace (have a history id).
        guard let resultId = tab.queryResult?.historyEntryId else { return }
        let state = PersistedResultViewState(chartConfig: tab.chartConfig, viewMode: tab.resultViewMode)
        guard let data = try? JSONEncoder.pharos.encode(state) else { return }
        let json = String(decoding: data, as: UTF8.self)
        DispatchQueue.global(qos: .utility).async {
            try? PharosCore.updateResultChartState(resultId: resultId, json: json)
        }
    }
```

If `ResultTab` has no direct history id accessor, use `queryResult?.historyEntryId`. Confirm the property name during implementation (grep `historyEntryId` usage in ContentViewController).

- [ ] **Step 2: Restore on workspace reopen**

In the reopen path (~line 2025-2038, where `rt` is built from `meta`), after setting the other fields, decode the persisted state:

```swift
                rt.totalRowCountHint = meta.rowCount.map(Int.init)
                if let json = meta.chartViewStateJson,
                   let data = json.data(using: .utf8),
                   let state = try? JSONDecoder.pharos.decode(PersistedResultViewState.self, from: data) {
                    rt.chartConfig = state.chartConfig
                    rt.resultViewMode = state.viewMode
                }
```

Then, after the active tab is selected in the reopen completion, if its `resultViewMode == .chart`, call `setResultViewMode(.chart)` so it opens directly into the chart (which shows the `.noData` empty state when rows were demoted).

- [ ] **Step 3: Restore on tab switch**

In `selectResultTab` (where `gridState` is restored, ~line 540/1520), after restoring grid state, sync the toggle + mode for the newly active tab:

```swift
        chartToggle.selectedSegment = (tab.resultViewMode == .chart) ? 1 : 0
        setResultViewMode(tab.resultViewMode)
```

Ensure `setResultViewMode` is idempotent (it already guards on the active tab). Capture the outgoing tab's `chartConfig` from `chartHost.currentConfig` before switching (mirror the `gridState` capture at ~1467):

```swift
        if let outIdx = resultTabs.firstIndex(where: { $0.id == outgoingId }),
           resultTabs[outIdx].resultViewMode == .chart {
            resultTabs[outIdx].chartConfig = chartHost.currentConfig
        }
```

- [ ] **Step 4: Set `totalRowCountHint` on execute**

Where a fresh `QueryResult` is stored onto a `ResultTab` after execution, set `tab.totalRowCountHint = Int(result.rowCount)`.

- [ ] **Step 5: Build + manual verification**

Run: `xcodegen generate`, build, run.
Verify:
1. Configure a chart, close & reopen the workspace → chart config + mode restored.
2. Reopen a workspace whose result rows were demoted (large/old) → chart mode opens to "re-run to chart" empty state; config still present.
3. Switch between result tabs → each remembers grid vs chart + its config.

- [ ] **Step 6: Commit**

```bash
git add Pharos/ViewControllers/ContentViewController.swift Pharos/Models/ResultTab.swift
git commit -m "feat(charts): persist + restore chart state across reopen and tab switch"
```

---

## Task 17: Full verification pass

**Files:** none (verification only)

- [ ] **Step 1: Run all pure-logic test harnesses**

Run:
```bash
scripts/test-chart-config.sh
scripts/test-column-classifier.sh
scripts/test-value-coercion.sh
scripts/test-chart-aggregator.sh
```
Expected: each ends with "All tests passed."

- [ ] **Step 2: Run Rust tests**

Run: `cd pharos-core && cargo test`
Expected: all pass, including `chart_view_state_round_trips`.

- [ ] **Step 3: Manual end-to-end (use the `verify` skill)**

Run the app (Cmd+R) and exercise each chart type against a real Postgres result:
- Bar/line/area: category + numeric value; try grouped series; try an aggregation change.
- Pie: single categorical breakdown.
- Scatter: two numeric columns; try a >3k-row result and confirm sampling (no beachball).
- Gantt: label + two date columns; confirm bars span and vertical scroll works.
- Temporal: a `timestamptz` category with `.month` binning → readable buckets, not one-per-row.
- Large result: banner counts + Load all.
- Persistence: reopen workspace + tab switching.
- Degenerate: unmapped role, all-null value column, demoted-row reopen.

- [ ] **Step 4: Confirm no regressions in grid mode**

Toggle back to Grid on each result: sort/filter/find/copy/export still work.

- [ ] **Step 5: Final commit (if any verification fixes were needed)**

```bash
git add -A
git commit -m "test(charts): phase-1 verification fixes"
```

---

## Notes for the implementer

- **Execution order:** Tasks 2–5 (pure core) are the safest to build first and are fully TDD. Tasks 6–9 (Rust/FFI/Swift persistence) form one vertical slice — build and commit them together. Tasks 10–16 are UI wiring, verified manually. Task 1 is a tiny prerequisite for the test helpers.
- **Sibling-link caveats** are called out inline (Task 2↔3 on `ColumnClassifier`, Task 3↔4 on `ValueCoercion`, Task 6↔7 on the model field). If a `swiftc`/`cargo` step fails only on an unresolved symbol from a sibling task, complete that sibling's implementation step, then return.
- **cbindgen header path:** confirm where the generated header lives (the `CPharosCore` module map target) and whether it's tracked in git; include it in the Task 8 commit if so.
- **Do not flip any Rust struct's `serde` casing** as a side effect — every workspace type is `rename_all = "camelCase"` and the Swift side depends on it.
