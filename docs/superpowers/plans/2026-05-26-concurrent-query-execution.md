# Concurrent Query Execution Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Allow multiple queries to run concurrently per editor tab, with dedup of identical re-runs, a multi-bar pulsing gutter, and a 3-state Stop button (run / cancel-one / open-popover).

**Architecture:** Replace `QueryTab`'s single in-flight tracker (`queryId` + `runningSegmentIndex` + `isExecuting`) with an ordered `[RunningQuery]` array. `pharos-core` is unchanged — it already supports concurrent queries keyed by `query_id`. Add a reusable `Toast` component, a 3-state Run/Stop button with numeric badge, and a `RunningQueriesPopoverVC` for the multi-query case.

**Tech Stack:** Swift 5 / AppKit, sqlx via Rust FFI (no Rust changes), XcodeGen (`project.yml`).

**Spec:** `docs/superpowers/specs/2026-05-26-concurrent-query-execution-design.md`

**Verification model:** No XCTest target in this project. After each task that touches Swift, build with `xcodebuild -scheme Pharos -configuration Debug build` from the repo root and confirm no errors. Behavior is verified by running the app (open `Pharos.xcodeproj` in Xcode, Cmd+R) and walking through the listed scenarios.

---

## File Structure

**Created:**
- `Pharos/Views/Toast.swift` — reusable transient toast
- `Pharos/ViewControllers/RunningQueriesPopoverVC.swift` — popover content for ≥2 in-flight queries

**Modified:**
- `Pharos/Models/QueryTab.swift` — `RunningQuery` struct, replace 3 fields with array + computed
- `Pharos/ViewControllers/ContentViewController.swift` — performQuery dedup + concurrent dispatch, completion/cancel paths, disconnect observer
- `Pharos/ViewControllers/EditorPaneVC.swift` — 3-state Run/Stop button + badge, popover trigger, per-id cancel delegate
- `Pharos/ViewControllers/QueryEditorVC.swift` — `setRunningSegmentIndices(Set<Int>)` passthrough
- `Pharos/Editor/LineNumberGutter.swift` — `runningSegmentIndices: Set<Int>` + per-index fade-out

**Regenerated:**
- `Pharos.xcodeproj` via `xcodegen generate` (whenever a new file is added)

---

## Task 1: Foundation — `RunningQuery` model + `QueryTab` refactor

This task migrates the data model and updates every call site in one pass. After this task, the app behaves the same as today *visually* (single pulsing bar, single Stop button), but concurrent execution is enabled silently — Cmd+Return while a query is running will launch a second one alongside (no dedup yet, no multi-bar yet).

**Files:**
- Modify: `Pharos/Models/QueryTab.swift`
- Modify: `Pharos/ViewControllers/ContentViewController.swift`
- Modify: `Pharos/ViewControllers/EditorPaneVC.swift`

- [ ] **Step 1.1: Add `RunningQuery` struct + replace fields in `QueryTab.swift`**

Open `Pharos/Models/QueryTab.swift`. Replace its full contents with:

```swift
import Foundation

/// Snapshot of the results grid view state for a tab.
struct ResultsGridState {
    var columnWidths: [String: CGFloat]
    var columnOrder: [String]?  // Column identifiers in display order (nil = default)
    var sortColumn: String?
    var sortAscending: Bool
    var columnFilters: [String: ColumnFilter]
    var scrollPosition: NSPoint
    var selectedRows: IndexSet
}

/// A single query currently executing for a tab. Multiple may be in flight
/// concurrently. `id` matches the `query_id` registered in pharos-core's
/// `running_queries` registry, so cancellation/lookup is symmetric across FFI.
struct RunningQuery: Identifiable, Equatable {
    let id: String
    let normalizedSQL: String       // trimmed + whitespace-collapsed, used for dedup
    let segmentIndex: Int           // -1 = direct-SQL (no parseable segment), >= 0 = segment
    let lineRange: ClosedRange<Int> // 1-based editor line range, for popover label
    let startTime: CFTimeInterval   // CACurrentMediaTime() at launch
}

/// Represents a single query editor tab.
struct QueryTab: Identifiable {
    let id: String
    var name: String
    var connectionId: String?
    var schemaName: String?
    var sql: String
    var cursorPosition: Int = 0
    var isDirty: Bool = false
    /// All in-flight queries launched from this tab, ordered by `startTime` ascending.
    var runningQueries: [RunningQuery] = []
    /// Computed: any in-flight query means this tab is executing.
    var isExecuting: Bool { !runningQueries.isEmpty }
    var result: QueryResult?
    var executeResult: ExecuteResult?
    var error: String?
    var savedQueryId: String?
    var historySchema: String?
    var historyTimestamp: String?
    var gridState: ResultsGridState?
    var paneId: String?
    /// Filesystem URL this tab was opened from, if any. Set when the tab is
    /// opened from a `.sql` or other plain-text file; ⌘S writes back here.
    var sourceURL: URL?

    init(id: String = UUID().uuidString, name: String = "Query 1", connectionId: String? = nil, schemaName: String? = nil, sql: String = "", paneId: String? = nil) {
        self.id = id
        self.name = name
        self.connectionId = connectionId
        self.schemaName = schemaName
        self.sql = sql
        self.paneId = paneId
    }
}
```

Notes:
- `isExecuting` is now a computed property — all existing readers of `tab.isExecuting` keep working.
- The old `queryId`, `runningSegmentIndex`, and stored `isExecuting` fields are gone. Every direct reader of them must be updated (Steps 1.2–1.6).
- Keep `import Foundation` (matches the original file).

- [ ] **Step 1.2: Update `ContentViewController.performQuery` launch site**

In `Pharos/ViewControllers/ContentViewController.swift`, find the block around line 935–948 that reads:

```swift
let queryId = UUID().uuidString
let color = createResultTab ? ResultTab.nextColor() : .clear
let startTime = CACurrentMediaTime()

stateManager.updateTab(id: tabId) { tab in
    tab.isExecuting = true
    tab.queryId = queryId
    tab.runningSegmentIndex = segmentIndex  // -1 for direct SQL, >= 0 for segment
    tab.error = nil
    if !createResultTab {
        tab.result = nil
        tab.executeResult = nil
    }
}
```

Replace with:

```swift
let queryId = UUID().uuidString
let color = createResultTab ? ResultTab.nextColor() : .clear
let startTime = CACurrentMediaTime()

let runningQuery = RunningQuery(
    id: queryId,
    normalizedSQL: Self.normalizeSQL(sql),
    segmentIndex: segmentIndex,
    lineRange: lineRange,
    startTime: startTime
)

stateManager.updateTab(id: tabId) { tab in
    tab.runningQueries.append(runningQuery)
    if !createResultTab {
        tab.error = nil
        tab.result = nil
        tab.executeResult = nil
    }
}
```

`Self.normalizeSQL` is added in Task 2. For now (Task 1), use the trimmed SQL as a placeholder:

```swift
let runningQuery = RunningQuery(
    id: queryId,
    normalizedSQL: sql.trimmingCharacters(in: .whitespacesAndNewlines),
    segmentIndex: segmentIndex,
    lineRange: lineRange,
    startTime: startTime
)
```

Task 2 swaps the placeholder for the real normalizer.

- [ ] **Step 1.3: Update `ContentViewController` SELECT completion path**

Find the SELECT-like completion block around line 962–981. The current code reads:

```swift
await MainActor.run {
    self.stateManager.updateTab(id: tabId) { tab in
        tab.isExecuting = false
        tab.queryId = nil
        tab.runningSegmentIndex = nil
        tab.result = result
    }
    if createResultTab { ... } else if self.stateManager.activeTabId == tabId { ... }
    ...
}
```

Change the `updateTab` block to:

```swift
self.stateManager.updateTab(id: tabId) { tab in
    tab.runningQueries.removeAll { $0.id == queryId }
    if !createResultTab {
        tab.result = result
    }
}
```

