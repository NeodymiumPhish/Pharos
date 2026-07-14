# Resizable / Auto-Sizing Column Filter Popover Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Make the results-grid column filter popover open sized to fit its distinct values (up to a window-relative cap) and let the user drag a corner grip to further widen it and grow the value list taller.

**Architecture:** Extract the clamp math into a pure, unit-tested `FilterPopoverSizing` enum. Make `ColumnFilterPopoverVC`'s width dynamic (stack `.fill` + a stored `currentWidth` driving `preferredContentSize`) instead of the fixed `innerWidth = 236` constraints. Auto-size on open by measuring value widths via a new `FilterValueListView.maxValueWidth(font:)`. Add a `ResizeGripView` that reports cumulative drag deltas via closures; the VC clamps them through `FilterPopoverSizing` and applies width to itself and height to the value list. The reference size (results pane) is passed in by the presenter.

**Tech Stack:** Swift / AppKit. Pure-logic tests via standalone `swiftc` harness (project has no XCTest target — see `scripts/test-*.sh`). App build via `xcodebuild`. New files require `xcodegen generate`.

---

## File Structure

- **Create** `Pharos/ViewControllers/ResultsGrid/FilterPopoverSizing.swift` — pure clamp math (min/max width & list height). No AppKit; unit-tested.
- **Create** `Pharos/ViewControllers/ResultsGrid/ResizeGripView.swift` — small bottom-right grip `NSView`; reports drag deltas via closures. Knows nothing about filters.
- **Create** `PharosTests/FilterPopoverSizingTests.swift` — harness tests for `FilterPopoverSizing`.
- **Create** `scripts/test-filter-popover-sizing.sh` — standalone test runner.
- **Modify** `Pharos/ViewControllers/ResultsGrid/FilterValueListView.swift` — variable list height (`listHeight` / `setListHeight`) + `maxValueWidth(font:)`.
- **Modify** `Pharos/ViewControllers/ResultsGrid/ColumnFilterPopoverVC.swift` — dynamic width, auto-size, grip wiring, `hostPopover`, `referenceSize`; remove `innerWidth` constraints.
- **Modify** `Pharos/ViewControllers/ResultsGrid/ResultsGridVC+Delegates.swift` — compute & pass `referenceSize`, set `hostPopover`.

**Standard app build command** (used in several tasks below; it also compiles the Rust core via the pre-build script):

```bash
xcodebuild -project Pharos.xcodeproj -scheme Pharos -configuration Debug build 2>&1 | tail -8
```
Expected on success: a line `** BUILD SUCCEEDED **`.

---

## Task 1: `FilterPopoverSizing` pure clamp math (TDD)

**Files:**
- Create: `Pharos/ViewControllers/ResultsGrid/FilterPopoverSizing.swift`
- Test: `PharosTests/FilterPopoverSizingTests.swift`
- Test runner: `scripts/test-filter-popover-sizing.sh`

- [ ] **Step 1: Write the failing test**

Create `PharosTests/FilterPopoverSizingTests.swift`:

```swift
// Standalone test runner for FilterPopoverSizing — no Xcode project involvement.
// Compiled with Pharos/ViewControllers/ResultsGrid/FilterPopoverSizing.swift
// by scripts/test-filter-popover-sizing.sh.
import CoreGraphics

var failures = 0

func expectEqual(_ actual: CGFloat, _ expected: CGFloat, _ name: String) {
    if abs(actual - expected) < 0.0001 { print("PASS \(name)") } else {
        failures += 1
        print("FAIL \(name)\n  expected: \(expected)\n  actual:   \(actual)")
    }
}

func runTests() {
    // maxWidth: 60% of reference, floored at minWidth (260)
    expectEqual(FilterPopoverSizing.maxWidth(referenceWidth: 1000), 600, "maxWidth 1000 → 600")
    expectEqual(FilterPopoverSizing.maxWidth(referenceWidth: 300), 260, "maxWidth 300 → floor 260")

    // clampWidth into [260, maxWidth]
    expectEqual(FilterPopoverSizing.clampWidth(500, referenceWidth: 1000), 500, "clampWidth mid → 500")
    expectEqual(FilterPopoverSizing.clampWidth(100, referenceWidth: 1000), 260, "clampWidth below → 260")
    expectEqual(FilterPopoverSizing.clampWidth(900, referenceWidth: 1000), 600, "clampWidth above → 600")

    // maxListHeight: 60% of reference, floored at minListHeight (120)
    expectEqual(FilterPopoverSizing.maxListHeight(referenceHeight: 1000), 600, "maxListHeight 1000 → 600")
    expectEqual(FilterPopoverSizing.maxListHeight(referenceHeight: 100), 120, "maxListHeight 100 → floor 120")

    // clampListHeight into [120, maxListHeight]
    expectEqual(FilterPopoverSizing.clampListHeight(300, referenceHeight: 1000), 300, "clampListHeight mid → 300")
    expectEqual(FilterPopoverSizing.clampListHeight(50, referenceHeight: 1000), 120, "clampListHeight below → 120")
    expectEqual(FilterPopoverSizing.clampListHeight(900, referenceHeight: 1000), 600, "clampListHeight above → 600")

    if failures == 0 { print("\nAll tests passed.") } else { print("\n\(failures) failure(s)."); exit(1) }
}
```

