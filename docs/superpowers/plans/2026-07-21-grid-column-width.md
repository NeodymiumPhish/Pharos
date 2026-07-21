# Results-Grid Column Width & Two-Row Header Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Make results-grid columns open snug to `max(name, type, rendered-content)` (no wasted whitespace), by turning the column header into two rows (name over type) with the sort/filter affordances overlaid on row 2 (reserving no width), measuring the *rendered* cell text, and raising the resize cap to 1000px.

**Architecture:** A single Foundation-only pure helper (`ResultCellText.rendered`) unit-tested via a `swiftc` harness gives the exact string each cell draws; the grid's cell styling and the new content-aware width measurement both use it, so they can't diverge. The two-row header (taller header view + two-row header cell + row-2 overlay affordances) and the shared `measuredColumnWidth` are AppKit rendering — build-gated + manually verified.

**Tech Stack:** Swift 5.10 / AppKit (`NSTableView`, `NSTableHeaderView`, `NSTableHeaderCell`), macOS 15. Pure logic via a standalone `swiftc` harness.

**Reference spec:** `docs/superpowers/specs/2026-07-21-grid-column-width-design.md`

---

## Key conventions (read before starting)

- **No Xcode test target.** Pure logic tested by `swiftc` scripts (impl files + one `PharosTests/XxxTests.swift` + `PharosTests/main.swift`); each test file defines its own `runTests()`/`failures`/`expect`.
- **`project.pbxproj` is tracked** — run `xcodegen generate` and stage it when adding a file. App build: `xcodegen generate && xcodebuild -project Pharos.xcodeproj -scheme Pharos -configuration Debug build 2>&1 | tail -25` (allow a long timeout; a Rust pre-build runs).
- The results grid: `ResultsGridVC.swift` (column creation `rebuildColumns` ~:430, `autoFitColumn` :661, `estimateColumnWidth` :456, header view assigned :119–121); `ResultsGrid/ResultsDataSource.swift` (`styleCell` :402, fonts/settings :93–98, `flattenedForCell` private String ext :6–15, cell text insets 6/6 :247–248); `ResultsGrid/FilterableHeaderView.swift` (`SortAwareHeaderCell` :6–25, funnel draw :207–229, `filterIconRect` :249–256, `updateSortCellIndicators` :234–245, `mouseDown` :147–188, `iconSize=13`/`iconPadding=6` :65–66).
- **The two-row header removes both affordances from the width budget** — so `measuredColumnWidth` adds **no** funnel/sort reserve.

---

## File Structure

**New (Foundation-only):** `Pharos/ViewControllers/ResultsGrid/ResultCellText.swift` — the `flattenedForCell` String extension (moved here, made internal) + `enum ResultCellText { rendered(...) }`.
**Modified:** `ResultsGrid/ResultsDataSource.swift` (drop the local `flattenedForCell` ext; `styleCell` uses `ResultCellText.rendered`); `ResultsGrid/FilterableHeaderView.swift` (two-row header cell; row-2 overlay sort+funnel; repurpose `updateSortCellIndicators`; reposition `filterIconRect`); `ResultsGridVC.swift` (`rebuildColumns` sets name/type on the cell + `measuredColumnWidth`; `autoFitColumn` uses it; remove `estimateColumnWidth`; `maxWidth`/clamp 1000; taller header).
**New tests:** `PharosTests/ResultCellTextTests.swift`; `scripts/test-result-cell-text.sh`.

---

# Phase A — Rendered-string helper (TDD)

## Task A1: ResultCellText.rendered + styleCell reuse

**Files:** Create `Pharos/ViewControllers/ResultsGrid/ResultCellText.swift`, `PharosTests/ResultCellTextTests.swift`, `scripts/test-result-cell-text.sh`; modify `ResultsGrid/ResultsDataSource.swift`.

