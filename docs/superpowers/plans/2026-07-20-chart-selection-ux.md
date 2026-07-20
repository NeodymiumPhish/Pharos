# Chart Selection & Drill UX Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Replace the chart's commit-on-click drill with a **staged selection** — a gesture (single / Shift / ⌘ click or drag-marquee) builds a selection that dims unselected marks and surfaces a labelled commit button in the action bar; committing (client → grid filters, server → detail query) replaces any prior chart filter. Plus a grid ⌘-click row-toggle parity fix.

**Architecture:** Two new Foundation-only pure helpers — `DrillSummary` (button/chip labels) and `DrillCoverage` (which marks are lit under the merged selection) — are TDD-tested via `swiftc` harnesses. `ChartCanvas` gains selection `@State`, modifier-aware gestures, merged-derived dimming, and a marquee, reporting the staged `[DrillKey]` up via `onSelectionChanged` (replacing `onDrill`). `ContentViewController` owns a new action-bar button that commits via the existing `applyDrill`/`applyServerDrill`. The grid fix is one branch in `ResultsCellSelection`.

**Tech Stack:** Swift 5.10 / AppKit + SwiftUI (Swift Charts), macOS 15. Pure logic via standalone `swiftc` harnesses.

**Reference spec:** `docs/superpowers/specs/2026-07-20-chart-selection-ux-design.md`

---

## Key conventions (read before starting)

- **No Xcode test target.** Pure logic is tested by `swiftc` scripts (impl files + one `PharosTests/XxxTests.swift` + `PharosTests/main.swift`); each test file defines its own `runTests()`/`failures`/`expect`.
- **Chart model/logic files import only `Foundation`.** `DrillSummary` and `DrillCoverage` are Foundation-only, in `Pharos/Models/Charts/`.
- **`DrillKey`** cases: `.anyOf(ColumnRef, [String])`, `.blank(ColumnRef)`, `.range(ColumnRef, Double, Double, RangeKind)`, `.overlap(ColumnRef, ColumnRef, Double, Double, RangeKind)`, `.compound([DrillKey])`. `DrillKey` is `Equatable`. `PharosBlanks.sentinel` is the null sentinel (`Pharos/Utilities/BlanksSentinel.swift`). `DrillMerge.merge(_:)` groups per column (union `.anyOf`, coalesce `.range`, fold lone `.blank`→sentinel, drop `.blank` beside a range).
- **The commit paths already exist** — `applyDrill` (client, grid filters) and `applyServerDrill` (server, detail-query tab) in `ContentViewController`. This plan makes them **button-triggered** and adds **replace** semantics; it does not change how a single set of keys becomes filters/predicates.
- **`project.pbxproj` is tracked** — run `xcodegen generate` and stage it when adding files. App build: `xcodegen generate && xcodebuild -project Pharos.xcodeproj -scheme Pharos -configuration Debug build 2>&1 | tail -25` (Rust pre-build runs; allow a long timeout).
- Re-run all chart harnesses after changes (Task V1).

---

## File Structure

**New (Foundation-only, `Pharos/Models/Charts/`):**
- `DrillSummary.swift` — pure label builder for the commit button + chip.
- `DrillCoverage.swift` — pure "is this mark inside the merged selection?" predicate for dimming.

**Modified:**
- `Pharos/ViewControllers/Charts/ChartView.swift` — selection `@State`, modifier gestures, dimming, marquee, `onSelectionChanged` (replaces `onDrill`); new params `committedKeys`, `clearToken`, `configFingerprint`.
- `Pharos/ViewControllers/Charts/ChartRootView.swift` — `ChartViewModel` gains `selectionKeys`/`committedKeys`/`clearToken`; `ChartRootView` passes the new params to `ChartCanvas`.
- `Pharos/ViewControllers/Charts/ChartHostingController.swift` — `onSelectionChanged` (replaces `onDrill`); `setCommittedKeys(_:)`, `clearSelection()`.
- `Pharos/ViewControllers/ContentViewController.swift` — `chartFilterButton`, staged/committed key storage, commit action, replace in `applyDrill`, chip label via `DrillSummary`.
- `Pharos/ViewControllers/ResultsGrid/ResultsCellSelection.swift` — ⌘-click row toggle.

**New tests + scripts:** `PharosTests/{DrillSummaryTests,DrillCoverageTests}.swift`; `scripts/test-drill-summary.sh`, `scripts/test-drill-coverage.sh`.

---

# Phase A — Pure helpers (TDD)

## Task A1: DrillSummary (button/chip label)

**Files:** Create `Pharos/Models/Charts/DrillSummary.swift`, `PharosTests/DrillSummaryTests.swift`, `scripts/test-drill-summary.sh`.

- [ ] **Step 1: Failing tests** — `PharosTests/DrillSummaryTests.swift`:
```swift
import Foundation

var failures = 0
func expect(_ c: Bool, _ n: String) { if c { print("PASS \(n)") } else { failures += 1; print("FAIL \(n)") } }

func runTests() {
    let country = ColumnRef(index: 3, name: "dst_country")
    let proto = ColumnRef(index: 1, name: "protocol")
    let port = ColumnRef(index: 2, name: "dst_port")

    // Discrete counts, ordered by column index ascending.
    let heat: [DrillKey] = [.anyOf(proto, ["HTTPS", "DNS"]), .anyOf(country, ["DE", "SG"])]
    expect(DrillSummary.label(heat, prefix: "Filtered by Chart")
           == "Filtered by Chart — protocol (2); dst_country (2)", "discrete counts, index order")

    // Null bucket counts as one value.
    let withNull: [DrillKey] = [.anyOf(proto, ["HTTPS", PharosBlanks.sentinel])]
    expect(DrillSummary.parts(withNull).first?.detail == "(2)", "sentinel counts as a bucket")

    // Lone blank → (null).
    expect(DrillSummary.parts([.blank(proto)]).first?.detail == "(null)", "lone blank → (null)")

    // Range / overlap → (range).
    expect(DrillSummary.parts([.range(port, 0, 50, .numeric)]).first?.detail == "(range)", "range → (range)")
    let start = ColumnRef(index: 4, name: "started"); let end = ColumnRef(index: 5, name: "finished")
    let ov: [DrillKey] = [.overlap(start, end, 0, 100, .temporal)]
    expect(DrillSummary.parts(ov).first?.column == "started" && DrillSummary.parts(ov).first?.detail == "(range)",
           "overlap labelled by start column, (range)")

    // Compound (heatmap cell) flattens to two columns.
    let cell: [DrillKey] = [.compound([.anyOf(proto, ["HTTPS"]), .anyOf(country, ["DE"])])]
    expect(DrillSummary.parts(cell).count == 2, "compound flattens to per-column parts")

    // Empty → bare prefix.
    expect(DrillSummary.label([], prefix: "Filter in Grid") == "Filter in Grid", "empty selection → prefix only")

    if failures == 0 { print("\nAll tests passed.") } else { print("\n\(failures) failure(s)."); exit(1) }
}
```

