# Concurrent Query Execution Per Editor Tab — Design

**Date:** 2026-05-26
**Status:** Design — pending implementation plan

## Problem

Today, an editor tab can only track one in-flight query at a time. If a user runs Query A and then hits Cmd+Return again (either on the same SQL, or after editing the SQL), the second invocation unconditionally launches Query B and overwrites `tab.queryId` and `tab.runningSegmentIndex`. Consequences:

- Query A keeps running on the backend but Swift loses the handle to cancel it.
- For direct-SQL execution (no parseable segments) both completions write to `tab.result`, last-writer-wins — Query A finishing after B can stomp B's output.
- The gutter pulse only shows one segment as running, even when two queries are concurrently in flight on the backend.
- No protection against accidentally running the same query twice (a common Cmd+Return slip).

The `pharos-core` Rust side already supports many concurrent queries keyed by `query_id` in `AppState.running_queries` — the constraint is purely in the Swift layer.

## Goal

Allow multiple queries to execute concurrently from a single editor tab, with:

- Silent-by-default deduplication when the user re-triggers the same SQL while it is already running, surfaced via a small in-app toast.
- A multi-bar pulsing gutter that shows which segments are currently running.
- A Stop control that scales from "cancel the one running query" to "open a popover of all in-flight queries with per-query cancel."

## Non-Goals

- No changes to `pharos-core`. The FFI surface (`execute_query`, `cancel_query`, `running_queries` registry) already supports the model.
- No fix for the pre-existing positional-segment-index quirk where editing SQL above a running segment can shift the pulse to the wrong bar. Out of scope.
- No queueing or rate-limit policy for concurrent queries. The sqlx connection pool provides natural backpressure.
- No general-purpose notification center. The new `Toast` component is reusable but no new call sites are introduced beyond the dedup case.

## Design Summary

1. **Data model** — `QueryTab` holds an ordered array of `RunningQuery` structs. `isExecuting` becomes a computed property.
2. **Execution flow** — `performQuery` normalizes the SQL, dedup-checks against the array, appends-and-launches on miss, shows a toast on hit. Direct-SQL runs are routed to result tabs when another direct-SQL run is already in flight, preventing inline-result clobbering.
3. **Gutter** — `LineNumberGutter` pulses all bars in `runningSegmentIndices: Set<Int>` in unison off a single shared pulse phase. Each removed index gets its own fade-out timer.
4. **Stop button** — three-state control: Run / Cancel-one / Open-popover-with-badge. Popover lists in-flight queries as `Lines X–Y — M:SS` with per-row cancel.
5. **Toast** — new reusable `NSVisualEffectView`-based transient notification, anchored bottom-center of the host view.

## Architecture

### Data Model (`Pharos/Models/QueryTab.swift`)

New struct:

```swift
struct RunningQuery: Identifiable {
    let id: String                  // queryId (UUID) — matches Rust running_queries key
    let normalizedSQL: String       // trimmed + whitespace-collapsed, used for dedup
    let segmentIndex: Int           // -1 for direct-SQL, >= 0 for parseable segment
    let lineRange: ClosedRange<Int> // 1-based editor line range, for popover label
    let startTime: CFTimeInterval   // CACurrentMediaTime() at launch
}
```

`QueryTab` changes:

```swift
// Removed:
var isExecuting: Bool = false
var queryId: String?
var runningSegmentIndex: Int?

// Added:
var runningQueries: [RunningQuery] = []   // ordered by startTime ascending

// Computed (new extension):
var isExecuting: Bool { !runningQueries.isEmpty }
```

`isExecuting` keeps the same call-site shape — all existing readers of `tab.isExecuting` continue to work. The previous direct readers of `tab.queryId` and `tab.runningSegmentIndex` (in `EditorPaneVC` and `ContentViewController`) are updated to read from `runningQueries`.

### Execution Flow (`Pharos/ViewControllers/ContentViewController.swift`)

`performQuery(_:segmentIndex:lineRange:customLabel:createResultTab:)` is modified:

```swift
let normalized = Self.normalizeSQL(sql)

// Dedup: re-running the same SQL while it's in flight is a no-op (with toast).
if let existing = activeTab.runningQueries.first(where: { $0.normalizedSQL == normalized }) {
    let elapsed = formatElapsed(CACurrentMediaTime() - existing.startTime)
    Toast.show(in: self.view,
               message: "Already running — lines \(existing.lineRange.lowerBound)–\(existing.lineRange.upperBound) (\(elapsed))",
               style: .info,
               duration: 2.0)
    return
}

// Direct-SQL routing: tab.result is only populated by direct-SQL runs
// (createResultTab=false). If another direct-SQL run is already in flight,
// route this one to a result tab to avoid clobbering tab.result.
// Segment runs always write to their own result tabs and never touch tab.result,
// so concurrent segment + direct-SQL needs no special routing.
var effectiveCreateResultTab = createResultTab
if segmentIndex == -1,
   activeTab.runningQueries.contains(where: { $0.segmentIndex == -1 }) {
    effectiveCreateResultTab = true
}

let queryId = UUID().uuidString
let running = RunningQuery(id: queryId, normalizedSQL: normalized,
                           segmentIndex: segmentIndex, lineRange: lineRange,
                           startTime: CACurrentMediaTime())

stateManager.updateTab(id: tabId) { tab in
    tab.runningQueries.append(running)
    // Only clear inline state if this run will populate it inline.
    if !effectiveCreateResultTab {
        tab.error = nil
        tab.result = nil
        tab.executeResult = nil
    }
}
```

On completion / failure / cancellation, remove by id:

```swift
stateManager.updateTab(id: tabId) { tab in
    tab.runningQueries.removeAll { $0.id == queryId }
    // Inline-result population (when !effectiveCreateResultTab) is unchanged.
}
```

**`normalizeSQL`:**
- Trim leading and trailing whitespace.
- Collapse runs of whitespace (spaces, tabs, newlines) inside the SQL to a single space.
- Do NOT strip comments or modify string/identifier literal contents.

This means `SELECT 1` and `SELECT  1\n` dedup-match, but `SELECT 1 -- v2` does not match `SELECT 1`.

**`formatElapsed(_ seconds: CFTimeInterval) -> String`:** small private helper, returns `"M:SS"` (e.g. `"0:08"`, `"1:23"`). Shared with the popover row labels.

### Gutter (`Pharos/Editor/LineNumberGutter.swift`)

Field changes:

```swift
// Removed:
private var runningSegmentIndex: Int?
private var fadeOutUntil: CFTimeInterval?
private var fadeStartAlpha: CGFloat = 0

// Added:
private var runningSegmentIndices: Set<Int> = []   // includes -1 for phantom
private var fadeOutStates: [Int: FadeState] = [:]  // per-index fade-out

private struct FadeState {
    let startAlpha: CGFloat
    let endTime: CFTimeInterval
}
```

New API:

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