Create `scripts/test-filter-popover-sizing.sh`:

```bash
#!/bin/bash
# Standalone test runner for FilterPopoverSizing — no Xcode project involvement.
set -euo pipefail
cd "$(dirname "$0")/.."
TMPMAIN=$(mktemp -d)/main.swift
echo "runTests()" > "$TMPMAIN"
swiftc -o /tmp/filter-popover-sizing-tests \
  Pharos/ViewControllers/ResultsGrid/FilterPopoverSizing.swift \
  PharosTests/FilterPopoverSizingTests.swift \
  "$TMPMAIN"
/tmp/filter-popover-sizing-tests
```

- [ ] **Step 2: Run test to verify it fails**

Run:
```bash
chmod +x scripts/test-filter-popover-sizing.sh && ./scripts/test-filter-popover-sizing.sh
```
Expected: FAIL — compile error, `cannot find 'FilterPopoverSizing' in scope` (the impl file does not exist yet).

- [ ] **Step 3: Write minimal implementation**

Create `Pharos/ViewControllers/ResultsGrid/FilterPopoverSizing.swift`:

```swift
import CoreGraphics

/// Pure sizing math for the column filter popover. No AppKit — unit-testable via
/// the standalone swiftc harness (scripts/test-filter-popover-sizing.sh).
enum FilterPopoverSizing {
    /// Narrowest the popover may be (the historical fixed width).
    static let minWidth: CGFloat = 260
    /// Shortest the value list may be (~5 rows at rowHeight 20 + spacing 2).
    static let minListHeight: CGFloat = 120
    /// The value list's height when the popover first opens.
    static let defaultListHeight: CGFloat = 180
    /// Fraction of the reference (results pane) size used as the upper bound.
    static let maxFraction: CGFloat = 0.6

    /// Upper bound for popover width given the reference (results pane) width.
    static func maxWidth(referenceWidth: CGFloat) -> CGFloat {
        max(minWidth, referenceWidth * maxFraction)
    }

    /// Upper bound for the value-list height given the reference height.
    static func maxListHeight(referenceHeight: CGFloat) -> CGFloat {
        max(minListHeight, referenceHeight * maxFraction)
    }

    /// Clamp a desired popover width into [minWidth, maxWidth(referenceWidth)].
    static func clampWidth(_ desired: CGFloat, referenceWidth: CGFloat) -> CGFloat {
        min(max(desired, minWidth), maxWidth(referenceWidth: referenceWidth))
    }

    /// Clamp a desired list height into [minListHeight, maxListHeight(referenceHeight)].
    static func clampListHeight(_ desired: CGFloat, referenceHeight: CGFloat) -> CGFloat {
        min(max(desired, minListHeight), maxListHeight(referenceHeight: referenceHeight))
    }
}
```

- [ ] **Step 4: Run test to verify it passes**

Run:
```bash
./scripts/test-filter-popover-sizing.sh
```
Expected: every line `PASS ...` then `All tests passed.`

- [ ] **Step 5: Commit**

```bash
git add Pharos/ViewControllers/ResultsGrid/FilterPopoverSizing.swift \
        PharosTests/FilterPopoverSizingTests.swift \
        scripts/test-filter-popover-sizing.sh
git commit -m "feat: FilterPopoverSizing — pure clamp math for filter popover + tests"
```