- [ ] **Step 2: Script** — `scripts/test-drill-summary.sh` (then `chmod +x`):
```bash
#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")/.."
swiftc -o /tmp/drill-summary-tests \
  Pharos/Models/QueryResult.swift \
  Pharos/Models/Charts/ChartTypes.swift \
  Pharos/Models/Charts/DrillKey.swift \
  Pharos/Utilities/BlanksSentinel.swift \
  Pharos/Models/Charts/DrillSummary.swift \
  PharosTests/DrillSummaryTests.swift \
  PharosTests/main.swift
/tmp/drill-summary-tests
```

- [ ] **Step 3: Run → FAIL.**

- [ ] **Step 4: Implement** `Pharos/Models/Charts/DrillSummary.swift`:
```swift
import Foundation

/// Pure builder for the chart-selection label shown on the commit button
/// ("Filter in Grid" / "Query Selected Rows") and the "Filtered by Chart" chip.
/// Groups drill keys per column and describes each; ordered by column index.
enum DrillSummary {
    struct Part: Equatable { let column: String; let detail: String }

    static func parts(_ keys: [DrillKey]) -> [Part] {
        var flat: [DrillKey] = []
        func walk(_ k: DrillKey) { if case .compound(let ks) = k { ks.forEach(walk) } else { flat.append(k) } }
        keys.forEach(walk)

        struct Acc { var ref: ColumnRef; var vals: Set<String>; var blank: Bool; var range: Bool }
        var byCol: [Int: Acc] = [:]
        func acc(_ r: ColumnRef) -> Int {
            if byCol[r.index] == nil { byCol[r.index] = Acc(ref: r, vals: [], blank: false, range: false) }
            return r.index
        }
        for k in flat {
            switch k {
            case .anyOf(let r, let vs):
                let i = acc(r)
                for v in vs { if v == PharosBlanks.sentinel { byCol[i]!.blank = true } else { byCol[i]!.vals.insert(v) } }
            case .blank(let r): byCol[acc(r)]!.blank = true
            case .range(let r, _, _, _): byCol[acc(r)]!.range = true
            case .overlap(let s, _, _, _, _): byCol[acc(s)]!.range = true
            case .compound: break
            }
        }
        return byCol.keys.sorted().map { idx in
            let a = byCol[idx]!
            let detail: String
            if a.range { detail = "(range)" }
            else if a.vals.isEmpty && a.blank { detail = "(null)" }
            else { detail = "(\(a.vals.count + (a.blank ? 1 : 0)))" }
            return Part(column: a.ref.name, detail: detail)
        }
    }

    /// e.g. "Filtered by Chart — protocol (2); dst_country (2)". Bare prefix when empty.
    static func label(_ keys: [DrillKey], prefix: String) -> String {
        let p = parts(keys)
        guard !p.isEmpty else { return prefix }
        return prefix + " — " + p.map { "\($0.column) \($0.detail)" }.joined(separator: "; ")
    }
}
```

- [ ] **Step 5: Run → PASS. Commit.**
```bash
xcodegen generate
git add Pharos/Models/Charts/DrillSummary.swift PharosTests/DrillSummaryTests.swift scripts/test-drill-summary.sh Pharos.xcodeproj/project.pbxproj
git commit -m "feat(charts): DrillSummary — per-column selection label helper"
```

---

## Task A2: DrillCoverage (lit-mark predicate)

**Files:** Create `Pharos/Models/Charts/DrillCoverage.swift`, `PharosTests/DrillCoverageTests.swift`, `scripts/test-drill-coverage.sh`.

This drives the honest dim/lit preview: a mark is lit iff its own drill key is subsumed by `DrillMerge.merge(stagedKeys)`. Coalesced ranges (widening) and cross-product discrete selections light the in-between marks; a dropped null dims.

- [ ] **Step 1: Failing tests** — `PharosTests/DrillCoverageTests.swift`:
```swift
import Foundation

var failures = 0
func expect(_ c: Bool, _ n: String) { if c { print("PASS \(n)") } else { failures += 1; print("FAIL \(n)") } }

func runTests() {
    let x = ColumnRef(index: 0, name: "x"); let y = ColumnRef(index: 1, name: "y")

    // anyOf membership.
    let mA: [DrillKey] = [.anyOf(x, ["a", "b"])]
    expect(DrillCoverage.covers(mA, .anyOf(x, ["a"])), "value in selection → lit")
    expect(!DrillCoverage.covers(mA, .anyOf(x, ["c"])), "value not in selection → dim")

    // null via sentinel.
    let mNull: [DrillKey] = [.anyOf(x, ["a", PharosBlanks.sentinel])]
    expect(DrillCoverage.covers(mNull, .blank(x)), "null mark lit when sentinel selected")

    // range containment (coalesced span lights in-between bins).
    let merged = DrillMerge.merge([.range(x, 0, 10, .numeric), .range(x, 40, 50, .numeric)])  // → [.range(x,0,50)]
    expect(DrillCoverage.covers(merged, .range(x, 20, 30, .numeric)), "in-between bin lit under coalesced span")
    expect(!DrillCoverage.covers(merged, .range(x, 50, 60, .numeric)), "bin outside span dim")

    // compound heatmap cell — cross product is honest.
    let mCross: [DrillKey] = [.anyOf(x, ["a", "b"]), .anyOf(y, ["p", "q"])]
    expect(DrillCoverage.covers(mCross, .compound([.anyOf(x, ["a"]), .anyOf(y, ["q"])])), "cross-product cell lit")
    expect(!DrillCoverage.covers(mCross, .compound([.anyOf(x, ["c"]), .anyOf(y, ["p"])])), "cell outside x-set dim")

    // dropped null: range + blank on one column merges to range only → null dims.
    let mDrop = DrillMerge.merge([.range(x, 0, 10, .numeric), .blank(x)])  // → [.range(x,0,10)]
    expect(!DrillCoverage.covers(mDrop, .blank(x)), "null dims when merge dropped it beside a range")

    // empty selection covers nothing (caller treats empty as 'all lit', not via covers()).
    expect(!DrillCoverage.covers([], .anyOf(x, ["a"])), "empty merged covers nothing")

    if failures == 0 { print("\nAll tests passed.") } else { print("\n\(failures) failure(s)."); exit(1) }
}
```