Draw loop (existing per-segment iteration in `draw(_:)`) updates the bar-color selection:

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
// `defaultBarColor(for:)` is the existing fallback selection extracted into
// a helper: resultColor[segIdx] ?? (segIdx == activeSegmentIndex ? accent : tertiary).
```

Phantom-pulse path (the `segmentIndex == -1` direct-SQL block at line 618) reads `runningSegmentIndices.contains(-1)` and uses `fadeOutStates[-1]` for its fade.

All running bars share the same `pulseValue`, so they pulse in unison — a single coordinated rhythm rather than independent chaotic animations.

When the segment array is replaced (existing `setSegments` path), `fadeOutStates` is cleared to drop orphan entries that would never paint a real bar.

Caller wiring (`Pharos/ViewControllers/EditorPaneVC.swift:259` and `:308`):

```swift
let indices = Set(tab.runningQueries.map { $0.segmentIndex })
editorVC.setRunningSegmentIndices(indices)
```

### Stop Button (`Pharos/ViewControllers/EditorPaneVC.swift`)

`runStopButton` becomes a three-state control driven by `tab.runningQueries.count`:

| Count | Appearance | Click behavior |
|-------|-----------|----------------|
| 0 | `play.fill`, accent tint | Run current segment (existing path) |
| 1 | `stop.fill`, red | Cancel that single query directly |
| ≥2 | `stop.fill` + numeric badge ("2", "3", …), red | Open running-queries popover |

Badge is drawn as a `CALayer` sublayer on the button: a ~14pt-diameter circle (top-right corner overlay) with system red fill and white centered text. The sublayer is added once in `setupEditorToolbar` and shown / hidden / re-textured in `updateEditorToolbarState`.

`updateEditorToolbarState` becomes:

```swift
let count = activeTab?.runningQueries.count ?? 0
let config = NSImage.SymbolConfiguration(pointSize: 13, weight: .medium)
switch count {
case 0:
    runStopButton.image = NSImage(systemSymbolName: "play.fill", ...)
    runStopButton.toolTip = "Run Query (Cmd+Return)"
    runStopButton.contentTintColor = .controlAccentColor
    badgeLayer.isHidden = true
case 1:
    runStopButton.image = NSImage(systemSymbolName: "stop.fill", ...)
    runStopButton.toolTip = "Stop Query"
    runStopButton.contentTintColor = .systemRed
    badgeLayer.isHidden = true
default:
    runStopButton.image = NSImage(systemSymbolName: "stop.fill", ...)
    runStopButton.toolTip = "\(count) queries running — click to manage"
    runStopButton.contentTintColor = .systemRed
    badgeLayer.string = "\(count)"
    badgeLayer.isHidden = false
}
```

`runStopTapped` dispatches based on count:

```swift
@objc private func runStopTapped() {
    let running = stateManager.activeTab?.runningQueries ?? []
    switch running.count {
    case 0:  delegate?.editorPaneDidRequestRunQuery(self)
    case 1:  delegate?.editorPane(self, didRequestCancelQueryId: running[0].id)
    default: showRunningQueriesPopover(anchor: runStopButton)
    }
}
```

The delegate gains a per-id cancel method; the old `editorPaneDidRequestCancelQuery(_:)` is replaced (`ContentViewController` is the only conformer).

### Running-Queries Popover (`Pharos/ViewControllers/RunningQueriesPopoverVC.swift`, new)

- `NSPopover`, `behavior = .transient`, content size ~260pt × dynamic-height.
- Content view: vertical `NSStackView`, header label `"N queries running"` on top, one row per `RunningQuery` sorted by `startTime` ascending.
- Each row: `NSStackView` (horizontal) with:
  - `"Lines X–Y"` label (left, monospace digits)
  - elapsed `"M:SS"` label (right, monospace digits, secondary color)
  - `xmark.circle.fill` button (12pt, system red on hover) calling `cancelQuery(id:)`
- A 1Hz `Timer` is created in `popoverDidShow` and invalidated in `popoverDidClose`. Each tick updates the elapsed label's `stringValue` — no row reload, no view-tree thrash.
- When a query completes or is cancelled while the popover is open, the corresponding row animates out (150ms fade) and is removed. If `runningQueries.count` drops to ≤1, the popover dismisses itself.

The popover observes `stateManager` for tab updates and reconciles its row list against `tab.runningQueries` on each change.

### Toast (`Pharos/Views/Toast.swift`, new)

A self-contained transient notification component.

Public surface:

```swift
enum ToastStyle { case info, success, warning, error }