---

## Task 2: `ResizeGripView` (new view)

**Files:**
- Create: `Pharos/ViewControllers/ResultsGrid/ResizeGripView.swift`

- [ ] **Step 1: Write the implementation**

Create `Pharos/ViewControllers/ResultsGrid/ResizeGripView.swift`:

```swift
import AppKit

/// A small bottom-right resize grip. Draws the standard diagonal-lines glyph and
/// reports cumulative drag deltas (from the drag's start point) via closures.
/// Self-contained: knows nothing about what it resizes.
final class ResizeGripView: NSView {

    /// Called on mouse-down, before any drag delta is reported.
    var onDragBegan: (() -> Void)?
    /// Cumulative delta from the drag's start point. dx > 0 = dragged right,
    /// dy > 0 = dragged down. Reported on every mouse-dragged event.
    var onDrag: ((_ dx: CGFloat, _ dy: CGFloat) -> Void)?
    /// Called on mouse-up (drag finished).
    var onDragEnded: (() -> Void)?

    private var startInWindow: NSPoint = .zero

    override func draw(_ dirtyRect: NSRect) {
        NSColor.secondaryLabelColor.setStroke()
        let path = NSBezierPath()
        path.lineWidth = 1
        let w = bounds.width
        // Three short diagonal ticks tucked into the corner.
        for offset in stride(from: CGFloat(3), through: w - 1, by: 4) {
            path.move(to: NSPoint(x: w - 1, y: offset))
            path.line(to: NSPoint(x: offset, y: 1))
        }
        path.stroke()
    }

    override func mouseDown(with event: NSEvent) {
        startInWindow = event.locationInWindow
        onDragBegan?()
    }

    override func mouseDragged(with event: NSEvent) {
        let p = event.locationInWindow
        let dx = p.x - startInWindow.x
        // Window coords are non-flipped (y up), so dragging DOWN lowers y →
        // startY - currentY is positive, which we treat as "grow height".
        let dy = startInWindow.y - p.y
        onDrag?(dx, dy)
    }

    override func mouseUp(with event: NSEvent) {
        onDragEnded?()
    }
}
```

- [ ] **Step 2: Commit** (build verified in Task 3 once the project is regenerated)

```bash
git add Pharos/ViewControllers/ResultsGrid/ResizeGripView.swift
git commit -m "feat: ResizeGripView — corner drag grip reporting cumulative deltas"
```

---

## Task 3: Regenerate project & verify new files compile

**Files:** (no source edits — regenerate + build)

- [ ] **Step 1: Regenerate the Xcode project**

Run:
```bash
xcodegen generate
```
Expected: `Loaded project ...` / `Created project at Pharos.xcodeproj`. This picks up the two new `.swift` files under `Pharos/` (XcodeGen globs the sources directory).

- [ ] **Step 2: Build the app to confirm the new files compile in-project**

Run:
```bash
xcodebuild -project Pharos.xcodeproj -scheme Pharos -configuration Debug build 2>&1 | tail -8
```
Expected: `** BUILD SUCCEEDED **`. (`FilterPopoverSizing` and `ResizeGripView` are unused so far — this just confirms they compile as part of the app target.)

- [ ] **Step 3: Commit the regenerated project**

```bash
git add Pharos.xcodeproj/project.pbxproj
git commit -m "chore: xcodegen — add FilterPopoverSizing + ResizeGripView to project"
```

---

## Task 4: `FilterValueListView` — variable height + value-width measurement

**Files:**
- Modify: `Pharos/ViewControllers/ResultsGrid/FilterValueListView.swift:19-20` (add stored constraint property), `:50-56` (setup constraints), and add two methods.

- [ ] **Step 1: Add a stored height-constraint property**

In the property block (after `private var searchQuery: String = ""`, around `:20`), add:

```swift
    private var heightConstraint: NSLayoutConstraint!
```

- [ ] **Step 2: Use the stored constraint in `setup()`**

Replace the `NSLayoutConstraint.activate([...])` block in `setup()` (currently `:50-56`):

```swift
        NSLayoutConstraint.activate([
            scrollView.topAnchor.constraint(equalTo: topAnchor),
            scrollView.leadingAnchor.constraint(equalTo: leadingAnchor),
            scrollView.trailingAnchor.constraint(equalTo: trailingAnchor),
            scrollView.bottomAnchor.constraint(equalTo: bottomAnchor),
            heightAnchor.constraint(equalToConstant: 180),
        ])
```