- [ ] **Step 1: Failing tests** — `PharosTests/ResultCellTextTests.swift`:
```swift
import Foundation

var failures = 0
func expect(_ c: Bool, _ n: String) { if c { print("PASS \(n)") } else { failures += 1; print("FAIL \(n)") } }

func runTests() {
    func r(_ v: AnyCodable, _ c: PGTypeCategory) -> String {
        ResultCellText.rendered(value: v, category: c, boolTrue: "✓", boolFalse: "✗", nullString: "NULL")
    }
    // BOOL → glyph, case-insensitive, both t/true and f/false.
    expect(r(AnyCodable("t"), .boolean) == "✓", "bool t → true glyph")
    expect(r(AnyCodable("true"), .boolean) == "✓", "bool true → true glyph")
    expect(r(AnyCodable("F"), .boolean) == "✗", "bool F → false glyph (case-insensitive)")
    expect(r(AnyCodable("false"), .boolean) == "✗", "bool false → false glyph")
    expect(r(AnyCodable("maybe"), .boolean) == "maybe", "unknown bool → raw")
    // NULL → null string regardless of category.
    expect(r(AnyCodable.null, .string) == "NULL", "null → null string")
    // string/json/array → newline-flattened.
    expect(r(AnyCodable("a\nb"), .string) == "a↵b", "string newline flattened")
    expect(r(AnyCodable("{\n}"), .json) == "{↵}", "json newline flattened")
    // numeric/temporal → raw displayString.
    expect(r(AnyCodable("42"), .numeric) == "42", "numeric raw")
    expect(r(AnyCodable("2026-01-01"), .temporal) == "2026-01-01", "temporal raw")

    if failures == 0 { print("\nAll tests passed.") } else { print("\n\(failures) failure(s)."); exit(1) }
}
```
NOTE: verify how a null `AnyCodable` is constructed in this codebase — the test uses `AnyCodable.null`; if the type exposes null differently (e.g. `AnyCodable(nil as String?)` or an `.isNull` on a specific init), adjust the two null-related lines to match `QueryResult.swift`'s `AnyCodable`. The glyphs `✓`/`✗` here are arbitrary test stand-ins for `boolTrue`/`boolFalse`.

- [ ] **Step 2: Script** — `scripts/test-result-cell-text.sh` (then `chmod +x`):
```bash
#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")/.."
swiftc -o /tmp/result-cell-text-tests \
  Pharos/Models/QueryResult.swift \
  Pharos/Utilities/PGTypeCategory.swift \
  Pharos/ViewControllers/ResultsGrid/ResultCellText.swift \
  PharosTests/ResultCellTextTests.swift \
  PharosTests/main.swift
/tmp/result-cell-text-tests
```
If `QueryResult.swift` or `PGTypeCategory.swift` pull in AppKit/UIKit and won't compile standalone, report it — but both are expected Foundation-only (other harnesses compile `QueryResult.swift`).

- [ ] **Step 3: Run → FAIL** (`ResultCellText` undefined). `scripts/test-result-cell-text.sh`

- [ ] **Step 4: Implement** — create `Pharos/ViewControllers/ResultsGrid/ResultCellText.swift`:
```swift
import Foundation

extension String {
    /// Replaces newlines with a visible ↵ so multi-line data shows as one line
    /// in the results grid. (Moved here from ResultsDataSource so the width
    /// measurement can share it; internal, not private.)
    var flattenedForCell: String {
        guard contains(where: \.isNewline) else { return self }
        return replacingOccurrences(of: "\r\n", with: "↵")
            .replacingOccurrences(of: "\n", with: "↵")
            .replacingOccurrences(of: "\r", with: "↵")
    }
}

/// The exact string a result cell renders for a value — shared by the grid's
/// cell styling (`styleCell`) and the column-width measurement, so what's
/// measured always equals what's drawn.
enum ResultCellText {
    static func rendered(value: AnyCodable, category: PGTypeCategory,
                         boolTrue: String, boolFalse: String, nullString: String) -> String {
        if value.isNull { return nullString }
        let raw = value.displayString
        switch category {
        case .boolean:
            switch raw.lowercased() {
            case "t", "true": return boolTrue
            case "f", "false": return boolFalse
            default: return raw
            }
        case .string, .json, .array:
            return raw.flattenedForCell
        case .numeric, .temporal:
            return raw
        }
    }
}
```

- [ ] **Step 5: Remove the duplicate + refactor `styleCell`** — in `ResultsGrid/ResultsDataSource.swift`:
  - Delete the `private extension String { var flattenedForCell … }` block (:6–15) — it now lives in `ResultCellText.swift` as an internal extension (still reachable from `styleCell`).
  - Replace `styleCell`'s string assignment + bool transform with the shared helper, keeping the colour/font logic:
```swift
    private func styleCell(_ cell: ResultCellView, value: AnyCodable, category: PGTypeCategory) {
        guard let textField = cell.textField else { return }
        textField.stringValue = ResultCellText.rendered(
            value: value, category: category,
            boolTrue: boolTrueString, boolFalse: boolFalseString, nullString: nullDisplayString)

        if value.isNull {
            textField.font = italicFont
            cell.normalTextColor = .tertiaryLabelColor
            return
        }
        textField.font = regularFont
        let color: NSColor
        switch category {
        case .numeric: color = .systemBlue
        case .boolean:
            let low = value.displayString.lowercased()
            color = (low == "t" || low == "true") ? .systemGreen
                  : (low == "f" || low == "false") ? .systemRed : .labelColor
        case .temporal: color = .systemPurple
        case .json: color = .systemOrange
        case .array: color = .secondaryLabelColor
        case .string: color = .labelColor
        }
        cell.normalTextColor = color
    }
```
(Colour for BOOL keys off the *raw* value, matching today; the rendered glyph only affects `stringValue`.)

- [ ] **Step 6: Run → PASS** (`scripts/test-result-cell-text.sh`), then **build** (`xcodegen generate && xcodebuild … build` → BUILD SUCCEEDED — confirms `styleCell` still compiles and `flattenedForCell` resolves).

- [ ] **Step 7: Commit**
```bash
xcodegen generate
git add Pharos/ViewControllers/ResultsGrid/ResultCellText.swift PharosTests/ResultCellTextTests.swift scripts/test-result-cell-text.sh Pharos/ViewControllers/ResultsGrid/ResultsDataSource.swift Pharos.xcodeproj/project.pbxproj
git commit -m "feat(grid): ResultCellText.rendered — shared cell-render string helper"
```

---

# Phase B — Two-row header (build-gated + manual)

## Task B1: Two-row header cell + taller header + remove old sort path

**Files:** `ResultsGrid/FilterableHeaderView.swift`, `ResultsGridVC.swift`.

