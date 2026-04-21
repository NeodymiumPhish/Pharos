# Query-Running Animation — Design

**Date:** 2026-04-21
**Status:** Design — pending implementation plan

## Problem

When a query is executing, the only visual indication today is the "Stop Query" button replacing the "Run Query" button in the query editor toolbar. Users have to actively watch that button to know a query is in flight. There's no ambient, peripheral-vision cue that says "a query is running," especially for longer-running queries where the user's attention has moved elsewhere in the UI.

## Goal

Add a coordinated visual indicator of query execution across three surfaces that the user's eye naturally tracks, so query-in-flight is apparent without looking at a specific control.

## Non-Goals

- No changes to query execution timing, cancellation, or error handling.
- No new UI surfaces beyond the three named below (e.g. no toast notifications, no progress percentage).
- No change to the existing "Stop Query" button — this feature supplements it, doesn't replace it.

## Design Summary

Three UI surfaces pulse in unison while a query is executing, driven by a single shared pulse clock so they breathe at the same rhythm and read as one coordinated animation:

1. **Gutter segment bar** — the bar for the currently-running SQL segment pulses in the accent color. Non-running segments are unaffected.
2. **Action bar top separator** — the 1px line at the top of `ResultsToolbarBar` (between editor and results) pulses, reflecting the *focused pane's active tab* only.
3. **Pane tab indicator** — a small pulsing dot is drawn on any tab (in any pane) whose query is executing. Replaces the existing static `⟳` prefix.

All three share:
- **Color:** `NSColor.controlAccentColor` (the system accent).
- **Rhythm:** 1.2-second period, `sin(t × 2π / 1.2)` remapped to `[0, 1]`, driving alpha/brightness.
- **Phase:** synchronized (single shared clock — no drift between surfaces).

## Architecture

### Pulse Clock (new)

A single shared pulse source, `Pharos/Core/PulseClock.swift`.

- Singleton `PulseClock.shared`.
- Drives a `CADisplayLink` targeted at the main screen's refresh rate.
- Publishes a `CurrentValueSubject<CGFloat, Never>` named `value`, continuously updated to `0.5 + 0.5 * sin((CACurrentMediaTime() - startTime) * 2π / 1.2)`.
- Reference-counted: exposes `observe() -> AnyCancellable`. The display link starts on the first observer and stops when observer count hits zero. No CPU cost when nothing is pulsing.
- Exposes `reduceMotion: Bool` (resolved once at startup and re-read on the `NSWorkspace.accessibilityDisplayOptionsDidChangeNotification`). When true, `value` is pinned to `1.0` — clients still subscribe, but they see a constant peak value, producing a static "accent highlight" state instead of motion.

### State source

The single source of truth is `QueryTab.isExecuting` on the existing `QueryTab` model. It is already flipped to `true` at query start and `false` on completion/failure/cancellation in `ContentViewController.performQuery` ([ContentViewController.swift:898](Pharos/ViewControllers/ContentViewController.swift:898)).

Each UI surface observes `isExecuting` via the existing `AppStateManager` publisher (`stateManager.$tabs` or equivalent — exact wiring confirmed during planning).

### Data flow

```
QueryTab.isExecuting ──► AppStateManager publisher ──► each UI surface
                                                            │
                                                            ▼
                                      subscribe/unsubscribe to PulseClock
                                                            │
                                                            ▼
                                       PulseClock.value ticks → needsDisplay
```

## Component Changes

### 1. `Pharos/Core/PulseClock.swift` (new, ~60 lines)

Display-link-driven pulse source described above. Public surface:

```swift
final class PulseClock {
    static let shared = PulseClock()
    let value: CurrentValueSubject<CGFloat, Never>
    var reduceMotion: Bool { get }
    func observe() -> AnyCancellable
}
```

### 2. `Pharos/Editor/LineNumberGutter.swift` (modified)

- Add a `runningSegmentIndex: Int?` property set by `QueryEditorVC` when that pane's tab starts/stops executing.
- When non-nil, subscribe to `PulseClock.shared.value` and call `needsDisplay = true` on each tick; unsubscribe when cleared.
- In `draw(_:)`, the running segment's bar color is computed as:
  - Base: `NSColor.controlAccentColor`
  - Alpha: interpolated from `0.55` to `1.0` by the current pulse value.
  - This overrides the existing "active segment" color path ([LineNumberGutter.swift:505](Pharos/Editor/LineNumberGutter.swift:505)) but only for the specific running index. `segmentColors[segIdx]` (result-tab color) continues to apply to non-running segments.
- Fallback when no segments are parsed (direct SQL execution): synthesize a "phantom segment" spanning the full text so the gutter-side bar pulses end-to-end. Implementation detail — gutter gets a separate `runningPhantomRange: ClosedRange<Int>?` set by the VC on direct execution.
- On `isExecuting` transitioning to false, trigger a 250ms linear fade-out from the current pulse alpha to the segment's idle color before unsubscribing. Implemented by keeping a `fadeOutStartTime` and continuing to drive `needsDisplay` from the pulse clock subscription for an additional 250ms after `runningSegmentIndex` is cleared.

### 3. `Pharos/ViewControllers/ResultsGridVC.swift` — `ResultsToolbarBar` (modified)