with:

```swift
        heightConstraint = heightAnchor.constraint(equalToConstant: 180)
        NSLayoutConstraint.activate([
            scrollView.topAnchor.constraint(equalTo: topAnchor),
            scrollView.leadingAnchor.constraint(equalTo: leadingAnchor),
            scrollView.trailingAnchor.constraint(equalTo: trailingAnchor),
            scrollView.bottomAnchor.constraint(equalTo: bottomAnchor),
            heightConstraint,
        ])
```

- [ ] **Step 3: Add the height accessor/mutator and width measurement**

Add these methods to the `FilterValueListView` class body (e.g. right after `setup()`):

```swift
    /// Current fixed height of the list.
    var listHeight: CGFloat { heightConstraint.constant }

    /// Set the list's fixed height. Caller is responsible for clamping.
    func setListHeight(_ h: CGFloat) { heightConstraint.constant = h }

    /// Widest rendered width across the full (pre-search) value set, using the
    /// given font. Accounts for the "(Blanks)" display label. Returns 0 if empty.
    func maxValueWidth(font: NSFont) -> CGFloat {
        let attrs: [NSAttributedString.Key: Any] = [.font: font]
        var widest: CGFloat = 0
        for value in allValues {
            let w = (displayLabel(for: value) as NSString).size(withAttributes: attrs).width
            if w > widest { widest = w }
        }
        return widest
    }
```

Note: `displayLabel(for:)` and `allValues` already exist on this class (`FilterValueListView.swift`, ~`:17` and ~`:82`). If `displayLabel` is declared in an extension, that's fine — it's the same type, so it's in scope.

- [ ] **Step 4: Build to verify it compiles**

Run:
```bash
xcodebuild -project Pharos.xcodeproj -scheme Pharos -configuration Debug build 2>&1 | tail -8
```
Expected: `** BUILD SUCCEEDED **`.

- [ ] **Step 5: Commit**

```bash
git add Pharos/ViewControllers/ResultsGrid/FilterValueListView.swift
git commit -m "feat: FilterValueListView — variable height + maxValueWidth(font:)"
```

---

## Task 5: `ColumnFilterPopoverVC` — dynamic width, auto-size, `referenceSize`, `hostPopover`

This task makes width dynamic and auto-sizes on open. Drag wiring is Task 6.

**Files:**
- Modify: `Pharos/ViewControllers/ResultsGrid/ColumnFilterPopoverVC.swift` — init (`:80-89`), stored properties (`:22-44`), `loadView` stack + constraint removals (`:103`, `:179-193`, `:187`), value-area constraint removals (`:402-461`), auto-size insertion (`:239`), and `recalculateSize` (`:473-479`).

- [ ] **Step 1: Add stored properties for width, reference size, and popover**

In the property block (after `private let existingFilter: ColumnFilter?` at `:28`), add:

```swift
    private let referenceSize: CGSize
```

And after `private let stackView = NSStackView()` (`:44`), add:

```swift
    /// Current popover content width. Set by auto-size on open and by drag-resize.
    private var currentWidth: CGFloat = FilterPopoverSizing.minWidth
    /// The presenting popover — used only to disable animation during drag.
    weak var hostPopover: NSPopover?
```

- [ ] **Step 2: Accept `referenceSize` in the initializer**

Change the initializer signature (`:80-81`) and body to store it. Replace:

```swift
    init(columnName: String, displayName: String, category: PGTypeCategory, dataType: String,
         existingFilter: ColumnFilter?, distinctValues: [String], hasBlanks: Bool) {
        self.columnName = columnName
        self.displayName = displayName
        self.category = category
        self.dataType = dataType
        self.existingFilter = existingFilter
        self.checklistValues = distinctValues + (hasBlanks ? [ColumnFilter.blanksSentinel] : [])
        super.init(nibName: nil, bundle: nil)
    }
```

with:

```swift
    init(columnName: String, displayName: String, category: PGTypeCategory, dataType: String,
         existingFilter: ColumnFilter?, distinctValues: [String], hasBlanks: Bool,
         referenceSize: CGSize) {
        self.columnName = columnName
        self.displayName = displayName
        self.category = category
        self.dataType = dataType
        self.existingFilter = existingFilter
        self.checklistValues = distinctValues + (hasBlanks ? [ColumnFilter.blanksSentinel] : [])
        self.referenceSize = referenceSize
        super.init(nibName: nil, bundle: nil)
    }
```