- [ ] **Step 1: Two-row header cell.** In `FilterableHeaderView.swift`, replace `SortAwareHeaderCell` (:6–25) with a two-row cell (keep the class name so existing references compile; drop `sortIndicator` + the left-shift):
```swift
/// Header cell that draws the column name on row 1 and the data type on row 2.
/// Sort/filter affordances are drawn by FilterableHeaderView as row-2 overlays
/// (not here), so this cell reserves no horizontal space for them.
class SortAwareHeaderCell: NSTableHeaderCell {
    var nameString: String = ""
    var typeString: String = ""

    static let nameFont = NSFont.systemFont(ofSize: 11.5, weight: .semibold)
    static let typeFont = NSFont.systemFont(ofSize: 9, weight: .regular)
    static let inset: CGFloat = 6

    override func drawInterior(withFrame cellFrame: NSRect, in controlView: NSView) {
        drawBackgroundOnly(withFrame: cellFrame, in: controlView)   // keep the header bg/sort tint if any
        let nameAttrs: [NSAttributedString.Key: Any] = [.font: Self.nameFont, .foregroundColor: NSColor.labelColor]
        let typeAttrs: [NSAttributedString.Key: Any] = [.font: Self.typeFont, .foregroundColor: NSColor.secondaryLabelColor]
        let nameSize = (nameString as NSString).size(withAttributes: nameAttrs)
        let typeSize = (typeString as NSString).size(withAttributes: typeAttrs)
        let gap: CGFloat = 1
        let totalH = nameSize.height + gap + typeSize.height
        // Header views are non-flipped (y up); place name above type, block-centered.
        let bottomY = cellFrame.midY - totalH / 2
        (typeString as NSString).draw(at: NSPoint(x: cellFrame.minX + Self.inset, y: bottomY), withAttributes: typeAttrs)
        (nameString as NSString).draw(at: NSPoint(x: cellFrame.minX + Self.inset, y: bottomY + typeSize.height + gap), withAttributes: nameAttrs)
    }

    /// Draw only the standard header background (no text) so our custom two-row
    /// text isn't drawn twice. If `super.drawInterior` paints text, avoid calling
    /// it; if the header background is drawn elsewhere (the header view), this can
    /// be a no-op. Verify visually and adjust.
    private func drawBackgroundOnly(withFrame cellFrame: NSRect, in controlView: NSView) { }
}
```
NOTE (manual-tune, the task's known risk): header cells are **not** flipped, so `draw(at:)` y grows upward — the code places type at `bottomY` and name above it. Verify the name sits on top and both are vertically centered; nudge `bottomY`/`gap` as needed. If `NSTableHeaderCell` needs its background drawn, call the appropriate `super` background path (not the text) — adjust `drawBackgroundOnly`.

- [ ] **Step 2: Feed name/type + keep `col.title`.** In `ResultsGridVC.rebuildColumns` (the `for (index, colDef)` loop ~:430), replace the combined `attributedStringValue` setup with:
```swift
            let headerCell = SortAwareHeaderCell()
            headerCell.nameString = colDef.name
            headerCell.typeString = colDef.dataType.uppercased()
            col.headerCell = headerCell
```
and **keep** `col.title = colDef.name` (~:432) — it feeds accessibility + the column-drag image. Remove the `attrStr`/`NSMutableAttributedString` block that built `"name  type"`.

- [ ] **Step 3: Taller header.** In `setupResultsGrid` where `filterableHeaderView` is created (~:119), set its height so two rows fit:
```swift
        filterableHeaderView = FilterableHeaderView()
        filterableHeaderView.filterDelegate = self
        var hf = filterableHeaderView.frame; hf.size.height = 34; filterableHeaderView.frame = hf
        tableView.headerView = filterableHeaderView
```
If `NSTableView` resets the header height, override it sticking (e.g. give `FilterableHeaderView` an explicit `frame`/`intrinsicContentSize` or set the height after `tableView.headerView =`); the layout code at `ResultsGridVC+Setup.swift:26` already reads `headerView?.frame.height`, so a taller header propagates to the clip/scroller math. **Verify the header actually grows before proceeding** (this is the spec's flagged main risk).

- [ ] **Step 4: Kill the old sort-cell path.** `updateSortCellIndicators` (:234–245) currently sets `cell.sortIndicator`. Repurpose it to just trigger a header redraw (the arrow is drawn by the view in Task B2):
```swift
    private func updateSortCellIndicators() {
        needsDisplay = true
    }
```
(Leave its call sites intact — they now just request a redraw. `SortAwareHeaderCell` no longer has `sortIndicator`, so this must not reference it.)

- [ ] **Step 5: Build + manual.** BUILD SUCCEEDED; header shows the **name on top, type beneath**; the `#` row-number header still reads cleanly (it has an empty `typeString`, so only its title/name draws — verify it looks right, tweak if the rownum cell isn't a `SortAwareHeaderCell`). No sort arrow yet (Task B2). No double-text.

- [ ] **Step 6: Commit** (`feat(grid): two-row header cell (name / type) + taller header`).

## Task B2: Row-2 overlay affordances (sort arrow + filter funnel)

**Files:** `ResultsGrid/FilterableHeaderView.swift`.

- [ ] **Step 1: Reposition the funnel to row 2.** `filterIconRect(inHeaderRect:)` (:249–256) currently vertically centers in the full header. Constrain it to the **bottom** (row-2) band:
```swift
    private func filterIconRect(inHeaderRect headerRect: NSRect) -> NSRect {
        let side = iconSize + iconPadding * 2
        let row2MidY = headerRect.minY + headerRect.height * 0.28   // lower third ≈ row 2 (non-flipped: minY = bottom)
        return NSRect(x: headerRect.maxX - side - 8, y: row2MidY - side / 2, width: side, height: side)
    }
```
(Adjust the `0.28` factor to line up with the type row after B1's vertical layout; verify visually.)

- [ ] **Step 2: Draw the sort arrow on row-2 right.** In `FilterableHeaderView.draw` (:207–229), after the funnel loop, add a sort-arrow overlay for sorted columns, positioned just left of the funnel slot on row 2:
```swift
        for (colIndex, column) in tableView.tableColumns.enumerated() {
            let colId = column.identifier.rawValue
            guard colId != "__rownum__", let dir = sortDirections[colId] else { continue }
            let headerRect = self.headerRect(ofColumn: colIndex)
            let arrow = dir == .ascending ? "▲" : "▼"
            let attrs: [NSAttributedString.Key: Any] = [
                .font: NSFont.systemFont(ofSize: 9, weight: .semibold),
                .foregroundColor: NSColor.secondaryLabelColor,
            ]
            let sz = (arrow as NSString).size(withAttributes: attrs)
            let funnelSlot = iconSize + iconPadding * 2 + 8
            let iconRect = filterIconRect(inHeaderRect: headerRect)
            let x = headerRect.maxX - funnelSlot - sz.width - 2
            (arrow as NSString).draw(at: NSPoint(x: x, y: iconRect.midY - sz.height / 2), withAttributes: attrs)
        }
```
(`sortDirections` already exists on the view and drives `updateSortCellIndicators`. This draws the arrow persistently when sorted, overlaying row-2's right — no width reserved. Verify it doesn't collide with the funnel when both show.)

- [ ] **Step 2b:** Confirm the `draw(...)` funnel block (:207–229) already uses `filterIconRect` (it does) so the funnel now renders on row 2 automatically from Step 1.

- [ ] **Step 3: Build + manual.**
  - Sort a column → arrow appears on row-2 right, visible **at rest** (not just hover), no text shift.
  - Hover a column → funnel appears on row-2 right; clicking it still opens the filter popover (routing via `filterIconRect` in `mouseDown` :147–188 is unchanged).
  - Clicking elsewhere on the header still sorts; right-edge double-click still auto-fits.
  - On a narrow column the overlays sit over the type label's tail; the **name is never covered**.

- [ ] **Step 4: Commit** (`feat(grid): sort + filter affordances as row-2 overlays (no reserved width)`).

---

# Phase C — Content-aware width (build-gated + manual)

## Task C1: measuredColumnWidth + default + auto-fit + 1000 cap

**Files:** `ResultsGridVC.swift`.

- [ ] **Step 1: Shared measurement.** Add `measuredColumnWidth`, replacing the guts of `autoFitColumn` and superseding `estimateColumnWidth`:
```swift
    /// Content-aware width: max of the header name row, the header type row, and the
    /// rendered cell contents (sampled), clamped to [minWidth, 1000]. No funnel/sort
    /// reserve — those overlay row 2 (two-row header). `includeVisibleSample` adds the
    /// on-screen rows (on-demand auto-fit); the initial default passes false because
    /// reloadData() hasn't run yet at column-creation time (visible rect is stale).
    func measuredColumnWidth(column: NSTableColumn, colId: String, includeVisibleSample: Bool) -> CGFloat {
        guard let idx = colIndex(from: colId) else { return column.width }
        let headerInset: CGFloat = 6 * 2
        let nameW: CGFloat
        let typeW: CGFloat
        if let cell = column.headerCell as? SortAwareHeaderCell {
            nameW = (cell.nameString as NSString).size(withAttributes: [.font: SortAwareHeaderCell.nameFont]).width
            typeW = (cell.typeString as NSString).size(withAttributes: [.font: SortAwareHeaderCell.typeFont]).width
        } else { nameW = 0; typeW = 0 }
        var maxW = max(nameW, typeW) + headerInset

        // Sample: first/last 100 always; visible rows only for on-demand auto-fit.
        var sampleIndices = Set<Int>()
        let total = displayRows.count
        for i in 0..<min(100, total) { sampleIndices.insert(i) }
        for i in max(0, total - 100)..<total { sampleIndices.insert(i) }
        if includeVisibleSample {
            let vr = tableView.rows(in: tableView.visibleRect)
            if vr.length > 0 { for i in vr.location..<(vr.location + vr.length) { sampleIndices.insert(i) } }
        }
        let attrs: [NSAttributedString.Key: Any] = [.font: NSFont.monospacedSystemFont(ofSize: 12, weight: .regular)]
        for r in sampleIndices {
            guard r < displayRows.count else { continue }
            let d = displayRows[r]
            guard d < rows.count, idx < rows[d].count else { continue }
            let cat = idx < columnCategories.count ? columnCategories[idx] : .string
            let text = ResultCellText.rendered(value: rows[d][idx], category: cat,
                                               boolTrue: boolDisplayTrue, boolFalse: boolDisplayFalse, nullString: nullDisplay)
            maxW = max(maxW, (text as NSString).size(withAttributes: attrs).width + 12)
        }
        return min(max(maxW, column.minWidth), 1000)
    }
```
NOTE: the data source holds `boolTrueString`/`boolFalseString`/`nullDisplayString` privately. Expose the current values to the VC — either read them from the settings the VC already has, or add read-only accessors on the data source (`var boolDisplayTrue: String { boolTrueString }`, etc.) and reference those. Use whichever the codebase makes cleanest; the values MUST match what `styleCell` uses. Replace `boolDisplayTrue`/`boolDisplayFalse`/`nullDisplay` above with those accessors.

- [ ] **Step 2: Auto-fit uses it.** Replace `autoFitColumn`'s body (:661–700) with:
```swift
    func autoFitColumn(at columnIndex: Int) {
        guard columnIndex >= 0, columnIndex < tableView.tableColumns.count else { return }
        let column = tableView.tableColumns[columnIndex]
        let colId = column.identifier.rawValue
        guard colId != "__rownum__" else { return }
        column.width = measuredColumnWidth(column: column, colId: colId, includeVisibleSample: true)
    }
```

- [ ] **Step 3: Default at creation + cap.** In `rebuildColumns` (the `for (index, colDef)` loop): set `col.maxWidth = 1000` (was 720), keep `col.minWidth = 50`, and set the default width via the shared measurement *after* the header cell's `nameString`/`typeString` are assigned (so the header rows measure):
```swift
            col.minWidth = 50
            col.maxWidth = 1000
            // (headerCell.nameString / .typeString already set per Task B1 Step 2)
            col.width = measuredColumnWidth(column: col, colId: "col_\(index)", includeVisibleSample: false)
```
Delete the `estimateColumnWidth(_:)` method (:456–470) and its call.

- [ ] **Step 4: Build + manual.**
  - `cc` and the two BOOL columns open **snug** (≈ 50px floor, not 150); no wasted whitespace.
  - A long-text/JSON column opens capped at 1000 and otherwise fits its content.
  - Drag a column — stops at 1000. Divider double-click auto-fit matches the default (and, for a sorted column, includes the arrow-free header — arrow overlays, so no under-measure).
  - A workspace with saved column widths still restores them (restore runs after and overwrites).

- [ ] **Step 5: Commit** (`feat(grid): content-aware column width (max name/type/content), 1000px cap`).

---

# Phase V — Verification

## Task V1: Harness + build

- [ ] **Step 1:** `scripts/test-result-cell-text.sh` → "All tests passed."
- [ ] **Step 2:** Re-run the other existing chart/grid harnesses to confirm no regressions from the `styleCell`/`flattenedForCell` move:
```bash
for s in result-cell-text drill-summary drill-coverage; do printf "%-18s " "$s:"; scripts/test-$s.sh 2>&1 | tail -1; done
```
- [ ] **Step 3:** Clean build → `** BUILD SUCCEEDED **`.

## Task V2: Manual GUI (use the `verify` skill)

- [ ] Two-row header renders (name over type); header height looks right; `#` column reads cleanly.
- [ ] Short text/BOOL columns snug to ~50px; long-content columns cap at 1000; drag stops at 1000; auto-fit (double-click divider) matches, including on a sorted column.
- [ ] Sort arrow shows at rest when sorted (row-2 right); filter funnel on hover opens the popover; header click sorts; overlays never shift/widen a column; the name is never obscured.
- [ ] Saved widths restore on workspace reopen.
- [ ] **Step:** Commit any fixes; ready for `finishing-a-development-branch`.

---

## Notes for the implementer

- **Execution order:** A (pure, TDD) → B1 (two-row cell + height — verify the header actually grows early, it's the main risk) → B2 (overlay affordances) → C1 (measurement) → V.
- **Pure vs UI boundary:** `ResultCellText.rendered` is Foundation-only and unit-tested; the header rendering, header height, overlay drawing, and `measuredColumnWidth` are AppKit — build-gated + manually verified.
- **`project.pbxproj` is tracked** — `xcodegen generate` + stage it for Task A1 (new file).
- **No new width reserve for icons** — the whole point of the two-row header: the funnel and sort arrow overlay row 2, so `measuredColumnWidth` sums nothing for them.
- **Verify while implementing:** how `AnyCodable` represents null (Task A1 test); whether the data source needs read accessors for the bool/null display strings (Task C1); that the custom header height sticks (Task B1); and the header cell's non-flipped `draw(at:)` vertical placement (Task B1).