Note: `tab.result = result` should ONLY be set when this run populates inline state (`!createResultTab`). Today's code assigned it unconditionally; that was harmless when result-tab runs also wrote `tab.result` because there was only one in-flight query. With concurrent runs, a concurrent direct-SQL run could be clobbered. The result-tab path still gets the result via `addResultTab(rt)` below the `updateTab` block.

- [ ] **Step 1.4: Update `ContentViewController` statement-completion path**

Find the statement (non-SELECT) completion block around line 994–1000. Change:

```swift
self.stateManager.updateTab(id: tabId) { tab in
    tab.isExecuting = false
    tab.queryId = nil
    tab.runningSegmentIndex = nil
    tab.executeResult = result
}
```

To:

```swift
self.stateManager.updateTab(id: tabId) { tab in
    tab.runningQueries.removeAll { $0.id == queryId }
    if !createResultTab {
        tab.executeResult = result
    }
}
```

Same reasoning — keep inline `executeResult` only when the run populates inline.

- [ ] **Step 1.5: Update `ContentViewController` error path**

Find the catch block around line 1026–1031:

```swift
self.stateManager.updateTab(id: tabId) { tab in
    tab.isExecuting = false
    tab.queryId = nil
    tab.runningSegmentIndex = nil
    tab.error = message
}
```

Change to:

```swift
self.stateManager.updateTab(id: tabId) { tab in
    tab.runningQueries.removeAll { $0.id == queryId }
    if !createResultTab {
        tab.error = message
    }
}
```

If this is a result-tab run (`createResultTab == true`), the error is also surfaced via the result tab in the existing flow below. The inline `tab.error` is reserved for inline-result runs.

- [ ] **Step 1.6: Update `ContentViewController.cancelQuery()` (existing single-query path)**

Find the function around line 1343–1357:

```swift
func cancelQuery() {
    guard let tab = stateManager.activeTab,
          let connectionId = tab.connectionId,
          tab.isExecuting,
          let queryId = tab.queryId else { return }
    cancelledQueryIds.insert(queryId)
    Task {
        _ = try? await PharosCore.cancelQuery(connectionId: connectionId, queryId: queryId)
    }
}
```

Replace with a version that cancels the most-recently-launched query (preserves existing single-query Stop-button behavior until Task 7 adds per-id cancel):

```swift
func cancelQuery() {
    guard let tab = stateManager.activeTab,
          let connectionId = tab.connectionId,
          let queryId = tab.runningQueries.last?.id else { return }
    cancelledQueryIds.insert(queryId)
    Task {
        _ = try? await PharosCore.cancelQuery(connectionId: connectionId, queryId: queryId)
    }
}
```

- [ ] **Step 1.7: Update `EditorPaneVC` readers of the removed fields**

Find the two reads in `Pharos/ViewControllers/EditorPaneVC.swift` (lines 259 and 308):

```swift
editorVC.setRunningSegmentIndex(tab.isExecuting ? tab.runningSegmentIndex : nil)
```

Replace both with:

```swift
editorVC.setRunningSegmentIndex(tab.runningQueries.first?.segmentIndex)
```

This temporarily shows only the first running segment in the gutter when multiple are in flight. Task 6 replaces this with the Set-based multi-bar API. `tab.isExecuting` is no longer needed as a guard because the optional handles "nothing running" via `nil`.

- [ ] **Step 1.8: Build and verify compile**

Run from repo root:

```bash
xcodebuild -scheme Pharos -configuration Debug -quiet build
```

Expected: `** BUILD SUCCEEDED **`. If any read of `tab.queryId`, `tab.runningSegmentIndex`, or `tab.isExecuting = …` (assignment) remains, fix it. To find any stragglers:

```bash
grep -rn "tab\.queryId\b\|tab\.runningSegmentIndex\|tab\.isExecuting\s*=" Pharos/
```

Expected: no matches.

- [ ] **Step 1.9: Manual smoke test**

Open `Pharos.xcodeproj` in Xcode, Cmd+R. Connect to a Postgres DB, run a simple `SELECT 1;`. Confirm:
- Result appears.
- Run button returns to play state after completion.
- Gutter bar pulses while running, stops after.

If the smoke test passes, the refactor is sound.

- [ ] **Step 1.10: Commit**

```bash
git add Pharos/Models/QueryTab.swift Pharos/ViewControllers/ContentViewController.swift Pharos/ViewControllers/EditorPaneVC.swift
git commit -m "$(cat <<'EOF'
refactor: migrate QueryTab to multi-query runningQueries array

Replace single-query fields (queryId, runningSegmentIndex, isExecuting
storage) with an ordered [RunningQuery] array and a computed
isExecuting. Update launch, three completion paths, and the existing
cancelQuery() (now cancels the most recent in-flight query) to use the
new model. EditorPaneVC gutter wiring temporarily reads first-running
until Task 6 adds the Set-based multi-bar API. Concurrent execution is
enabled as a side effect; visual affordances follow in subsequent tasks.
EOF
)"
```

---

## Task 2: SQL normalization + elapsed formatting helpers

Two small static helpers used by dedup logic (Task 4) and the popover (Task 8).

**Files:**
- Modify: `Pharos/ViewControllers/ContentViewController.swift`

- [ ] **Step 2.1: Add `normalizeSQL` and `formatElapsed` static helpers**

In `ContentViewController.swift`, find the existing static helper section (around `isSelectLikeSQL` / `stripLeadingComments`, near line 1073). Add:

```swift
/// Trim leading/trailing whitespace and collapse internal whitespace runs to
/// a single space. Comments and string-literal contents are NOT stripped —
/// they participate in the equality check so `SELECT 1 -- v2` does not match
/// `SELECT 1`.
static func normalizeSQL(_ sql: String) -> String {
    let trimmed = sql.trimmingCharacters(in: .whitespacesAndNewlines)
    var result = ""
    result.reserveCapacity(trimmed.count)
    var lastWasWhitespace = false
    for ch in trimmed {
        if ch.isWhitespace {
            if !lastWasWhitespace {
                result.append(" ")
                lastWasWhitespace = true
            }
        } else {
            result.append(ch)
            lastWasWhitespace = false
        }
    }
    return result
}

/// Format an elapsed-time interval as `M:SS` (e.g. "0:08", "1:23", "12:34").
static func formatElapsed(_ seconds: CFTimeInterval) -> String {
    let total = max(0, Int(seconds))
    let mins = total / 60
    let secs = total % 60
    return String(format: "%d:%02d", mins, secs)
}
```

- [ ] **Step 2.2: Swap the placeholder normalizer in `performQuery`**

In the block edited in Step 1.2, change:

```swift
normalizedSQL: sql.trimmingCharacters(in: .whitespacesAndNewlines),
```

To:

```swift
normalizedSQL: Self.normalizeSQL(sql),
```

- [ ] **Step 2.3: Build**

```bash
xcodebuild -scheme Pharos -configuration Debug -quiet build
```

Expected: `** BUILD SUCCEEDED **`.

- [ ] **Step 2.4: Commit**

```bash
git add Pharos/ViewControllers/ContentViewController.swift
git commit -m "feat: add normalizeSQL and formatElapsed static helpers"
```

---

## Task 3: Toast component

Self-contained reusable transient toast. No call sites added yet.

**Files:**
- Create: `Pharos/Views/Toast.swift`

- [ ] **Step 3.1: Create `Toast.swift`**

Create `Pharos/Views/Toast.swift` with:

```swift
import AppKit

/// Styling categories for `Toast.show`. Drives the leading-stripe color and icon.
enum ToastStyle {
    case info, success, warning, error

    var color: NSColor {
        switch self {
        case .info:    return .controlAccentColor
        case .success: return .systemGreen
        case .warning: return .systemOrange
        case .error:   return .systemRed
        }
    }

    var symbolName: String {
        switch self {
        case .info:    return "info.circle.fill"
        case .success: return "checkmark.circle.fill"
        case .warning: return "exclamationmark.triangle.fill"
        case .error:   return "xmark.octagon.fill"
        }
    }
}

/// Self-managed transient notification. Each call adds one toast view to the
/// host's view tree, fades it in/out, and removes it. Multiple concurrent
/// toasts stack upward from the bottom-center of the host.
enum Toast {

    static func show(in host: NSView,
                     message: String,
                     style: ToastStyle = .info,
                     duration: TimeInterval = 2.0) {
        let toast = ToastView(message: message, style: style)
        toast.translatesAutoresizingMaskIntoConstraints = false
        host.addSubview(toast)

        // Stack offset: count existing ToastView siblings already in host.
        let siblingCount = host.subviews.filter { $0 is ToastView && $0 !== toast }.count
        let bottomInset: CGFloat = 12 + CGFloat(siblingCount) * (toast.intrinsicContentSize.height + 6)

        NSLayoutConstraint.activate([
            toast.centerXAnchor.constraint(equalTo: host.centerXAnchor),
            toast.bottomAnchor.constraint(equalTo: host.bottomAnchor, constant: -bottomInset),
        ])

        toast.alphaValue = 0
        NSAnimationContext.runAnimationGroup({ ctx in
            ctx.duration = 0.15
            toast.animator().alphaValue = 1.0
        })

        DispatchQueue.main.asyncAfter(deadline: .now() + duration) {
            NSAnimationContext.runAnimationGroup({ ctx in
                ctx.duration = 0.25
                toast.animator().alphaValue = 0
            }, completionHandler: {
                toast.removeFromSuperview()
            })
        }
    }
}

/// Visual view used by `Toast.show`. Outside callers should use `Toast.show`.
final class ToastView: NSVisualEffectView {

    private let style: ToastStyle

    init(message: String, style: ToastStyle) {
        self.style = style
        super.init(frame: .zero)
        self.material = .hudWindow
        self.state = .active
        self.blendingMode = .withinWindow
        self.wantsLayer = true
        self.layer?.cornerRadius = 8
        self.layer?.masksToBounds = true

        let stripe = NSView()
        stripe.translatesAutoresizingMaskIntoConstraints = false
        stripe.wantsLayer = true
        stripe.layer?.backgroundColor = style.color.cgColor
        addSubview(stripe)

        let icon = NSImageView()
        icon.translatesAutoresizingMaskIntoConstraints = false
        let config = NSImage.SymbolConfiguration(pointSize: 13, weight: .medium)
        icon.image = NSImage(systemSymbolName: style.symbolName, accessibilityDescription: nil)?
            .withSymbolConfiguration(config)
        icon.contentTintColor = style.color
        addSubview(icon)

        let label = NSTextField(labelWithString: message)
        label.translatesAutoresizingMaskIntoConstraints = false
        label.font = .systemFont(ofSize: 12)
        label.lineBreakMode = .byTruncatingTail
        label.maximumNumberOfLines = 1
        addSubview(label)

        NSLayoutConstraint.activate([
            stripe.leadingAnchor.constraint(equalTo: leadingAnchor),
            stripe.topAnchor.constraint(equalTo: topAnchor),
            stripe.bottomAnchor.constraint(equalTo: bottomAnchor),
            stripe.widthAnchor.constraint(equalToConstant: 3),

            icon.leadingAnchor.constraint(equalTo: stripe.trailingAnchor, constant: 10),
            icon.centerYAnchor.constraint(equalTo: centerYAnchor),
            icon.widthAnchor.constraint(equalToConstant: 16),
            icon.heightAnchor.constraint(equalToConstant: 16),

            label.leadingAnchor.constraint(equalTo: icon.trailingAnchor, constant: 8),
            label.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -12),
            label.centerYAnchor.constraint(equalTo: centerYAnchor),

            heightAnchor.constraint(equalToConstant: 32),
            widthAnchor.constraint(greaterThanOrEqualToConstant: 200),
            widthAnchor.constraint(lessThanOrEqualToConstant: 520),
        ])
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) not used") }
}
```

- [ ] **Step 3.2: Regenerate the Xcode project**

```bash
cd /Users/nfinn/Projects/aSideProjects/Pharos && xcodegen generate
```

Expected: regeneration completes without errors, picks up the new file under `Pharos/Views/`.

- [ ] **Step 3.3: Build**

```bash
xcodebuild -scheme Pharos -configuration Debug -quiet build
```

Expected: `** BUILD SUCCEEDED **`.

- [ ] **Step 3.4: Commit**

```bash
git add Pharos/Views/Toast.swift Pharos.xcodeproj
git commit -m "feat: add reusable Toast notification component"
```

---

## Task 4: Dedup logic + toast trigger

Plug dedup into `performQuery`. On a normalized-SQL match against an in-flight query, show a toast and return early without launching.

**Files:**
- Modify: `Pharos/ViewControllers/ContentViewController.swift`

- [ ] **Step 4.1: Add the dedup check above the launch block**

In `performQuery`, find the section added in Task 1 (Step 1.2) that begins `let queryId = UUID().uuidString`. Just *above* that line, insert:

```swift
let normalized = Self.normalizeSQL(sql)

// Dedup: re-running the same SQL while it's in flight is a no-op (with toast).
if let existing = activeTab.runningQueries.first(where: { $0.normalizedSQL == normalized }) {
    let elapsed = Self.formatElapsed(CACurrentMediaTime() - existing.startTime)
    Toast.show(
        in: self.view,
        message: "Already running — lines \(existing.lineRange.lowerBound)–\(existing.lineRange.upperBound) (\(elapsed))",
        style: .info,
        duration: 2.0
    )
    return
}
```

Then, change the `RunningQuery` construction below to reuse the `normalized` constant:

```swift
let runningQuery = RunningQuery(
    id: queryId,
    normalizedSQL: normalized,
    segmentIndex: segmentIndex,
    lineRange: lineRange,
    startTime: startTime
)
```

- [ ] **Step 4.2: Build**

```bash
xcodebuild -scheme Pharos -configuration Debug -quiet build
```

Expected: `** BUILD SUCCEEDED **`.

- [ ] **Step 4.3: Manual test — same-SQL dedup**

In Xcode, Cmd+R. Connect to Postgres. Open a tab and type:

```sql
SELECT pg_sleep(3), 'A' AS marker;
```

Cmd+Return to launch. While it's running, hit Cmd+Return again. Expected:
- Toast appears at the bottom-center of the content view: "Already running — lines 1–1 (0:0X)"
- Only one query completes (after ~3s); no duplicate result tab.

Then hit Cmd+Return a third time *after* completion. Expected: a new run launches normally, toast does not appear.

- [ ] **Step 4.4: Manual test — different SQL runs concurrently**

In the same tab, edit to:

```sql
SELECT pg_sleep(3), 'A' AS marker;

SELECT pg_sleep(1), 'B' AS marker;
```