- [ ] **Step 3: Make the main stack and advanced container fill their width**

In `loadView`, change the main stack alignment (`:103`) from:

```swift
        stackView.alignment = .leading
```
to:
```swift
        stackView.alignment = .fill
```

And change the advanced container alignment (`:187`) from:

```swift
        advancedContainer.alignment = .leading
```
to:
```swift
        advancedContainer.alignment = .fill
```

- [ ] **Step 4: Remove the fixed `innerWidth` width constraints in `loadView`**

The block at `:171-193` pins everything to `innerWidth = 236`. Delete these five width-constraint lines (leave the surrounding code intact):

- `:179` `searchField.widthAnchor.constraint(equalToConstant: innerWidth).isActive = true`
- `:182` `valueList.widthAnchor.constraint(equalToConstant: innerWidth).isActive = true`
- `:189` `operatorPopup.widthAnchor.constraint(equalToConstant: innerWidth).isActive = true`
- `:191` `advancedContainer.widthAnchor.constraint(equalToConstant: innerWidth).isActive = true`
- `:193` `buttonRow.widthAnchor.constraint(equalToConstant: innerWidth).isActive = true`

Then delete the now-unused local constant declaration at `:171`:

```swift
        let innerWidth: CGFloat = 236  // 260 content - 24 padding
```

(The `valueList.onSelectionChanged = ...` line at `:183` stays.)

- [ ] **Step 5: Remove the accumulating `innerWidth` constraints in `updateValueArea`**

In `updateValueArea` (`:396-468`), delete the local `let innerWidth: CGFloat = 236` (`:398`) and every `...widthAnchor.constraint(equalToConstant: innerWidth).isActive = true` line on the reused/created fields:

- `:402` `tokenField.widthAnchor...`
- `:409` `row1.widthAnchor...`
- `:419` `row2.widthAnchor...`
- `:431` `timePicker.widthAnchor...`
- `:446` `timePicker2.widthAnchor...`
- `:453` `valueField.widthAnchor...`
- `:461` `value2Field.widthAnchor...`

With the advanced container now `.fill`, these views stretch to the container width. (This also removes the constraint-accumulation issue where reused fields gained a fresh width constraint on every `updateValueArea` call.)

- [ ] **Step 6: Add `autoSizeWidth()` and call it before the first sizing**

Add this method to the class (e.g. just above `recalculateSize`):

```swift
    /// Size the popover width to fit the widest value, clamped to
    /// [minWidth, 0.6 × referenceWidth]. Runs once when the popover opens.
    private func autoSizeWidth() {
        let font = NSFont.systemFont(ofSize: 12)               // matches the checklist row font
        let widest = valueList.maxValueWidth(font: font)
        // Row chrome (checkbox glyph + gaps + trailing) + scroller + list bezel + stack insets.
        let chrome: CGFloat = 78
        currentWidth = FilterPopoverSizing.clampWidth(widest + chrome,
                                                      referenceWidth: referenceSize.width)
    }
```

Then, in `loadView`, insert the call immediately before `updateValueArea()` (`:239`). Change:

```swift
        updateValueArea()
        updateApplyEnabled()
```
to:
```swift
        autoSizeWidth()
        updateValueArea()
        updateApplyEnabled()
```

(`valueList.setValues(...)` has already run in the branch above at `:226/:229/:236`, so `maxValueWidth` sees the full value set.)

- [ ] **Step 7: Drive width from `currentWidth` in `recalculateSize`**

Replace `recalculateSize()` (`:473-479`):

```swift
    private func recalculateSize() {
        stackView.layoutSubtreeIfNeeded()
        let fitting = stackView.fittingSize
        // Calendar pickers need more width than text fields
        let width: CGFloat = max(260, fitting.width)
        preferredContentSize = NSSize(width: width, height: fitting.height)
    }
```

with:

```swift
    private func recalculateSize() {
        stackView.layoutSubtreeIfNeeded()
        let fitting = stackView.fittingSize
        // Width is driven by auto-size / drag (currentWidth); height stays content-driven.
        preferredContentSize = NSSize(width: currentWidth, height: fitting.height)
    }
```