enum Toast {
    static func show(in host: NSView,
                     message: String,
                     style: ToastStyle = .info,
                     duration: TimeInterval = 2.0)
}
```

Visual:
- `NSVisualEffectView` (material `.hudWindow`), 8pt corner radius.
- 3pt leading vertical stripe colored by `style` (info=accent, success=systemGreen, warning=systemOrange, error=systemRed).
- Optional SF Symbol leading the text (style-driven: `info.circle.fill`, `checkmark.circle.fill`, etc.).
- Single-line `NSTextField` label.
- Anchored bottom-center of `host`, 12pt inset from the bottom.

Behavior:
- Fade in (150ms) → hold (`duration` seconds) → fade out (250ms). Removes self from superview after fade-out.
- Stacking: at `show` time, measures existing `Toast` siblings in `host` and offsets vertically so multiple concurrent toasts stack upward.
- No shared state, no manager singleton, no queue — each call creates a self-managed instance.

### Cancellation Paths

**Per-query cancel** (popover row, or 1-query Stop click):

```swift
PharosCore.cancelQuery(queryId: id)
stateManager.updateTab(id: tabId) { tab in
    tab.runningQueries.removeAll { $0.id == id }
}
```

Idempotent — the in-flight Task's completion handler will also attempt the same removal.

**Tab close with queries in flight:** existing tab-close handler in `ContentViewController` is updated from `tab.queryId`-based cancel to iterating `tab.runningQueries` and cancelling each. Completion callbacks that fire after tab removal hit `stateManager.updateTab(id:)` on an unknown id and no-op.

**Connection disconnect:** existing disconnect path drops the connection pool; in-flight queries fail with connection errors. Add an explicit clear of `tab.runningQueries` for every tab on that `connectionId` so the UI returns to idle without waiting for each completion callback.

**`tab.error` semantics:** today, `performQuery` clears `tab.error` at launch. Updated to clear only when `effectiveCreateResultTab == false` — i.e., when the new run will populate inline state. Result-tab errors are scoped to the result tab. This prevents one concurrent run from masking another's inline error.

## Edge Cases

- **Dedup race — match completes mid-trigger:** user hits Cmd+Return on SQL that matches a running query about to finish (within ms). Toast briefly shows "Already running…"; a tick later the original completes. The toast lingers for its 2-second duration; the user's intent ("don't double-fire the same query") is honored.

- **Switching editor tabs mid-flight:** off-screen tab keeps running. The existing `updateContent` path in `EditorPaneVC` re-applies `runningQueries → setRunningSegmentIndices` when the tab becomes active again, so the pulse resumes correctly.

- **Editing SQL inside a running segment:** doesn't affect the in-flight query (SQL was captured into `RunningQuery.normalizedSQL` at launch). The gutter pulse tracks the segment positionally — same as today. Pre-existing quirk: editing *above* a running segment can shift indices and visually mis-track. Not fixed here.

- **Dedup interaction with formatting:** if the user formats their SQL (which changes whitespace only) and re-runs, normalized SQL is unchanged → dedup'd. Correct behavior.

- **Pool exhaustion:** sqlx pool size limits concurrent queries naturally — queries beyond the pool size queue inside sqlx until a connection is available. No Swift-side cap needed.

## Files Touched

- `Pharos/Models/QueryTab.swift` — `RunningQuery` struct; replace three fields with `runningQueries` + computed `isExecuting`.
- `Pharos/ViewControllers/ContentViewController.swift` — `performQuery` dedup + concurrent-dispatch logic; completion handlers update `runningQueries`; tab-close and disconnect cancel paths updated.
- `Pharos/ViewControllers/EditorPaneVC.swift` — three-state Run/Stop button; badge sublayer; popover trigger; delegate method renamed to per-id.
- `Pharos/ViewControllers/RunningQueriesPopoverVC.swift` — **new** popover content controller.
- `Pharos/Views/Toast.swift` — **new** reusable transient toast component.
- `Pharos/Editor/LineNumberGutter.swift` — `runningSegmentIndices: Set<Int>` + per-index `fadeOutStates`; updated draw loop and phantom-pulse path.
- `Pharos/ViewControllers/QueryEditorVC.swift` — `setRunningSegmentIndex(Int?)` replaced with `setRunningSegmentIndices(Set<Int>)`.

No `pharos-core` changes.

## Testing

- Manual: run two non-trivial queries (one slow, one fast) from the same editor; confirm both produce result tabs in launch order regardless of completion order.
- Manual: run a slow query, then hit Cmd+Return on the same SQL — confirm toast appears and no second execution is launched.
- Manual: launch 3+ queries, click the Stop button — confirm popover opens with 3 rows, elapsed timers tick, per-row cancel removes only that row.
- Manual: launch a query, close the tab — confirm the query is cancelled (check Postgres `pg_stat_activity` for backend cancellation).
- Manual: launch a query, disconnect the connection — confirm `runningQueries` clears and the gutter returns to idle.
- Manual: visual check — multiple gutter bars pulse in unison; fade-out fires per-bar on individual completion.