- [ ] **Step 2: Script** — `scripts/test-drill-coverage.sh` (`chmod +x`):
```bash
#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")/.."
swiftc -o /tmp/drill-coverage-tests \
  Pharos/Models/QueryResult.swift \
  Pharos/Models/Charts/ChartTypes.swift \
  Pharos/Models/Charts/DrillKey.swift \
  Pharos/Utilities/BlanksSentinel.swift \
  Pharos/Models/Charts/DrillMerge.swift \
  Pharos/Models/Charts/DrillCoverage.swift \
  PharosTests/DrillCoverageTests.swift \
  PharosTests/main.swift
/tmp/drill-coverage-tests
```

- [ ] **Step 3: Run → FAIL.**

- [ ] **Step 4: Implement** `Pharos/Models/Charts/DrillCoverage.swift`:
```swift
import Foundation

/// Whether one chart mark falls inside a merged drill selection — drives the
/// chart's dim/lit preview so it matches exactly what a commit filters. Pure.
/// `merged` is post-`DrillMerge` per-column keys; `mark` is one mark's own key
/// (a value, null, range, or a compound of per-axis sub-keys).
enum DrillCoverage {
    static func covers(_ merged: [DrillKey], _ mark: DrillKey) -> Bool {
        let idx = index(merged)
        let subs = flatten(mark)
        guard !subs.isEmpty else { return false }
        return subs.allSatisfy { coversSub(idx, $0) }
    }

    private struct ColSel { var vals: Set<String>; var blank: Bool; var range: (lo: Double, hi: Double)? }

    private static func flatten(_ key: DrillKey) -> [DrillKey] {
        var out: [DrillKey] = []
        func walk(_ k: DrillKey) { if case .compound(let ks) = k { ks.forEach(walk) } else { out.append(k) } }
        walk(key)
        return out
    }

    private static func index(_ merged: [DrillKey]) -> [Int: ColSel] {
        var out: [Int: ColSel] = [:]
        func ensure(_ i: Int) { if out[i] == nil { out[i] = ColSel(vals: [], blank: false, range: nil) } }
        for k in flatten(.compound(merged)) {
            switch k {
            case .anyOf(let r, let vs):
                ensure(r.index)
                for v in vs { if v == PharosBlanks.sentinel { out[r.index]!.blank = true } else { out[r.index]!.vals.insert(v) } }
            case .blank(let r): ensure(r.index); out[r.index]!.blank = true
            case .range(let r, let lo, let hi, _): ensure(r.index); out[r.index]!.range = (lo, hi)
            case .overlap, .compound: break
            }
        }
        return out
    }

    private static func coversSub(_ idx: [Int: ColSel], _ sub: DrillKey) -> Bool {
        switch sub {
        case .anyOf(let r, let vs):
            guard let c = idx[r.index] else { return false }
            return vs.allSatisfy { $0 == PharosBlanks.sentinel ? c.blank : c.vals.contains($0) }
        case .blank(let r):
            return idx[r.index]?.blank ?? false
        case .range(let r, let mlo, let mhi, _):
            guard let rg = idx[r.index]?.range else { return false }
            return rg.lo <= mlo && mhi <= rg.hi
        case .overlap, .compound:
            return false
        }
    }
}
```
(`flatten(.compound(merged))` is a tidy way to walk a `[DrillKey]`; merged keys are never nested compounds, so this just iterates them.)

- [ ] **Step 5: Run → PASS. Commit.**
```bash
xcodegen generate
git add Pharos/Models/Charts/DrillCoverage.swift PharosTests/DrillCoverageTests.swift scripts/test-drill-coverage.sh Pharos.xcodeproj/project.pbxproj
git commit -m "feat(charts): DrillCoverage — merged-selection membership for dim/lit preview"
```

---

# Phase B — ChartCanvas selection model (build-gated + manual)

SwiftUI gestures can't be unit-tested headlessly; verification is a clean build + manual GUI. The pure logic they lean on (`DrillMerge`, `DrillCoverage`, `DrillSummary`) is already tested.

## Task B1: Selection state, staged reporting, plumbing

**Files:** `ChartView.swift`, `ChartRootView.swift`, `ChartHostingController.swift`.

Introduce the staged-selection scaffold and swap the commit callback, wiring a single gesture (bar click) end-to-end to prove the pipe. Modifier logic and other types come in B2; dimming/marquee in B3.

- [ ] **Step 1: `ChartCanvas` selection state + params + reporting.** In `ChartView.swift`, replace `var onDrill: ([DrillKey]) -> Void = { _ in }` with the new callback + params, and add state:
```swift
    /// Reports the current *staged* selection (post-merge) up to the host; the
    /// host/VC commit it when the action-bar button is pressed. `[]` = cleared.
    var onSelectionChanged: ([DrillKey]) -> Void = { _ in }
    /// The committed chart filter's keys (from the VC) — used to light marks when
    /// no live selection is staged, so a committed filter stays visible on return.
    var committedKeys: [DrillKey] = []
    /// Bumped by the VC to clear the staged selection (post-commit / Esc).
    var clearToken: Int = 0
    /// Identity of the current config (mappings + type + bins); changing it clears
    /// the staged selection, since the marks change underneath it.
    var configFingerprint: String = ""

    // Staged selection: discrete marks (bar/line/area/pie/heatmap/gantt rows).
    @State private var selectedIDs: Set<String> = []
    @State private var anchorID: String? = nil
    // Continuous selection (scatter marquee / gantt time-axis overlap): the keys +
    // geometry for dimming. nil when a discrete selection (or none) is active.
    @State private var rangeSel: RangeSelection? = nil
    // Live marquee rectangle in plot-local coords, drawn while dragging.
    @State private var marquee: CGRect? = nil

    struct RangeSelection: Equatable {
        var keys: [DrillKey]
        var xLo: Double; var xHi: Double        // data-space x bounds (scatter/gantt)
        var yLo: Double?; var yHi: Double?       // scatter optional y bounds
    }
```