- [ ] **Step 8: Build (expected to FAIL at the call site)**

Run:
```bash
xcodebuild -project Pharos.xcodeproj -scheme Pharos -configuration Debug build 2>&1 | tail -12
```
Expected: FAIL — `ResultsGridVC+Delegates.swift` still calls the old initializer without `referenceSize` (`missing argument for parameter 'referenceSize'`). This is fixed in Task 6. (If you prefer a green build here, do Task 6 before building.)

- [ ] **Step 9: Commit**

```bash
git add Pharos/ViewControllers/ResultsGrid/ColumnFilterPopoverVC.swift
git commit -m "feat: dynamic-width filter popover with auto-size on open"
```

---

## Task 6: Wire the resize grip + pass `referenceSize`/`hostPopover` from the presenter

**Files:**
- Modify: `Pharos/ViewControllers/ResultsGrid/ColumnFilterPopoverVC.swift` — `loadView` (add grip subview + drag closures).
- Modify: `Pharos/ViewControllers/ResultsGrid/ResultsGridVC+Delegates.swift:135-149` — compute reference size, pass it, set `hostPopover`.

- [ ] **Step 1: Add the grip and drag handling in `ColumnFilterPopoverVC.loadView`**

At the end of `loadView`, after `updateApplyEnabled()` (the new `:242` region) and before the closing brace, add:

```swift
        // Bottom-right resize grip: widen the popover and grow the value list.
        let grip = ResizeGripView()
        grip.translatesAutoresizingMaskIntoConstraints = false
        container.addSubview(grip)   // added last → sits above the stack
        NSLayoutConstraint.activate([
            grip.trailingAnchor.constraint(equalTo: container.trailingAnchor, constant: -2),
            grip.bottomAnchor.constraint(equalTo: container.bottomAnchor, constant: -2),
            grip.widthAnchor.constraint(equalToConstant: 14),
            grip.heightAnchor.constraint(equalToConstant: 14),
        ])

        var dragStartWidth: CGFloat = 0
        var dragStartListHeight: CGFloat = 0
        grip.onDragBegan = { [weak self] in
            guard let self else { return }
            dragStartWidth = self.currentWidth
            dragStartListHeight = self.valueList.listHeight
            self.hostPopover?.animates = false
        }
        grip.onDrag = { [weak self] dx, dy in
            guard let self else { return }
            self.currentWidth = FilterPopoverSizing.clampWidth(
                dragStartWidth + dx, referenceWidth: self.referenceSize.width)
            let h = FilterPopoverSizing.clampListHeight(
                dragStartListHeight + dy, referenceHeight: self.referenceSize.height)
            self.valueList.setListHeight(h)
            self.recalculateSize()
        }
        grip.onDragEnded = { [weak self] in
            self?.hostPopover?.animates = true
        }
```

(`container` is the local from `loadView` line `:95-96`: `let container = NSView(); self.view = container`. It is in scope at the end of the method.)

- [ ] **Step 2: Pass `referenceSize` and set `hostPopover` in the presenter**

In `ResultsGridVC+Delegates.swift`, replace the popover construction (`:135-149`):

```swift
        let popoverVC = ColumnFilterPopoverVC(
            columnName: colId,
            displayName: columns[idx].name,
            category: category,
            dataType: rawDataType,
            existingFilter: existing,
            distinctValues: distinct.values,
            hasBlanks: distinct.hasBlanks
        )
        popoverVC.filterDelegate = self

        let popover = NSPopover()
        popover.contentViewController = popoverVC
        popover.behavior = .transient
        popover.show(relativeTo: rect, of: headerView, preferredEdge: .maxY)
```

with:

```swift
        // Reference size for width/height caps = the results pane (the table's
        // enclosing scroll view), falling back to the window, then a default.
        let referenceSize = headerView.enclosingScrollView?.bounds.size
            ?? headerView.window?.frame.size
            ?? CGSize(width: 800, height: 600)

        let popoverVC = ColumnFilterPopoverVC(
            columnName: colId,
            displayName: columns[idx].name,
            category: category,
            dataType: rawDataType,
            existingFilter: existing,
            distinctValues: distinct.values,
            hasBlanks: distinct.hasBlanks,
            referenceSize: referenceSize
        )
        popoverVC.filterDelegate = self

        let popover = NSPopover()
        popover.contentViewController = popoverVC
        popover.behavior = .transient
        popoverVC.hostPopover = popover
        popover.show(relativeTo: rect, of: headerView, preferredEdge: .maxY)
```