- Add `isPulsing: Bool` property on `ResultsToolbarBar`.
- `ContentViewController` sets this based on the focused pane's active tab's `isExecuting`.
- When `isPulsing` is true, subscribe to `PulseClock.shared.value` and invalidate display each tick.
- In `draw(_:)` ([ResultsGridVC.swift:712](Pharos/ViewControllers/ResultsGridVC.swift:712)), the top separator stroke color is interpolated between `NSColor.separatorColor` (at pulse value 0) and `NSColor.controlAccentColor` (at pulse value 1). Line geometry unchanged (stays 1px).
- Same 250ms fade-out on `isPulsing` transitioning to false.

### 4. `Pharos/Views/PaneTabBar.swift` (modified)

- Remove the `⟳` prefix logic in `segmentLabel(for:)` ([PaneTabBar.swift:283](Pharos/Views/PaneTabBar.swift:283)). The `isDirty` `•` prefix is retained.
- Add a new overlay subview on top of the `NSSegmentedControl` that:
  - Is a non-interactive `NSView` (`hitTest(_:)` returns `nil`) so clicks pass through.
  - Has the same frame as the segmented control.
  - Reads the current tabs' `isExecuting` states and renders a 6pt filled circle near the leading edge of each executing segment (inside the segment's text area, before the label).
  - Subscribes to `PulseClock.shared.value` when *any* segment is executing; unsubscribes when none are.
  - Dot color: `NSColor.controlAccentColor`, alpha interpolated from pulse value the same way as the other surfaces.
  - Redraws whenever the tabs array or any `isExecuting` state changes.
- Segment content-width calculations may need a small additional leading inset for the dot to coexist with the label without clipping.

### 5. `Pharos/ViewControllers/ContentViewController.swift` (small wiring)

- When the focused pane changes, or the focused pane's active tab changes, or that tab's `isExecuting` changes, update `actionBar.isPulsing` accordingly.
- When any tab's `isExecuting` changes, notify the owning `PaneTabBar` to refresh its overlay (the overlay reads the tab states directly but needs a redraw trigger).
- In `performQuery`, after setting `tab.isExecuting = true`, also set the focused pane's gutter `runningSegmentIndex` (or `runningPhantomRange`) based on the segment being executed. On completion, clear it.

## Accessibility

- **Reduce Motion:** `NSWorkspace.shared.accessibilityDisplayShouldReduceMotion` is checked by `PulseClock`. When true, the clock's value publisher is pinned to `1.0`, so all three surfaces render in their peak accent-color state continuously while executing. No animation, same informational content.
- **Color contrast:** Accent color alpha stays ≥ 0.55 at the pulse trough, so the indicator remains visible in light and dark appearances. In dark mode, the separator-to-accent interpolation retains enough contrast to be perceptible.

## Edge Cases

- **Concurrent queries in multiple panes:** Each pane's `QueryEditorVC` tracks its own `runningSegmentIndex`, so two gutters can pulse independently. The action bar reflects only the focused pane. The tab bar shows a dot for any executing tab regardless of pane.
- **Concurrent segments in the same tab:** Currently one segment executes at a time per tab (`tab.isExecuting` is a single boolean). Design accommodates only one running segment per tab; if future work adds parallelism, extend to a `Set<Int>`.
- **Sub-second queries:** 250ms completion fade-out prevents a jarring flicker on fast queries.
- **Query cancellation / failure:** `isExecuting` still flips to false; pulse fades out normally. The existing red error dot in the gutter and the error display in the results area handle error signaling.
- **Tab close while executing:** `PaneTabBar` overlay observes the current tabs array; removed tabs simply no longer draw dots. `PulseClock` reference count drops if this was the last executing surface.
- **Window deactivation:** `CADisplayLink` keeps running but pulses are cheap; no special handling. Pulse continues when window regains focus.

## Testing Plan

All manual, via the running app against the user's test databases:

1. **Happy path:** Run `SELECT pg_sleep(3)` on Macbook DB / `public` schema. Confirm the gutter segment bar pulses, the action bar top separator pulses, and the active tab's dot pulses — all in visual sync. Confirm smooth fade-out on completion.
2. **Multi-pane concurrency:** Open side-by-side panes, run concurrent `pg_sleep` queries in each. Confirm both gutters pulse independently but the action bar separator reflects only the focused pane.
3. **Background tab:** Run a long query in Tab 1, switch to Tab 2 in the same pane. Confirm Tab 1's dot continues pulsing in the tab bar, but the gutter (now showing Tab 2) and action bar separator are idle.
4. **Fallback path:** Run a query with text that has no parseable segments. Confirm the pulse falls back to a full-height gutter bar.
5. **Reduce motion:** Toggle macOS "Reduce motion" (`System Settings > Accessibility > Display`). Re-run step 1. Confirm all three surfaces show the static peak accent color for the duration of execution (no breathing motion).
6. **Error path:** Run a syntactically invalid query. Confirm pulse fades out, red error dot appears, error is displayed — no stuck pulse.
7. **Cancel path:** Start `pg_sleep(30)`, click "Stop Query". Confirm pulse fades out on cancellation.
8. **CPU when idle:** With no queries running and the app visible, confirm `CADisplayLink` is not running (PulseClock observer count = 0). Spot-check via Activity Monitor or Instruments.

## Open Questions

None at time of writing. Implementation plan will verify the exact Combine publisher used by `AppStateManager` for per-tab `isExecuting` observation.