Place the cursor in the first statement, Cmd+Return. Immediately move the cursor to the second statement and Cmd+Return. Expected:
- Two queries run concurrently.
- Two result tabs appear, in completion order (B first since it's faster).
- No toast.

- [ ] **Step 4.5: Commit**

```bash
git add Pharos/ViewControllers/ContentViewController.swift
git commit -m "feat: dedup identical re-runs with a toast"
```

---

## Task 5: Direct-SQL inline-result routing rule

If a direct-SQL run is fired while another direct-SQL run is already in flight, route the new one to a result tab to prevent `tab.result` clobbering. Segment runs always write to result tabs (existing behavior), so segment ↔ segment and segment ↔ direct-SQL combinations need no special handling.

**Files:**
- Modify: `Pharos/ViewControllers/ContentViewController.swift`

- [ ] **Step 5.1: Add the routing rule**

In `performQuery`, immediately after the dedup check from Step 4.1 and before the launch block, insert:

```swift
// Direct-SQL inline-result protection: if another direct-SQL run is already
// in flight, route this one to a result tab so the two completions don't
// race to overwrite tab.result.
var effectiveCreateResultTab = createResultTab
if segmentIndex == -1,
   activeTab.runningQueries.contains(where: { $0.segmentIndex == -1 }) {
    effectiveCreateResultTab = true
}
```

Then, replace every subsequent reference to `createResultTab` *within the rest of this function body* with `effectiveCreateResultTab`. To find them:

```bash
grep -n "createResultTab" Pharos/ViewControllers/ContentViewController.swift
```

Inside `performQuery` (which spans roughly lines 919–1052), replace each usage. Outside of `performQuery`, leave `createResultTab` alone — it's a parameter name in other functions or a struct field.

The relevant in-function reads are at the launch `if !createResultTab` block, the SELECT-completion `if createResultTab` / `else` branch, the statement-completion equivalent, and the error path. Replace all of them.

- [ ] **Step 5.2: Build**

```bash
xcodebuild -scheme Pharos -configuration Debug -quiet build
```

Expected: `** BUILD SUCCEEDED **`.

- [ ] **Step 5.3: Manual test**

This case is rare (only triggers when SQL has no parseable segments). To force it, paste a single statement without a trailing semicolon and ensure it's the entire editor content. Connect to Postgres. Type:

```
SELECT pg_sleep(3), 'A' AS marker
```

No semicolon, single line. Cmd+Return — confirm the inline result panel updates after 3s.

Then while it's running, change the SQL to:

```
SELECT pg_sleep(1), 'B' AS marker
```

Cmd+Return. Expected: a NEW result tab appears with the B result (since `tab.result` is in use by the first direct-SQL run). When the first completes, its result lands in the inline panel.

If this case is hard to reproduce in your DB, mark this step as verified-by-inspection — the rule is small and contained.

- [ ] **Step 5.4: Commit**

```bash
git add Pharos/ViewControllers/ContentViewController.swift
git commit -m "feat: route concurrent direct-SQL runs to result tabs"
```

---

## Task 6: Multi-bar gutter pulse

Replace `runningSegmentIndex: Int?` with `runningSegmentIndices: Set<Int>` and per-index fade-out states. All running bars pulse in unison.

**Files:**
- Modify: `Pharos/Editor/LineNumberGutter.swift`
- Modify: `Pharos/ViewControllers/QueryEditorVC.swift`
- Modify: `Pharos/ViewControllers/EditorPaneVC.swift`

- [ ] **Step 6.1: Read the gutter file to confirm current shape**

```bash
grep -n "runningSegmentIndex\|fadeOutUntil\|fadeStartAlpha\|pulseValue\|fadeOutDuration\|startPulse\|stopPulse" Pharos/Editor/LineNumberGutter.swift
```

Note the exact line ranges of the affected fields and methods. Three field declarations need replacement: `runningSegmentIndex: Int?`, `fadeOutUntil: CFTimeInterval?`, `fadeStartAlpha: CGFloat`. The function `setRunningSegmentIndex(_ index: Int?)` needs replacement. The `draw(_:)` method needs the per-bar color selection logic updated.

- [ ] **Step 6.2: Replace the fields**

In `Pharos/Editor/LineNumberGutter.swift`, find:

```swift
private var runningSegmentIndex: Int?
```

(around line 62), and the nearby `fadeOutUntil` / `fadeStartAlpha` declarations. Replace those three lines with:

```swift
private var runningSegmentIndices: Set<Int> = []   // includes -1 for phantom/direct-SQL
private var fadeOutStates: [Int: FadeState] = [:]  // keyed by segment index

private struct FadeState {
    let startAlpha: CGFloat
    let endTime: CFTimeInterval
}
```

- [ ] **Step 6.3: Replace `setRunningSegmentIndex` with `setRunningSegmentIndices`**

Find:

```swift
func setRunningSegmentIndex(_ index: Int?) {
    guard runningSegmentIndex != index else { return }
    ...
    runningSegmentIndex = index
    ...
}
```

Replace the entire function body with:

```swift
func setRunningSegmentIndices(_ indices: Set<Int>) {
    let removed = runningSegmentIndices.subtracting(indices)
    for idx in removed {
        fadeOutStates[idx] = FadeState(
            startAlpha: 0.55 + 0.45 * pulseValue,
            endTime: CACurrentMediaTime() + fadeOutDuration
        )
    }
    runningSegmentIndices = indices
    if !indices.isEmpty {
        startPulse()
    } else if fadeOutStates.isEmpty {
        stopPulse()
    }
    needsDisplay = true
}
```

Use the same `startPulse()` / `stopPulse()` symbols the old function called. If their names differ in your file, mirror what the old `setRunningSegmentIndex` used.

- [ ] **Step 6.4: Update the per-bar draw color selection**

In `draw(_:)`, find the segment-bar color block around line 596–606 that currently begins:

```swift
let barColor: NSColor
if pulseActiveIndex == segIdx, segIdx >= 0 {
    barColor = NSColor.controlAccentColor.withAlphaComponent(pulseEffectAlpha)
} else if let resultColor = segmentColors[segIdx] {
    ...
```

Replace the entire `let barColor: NSColor = ...` selection (up through the `}` that closes the else-chain) with:

```swift
let barColor: NSColor
if runningSegmentIndices.contains(segIdx) {
    barColor = NSColor.controlAccentColor.withAlphaComponent(0.55 + 0.45 * pulseValue)
} else if let fade = fadeOutStates[segIdx] {
    let remaining = fade.endTime - now
    if remaining > 0 {
        let progress = CGFloat(1.0 - (remaining / fadeOutDuration))
        barColor = NSColor.controlAccentColor.withAlphaComponent(fade.startAlpha * (1.0 - progress))
    } else {
        fadeOutStates.removeValue(forKey: segIdx)
        barColor = defaultBarColor(for: segIdx)
    }
} else {
    barColor = defaultBarColor(for: segIdx)
}
```

Then extract the existing default-color selection into a helper. After the `draw(_:)` method, add:

```swift
/// Existing fallback bar color: result-tab color first, then active-segment
/// highlight, then the tertiary idle color. Extracted from `draw(_:)` so the
/// running / fade-out / default branches can share it.
private func defaultBarColor(for segIdx: Int) -> NSColor {
    if let resultColor = segmentColors[segIdx] {
        return resultColor
    } else if segIdx == activeSegmentIndex {
        return NSColor.controlAccentColor
    } else {
        return NSColor.tertiaryLabelColor.withAlphaComponent(0.35)
    }
}
```

Also remove the now-dead `pulseActiveIndex` / `pulseEffectAlpha` local computation at the top of the draw block (the closure around line 562–580 that computed them) — those came from the single-index path and are no longer needed.

- [ ] **Step 6.5: Update the phantom-pulse path**

Find the block around line 617–625 that begins `if runningSegmentIndex == -1, lineYPositions.count >= 1 {`. Replace with:

```swift
// Phantom pulse for direct-SQL execution (segmentIndex == -1).
if runningSegmentIndices.contains(-1), lineYPositions.count >= 1 {
    let top = lineYPositions.first!.y + 2
    let bottomEntry = lineYPositions.last!
    let bottom = bottomEntry.y + bottomEntry.height - 2
    let phantomRect = NSRect(x: barX, y: top, width: segmentBarWidth, height: max(bottom - top, 4))
    NSColor.controlAccentColor.withAlphaComponent(0.55 + 0.45 * pulseValue).setFill()
    NSBezierPath(roundedRect: phantomRect, xRadius: 2, yRadius: 2).fill()
} else if let fade = fadeOutStates[-1], lineYPositions.count >= 1 {
    let remaining = fade.endTime - now
    if remaining > 0 {
        let top = lineYPositions.first!.y + 2
        let bottomEntry = lineYPositions.last!
        let bottom = bottomEntry.y + bottomEntry.height - 2
        let phantomRect = NSRect(x: barX, y: top, width: segmentBarWidth, height: max(bottom - top, 4))
        let progress = CGFloat(1.0 - (remaining / fadeOutDuration))
        NSColor.controlAccentColor.withAlphaComponent(fade.startAlpha * (1.0 - progress)).setFill()
        NSBezierPath(roundedRect: phantomRect, xRadius: 2, yRadius: 2).fill()
    } else {
        fadeOutStates.removeValue(forKey: -1)
    }
}
```

- [ ] **Step 6.6: Update the redraw-driver block**

The existing fade-out redraw-driver at the bottom of `draw(_:)` (around line 627–635) reads `fadeOutUntil`. Replace it with one driven by any non-empty `fadeOutStates`:

```swift
// Drive fade-out redraws. Pulse subscription stops in setRunningSegmentIndices
// when indices clears; fade-out redraws keep ticking until all fades expire.
if !fadeOutStates.isEmpty {
    DispatchQueue.main.async { [weak self] in self?.needsDisplay = true }
}
```

- [ ] **Step 6.7: Clear orphan fade-out entries when segments are replaced**

Find where `setSegments` (or whatever function in this file replaces the `segments` array) is implemented. Add at the end of that function (after assigning the new segments array):

```swift
// Drop orphan fade-out entries that no longer correspond to a real segment.
let validIndices = Set(segments.indices) .union([-1])
fadeOutStates = fadeOutStates.filter { validIndices.contains($0.key) }
```

If you can't find a `setSegments`, search:

```bash
grep -n "segments\s*=\s*\|var segments" Pharos/Editor/LineNumberGutter.swift
```

Add the filter wherever `segments` is reassigned externally.

- [ ] **Step 6.8: Update `QueryEditorVC` passthrough**

In `Pharos/ViewControllers/QueryEditorVC.swift`, find the function around line 299:

```swift
func setRunningSegmentIndex(_ index: Int?) {
    gutter?.setRunningSegmentIndex(index)
}
```

Replace with:

```swift
func setRunningSegmentIndices(_ indices: Set<Int>) {
    gutter?.setRunningSegmentIndices(indices)
}
```

- [ ] **Step 6.9: Update `EditorPaneVC` callers**

In `Pharos/ViewControllers/EditorPaneVC.swift`, find the two lines that read (after Task 1.7):

```swift
editorVC.setRunningSegmentIndex(tab.runningQueries.first?.segmentIndex)
```

(lines around 259 and 308). Replace both with:

```swift
editorVC.setRunningSegmentIndices(Set(tab.runningQueries.map { $0.segmentIndex }))
```

Also find the line around 256 that reads:

```swift
editorVC.setRunningSegmentIndex(nil)
```

(if present — it's typically called when clearing the editor). Replace with:

```swift
editorVC.setRunningSegmentIndices([])
```

- [ ] **Step 6.10: Build**

```bash
xcodebuild -scheme Pharos -configuration Debug -quiet build
```

Expected: `** BUILD SUCCEEDED **`. If any compile errors mention `setRunningSegmentIndex`, hunt down stragglers:

```bash
grep -rn "setRunningSegmentIndex\b\|runningSegmentIndex\b\|fadeOutUntil\|fadeStartAlpha" Pharos/
```

Expected: no matches anywhere (all migrated to the new names).

- [ ] **Step 6.11: Manual test**

Open the app. In one editor tab, create:

```sql
SELECT pg_sleep(4), 'A' AS marker;

SELECT pg_sleep(2), 'B' AS marker;

SELECT pg_sleep(3), 'C' AS marker;
```

Run all three quickly (place cursor in each, Cmd+Return). Expected:
- All three segment bars pulse in unison (same phase) while running.
- Each bar individually fades out as its query completes.
- After all complete, gutter returns to idle.

- [ ] **Step 6.12: Commit**

```bash
git add Pharos/Editor/LineNumberGutter.swift Pharos/ViewControllers/QueryEditorVC.swift Pharos/ViewControllers/EditorPaneVC.swift
git commit -m "feat: multi-bar gutter pulse for concurrent queries"
```

---

## Task 7: 3-state Stop button + per-id cancel delegate + badge

Run/Stop button morphs based on `runningQueries.count`. Delegate gains a per-id cancel method. The "open popover" path is stubbed with a print until Task 8 builds the popover.

**Files:**
- Modify: `Pharos/ViewControllers/EditorPaneVC.swift`
- Modify: `Pharos/ViewControllers/ContentViewController.swift`

- [ ] **Step 7.1: Update the `EditorPaneDelegate` protocol**

In `Pharos/ViewControllers/EditorPaneVC.swift`, find the `EditorPaneDelegate` protocol (around line 13). Remove this line:

```swift
func editorPaneDidRequestCancelQuery(_ pane: EditorPaneVC)
```

Add in its place:

```swift
func editorPane(_ pane: EditorPaneVC, didRequestCancelQueryId queryId: String)
```

- [ ] **Step 7.2: Add a badge layer to `EditorPaneVC`**

In `EditorPaneVC.swift`, in the class's property declarations (near the top), add:

```swift
private let badgeLayer = CATextLayer()
```

In the function that builds the toolbar (find `setupEditorToolbar` or the place where `runStopButton.image = NSImage(systemSymbolName: "play.fill", ...)` first appears, around line 388), after `runStopButton` is configured, add:

```swift
// Badge for ≥2 running queries. Hidden by default.
badgeLayer.frame = CGRect(x: 16, y: 16, width: 14, height: 14)
badgeLayer.cornerRadius = 7
badgeLayer.masksToBounds = true
badgeLayer.backgroundColor = NSColor.systemRed.cgColor
badgeLayer.foregroundColor = NSColor.white.cgColor
badgeLayer.alignmentMode = .center
badgeLayer.fontSize = 9
badgeLayer.font = NSFont.boldSystemFont(ofSize: 9)
badgeLayer.contentsScale = NSScreen.main?.backingScaleFactor ?? 2.0
badgeLayer.isHidden = true
runStopButton.wantsLayer = true
runStopButton.layer?.addSublayer(badgeLayer)
```

- [ ] **Step 7.3: Replace `updateEditorToolbarState`**

Find the function around line 514–531. Replace the body's Run/Stop section with:

```swift
private func updateEditorToolbarState() {
    guard let pane = stateManager.panes.first(where: { $0.id == paneId }) else { return }
    let activeTab = stateManager.tabs.first { $0.id == pane.activeTabId }
    let count = activeTab?.runningQueries.count ?? 0

    let config = NSImage.SymbolConfiguration(pointSize: 13, weight: .medium)
    switch count {
    case 0:
        runStopButton.image = NSImage(systemSymbolName: "play.fill", accessibilityDescription: "Run Query")?.withSymbolConfiguration(config)
        runStopButton.toolTip = "Run Query (Cmd+Return)"
        runStopButton.contentTintColor = .controlAccentColor
        badgeLayer.isHidden = true
    case 1:
        runStopButton.image = NSImage(systemSymbolName: "stop.fill", accessibilityDescription: "Stop Query")?.withSymbolConfiguration(config)
        runStopButton.toolTip = "Stop Query"
        runStopButton.contentTintColor = .systemRed
        badgeLayer.isHidden = true
    default:
        runStopButton.image = NSImage(systemSymbolName: "stop.fill", accessibilityDescription: "Stop Queries")?.withSymbolConfiguration(config)
        runStopButton.toolTip = "\(count) queries running — click to manage"
        runStopButton.contentTintColor = .systemRed
        badgeLayer.string = "\(count)"
        badgeLayer.isHidden = false
    }

    // Save dropdown logic unchanged from the original function — preserve it:
    let canSaveInPlace = activeTab?.savedQueryId != nil || activeTab?.sourceURL != nil
    if let saveItem = saveDropdown.menu?.item(at: 1) {
        saveItem.isEnabled = canSaveInPlace
    }
}
```

Also remove the now-unused `private var isExecuting = false` field (around line 34) and any other place that referenced it locally.

- [ ] **Step 7.4: Replace `runStopTapped`**

Find around line 494:

```swift
@objc private func runStopTapped() {
    if isExecuting {
        delegate?.editorPaneDidRequestCancelQuery(self)
    } else {
        delegate?.editorPaneDidRequestRunQuery(self)
    }
}
```

Replace with:

```swift
@objc private func runStopTapped() {
    let running = activeTab?.runningQueries ?? []
    switch running.count {
    case 0:
        delegate?.editorPaneDidRequestRunQuery(self)
    case 1:
        delegate?.editorPane(self, didRequestCancelQueryId: running[0].id)
    default:
        showRunningQueriesPopover(running)
    }
}

private var activeTab: QueryTab? {
    guard let pane = stateManager.panes.first(where: { $0.id == paneId }) else { return nil }
    return stateManager.tabs.first { $0.id == pane.activeTabId }
}

private func showRunningQueriesPopover(_ queries: [RunningQuery]) {
    // Stub — Task 8 wires up the real popover.
    NSLog("Pharos: would open running-queries popover for \(queries.count) queries")
}
```

If a property or computed accessor named `activeTab` already exists in the class, don't add it again — reuse the existing one. Search first:

```bash
grep -n "activeTab" Pharos/ViewControllers/EditorPaneVC.swift
```

- [ ] **Step 7.5: Add per-id `cancelQuery(id:)` to `ContentViewController`**

In `Pharos/ViewControllers/ContentViewController.swift`, find the existing `cancelQuery()` function (around line 1343–1357). Just below it, add an overload:

```swift
/// Cancel a specific in-flight query in the active tab by `id`.
func cancelQuery(id: String) {
    guard let tab = stateManager.activeTab,
          let connectionId = tab.connectionId,
          tab.runningQueries.contains(where: { $0.id == id }) else { return }
    cancelledQueryIds.insert(id)
    Task {
        _ = try? await PharosCore.cancelQuery(connectionId: connectionId, queryId: id)
    }
}
```

The completion handler for the cancelled query will hit the error path and remove the entry from `runningQueries` (already wired in Task 1.5).

- [ ] **Step 7.6: Update `ContentViewController`'s `EditorPaneDelegate` conformance**

Find the existing extension around line 1404:

```swift
func editorPaneDidRequestCancelQuery(_ pane: EditorPaneVC) {
    cancelQuery()
}
```

Replace with:

```swift
func editorPane(_ pane: EditorPaneVC, didRequestCancelQueryId queryId: String) {
    cancelQuery(id: queryId)
}
```

- [ ] **Step 7.7: Build**

```bash
xcodebuild -scheme Pharos -configuration Debug -quiet build
```

Expected: `** BUILD SUCCEEDED **`. If any reference to `editorPaneDidRequestCancelQuery` (without the `id:` label) remains:

```bash
grep -rn "editorPaneDidRequestCancelQuery" Pharos/
```

Expected: no matches.

- [ ] **Step 7.8: Manual test**

Open the app. With one query running, confirm:
- Run button morphs to red `stop.fill`, no badge.
- Click cancels that single query (gutter pulse stops, button returns to play).

With two queries running, confirm:
- Run button shows red `stop.fill` with a "2" badge in the top-right corner.
- Click prints to the Xcode console: `Pharos: would open running-queries popover for 2 queries`.
- Tooltip reads "2 queries running — click to manage".

- [ ] **Step 7.9: Commit**

```bash
git add Pharos/ViewControllers/EditorPaneVC.swift Pharos/ViewControllers/ContentViewController.swift
git commit -m "feat: 3-state Run/Stop button with badge and per-id cancel delegate"
```

---

## Task 8: `RunningQueriesPopoverVC`

Replace the popover stub with a real `NSPopover` listing each in-flight query with line range, elapsed time, and a per-row cancel button.

**Files:**
- Create: `Pharos/ViewControllers/RunningQueriesPopoverVC.swift`
- Modify: `Pharos/ViewControllers/EditorPaneVC.swift`

- [ ] **Step 8.1: Create `RunningQueriesPopoverVC.swift`**

Create `Pharos/ViewControllers/RunningQueriesPopoverVC.swift`:

```swift
import AppKit
import Combine

/// Delegate for popover row actions. The owning `EditorPaneVC` forwards
/// cancel requests to its own delegate so the `ContentViewController`
/// stays the single owner of cancellation logic.
protocol RunningQueriesPopoverDelegate: AnyObject {
    func runningQueriesPopover(_ vc: RunningQueriesPopoverVC, didRequestCancelQueryId id: String)
}

/// Popover content showing one row per in-flight query for a tab.
final class RunningQueriesPopoverVC: NSViewController {

    weak var delegate: RunningQueriesPopoverDelegate?

    private let stateManager: AppStateManager
    private let tabId: String
    private var subscription: AnyCancellable?
    private var elapsedTimer: Timer?

    private let headerLabel = NSTextField(labelWithString: "")
    private let stackView = NSStackView()
    private var rowsById: [String: RunningQueryRow] = [:]
    private var orderedIds: [String] = []

    init(stateManager: AppStateManager, tabId: String) {
        self.stateManager = stateManager
        self.tabId = tabId
        super.init(nibName: nil, bundle: nil)
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) not used") }

    override func loadView() {
        let root = NSView()
        root.translatesAutoresizingMaskIntoConstraints = false

        headerLabel.font = .systemFont(ofSize: 11, weight: .semibold)
        headerLabel.textColor = .secondaryLabelColor
        headerLabel.translatesAutoresizingMaskIntoConstraints = false

        stackView.orientation = .vertical
        stackView.spacing = 4
        stackView.alignment = .leading
        stackView.translatesAutoresizingMaskIntoConstraints = false

        root.addSubview(headerLabel)
        root.addSubview(stackView)

        NSLayoutConstraint.activate([
            headerLabel.topAnchor.constraint(equalTo: root.topAnchor, constant: 8),
            headerLabel.leadingAnchor.constraint(equalTo: root.leadingAnchor, constant: 12),
            headerLabel.trailingAnchor.constraint(lessThanOrEqualTo: root.trailingAnchor, constant: -12),

            stackView.topAnchor.constraint(equalTo: headerLabel.bottomAnchor, constant: 6),
            stackView.leadingAnchor.constraint(equalTo: root.leadingAnchor, constant: 12),
            stackView.trailingAnchor.constraint(equalTo: root.trailingAnchor, constant: -12),
            stackView.bottomAnchor.constraint(equalTo: root.bottomAnchor, constant: -8),

            root.widthAnchor.constraint(equalToConstant: 260),
        ])

        self.view = root
    }

    override func viewWillAppear() {
        super.viewWillAppear()
        reconcileRows()
        startElapsedTimer()
        subscription = stateManager.$tabs
            .receive(on: DispatchQueue.main)
            .sink { [weak self] _ in self?.reconcileRows() }
    }

    override func viewWillDisappear() {
        super.viewWillDisappear()
        subscription?.cancel()
        subscription = nil
        elapsedTimer?.invalidate()
        elapsedTimer = nil
    }

    private func startElapsedTimer() {
        elapsedTimer?.invalidate()
        let timer = Timer(timeInterval: 1.0, repeats: true) { [weak self] _ in
            self?.tickElapsed()
        }
        RunLoop.main.add(timer, forMode: .common)
        elapsedTimer = timer
    }

    private func tickElapsed() {
        guard let tab = stateManager.tabs.first(where: { $0.id == tabId }) else { return }
        let now = CACurrentMediaTime()
        for q in tab.runningQueries {
            rowsById[q.id]?.setElapsed(ContentViewController.formatElapsed(now - q.startTime))
        }
    }

    private func reconcileRows() {
        guard let tab = stateManager.tabs.first(where: { $0.id == tabId }) else {
            dismissPopover()
            return
        }
        let queries = tab.runningQueries.sorted { $0.startTime < $1.startTime }

        // Auto-dismiss when only one (or none) remains — the toolbar button
        // takes over again for 0/1.
        if queries.count <= 1 {
            dismissPopover()
            return
        }

        headerLabel.stringValue = "\(queries.count) queries running"

        let now = CACurrentMediaTime()
        let presentIds = Set(queries.map { $0.id })

        // Remove rows for queries no longer running.
        for id in orderedIds where !presentIds.contains(id) {
            if let row = rowsById.removeValue(forKey: id) {
                stackView.removeArrangedSubview(row)
                row.removeFromSuperview()
            }
        }
        orderedIds.removeAll { !presentIds.contains($0) }

        // Add rows for new queries, in startTime order.
        for q in queries where rowsById[q.id] == nil {
            let row = RunningQueryRow(query: q,
                                      elapsed: ContentViewController.formatElapsed(now - q.startTime)) { [weak self] id in
                guard let self else { return }
                self.delegate?.runningQueriesPopover(self, didRequestCancelQueryId: id)
            }
            rowsById[q.id] = row
            stackView.addArrangedSubview(row)
            orderedIds.append(q.id)
        }
    }

    private func dismissPopover() {
        self.view.window?.close()
    }
}

/// Single popover row: "Lines X–Y" left, "M:SS" right, cancel button trailing.
private final class RunningQueryRow: NSView {

    private let queryId: String
    private let onCancel: (String) -> Void
    private let elapsedLabel = NSTextField(labelWithString: "")
    private let linesLabel: NSTextField

    init(query: RunningQuery, elapsed: String, onCancel: @escaping (String) -> Void) {
        self.queryId = query.id
        self.onCancel = onCancel
        let linesText: String
        if query.segmentIndex == -1 {
            linesText = "Direct SQL"
        } else if query.lineRange.lowerBound == query.lineRange.upperBound {
            linesText = "Line \(query.lineRange.lowerBound)"
        } else {
            linesText = "Lines \(query.lineRange.lowerBound)–\(query.lineRange.upperBound)"
        }
        self.linesLabel = NSTextField(labelWithString: linesText)
        super.init(frame: .zero)

        linesLabel.font = .monospacedSystemFont(ofSize: 11, weight: .regular)
        linesLabel.translatesAutoresizingMaskIntoConstraints = false
        elapsedLabel.font = .monospacedSystemFont(ofSize: 11, weight: .regular)
        elapsedLabel.textColor = .secondaryLabelColor
        elapsedLabel.stringValue = elapsed
        elapsedLabel.translatesAutoresizingMaskIntoConstraints = false

        let cancelButton = NSButton()
        cancelButton.bezelStyle = .recessed
        cancelButton.isBordered = false
        cancelButton.title = ""
        let config = NSImage.SymbolConfiguration(pointSize: 12, weight: .medium)
        cancelButton.image = NSImage(systemSymbolName: "xmark.circle.fill", accessibilityDescription: "Cancel")?
            .withSymbolConfiguration(config)
        cancelButton.contentTintColor = .systemRed
        cancelButton.target = self
        cancelButton.action = #selector(cancelTapped)
        cancelButton.translatesAutoresizingMaskIntoConstraints = false

        addSubview(linesLabel)
        addSubview(elapsedLabel)
        addSubview(cancelButton)

        NSLayoutConstraint.activate([
            heightAnchor.constraint(equalToConstant: 22),
            linesLabel.leadingAnchor.constraint(equalTo: leadingAnchor),
            linesLabel.centerYAnchor.constraint(equalTo: centerYAnchor),

            elapsedLabel.trailingAnchor.constraint(equalTo: cancelButton.leadingAnchor, constant: -8),
            elapsedLabel.centerYAnchor.constraint(equalTo: centerYAnchor),

            cancelButton.trailingAnchor.constraint(equalTo: trailingAnchor),
            cancelButton.centerYAnchor.constraint(equalTo: centerYAnchor),
            cancelButton.widthAnchor.constraint(equalToConstant: 18),
            cancelButton.heightAnchor.constraint(equalToConstant: 18),
        ])
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) not used") }

    func setElapsed(_ text: String) {
        elapsedLabel.stringValue = text
    }

    @objc private func cancelTapped() {
        onCancel(queryId)
    }
}
```

- [ ] **Step 8.2: Wire `EditorPaneVC` to the popover**

In `Pharos/ViewControllers/EditorPaneVC.swift`, add an `NSPopover` property near the other properties:

```swift
private var runningQueriesPopover: NSPopover?
```

Replace the stub `showRunningQueriesPopover(_:)` from Step 7.4 with:

```swift
private func showRunningQueriesPopover(_ queries: [RunningQuery]) {
    runningQueriesPopover?.close()

    guard let tabId = activeTab?.id else { return }
    let vc = RunningQueriesPopoverVC(stateManager: stateManager, tabId: tabId)
    vc.delegate = self

    let popover = NSPopover()
    popover.contentViewController = vc
    popover.behavior = .transient
    popover.show(relativeTo: runStopButton.bounds, of: runStopButton, preferredEdge: .minY)
    runningQueriesPopover = popover
}
```

Then add the delegate conformance at the bottom of the file:

```swift
// MARK: - RunningQueriesPopoverDelegate

extension EditorPaneVC: RunningQueriesPopoverDelegate {
    func runningQueriesPopover(_ vc: RunningQueriesPopoverVC, didRequestCancelQueryId id: String) {
        delegate?.editorPane(self, didRequestCancelQueryId: id)
    }
}
```

- [ ] **Step 8.3: Regenerate the Xcode project**

```bash
cd /Users/nfinn/Projects/aSideProjects/Pharos && xcodegen generate
```

- [ ] **Step 8.4: Build**

```bash
xcodebuild -scheme Pharos -configuration Debug -quiet build
```

Expected: `** BUILD SUCCEEDED **`.

- [ ] **Step 8.5: Manual test**

Open the app. Launch 3 concurrent queries:

```sql
SELECT pg_sleep(8), 'A' AS marker;

SELECT pg_sleep(6), 'B' AS marker;

SELECT pg_sleep(4), 'C' AS marker;
```

Run all three. Click the badged Stop button. Expected:
- Popover opens below the button.
- Header: "3 queries running".
- Three rows, each showing "Lines X–Y" on the left and "M:SS" on the right (ticking up each second).
- Click the X on the "B" row — that single row disappears, the corresponding gutter bar stops pulsing, the badge updates to "2".
- When the running count drops to 1 (either by waiting for natural completion or cancelling another row), the popover auto-dismisses and the Stop button returns to single-cancel mode.

- [ ] **Step 8.6: Commit**

```bash
git add Pharos/ViewControllers/RunningQueriesPopoverVC.swift Pharos/ViewControllers/EditorPaneVC.swift Pharos.xcodeproj
git commit -m "feat: running-queries popover with per-row cancel and live elapsed"
```

---

## Task 9: Tab close + disconnect cancel paths

Ensure in-flight queries are cancelled when their owning tab is closed, and that disconnecting a connection clears `runningQueries` for any tab on that connection so the UI returns to idle promptly (without waiting for each in-flight query's error to round-trip).

**Files:**
- Modify: `Pharos/ViewControllers/ContentViewController.swift`
- Possibly: `Pharos/Core/AppStateManager.swift` (only if the tab-close path is there)

- [ ] **Step 9.1: Find the tab-close handler**

```bash
grep -n "closeTab\|removeTab\|tab\.queryId" Pharos/ViewControllers/ContentViewController.swift Pharos/Core/AppStateManager.swift Pharos/ViewControllers/EditorPaneVC.swift 2>/dev/null
```

Identify the function that handles closing a tab (cancelling its query was previously done via `tab.queryId`). If a `tab.queryId`-based cancel exists in any close handler, that's the call site to update. If no such call site exists (the existing code may rely on the in-flight Task error-pathing), add cancellation there now.

- [ ] **Step 9.2: Update the tab-close cancel path**

In whichever file you identified in Step 9.1, locate the tab-close handler. Insert (or replace the existing `tab.queryId`-based cancel with):

```swift
// Cancel all in-flight queries for the closing tab. Completion callbacks
// that fire after the tab is removed hit updateTab(id:) on an unknown id
// and no-op.
if let tab = stateManager.tabs.first(where: { $0.id == tabId }),
   let connectionId = tab.connectionId {
    for q in tab.runningQueries {
        cancelledQueryIds.insert(q.id)
        Task {
            _ = try? await PharosCore.cancelQuery(connectionId: connectionId, queryId: q.id)
        }
    }
}
```

Adjust `tabId` / variable names to match the surrounding handler. `cancelledQueryIds` only exists on `ContentViewController` — if the tab-close handler lives in `AppStateManager`, post a notification that `ContentViewController` observes and cancels from. Pick the file that already references `cancelledQueryIds`; that's `ContentViewController`.

- [ ] **Step 9.3: Add a disconnect observer in `ContentViewController`**

`AppStateManager.swift` already posts `Notification.Name(...)` when connection status changes (line ~533, see `postStatusChange`). Find the existing observer registration in `ContentViewController` (search for `NSWorkspace.didActivateApplicationNotification` or `NotificationCenter.default.addObserver` in `viewDidLoad`), and add an observer for the connection-status notification:

```bash
grep -n "addObserver\|connectionStatusDidChange\|postStatusChange" Pharos/Core/AppStateManager.swift Pharos/ViewControllers/ContentViewController.swift
```

Note the exact `Notification.Name` (likely `connectionStatusDidChange` or similar) that `postStatusChange` posts. In `ContentViewController.viewDidLoad` (or wherever observer registration is grouped), add:

```swift
NotificationCenter.default.addObserver(
    self,
    selector: #selector(handleConnectionStatusChanged(_:)),
    name: AppStateManager.connectionStatusDidChangeNotification, // use the actual symbol from AppStateManager
    object: nil
)
```

And add the handler:

```swift
@objc private func handleConnectionStatusChanged(_ note: Notification) {
    guard let connectionId = note.userInfo?["connectionId"] as? String else { return }
    guard stateManager.status(for: connectionId) != .connected else { return }
    // Connection dropped — clear runningQueries for every tab on this connection.
    let affectedTabIds = stateManager.tabs.compactMap { $0.connectionId == connectionId ? $0.id : nil }
    for tabId in affectedTabIds {
        stateManager.updateTab(id: tabId) { tab in
            // Mark all as user-cancelled so the error path doesn't notify.
            for q in tab.runningQueries {
                self.cancelledQueryIds.insert(q.id)
            }
            tab.runningQueries.removeAll()
        }
    }
}
```

Use the actual notification name and userInfo key — check the implementation of `postStatusChange` in `AppStateManager.swift` (around line 533) for ground truth.

- [ ] **Step 9.4: Build**

```bash
xcodebuild -scheme Pharos -configuration Debug -quiet build
```

Expected: `** BUILD SUCCEEDED **`.

- [ ] **Step 9.5: Manual test — tab close**

Launch a slow query (`SELECT pg_sleep(10);`). While running, close the tab (`⌘W` or the X on the tab). Expected:
- Tab disappears immediately.
- No console errors.
- If you connect to the DB via psql or a monitoring tool and check `pg_stat_activity`, the corresponding backend is no longer running the sleep (it was cancelled).

- [ ] **Step 9.6: Manual test — disconnect**

Launch 2 concurrent slow queries. Right-click the connection in the sidebar and disconnect. Expected:
- Both gutter pulses stop immediately (not after a delay).
- Stop button returns to play.
- Console may show "Query was cancelled" / connection-dropped errors from the in-flight Tasks; this is fine.

- [ ] **Step 9.7: Commit**

```bash
git add Pharos/ViewControllers/ContentViewController.swift
git commit -m "feat: cancel in-flight queries on tab close and connection disconnect"
```

---

## Task 10: Final manual verification pass

Run through every scenario in the spec's Testing section. Document any deviations or bugs and fix them before declaring done.

**No code changes** — verification only. If a deviation requires a fix, the fix gets its own commit referencing the failing scenario.

- [ ] **Step 10.1: Concurrent execution produces ordered result tabs**

In one editor tab, run two SELECTs of different durations (one 5s, one 1s) close in time. Expected: both result tabs appear in completion order (fast finishes first). Both gutter bars pulsed in unison while running.

- [ ] **Step 10.2: Re-running identical SQL shows toast**

While a slow `SELECT pg_sleep(5);` is running, hit Cmd+Return again on the same statement. Expected:
- Toast appears: "Already running — lines X–Y (0:0N)".
- Toast fades after 2 seconds.
- Only one result tab is produced.

- [ ] **Step 10.3: Three concurrent queries — popover behavior**

Launch 3 concurrent queries. Click the Stop button. Expected:
- Popover opens with 3 rows.
- Header reads "3 queries running".
- Elapsed timers tick up every second.
- Per-row cancel removes that one row; corresponding gutter bar stops; badge count decrements.
- When count drops to 1, popover auto-dismisses.

- [ ] **Step 10.4: Tab close cancels in-flight queries**

Launch a slow query. Close its tab. Verify in `pg_stat_activity` that the backend stopped executing (or the query disappeared from `pg_stat_activity` entirely).

- [ ] **Step 10.5: Disconnect clears runningQueries promptly**

Launch 2 slow queries. Disconnect. Verify:
- Gutter pulses stop immediately.
- Button returns to play.
- `runningQueries` is empty (you can verify visually — no badge, no pulse, no popover-trigger).

- [ ] **Step 10.6: Gutter — all bars pulse in unison**

Launch 3 concurrent queries on different segments. Visually confirm all three pulse with the same phase (peak at the same moment, trough at the same moment) — they should breathe together.

- [ ] **Step 10.7: Gutter — individual fade-out**

Launch 3 concurrent queries with staggered finish times (e.g. 1s, 3s, 5s). Watch the gutter. Expected: each bar individually fades out over ~400ms (the existing `fadeOutDuration`) as its query finishes; others keep pulsing.

- [ ] **Step 10.8: Result-tab racing — segment + direct-SQL**

In one editor tab, run a long segment (`SELECT pg_sleep(5), 'segment';`). While running, edit the editor so it has only a single non-semicolon statement (`SELECT 'direct'`), and Cmd+Return. Expected: the segment result still lands in its own result tab; the direct-SQL result populates the inline result panel (since no *other direct-SQL* is in flight).

- [ ] **Step 10.9: Final commit (if any fixes were made)**

If Steps 10.1–10.8 caught issues, commit each fix individually with a message referencing the scenario.

If no fixes were needed, no commit. Done.

---

## Self-Review Notes

This plan was self-reviewed after writing. Spec coverage check:
- Data model (spec §Architecture/Data Model) → Task 1
- Execution flow + dedup + toast (spec §Execution Flow) → Tasks 1, 2, 4
- Direct-SQL routing (spec §Execution Flow) → Task 5
- Gutter multi-bar (spec §Gutter) → Task 6
- Stop button + badge (spec §Stop Button) → Task 7
- Popover (spec §Running-Queries Popover) → Task 8
- Toast component (spec §Toast) → Task 3
- Cancellation paths (spec §Cancellation Paths) → Tasks 1.6, 7.5, 9
- Edge cases (spec §Edge Cases) → Task 10 verification

No `pharos-core` task — the spec explicitly calls this out as zero-change on the Rust side.