- [ ] **Step 3: Build to verify the whole feature compiles**

Run:
```bash
xcodebuild -project Pharos.xcodeproj -scheme Pharos -configuration Debug build 2>&1 | tail -8
```
Expected: `** BUILD SUCCEEDED **`.

- [ ] **Step 4: Commit**

```bash
git add Pharos/ViewControllers/ResultsGrid/ColumnFilterPopoverVC.swift \
        Pharos/ViewControllers/ResultsGrid/ResultsGridVC+Delegates.swift
git commit -m "feat: drag-to-resize grip + window-relative sizing for filter popover"
```

---

## Task 7: Manual verification

The behavioral/visual parts (popover sizing, drag) are not covered by the headless harness. Verify by running the app (`open Pharos.xcodeproj`, Cmd+R, or the built `.app`) against a database with a long-value column — e.g. a Zeek `dns` table's `query` column.

- [ ] **Step 1: Auto-size on open (long values)**

Open the filter on `dns.query`. Confirm the popover opens **wider than before**, fitting most values without hovering, and that it does not exceed ~60% of the results pane width. Very long outliers still truncate with the full value shown on hover.

- [ ] **Step 2: Auto-size stays compact for short values**

Open the filter on a short-value column (e.g. `qclass`). Confirm the popover opens at/near the 260pt minimum — not needlessly wide.

- [ ] **Step 3: Drag to resize width and height**

Drag the bottom-right grip. Confirm the popover widens and the value list grows taller as you drag out, shrinks as you drag in, and is bounded (won't exceed ~60% of the pane in either dimension, won't shrink below the 260 / 120 minimums, won't run off-screen). Confirm resizing feels smooth (no per-frame reposition animation).

- [ ] **Step 4: Grip doesn't block Apply**

Confirm the grip in the bottom-right corner does not swallow clicks intended for the **Apply** button; both are usable.

- [ ] **Step 5: Advanced section fills width**

Expand "Advanced text filter". Confirm the operator popup and value field(s) stretch to the popover width (no fixed 236 clipping) and that calendar/date pickers render acceptably (they keep their intrinsic width; note if any stretch looks off).

- [ ] **Step 6: Regression pass**

Confirm unchanged behavior: Search narrows the list (and does **not** change the popover width after opening); Select-All tri-state; "(Blanks)" row; tooltips; Clear and Apply; and re-opening a column that already has a filter restores its state correctly.

- [ ] **Step 7: Record results**

Note the outcome of each check in `tasks/todo.md` (or the plan's review section). If any check fails, STOP and re-plan per the project workflow rules rather than pushing forward.

---

## Self-Review Notes

- **Spec coverage:** dynamic width (Task 5) ✓; auto-size on open with window-relative cap (Tasks 1, 5) ✓; drag width + list height with clamps (Tasks 1, 2, 6) ✓; reference-size fallback chain (Task 6) ✓; truncation+tooltip unchanged (untouched) ✓; constraint-accumulation cleanup (Task 5 steps 4-5) ✓; `hostPopover.animates` during drag (Task 6) ✓.
- **Deviation from spec (intentional, simpler):** the spec mentioned a `userDidResize` flag to stop auto-size from overriding a manual resize. It is omitted: `autoSizeWidth()` runs exactly once in `loadView`, and `recalculateSize()` always uses `currentWidth`, so later recalcs (search, advanced toggle) already preserve both the auto and the dragged width. The flag would be dead state. Reference size is passed in by the presenter (not read from `view.window`) because the view has no window yet when auto-size runs during `loadView`.
- **Type consistency:** `FilterPopoverSizing.clampWidth/clampListHeight/maxWidth/maxListHeight`, `FilterValueListView.listHeight/setListHeight(_:)/maxValueWidth(font:)`, `ResizeGripView.onDragBegan/onDrag/onDragEnded`, and `ColumnFilterPopoverVC.currentWidth/hostPopover/referenceSize/autoSizeWidth()` are used consistently across tasks.
- **Line numbers** are from the pre-change files and will drift as edits land; anchor on the quoted code, not the numbers.