- [ ] **Step 2: Mark model + staged keys + report.** Add to `ChartCanvas`:
```swift
    private struct Mark { let id: String; let drill: DrillKey? }

    /// All discrete marks with a stable ID (`xLabel\u{1}seriesName`, `HeatmapCell.id`,
    /// or gantt label) and their pre-computed drill key. Empty for scatter.
    private var marks: [Mark] {
        switch chartType {
        case .bar, .line, .area:
            return data.series.flatMap { s in s.points.map { Mark(id: "\($0.xLabel)\u{1}\(s.name)", drill: $0.drill) } }
        case .pie:
            return (data.series.first?.points ?? []).map { Mark(id: "\($0.xLabel)\u{1}", drill: $0.drill) }
        case .heatmap:
            return data.heatmapCells.map { Mark(id: $0.id, drill: $0.drill) }
        case .gantt:
            guard let ref = config.mappings[.label] else { return [] }
            return data.ganttBars.map { Mark(id: $0.label, drill: .anyOf(ref, [$0.label])) }
        case .scatter:
            return []
        }
    }
```
(A gantt row's drill is `.anyOf(labelRef, [bar.label])` — the same key `ganttTap` produced in phase 4.) Add the staged-keys computation + reporter:
```swift
    /// Selected discrete marks' keys, merged; or the continuous range keys.
    private var stagedKeys: [DrillKey] {
        if let r = rangeSel { return r.keys }
        let keys = marks.filter { selectedIDs.contains($0.id) }.compactMap { $0.drill }
        return DrillMerge.merge(keys)
    }
    private var hasStagedSelection: Bool { !selectedIDs.isEmpty || rangeSel != nil }
    private func report() { onSelectionChanged(stagedKeys) }
    private func clearSelection() { selectedIDs = []; anchorID = nil; rangeSel = nil; marquee = nil; report() }
```

- [ ] **Step 3: Rewire the bar tap to stage (not commit).** In `categoryTap(...)` (currently calls `onDrill`), for now replace its body with a plain single-select of the tapped mark's ID (full modifier logic is B2):
```swift
    private func categoryTap(_ label: String, atY py: CGFloat, proxy: ChartProxy) {
        // Resolve the hit mark ID (single-series → seriesName ""; multi-series uses
        // the existing band/nearest resolution to pick the series, else category-only).
        let seriesName = resolveHitSeries(label: label, atY: py, proxy: proxy)   // helper below
        let id = "\(label)\u{1}\(seriesName)"
        selectedIDs = [id]; anchorID = id; rangeSel = nil
        report()
    }

    /// The series name of the mark a bar/line/area tap hit, or "" (category-only /
    /// single-series). Reuses the phase-4 stacked-band / nearest-series logic.
    private func resolveHitSeries(label: String, atY py: CGFloat, proxy: ChartProxy) -> String {
        guard data.series.count > 1, let tv = proxy.value(atY: py, as: Double.self) else {
            return data.series.count == 1 ? data.series[0].name : ""
        }
        switch chartType {
        case .bar where config.display.stacked:
            var acc = 0.0
            for s in data.series { if let pt = s.points.first(where: { $0.xLabel == label }) { acc += pt.y; if tv <= acc { return s.name } } }
            return ""
        case .line, .area:
            return data.series.min(by: { s1, s2 in
                let y1 = s1.points.first(where: { $0.xLabel == label })?.y ?? .infinity
                let y2 = s2.points.first(where: { $0.xLabel == label })?.y ?? .infinity
                return abs(y1 - tv) < abs(y2 - tv)
            })?.name ?? ""
        default:
            return ""   // grouped/ambiguous → category-only (seriesName "")
        }
    }
```
Note: an empty `seriesName` selects the *category* (all series) because dimming/commit go through the merged keys; a specific `seriesName` narrows to that band. Multi-series marks carry `.compound([categoryKey, seriesKey])` (phase 4), so selecting one band's ID stages exactly that cell; selecting via `""` won't match a specific `marks` ID, so category-only is handled in B2's range/marquee paths and by mapping `""` to *all* series IDs for that category — implement that expansion in B2.

- [ ] **Step 4: `ChartRootView` + `ChartViewModel` plumbing.** In `ChartRootView.swift`:
  - `ChartViewModel`: replace `var onDrill: (([DrillKey]) -> Void)?` with `var onSelectionChanged: (([DrillKey]) -> Void)?`; add `@Published var committedKeys: [DrillKey] = []` and `@Published var clearToken: Int = 0`. Add a computed `var configFingerprint: String { "\(config.chartType.rawValue)|\(config.mappings.map { "\($0.key.rawValue):\($0.value.index)" }.sorted().joined(separator: ","))|\(config.temporalBin.rawValue)|\(config.numericBin.rawValue)|\(config.axisBins.map { "\($0.key.rawValue):\($0.value.temporal.rawValue)/\($0.value.numeric.rawValue)" }.sorted().joined(separator: ","))" }`.
  - In `ChartRootView.body`, update the `ChartCanvas(...)` call:
```swift
                ChartCanvas(data: model.data, config: model.config,
                            onSelectionChanged: { keys in model.onSelectionChanged?(keys) },
                            committedKeys: model.committedKeys,
                            clearToken: model.clearToken,
                            configFingerprint: model.configFingerprint)
```

- [ ] **Step 5: `ChartHostingController` plumbing.** In `ChartHostingController.swift`:
  - Replace `var onDrill: (([DrillKey]) -> Void)?` with `var onSelectionChanged: (([DrillKey]) -> Void)?`.
  - In `present(...)`, replace `vm.onDrill = { [weak self] keys in self?.onDrill?(keys) }` with `vm.onSelectionChanged = { [weak self] keys in self?.onSelectionChanged?(keys) }`.
  - Add:
```swift
    /// Push the committed filter's keys into the view model so the chart lights them
    /// when no live selection is staged.
    func setCommittedKeys(_ keys: [DrillKey]) { model?.committedKeys = keys }
    /// Clear the staged selection in the chart (post-commit / Esc).
    func clearSelection() { model?.clearToken += 1 }
```

- [ ] **Step 6: Fix the VC's now-broken `onDrill` reference (minimal, keeps build green).** In `ContentViewController.presentChart`, replace `chartHost.onDrill = { [weak self] keys in self?.applyDrill(keys) }` with a temporary staged-selection sink (Task C wires the real button):
```swift
        chartHost.onSelectionChanged = { [weak self] keys in self?.chartSelectionChanged(keys) }
```
and add a stub `private func chartSelectionChanged(_ keys: [DrillKey]) { stagedChartKeys = keys }` plus `private var stagedChartKeys: [DrillKey] = []`. (Also remove the `chartHost.onDrill = nil` line in the demoted-result branch, or rename it to `chartHost.onSelectionChanged = nil`.)

- [ ] **Step 7: Build.** `xcodegen generate && xcodebuild … build` → BUILD SUCCEEDED. (Selecting a bar now stages a selection; nothing visibly changes yet — commit button is Task C, dimming is B3.)

- [ ] **Step 8: Commit** (`feat(charts): staged chart-selection scaffold + onSelectionChanged plumbing`). Stage `ChartView.swift`, `ChartRootView.swift`, `ChartHostingController.swift`, `ContentViewController.swift`.

---

## Task B2: Modifier-aware gestures per chart type

**Files:** `ChartView.swift`.

Wire single / Shift-range / ⌘-toggle across the discrete charts, plus the continuous (scatter/gantt-time) range selections. Modifiers via `NSEvent.modifierFlags` (already imported `AppKit`).

- [ ] **Step 1: Shared selection ops.** Add to `ChartCanvas`:
```swift
    private func stageSingle(_ ids: [String]) { selectedIDs = Set(ids); anchorID = ids.last; rangeSel = nil; report() }
    private func stageToggle(_ ids: [String]) {
        for id in ids { if selectedIDs.contains(id) { selectedIDs.remove(id) } else { selectedIDs.insert(id) } }
        anchorID = ids.last; rangeSel = nil; report()
    }
    /// Modifier dispatch for a hit whose selection maps to one-or-more mark IDs
    /// (a category expands to all its series IDs), given the ordered ID list for
    /// Shift-range and a function from an ID to its "range unit" (category/cell/row).
    private func applyModifier(hitIDs: [String], rangeIDs: () -> [String]) {
        let m = NSEvent.modifierFlags
        if m.contains(.command) { stageToggle(hitIDs) }
        else if m.contains(.shift), anchorID != nil { selectedIDs = Set(rangeIDs()); rangeSel = nil; report() }
        else { stageSingle(hitIDs) }
    }
```

- [ ] **Step 2: Bar/line/area.** Rewrite `categoryTap` to expand a category to its series IDs and support the modifiers; add the ordered category list + range expansion:
```swift
    private var orderedCategories: [String] {
        var seen = Set<String>(); var out: [String] = []
        for s in data.series { for p in s.points where !seen.contains(p.xLabel) { seen.insert(p.xLabel); out.append(p.xLabel) } }
        return out
    }
    private func idsForCategory(_ cat: String) -> [String] { data.series.map { "\(cat)\u{1}\($0.name)" } }
    private func categoryOf(_ id: String) -> String { String(id.split(separator: "\u{1}", maxSplits: 1, omittingEmptySubsequences: false).first ?? "") }

    private func categoryTap(_ label: String, atY py: CGFloat, proxy: ChartProxy) {
        let series = resolveHitSeries(label: label, atY: py, proxy: proxy)
        let hitIDs = series.isEmpty ? idsForCategory(label) : ["\(label)\u{1}\(series)"]
        applyModifier(hitIDs: hitIDs) {
            // Shift-range along the category axis (all series in the block).
            let cats = orderedCategories
            let aCat = anchorID.map { categoryOf($0) }
            guard let a = aCat, let ia = cats.firstIndex(of: a), let ib = cats.firstIndex(of: label) else { return hitIDs }
            let block = cats[min(ia, ib)...max(ia, ib)]
            return block.flatMap { idsForCategory($0) }
        }
    }
```
Keep the anchor as the tapped ID (`stageSingle`/`stageToggle` set `anchorID`); for Shift the anchor's category defines the block start.

- [ ] **Step 3: Bar/line/area marquee (drag).** `categoryBrush` currently commits; make it stage. Replace its body:
```swift
    private func categoryBrush(_ lo: CGFloat, _ hi: CGFloat, _ proxy: ChartProxy) {
        var ids: [String] = []
        for cat in orderedCategories {
            if let px = proxy.position(forX: cat), px >= lo, px <= hi { ids.append(contentsOf: idsForCategory(cat)) }
        }
        selectedIDs = Set(ids); anchorID = ids.last; rangeSel = nil; report()
    }
```

- [ ] **Step 4: Pie.** Replace the `onChange(of: pieSelection)` accumulation (it currently calls `onDrill`) with modifier-aware staging over slice IDs (`"\(label)\u{1}"`), Shift-range over slice order:
```swift
        .onChange(of: pieSelection) { _, newValue in
            guard let label = newValue else { return }
            let id = "\(label)\u{1}"
            let order = (data.series.first?.points ?? []).map { "\($0.xLabel)\u{1}" }
            applyModifier(hitIDs: [id]) {
                guard let a = anchorID, let ia = order.firstIndex(of: a), let ib = order.firstIndex(of: id) else { return [id] }
                return Array(order[min(ia, ib)...max(ia, ib)])
            }
        }
```
Remove the now-unused `pieSelected` state.

- [ ] **Step 5: Heatmap.** Rewrite `heatmapTap` for modifiers (Shift = bounding rectangle by x/y index) and `heatmapBrush` to stage (not commit):
```swift
    private var orderedHeatX: [String] { var s = Set<String>(); var o: [String] = []; for c in data.heatmapCells where !s.contains(c.x) { s.insert(c.x); o.append(c.x) }; return o }
    private var orderedHeatY: [String] { var s = Set<String>(); var o: [String] = []; for c in data.heatmapCells where !s.contains(c.y) { s.insert(c.y); o.append(c.y) }; return o }

    private func heatmapTap(_ px: CGFloat, _ py: CGFloat, _ proxy: ChartProxy) {
        guard let xl = proxy.value(atX: px, as: String.self), let yl = proxy.value(atY: py, as: String.self),
              let cell = data.heatmapCells.first(where: { $0.x == xl && $0.y == yl }) else { return }
        applyModifier(hitIDs: [cell.id]) {
            // bounding rect between anchor cell and this cell, by x/y index.
            guard let a = anchorID, let ac = data.heatmapCells.first(where: { $0.id == a }) else { return [cell.id] }
            let xs = orderedHeatX, ys = orderedHeatY
            guard let ax = xs.firstIndex(of: ac.x), let bx = xs.firstIndex(of: xl),
                  let ay = ys.firstIndex(of: ac.y), let by = ys.firstIndex(of: yl) else { return [cell.id] }
            let xset = Set(xs[min(ax, bx)...max(ax, bx)]); let yset = Set(ys[min(ay, by)...max(ay, by)])
            return data.heatmapCells.filter { xset.contains($0.x) && yset.contains($0.y) }.map { $0.id }
        }
    }

    private func heatmapBrush(_ xlo: CGFloat, _ xhi: CGFloat, _ ylo: CGFloat, _ yhi: CGFloat, _ proxy: ChartProxy) {
        var ids: [String] = []
        for cell in data.heatmapCells {
            if let cx = proxy.position(forX: cell.x), let cy = proxy.position(forY: cell.y),
               cx >= xlo, cx <= xhi, cy >= ylo, cy <= yhi { ids.append(cell.id) }
        }
        selectedIDs = Set(ids); anchorID = ids.last; rangeSel = nil; report()
    }
```

- [ ] **Step 6: Gantt rows.** `ganttTap` (per-row `onTapGesture`) becomes modifier-aware over the row order:
```swift
    private func ganttTap(_ bar: GanttBar) {
        applyModifier(hitIDs: [bar.label]) {
            let order = data.ganttBars.map { $0.label }
            guard let a = anchorID, let ia = order.firstIndex(of: a), let ib = order.firstIndex(of: bar.label) else { return [bar.label] }
            return Array(order[min(ia, ib)...max(ia, ib)])
        }
    }
```

- [ ] **Step 7: Scatter + gantt time-axis (continuous).** `scatterBrush` and `ganttBrush` set `rangeSel` (stage) instead of `onDrill`:
```swift
    // scatterBrush(...) tail — after computing keys x0/x1[/y0/y1]:
        rangeSel = RangeSelection(keys: keys, xLo: Swift.min(x0, x1), xHi: Swift.max(x0, x1),
                                  yLo: (config.mappings[.y] != nil ? Swift.min(ya, yb) : nil),
                                  yHi: (config.mappings[.y] != nil ? Swift.max(ya, yb) : nil))
        selectedIDs = []; anchorID = nil; report()
```
```swift
    // ganttBrush(...) tail — after building the .overlap key `ov`:
        rangeSel = RangeSelection(keys: [ov], xLo: d0.timeIntervalSince1970, xHi: d1.timeIntervalSince1970, yLo: nil, yHi: nil)
        selectedIDs = []; anchorID = nil; report()
```
(Scatter single-click still clears via `scatterTap` → call `clearSelection()` instead of the callout-only behavior, keeping the inspect callout.)

- [ ] **Step 8: Build + manual.** Verify each gesture *stages* (no immediate grid switch): single/Shift/⌘ on bar, pie, heatmap (Shift = rect), gantt rows; scatter/gantt-time drag. (Dimming + button come next; for now confirm no crashes and that a `print` in `chartSelectionChanged` shows sensible keys.)

- [ ] **Step 9: Commit** (`feat(charts): modifier-aware staged selection gestures per chart type`).

---

## Task B3: Dimming, marquee, and clear triggers

**Files:** `ChartView.swift`.

- [ ] **Step 1: Lit predicate.** Add:
```swift
    /// Keys that drive dimming: the live staged selection if present, else the
    /// committed filter (so a committed filter stays visible on return to chart).
    private var effectiveKeys: [DrillKey] { hasStagedSelection ? stagedKeys : committedKeys }

    private func isLit(_ drill: DrillKey?) -> Bool {
        if effectiveKeys.isEmpty { return true }         // nothing selected → all lit
        guard let d = drill else { return false }
        return DrillCoverage.covers(effectiveKeys, d)
    }
```

- [ ] **Step 2: Apply dimming.** Multiply each mark's opacity by `isLit`:
  - Bar/line/area — in `categoryChart`'s `mark(pt)`: `.opacity(isLit(pt.drill) ? 1 : 0.2)`.
  - Pie — `SectorMark(...)`: `.opacity(isLit(pt.drill) ? 1 : 0.2)`.
  - Heatmap — `RectangleMark(...)`: `.opacity(isLit(cell.drill) ? 1 : 0.2)`.
  - Gantt rows — in `ganttRows`, the per-row `VStack`: `.opacity(ganttRowLit(bar) ? 1 : 0.2)`, with this method added to `ChartCanvas`:
```swift
    private func ganttRowLit(_ bar: GanttBar) -> Bool {
        if let r = rangeSel { return bar.start <= r.xHi && bar.end >= r.xLo }   // time-axis overlap window
        if effectiveKeys.isEmpty { return true }
        guard let ref = config.mappings[.label] else { return true }
        return DrillCoverage.covers(effectiveKeys, .anyOf(ref, [bar.label]))
    }
```
  - Scatter — dim points outside the range box. Scatter uses `PointPlot(pts, …)`; per-point opacity isn't available, so **split** the points into inside/outside and draw two `PointPlot`s (inside full, outside 0.2) when `rangeSel != nil`:
```swift
    // in scatterChart, replace the single PointPlot:
    if let r = rangeSel {
        let inside = pts.filter { r.xLo <= $0.x && $0.x <= r.xHi && (r.yLo == nil || (r.yLo! <= $0.y && $0.y <= r.yHi!)) }
        let outside = pts.filter { !(r.xLo <= $0.x && $0.x <= r.xHi && (r.yLo == nil || (r.yLo! <= $0.y && $0.y <= r.yHi!))) }
        PointPlot(outside, x: .value("X", \.x), y: .value("Y", \.y)).foregroundStyle(.gray.opacity(0.2))
        PointPlot(inside, x: .value("X", \.x), y: .value("Y", \.y))
    } else {
        PointPlot(pts, x: .value("X", \.x), y: .value("Y", \.y))
    }
```

- [ ] **Step 3: Marquee overlay.** Track the live drag rect and draw it. In each drag `.onChanged` (add `.onChanged` alongside the existing `.onEnded` in `categoryOverlay`, `heatmapOverlay`, `scatterChart`'s overlay, and the gantt header overlay), set `marquee` to the rect between start and current (plot-local); clear it in `.onEnded`. Draw in the overlay's `ZStack`:
```swift
        if let m = marquee {
            Rectangle().fill(Color.accentColor.opacity(0.12))
                .overlay(Rectangle().stroke(style: StrokeStyle(lineWidth: 1.5, dash: [4])).foregroundStyle(Color.accentColor))
                .frame(width: m.width, height: m.height).position(x: m.midX + origin.x, y: m.midY + origin.y)
        }
```
For the categorical x-band marquee, use full plot height (`m.height` = plot height); for heatmap/scatter use the 2D rect.

- [ ] **Step 4: Clear triggers.** Add to the chart root view modifiers (on the outer `chart`):
```swift
        .onChange(of: clearToken) { _, _ in clearSelection() }
        .onChange(of: configFingerprint) { _, _ in clearSelection() }
```
Empty-plot-area click: in each overlay's `.onEnded`, if the gesture was a tap (translation < 6pt) and hit no mark, call `clearSelection()` (the existing tap handlers already early-return on no hit — change those to `clearSelection()`).

- [ ] **Step 5: Build + manual.** Marquee draws while dragging; unselected marks dim; ⌘-select two non-adjacent bins → the in-between span lights *before* commit; a lit null bucket beside a range dims; Esc/empty-click clears (Esc after Task C wires the VC). Config change / tab switch clears.

- [ ] **Step 6: Commit** (`feat(charts): dim/lit preview from merged coverage + drag marquee`).

---

# Phase C — VC commit + action bar (build-gated + manual)

## Task C1: Action-bar commit button + label + clear routing

**Files:** `ContentViewController.swift`.

- [ ] **Step 1: Button property + config.** Add `let chartFilterButton = NSButton()` near `drillChip` (line ~82). Configure it in setup (next to the `drillChip` block, ~line 865) mirroring the chip:
```swift
        chartFilterButton.bezelStyle = .recessed
        chartFilterButton.font = .systemFont(ofSize: 11)
        chartFilterButton.image = NSImage(systemSymbolName: "line.3.horizontal.decrease.circle", accessibilityDescription: "Filter selection")?
            .withSymbolConfiguration(drillConfig)
        chartFilterButton.imagePosition = .imageLeading
        chartFilterButton.contentTintColor = .controlAccentColor
        chartFilterButton.target = self
        chartFilterButton.action = #selector(commitChartSelection)
        chartFilterButton.isHidden = true
        chartFilterButton.setContentHuggingPriority(.required, for: .horizontal)
        chartFilterButton.setContentCompressionResistancePriority(.required, for: .horizontal)
```
Insert it into `actionStack` right after `chartToggle` (before `drillChip`):
```swift
        let actionStack = NSStackView(views: [chartToggle, chartFilterButton, drillChip, pinButton, exportButton, copyButton, findToolbarButton, resetSortButton, resetFiltersButton, clearSelectionButton])
```

- [ ] **Step 2: Selection-changed handler (label + show/hide).** Replace the B1 stub `chartSelectionChanged` with:
```swift
    /// The chart reported a new staged selection — show/label the commit button.
    private func chartSelectionChanged(_ keys: [DrillKey]) {
        stagedChartKeys = keys
        guard !keys.isEmpty else { chartFilterButton.isHidden = true; return }
        let server = activeChartUsesServerMode()
        chartFilterButton.title = DrillSummary.label(keys, prefix: server ? "Query Selected Rows" : "Filter in Grid")
        chartFilterButton.toolTip = chartFilterButton.title
        chartFilterButton.isHidden = false
    }

    /// Whether the active chart is committing via server-aggregation (detail query)
    /// rather than grid filters.
    private func activeChartUsesServerMode() -> Bool {
        guard let id = activeResultTabId, let idx = resultTabs.firstIndex(where: { $0.id == id }),
              let cfg = resultTabs[idx].chartConfig else { return false }
        return cfg.serverAggregation && chartTypeSupportsServer(cfg.chartType)
    }
```

- [ ] **Step 3: Build.** BUILD SUCCEEDED. (Button now appears/labels on selection; commit is Step-next.)

- [ ] **Step 4: Commit** (`feat(charts): chart-filter commit button with per-column label`).

## Task C2: Commit action, replace semantics, chip relabel

**Files:** `ContentViewController.swift`.

- [ ] **Step 1: Commit action.** Add:
```swift
    @objc private func commitChartSelection() {
        guard !stagedChartKeys.isEmpty else { return }
        applyDrill(stagedChartKeys)                 // client: replace + grid filters; server: detail query (branch inside)
        stagedChartKeys = []
        chartFilterButton.isHidden = true
        chartHost.clearSelection()                  // clear the chart's staged selection
    }
```

- [ ] **Step 2: Replace in `applyDrill` + store committed keys.** In `applyDrill(_ keys:)`, the client-mode branch (after the server-mode early return) currently sets filters accumulating. Make it replace-first and record the committed keys:
```swift
        // Replace any prior committed chart filter (restore displaced manual filters first).
        tearDownDrill(restoreManual: true)

        let applied = DrillTranslator.filters(for: keys, columns: result.columns)
        guard !applied.isEmpty else { committedChartKeys = []; chartHost.setCommittedKeys([]); return }
        guard let fc = resultsVC.columnFilterController else { return }
        for a in applied {
            if let existing = fc.filter(forColumn: a.columnId) { displacedFilters[a.columnId] = existing }
            fc.setFilter(a.filter, forColumn: a.columnId)
            if !drillColumns.contains(a.columnId) { drillColumns.append(a.columnId) }
        }
        committedChartKeys = keys
        chartHost.setCommittedKeys(DrillMerge.merge(keys))
        resultsVC.refreshColumnFilters()
        setResultViewMode(.grid)
        updateDrillChip()
```
Add `private var committedChartKeys: [DrillKey] = []` near `drillColumns`. (The `if !drillColumns.contains` snapshot guard is no longer needed since `tearDownDrill` cleared them, but keep the append-dedup for safety.)

- [ ] **Step 3: Chip label via `DrillSummary`.** Rewrite `updateDrillChip`:
```swift
    private func updateDrillChip() {
        let active = !drillColumns.isEmpty
        drillChip.isHidden = !active
        if active { drillChip.title = DrillSummary.label(committedChartKeys, prefix: "Filtered by Chart") }
    }
```

- [ ] **Step 4: Clear committed keys on `clearDrill`/teardown.** In `tearDownDrill`, after `drillColumns.removeAll(); displacedFilters.removeAll()`, add `committedChartKeys = []; chartHost.setCommittedKeys([])`.

- [ ] **Step 5: Esc to clear staged selection (optional convenience).** In the VC, add a `keyDown` (or use the existing responder) so Esc calls `chartHost.clearSelection()` + `chartFilterButton.isHidden = true` when in chart mode. If the responder chain fights it, skip — empty-plot-area click (B3) is the primary clear.

- [ ] **Step 6: Build + manual verify.**
  - Client: select → "Filter in Grid — …" appears → commit switches to grid with the right filters + chip "Filtered by Chart — …"; a *new* selection replaces (no stacking); ✕ clears.
  - Server: toggle server aggregation → button reads "Query Selected Rows — …" → commit spawns the filtered detail tab; multi-select builds one compound `WHERE`.
  - Return to chart after commit → committed marks lit, no button until a new gesture.

- [ ] **Step 7: Commit** (`feat(charts): commit staged selection (replace) + DrillSummary chip label`).

---

# Phase D — Grid ⌘-click parity

## Task D1: Discontiguous row selection

**Files:** `Pharos/ViewControllers/ResultsGrid/ResultsCellSelection.swift`.

- [ ] **Step 1: Add the ⌘ branch.** In `handleMouseDown`, the row branch (`if let rowIdx = rowIndex(from: event)`), currently handles Shift and else. Insert a `.command` case that toggles and does **not** start a drag selection:
```swift
            if event.modifierFlags.contains(.command) {
                if state.selectedRows.contains(rowIdx) { state.selectedRows.remove(rowIdx) }
                else { state.selectedRows.insert(rowIdx) }
                rowAnchor = rowIdx
                state.isSelecting = false          // do NOT drag-range: handleMouseDragged would clobber the set
                onChange?(state)
                return
            }
            if event.modifierFlags.contains(.shift), let anchor = rowAnchor {
                let lo = min(anchor, rowIdx); let hi = max(anchor, rowIdx)
                state.selectedRows = IndexSet(integersIn: lo...hi)
            } else {
                state.selectedRows = IndexSet(integer: rowIdx)
                rowAnchor = rowIdx
            }
            state.isSelecting = true
            onChange?(state)
            return
```
(Replace the existing Shift/else block with the above; the `.command` branch precedes it and returns early with `isSelecting = false`.)

- [ ] **Step 2: Build + manual verify.** ⌘-click toggles individual rows into a discontiguous selection; a small drag during ⌘-click does **not** wipe it; Shift-click still ranges from the anchor; plain click single-selects. Copy/inspector reflect the discontiguous set.

- [ ] **Step 3: Commit** (`fix(grid): ⌘-click toggles discontiguous row selection (macOS parity)`).

---

# Phase V — Verification

## Task V1: Harnesses + build

- [ ] **Step 1: All chart harnesses** (incl. the two new):
```bash
for s in chart-config chart-aggregator column-classifier value-coercion drill-key drill-translator drill-sql drill-merge sql-pushdown server-chart-builder drill-summary drill-coverage; do
  printf "%-20s " "$s:"; scripts/test-$s.sh 2>&1 | tail -1
done
```
Expected: each "All tests passed."

- [ ] **Step 2: Clean build** → `** BUILD SUCCEEDED **`.

## Task V2: Manual GUI (use the `verify` skill)

- [ ] Marquee draws while dragging; unselected marks dim (bar/line/area/pie/heatmap/gantt/scatter).
- [ ] Single / Shift-range / ⌘-toggle on bar, pie, heatmap (Shift = bounding rect), gantt rows; scatter drag-only; gantt time-axis overlap.
- [ ] Per-series band toggles independently; merged-preview honesty (two non-adjacent numeric bins light the in-between span before commit; null-beside-range dims).
- [ ] "Filter in Grid" appears only with a selection, correct label, commit → grid + chip; new selection replaces (no stacking); ✕ clears.
- [ ] Server mode: "Query Selected Rows" → filtered detail tab; multi-select → one compound `WHERE`.
- [ ] Grid: ⌘-click discontiguous rows (survives a small drag); Shift ranges; plain click single.
- [ ] Backward compat: a phase-1..4 workspace chart still restores and charts.

- [ ] **Step:** Commit any fixes; ready for `finishing-a-development-branch`.

---

## Notes for the implementer

- **Execution order:** A (pure, TDD) → B1 → B2 → B3 → C1 → C2 → D1 → V. B must land before C (C1's `chartSelectionChanged` replaces B1's stub).
- **Pure vs UI boundary:** `DrillSummary`/`DrillCoverage` are Foundation-only and fully unit-tested; everything in `ChartView`/`ChartRootView`/`ChartHostingController`/`ContentViewController`/`ResultsCellSelection` is build-gated + manually verified (SwiftUI gestures + AppKit).
- **`project.pbxproj` is tracked** — `xcodegen generate` + stage it for Tasks A1, A2 (new files).
- **Reuse, don't reinvent:** commit still flows through the existing `applyDrill`/`applyServerDrill`; `DrillMerge` still does the per-column merge; the only new logic is labelling (`DrillSummary`) and lit-membership (`DrillCoverage`).
- **Verify during implementation:** `NSEvent.modifierFlags` reads correctly in tap-sized drags; `proxy.position(forX:)`/`value(atX:as:)` behave for the marquee/hit-testing; the scatter two-`PointPlot` dim split renders.
