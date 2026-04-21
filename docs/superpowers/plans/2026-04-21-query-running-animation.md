# Query-Running Animation — Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Add a coordinated "breathing" accent-color pulse across three UI surfaces (gutter segment bar, action-bar top separator, per-tab indicator dot) while a query is executing, so query-in-flight is apparent at a glance without staring at the Stop Query button.

**Architecture:** One shared `PulseClock` singleton drives a `CADisplayLink`-backed breathing value in `[0, 1]`. Three surfaces subscribe on demand and interpolate their own colors each tick. Source of truth is a new `QueryTab.runningSegmentIndex: Int?` property (`nil` = idle, `-1` = full-editor phantom, `≥ 0` = specific segment). The existing Combine `$tabs` pipeline propagates state to observers. Reduce-Motion is handled centrally in `PulseClock` by pinning the published value to `1.0`.

**Tech Stack:** Swift / AppKit / Combine / QuartzCore (`CADisplayLink`).

Design spec: [docs/superpowers/specs/2026-04-21-query-running-animation-design.md](../specs/2026-04-21-query-running-animation-design.md)

---

### Task 1: Create the shared `PulseClock`

**Files:**
- Create: `Pharos/Core/PulseClock.swift`

- [ ] **Step 1: Create the PulseClock file**

Create `Pharos/Core/PulseClock.swift` with the following content:

```swift
import AppKit
import Combine
import QuartzCore

/// Shared pulse source driving the "query running" breathing animation across
/// the gutter, the results action bar, and the per-tab indicator dots.
///
/// The clock publishes a value in [0, 1] following a sine wave with a 1.2s period.
/// All three surfaces subscribe to the same publisher so their animations stay
/// phase-locked.
///
/// The underlying `CADisplayLink` is reference-counted: it starts on the first
/// `observe()` call and stops when the observer count returns to zero, so idle
/// sessions have zero CPU cost.
///
/// When the system-wide "Reduce Motion" accessibility setting is enabled, the
/// published value is pinned to `1.0`, which renders each surface in its static
/// peak-accent state (same informational content, no motion).
final class PulseClock {

    static let shared = PulseClock()

    /// Breathing value in [0, 1]. Continuous while one or more clients are observing.
    let value = CurrentValueSubject<CGFloat, Never>(1.0)

    /// Whether the system is in Reduce Motion mode. Re-read on change notifications.
    private(set) var reduceMotion: Bool

    // MARK: - Internals

    private var displayLink: CVDisplayLink?
    private var observerCount: Int = 0
    private let startTime = CACurrentMediaTime()
    private let period: CFTimeInterval = 1.2

    private init() {
        self.reduceMotion = NSWorkspace.shared.accessibilityDisplayShouldReduceMotion

        NSWorkspace.shared.notificationCenter.addObserver(
            self,
            selector: #selector(reduceMotionChanged),
            name: NSWorkspace.accessibilityDisplayOptionsDidChangeNotification,
            object: nil
        )
    }

    deinit {
        stop()
        NSWorkspace.shared.notificationCenter.removeObserver(self)
    }

    /// Subscribe to the pulse. Returns a token; when the token is cancelled or
    /// deallocated, the observer count decrements and the display link stops
    /// if this was the last observer.
    func observe() -> AnyCancellable {
        start()
        return AnyCancellable { [weak self] in
            self?.stop()
        }
    }

    // MARK: - Display Link Lifecycle

    private func start() {
        observerCount += 1
        guard observerCount == 1, displayLink == nil else { return }

        var link: CVDisplayLink?
        CVDisplayLinkCreateWithActiveCGDisplays(&link)
        guard let link else { return }

        let callback: CVDisplayLinkOutputCallback = { _, _, _, _, _, userInfo in
            guard let userInfo else { return kCVReturnSuccess }
            let clock = Unmanaged<PulseClock>.fromOpaque(userInfo).takeUnretainedValue()
            clock.tick()
            return kCVReturnSuccess
        }
        CVDisplayLinkSetOutputCallback(link, callback, Unmanaged.passUnretained(self).toOpaque())
        CVDisplayLinkStart(link)
        displayLink = link
    }

    private func stop() {
        observerCount = max(0, observerCount - 1)
        guard observerCount == 0, let link = displayLink else { return }
        CVDisplayLinkStop(link)
        displayLink = nil
    }

    // MARK: - Tick

    private func tick() {
        if reduceMotion {
            // Static peak — publish only once per change, not every frame.
            if value.value != 1.0 {
                DispatchQueue.main.async { [weak self] in self?.value.send(1.0) }
            }
            return
        }

        let t = CACurrentMediaTime() - startTime
        let phase = (t.truncatingRemainder(dividingBy: period)) / period
        let sine = sin(phase * 2 * .pi)
        let normalized = CGFloat(0.5 + 0.5 * sine)  // [0, 1]

        DispatchQueue.main.async { [weak self] in self?.value.send(normalized) }
    }

    @objc private func reduceMotionChanged() {
        reduceMotion = NSWorkspace.shared.accessibilityDisplayShouldReduceMotion
        if reduceMotion {
            DispatchQueue.main.async { [weak self] in self?.value.send(1.0) }
        }
    }
}
```

- [ ] **Step 2: Regenerate Xcode project and verify it compiles**

Run: `cd /Users/nfinn/Projects/aSideProjects/Pharos && xcodegen generate && xcodebuild -project Pharos.xcodeproj -scheme Pharos -configuration Debug build 2>&1 | tail -20`
Expected: Build succeeds with no errors.

- [ ] **Step 3: Commit**

```bash
git add Pharos/Core/PulseClock.swift project.yml Pharos.xcodeproj
git commit -m "add-pulse-clock-for-query-running-animation"
```

---

### Task 2: Add `runningSegmentIndex` to `QueryTab`

**Files:**
- Modify: `Pharos/Models/QueryTab.swift`

- [ ] **Step 1: Add the property**

Open `Pharos/Models/QueryTab.swift` and add `runningSegmentIndex` after `queryId`:

```swift
/// Represents a single query editor tab.
struct QueryTab: Identifiable {
    let id: String
    var name: String
    var connectionId: String?
    var schemaName: String?
    var sql: String
    var cursorPosition: Int = 0
    var isDirty: Bool = false
    var isExecuting: Bool = false
    var queryId: String?
    /// Index of the SQL segment currently executing. `nil` = idle, `-1` = full-editor
    /// (no segment parseable / direct execution fallback), `>= 0` = specific segment.
    /// Set alongside `isExecuting` when a query starts; cleared on completion/failure/cancel.
    var runningSegmentIndex: Int?
    var result: QueryResult?
    var executeResult: ExecuteResult?
    var error: String?
    var savedQueryId: String?
    var historySchema: String?
    var historyTimestamp: String?
    var gridState: ResultsGridState?
    var paneId: String?

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

- [ ] **Step 2: Verify it compiles**

Run: `cd /Users/nfinn/Projects/aSideProjects/Pharos && xcodebuild -project Pharos.xcodeproj -scheme Pharos -configuration Debug build 2>&1 | tail -20`
Expected: Build succeeds.

- [ ] **Step 3: Commit**

```bash
git add Pharos/Models/QueryTab.swift
git commit -m "add-runningSegmentIndex-to-QueryTab"
```

---

### Task 3: Set/clear `runningSegmentIndex` in `performQuery`

**Files:**
- Modify: `Pharos/ViewControllers/ContentViewController.swift:898-1000` (the `performQuery` method)

- [ ] **Step 1: Set `runningSegmentIndex` when starting the query**

In `Pharos/ViewControllers/ContentViewController.swift`, inside `performQuery(_:segmentIndex:lineRange:customLabel:createResultTab:)`, locate the block that sets `tab.isExecuting = true`:

```swift
        stateManager.updateTab(id: tabId) { tab in
            tab.isExecuting = true
            tab.queryId = queryId
            tab.error = nil
            if !createResultTab {
                tab.result = nil
                tab.executeResult = nil
            }
        }
```

Replace with:

```swift
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

- [ ] **Step 2: Clear `runningSegmentIndex` on the three completion paths (SELECT success, statement success, error)**

In the same method, find each of the three `tab.isExecuting = false` sites. There are three `updateTab` blocks in this method. Update each one as shown.

**Site 1** — SELECT success (around the `self.stateManager.updateTab` block after `PharosCore.executeQuery`):

```swift
                    await MainActor.run {
                        self.stateManager.updateTab(id: tabId) { tab in
                            tab.isExecuting = false
                            tab.queryId = nil
                            tab.runningSegmentIndex = nil
                            tab.result = result
                        }
```

**Site 2** — statement success (after `PharosCore.executeStatement`):

```swift
                    await MainActor.run {
                        self.stateManager.updateTab(id: tabId) { tab in
                            tab.isExecuting = false
                            tab.queryId = nil
                            tab.runningSegmentIndex = nil
                            tab.executeResult = result
                        }
```

**Site 3** — error path (the `catch` block around line 988; confirm via grep before editing):

```swift
                    await MainActor.run {
                        self.stateManager.updateTab(id: tabId) { tab in
                            tab.isExecuting = false
                            tab.queryId = nil
                            tab.runningSegmentIndex = nil
                            tab.error = message
                        }
```

(Preserve any other fields that block was already setting — this step only adds the one line `tab.runningSegmentIndex = nil`.)

- [ ] **Step 3: Verify it compiles**

Run: `cd /Users/nfinn/Projects/aSideProjects/Pharos && xcodebuild -project Pharos.xcodeproj -scheme Pharos -configuration Debug build 2>&1 | tail -20`
Expected: Build succeeds.

- [ ] **Step 4: Commit**

```bash
git add Pharos/ViewControllers/ContentViewController.swift
git commit -m "wire-runningSegmentIndex-into-performQuery-lifecycle"
```

---

### Task 4: Add pulse rendering to `LineNumberGutter`

**Files:**
- Modify: `Pharos/Editor/LineNumberGutter.swift`

- [ ] **Step 1: Add pulse state properties and Combine import**

At the top of `Pharos/Editor/LineNumberGutter.swift`, add `import Combine` after `import AppKit`:

```swift
import AppKit
import Combine
```

Then, inside the `LineNumberGutter` class, after the existing `segmentBarGap` constant, add the pulse state:

```swift
    // MARK: - Pulse State

    /// Index of the segment currently executing (nil = idle, -1 = full-editor phantom, >= 0 = segment).
    private var runningSegmentIndex: Int?

    /// Subscription to PulseClock while pulsing (including fade-out).
    private var pulseSubscription: AnyCancellable?

    /// Current pulse value [0, 1] read from PulseClock.
    private var pulseValue: CGFloat = 1.0

    /// Time at which fade-out should end; nil while actively pulsing.
    private var fadeOutUntil: CFTimeInterval?

    /// Duration of the completion fade-out, in seconds.
    private let fadeOutDuration: CFTimeInterval = 0.25
```

- [ ] **Step 2: Add public setter for the running segment index**

Add this method next to the existing `setSegments(_:activeIndex:)` method in the "Public API" section:

```swift
    /// Set the currently-executing segment index.
    /// - `nil` = idle (stops pulsing with a fade-out)
    /// - `-1` = full-editor phantom (pulses the entire gutter bar)
    /// - `>= 0` = specific segment pulses
    func setRunningSegmentIndex(_ index: Int?) {
        guard runningSegmentIndex != index else { return }

        if index != nil {
            fadeOutUntil = nil
            if pulseSubscription == nil {
                pulseSubscription = Self.composedPulseSubscription { [weak self] v in
                    self?.pulseValue = v
                    self?.needsDisplay = true
                }
            }
            runningSegmentIndex = index
            needsDisplay = true
        } else {
            // Stopping: begin fade-out. Keep subscription alive until fade ends
            // (the fade-out redraw loop in draw(_:) clears it when the fade finishes).
            runningSegmentIndex = nil
            fadeOutUntil = CACurrentMediaTime() + fadeOutDuration
            needsDisplay = true
        }
    }

    /// Compose a `PulseClock` subscription that retains the `observe()` token
    /// alongside the `sink` cancellable, so cancelling one cancels both.
    private static func composedPulseSubscription(
        onValue: @escaping (CGFloat) -> Void
    ) -> AnyCancellable {
        let token = PulseClock.shared.observe()
        let sub = PulseClock.shared.value.sink(receiveValue: onValue)
        return AnyCancellable {
            sub.cancel()
            token.cancel()
        }
    }
```

- [ ] **Step 3: Update the segment-bar drawing loop to render the pulse**

In `draw(_:)`, locate the block that computes `barColor` for each segment (currently around line 501-509). Replace the whole `for (segIdx, segment) in segments.enumerated() { ... }` loop body's color-decision section with:

```swift
        // Compute current pulse effect (including fade-out).
        let now = CACurrentMediaTime()
        let (pulseActiveIndex, pulseEffectAlpha): (Int?, CGFloat) = {
            if let idx = runningSegmentIndex {
                // Actively pulsing. Map clock value [0,1] to visual alpha [0.55, 1.0].
                let a = 0.55 + 0.45 * pulseValue
                return (idx, a)
            }
            if let fadeEnd = fadeOutUntil {
                let remaining = fadeEnd - now
                if remaining > 0 {
                    // Fading: continue from last pulse alpha, taper to 0 over fadeOutDuration.
                    let progress = CGFloat(1.0 - (remaining / fadeOutDuration))  // [0,1]
                    let tail = (0.55 + 0.45 * pulseValue) * (1.0 - progress)
                    return (nil, tail)  // nil idx means fade-out ghost — handled below
                } else {
                    // Fade finished.
                    return (nil, 0)
                }
            }
            return (nil, 0)
        }()

        for (segIdx, segment) in segments.enumerated() {
            // Skip segments that don't overlap the visible line range
            guard segment.endLine >= firstVisibleLine && segment.startLine <= lastVisibleLine else { continue }

            let clampedStart = max(segment.startLine, firstVisibleLine)
            let clampedEnd = min(segment.endLine, lastVisibleLine)

            guard let startEntry = linePositionMap[clampedStart],
                  let endEntry = linePositionMap[clampedEnd] else { continue }

            let barY = startEntry.y + 2
            let barBottom = endEntry.y + endEntry.height - 2
            let barHeight = max(barBottom - barY, 4)

            // Determine bar color
            let barColor: NSColor
            if pulseActiveIndex == segIdx, segIdx >= 0 {
                // Actively pulsing segment: accent color with breathing alpha.
                barColor = NSColor.controlAccentColor.withAlphaComponent(pulseEffectAlpha)
            } else if let resultColor = segmentColors[segIdx] {
                barColor = resultColor
            } else if segIdx == activeSegmentIndex {
                barColor = NSColor.controlAccentColor
            } else {
                barColor = NSColor.tertiaryLabelColor.withAlphaComponent(0.35)
            }

            let barRect = NSRect(x: barX, y: barY, width: segmentBarWidth, height: barHeight)
            barColor.setFill()
            NSBezierPath(roundedRect: barRect, xRadius: 2, yRadius: 2).fill()

            if segIdx == hoveredSegmentIndex {
                drawRunButton(at: barRect, color: barColor)
            }
        }

        // Phantom pulse for direct-SQL execution (no parseable segments).
        if runningSegmentIndex == -1, lineYPositions.count >= 2 {
            let top = lineYPositions.first!.y + 2
            let bottomEntry = lineYPositions.last!
            let bottom = bottomEntry.y + bottomEntry.height - 2
            let phantomRect = NSRect(x: barX, y: top, width: segmentBarWidth, height: max(bottom - top, 4))
            NSColor.controlAccentColor.withAlphaComponent(0.55 + 0.45 * pulseValue).setFill()
            NSBezierPath(roundedRect: phantomRect, xRadius: 2, yRadius: 2).fill()
        }

        // Drive fade-out redraws even when the pulse clock isn't ticking anymore.
        if let fadeEnd = fadeOutUntil {
            let remaining = fadeEnd - now
            if remaining <= 0 {
                fadeOutUntil = nil
                pulseSubscription = nil
            } else {
                // Continue requesting redraws for the fade tail.
                DispatchQueue.main.async { [weak self] in self?.needsDisplay = true }
            }
        }
```

(Replace the existing `for (segIdx, segment)` loop + the tail of `draw(_:)` that starts at "Draw segment bars" / `guard !segments.isEmpty` with this block. The `guard` at the top that early-returns when there are no segments must be relaxed so the phantom pulse can still render when there are no parsed segments — see Step 4.)

- [ ] **Step 4: Relax the no-segments early-return to allow phantom pulse rendering**

Find the guard in `draw(_:)`:

```swift
        // Draw segment bars
        guard !segments.isEmpty, !lineYPositions.isEmpty,
              let firstEntry = lineYPositions.first,
              let lastEntry = lineYPositions.last else { return }
```

Replace with:

```swift
        // Draw segment bars / phantom pulse
        guard !lineYPositions.isEmpty,
              let firstEntry = lineYPositions.first,
              let lastEntry = lineYPositions.last else { return }
```

(The `!segments.isEmpty` guard was blocking the phantom path. `firstVisibleLine` / `lastVisibleLine` computed below still work with empty segments.)

- [ ] **Step 5: Verify it compiles**

Run: `cd /Users/nfinn/Projects/aSideProjects/Pharos && xcodebuild -project Pharos.xcodeproj -scheme Pharos -configuration Debug build 2>&1 | tail -20`
Expected: Build succeeds.

- [ ] **Step 6: Commit**

```bash
git add Pharos/Editor/LineNumberGutter.swift
git commit -m "add-pulse-rendering-to-LineNumberGutter"
```

---

### Task 5: Forward tab-executing state from `EditorPaneVC` to the gutter

**Files:**
- Modify: `Pharos/ViewControllers/QueryEditorVC.swift`
- Modify: `Pharos/ViewControllers/EditorPaneVC.swift`

- [ ] **Step 1: Add a public gutter passthrough on `QueryEditorVC`**

In `Pharos/ViewControllers/QueryEditorVC.swift`, add a new public method near the other gutter passthroughs (`setSegmentResultColor`, `clearSegmentResultColors`):

```swift
    /// Forward the tab's running-segment index to the gutter. Pass nil to stop pulsing.
    func setRunningSegmentIndex(_ index: Int?) {
        gutter?.setRunningSegmentIndex(index)
    }
```

- [ ] **Step 2: Observe `$tabs` in `EditorPaneVC` and push the state to the gutter**

In `Pharos/ViewControllers/EditorPaneVC.swift`, find the existing `$tabs` subscription (around line 153):

```swift
        stateManager.$tabs
            .receive(on: RunLoop.main)
            .sink { [weak self] _ in
                self?.refreshTabBar()
                self?.updateEditorToolbarState()
                self?.rebuildConnectionMenu()
                self?.rebuildSchemaMenu()
            }
            .store(in: &cancellables)
```

Replace with:

```swift
        stateManager.$tabs
            .receive(on: RunLoop.main)
            .sink { [weak self] tabs in
                guard let self else { return }
                self.refreshTabBar()
                self.updateEditorToolbarState()
                self.rebuildConnectionMenu()
                self.rebuildSchemaMenu()
                self.updateGutterPulseForActiveTab(tabs: tabs)
            }
            .store(in: &cancellables)
```

- [ ] **Step 3: Add the `updateGutterPulseForActiveTab` helper**

Anywhere in the `EditorPaneVC` class body (e.g. after the `refreshTabBar` method), add:

```swift
    /// Read the pane's active tab from the tabs array and push its running-segment
    /// index to the gutter (or `nil` if the tab isn't executing).
    private func updateGutterPulseForActiveTab(tabs: [QueryTab]) {
        guard let activeTabId = stateManager.panes.first(where: { $0.id == paneId })?.activeTabId,
              let tab = tabs.first(where: { $0.id == activeTabId }) else {
            editorVC.setRunningSegmentIndex(nil)
            return
        }
        editorVC.setRunningSegmentIndex(tab.isExecuting ? tab.runningSegmentIndex : nil)
    }
```

- [ ] **Step 4: Also push state when the active tab within the pane changes**

Find the `tabChanged(from:to:)` method in `EditorPaneVC` (around line 265). At the end of its body, after `editorVC.setSQL(tab.sql)` and related setup, add:

```swift
        // Sync gutter pulse to the newly-activated tab.
        editorVC.setRunningSegmentIndex(tab.isExecuting ? tab.runningSegmentIndex : nil)
```

(Place it just before the method's closing brace, after the existing tab-swap setup lines.)

- [ ] **Step 5: Verify it compiles**

Run: `cd /Users/nfinn/Projects/aSideProjects/Pharos && xcodebuild -project Pharos.xcodeproj -scheme Pharos -configuration Debug build 2>&1 | tail -20`
Expected: Build succeeds.

- [ ] **Step 6: Commit**

```bash
git add Pharos/ViewControllers/QueryEditorVC.swift Pharos/ViewControllers/EditorPaneVC.swift
git commit -m "forward-running-segment-state-from-pane-to-gutter"
```

---

### Task 6: Add pulse support to `ResultsToolbarBar`

**Files:**
- Modify: `Pharos/ViewControllers/ResultsGridVC.swift` (the `ResultsToolbarBar` class at the bottom)

- [ ] **Step 1: Import Combine and add pulse state**

At the top of `Pharos/ViewControllers/ResultsGridVC.swift`, confirm `import Combine` is present. If not, add it.

Inside the `ResultsToolbarBar` class, just below the existing `drawsBottomSeparator` and `contentViewController` declarations, add:

```swift
    /// Whether the top separator should pulse in the accent color (query running in focused tab).
    var isPulsing: Bool = false {
        didSet {
            guard oldValue != isPulsing else { return }
            if isPulsing {
                startPulseSubscription()
            } else {
                beginPulseFadeOut()
            }
            needsDisplay = true
        }
    }

    private var pulseSubscription: AnyCancellable?
    private var pulseValue: CGFloat = 1.0
    private var fadeOutUntil: CFTimeInterval?
    private let fadeOutDuration: CFTimeInterval = 0.25

    private func startPulseSubscription() {
        fadeOutUntil = nil
        guard pulseSubscription == nil else { return }
        let token = PulseClock.shared.observe()
        let sub = PulseClock.shared.value.sink { [weak self] v in
            self?.pulseValue = v
            self?.needsDisplay = true
        }
        pulseSubscription = AnyCancellable {
            sub.cancel()
            token.cancel()
        }
    }

    private func beginPulseFadeOut() {
        fadeOutUntil = CACurrentMediaTime() + fadeOutDuration
    }
```

- [ ] **Step 2: Blend the top-separator color in `draw(_:)`**

In `ResultsToolbarBar.draw(_:)`, locate the block that strokes the top separator (currently uses `NSColor.separatorColor.setStroke()` then strokes `topPath`). Replace:

```swift
        // Top separator line
        NSColor.separatorColor.setStroke()
        let topPath = NSBezierPath()
        topPath.move(to: NSPoint(x: bounds.minX, y: bounds.maxY - 0.5))
        topPath.line(to: NSPoint(x: bounds.maxX, y: bounds.maxY - 0.5))
        topPath.stroke()
```

With:

```swift
        // Top separator line — blended with accent color when pulsing (or during fade-out).
        let now = CACurrentMediaTime()
        let pulseAlpha: CGFloat = {
            if isPulsing {
                return 0.55 + 0.45 * pulseValue
            }
            if let fadeEnd = fadeOutUntil {
                let remaining = fadeEnd - now
                if remaining > 0 {
                    let progress = CGFloat(1.0 - (remaining / fadeOutDuration))
                    return (0.55 + 0.45 * pulseValue) * (1.0 - progress)
                }
            }
            return 0
        }()

        let baseColor = NSColor.separatorColor
        let topStroke: NSColor
        if pulseAlpha > 0 {
            // Blend accent (at pulseAlpha) over the base separator color.
            topStroke = NSColor.controlAccentColor.withAlphaComponent(pulseAlpha)
            baseColor.setStroke()
            let basePath = NSBezierPath()
            basePath.move(to: NSPoint(x: bounds.minX, y: bounds.maxY - 0.5))
            basePath.line(to: NSPoint(x: bounds.maxX, y: bounds.maxY - 0.5))
            basePath.stroke()
            topStroke.setStroke()
        } else {
            topStroke = baseColor
            topStroke.setStroke()
        }
        let topPath = NSBezierPath()
        topPath.move(to: NSPoint(x: bounds.minX, y: bounds.maxY - 0.5))
        topPath.line(to: NSPoint(x: bounds.maxX, y: bounds.maxY - 0.5))
        topPath.stroke()

        // Drive fade-out redraws.
        if let fadeEnd = fadeOutUntil {
            if fadeEnd - now <= 0 {
                fadeOutUntil = nil
                pulseSubscription = nil
            } else {
                DispatchQueue.main.async { [weak self] in self?.needsDisplay = true }
            }
        }
```

- [ ] **Step 3: Verify it compiles**

Run: `cd /Users/nfinn/Projects/aSideProjects/Pharos && xcodebuild -project Pharos.xcodeproj -scheme Pharos -configuration Debug build 2>&1 | tail -20`
Expected: Build succeeds.

- [ ] **Step 4: Commit**

```bash
git add Pharos/ViewControllers/ResultsGridVC.swift
git commit -m "add-pulse-support-to-ResultsToolbarBar"
```

---

### Task 7: Wire `ContentViewController` to drive `actionBar.isPulsing`

**Files:**
- Modify: `Pharos/ViewControllers/ContentViewController.swift`

- [ ] **Step 1: Find existing Combine subscriptions**

In `Pharos/ViewControllers/ContentViewController.swift`, locate the area where `stateManager.$panes` is subscribed (around line 231). Confirm there is a `cancellables` set already (there is — see `private var cancellables = Set<AnyCancellable>()` near the top).

- [ ] **Step 2: Add a subscription that computes `actionBar.isPulsing` from `($tabs, $panes, $focusedPaneId)`**

Near the other Combine subscriptions in `viewDidLoad` (or equivalent setup method), add:

```swift
        // Drive the action-bar pulse from the focused pane's active tab's executing state.
        Publishers.CombineLatest3(
            stateManager.$tabs,
            stateManager.$panes,
            stateManager.$focusedPaneId
        )
        .receive(on: RunLoop.main)
        .sink { [weak self] tabs, panes, focusedPaneId in
            guard let self else { return }
            let focusedPane = panes.first { $0.id == focusedPaneId }
            let activeTabId = focusedPane?.activeTabId
            let activeTab = tabs.first { $0.id == activeTabId }
            self.actionBar.isPulsing = activeTab?.isExecuting == true
        }
        .store(in: &cancellables)
```

(Place it alongside the existing subscription blocks — grep for `stateManager.$panes` or `stateManager.$tabs` to find the right neighborhood.)

- [ ] **Step 3: Verify it compiles and the right properties are referenced**

Run: `cd /Users/nfinn/Projects/aSideProjects/Pharos && xcodebuild -project Pharos.xcodeproj -scheme Pharos -configuration Debug build 2>&1 | tail -20`
Expected: Build succeeds.

- [ ] **Step 4: Commit**

```bash
git add Pharos/ViewControllers/ContentViewController.swift
git commit -m "drive-action-bar-pulse-from-focused-tab-executing-state"
```

---

### Task 8: Add pulsing dot overlay to `PaneTabBar` and remove `⟳` prefix

**Files:**
- Modify: `Pharos/Views/PaneTabBar.swift`

- [ ] **Step 1: Remove the `⟳` prefix from `segmentLabel(for:)`**

Find the method at line 282:

```swift
    private func segmentLabel(for tab: QueryTab) -> String {
        if tab.isExecuting {
            return "⟳ \(tab.name)"
        } else if tab.isDirty {
            return "• \(tab.name)"
        }
        return tab.name
    }
```

Replace with:

```swift
    private func segmentLabel(for tab: QueryTab) -> String {
        if tab.isDirty {
            return "• \(tab.name)"
        }
        return tab.name
    }
```

- [ ] **Step 2: Add a non-interactive overlay view that draws pulsing dots**

Near the bottom of `Pharos/Views/PaneTabBar.swift` (after the `PaneTabBar` class definition but still in the same file), add a new overlay class:

```swift
/// Non-interactive overlay drawn on top of the segmented control. Renders a small
/// pulsing accent-color dot on each segment whose tab is currently executing.
/// Click-through is preserved via `hitTest(_:) -> nil`.
final class PaneTabBarPulseOverlay: NSView {
    private var executingSegmentIndexes: Set<Int> = []
    private var segmentFrames: [NSRect] = []
    private var pulseSubscription: AnyCancellable?
    private var pulseValue: CGFloat = 1.0

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        wantsLayer = true
    }
    required init?(coder: NSCoder) { fatalError() }

    override func hitTest(_ point: NSPoint) -> NSView? { nil }

    /// Update which segments have executing tabs, plus the per-segment frames.
    func update(executingIndexes: Set<Int>, segmentFrames: [NSRect]) {
        self.executingSegmentIndexes = executingIndexes
        self.segmentFrames = segmentFrames

        if !executingIndexes.isEmpty, pulseSubscription == nil {
            let token = PulseClock.shared.observe()
            let sub = PulseClock.shared.value.sink { [weak self] v in
                self?.pulseValue = v
                self?.needsDisplay = true
            }
            pulseSubscription = AnyCancellable {
                sub.cancel()
                token.cancel()
            }
        } else if executingIndexes.isEmpty {
            pulseSubscription = nil
        }

        needsDisplay = true
    }

    override func draw(_ dirtyRect: NSRect) {
        guard !executingSegmentIndexes.isEmpty else { return }

        let dotSize: CGFloat = 6
        let leftPad: CGFloat = 8
        let alpha: CGFloat = 0.55 + 0.45 * pulseValue
        NSColor.controlAccentColor.withAlphaComponent(alpha).setFill()

        for idx in executingSegmentIndexes {
            guard idx >= 0, idx < segmentFrames.count else { continue }
            let segFrame = segmentFrames[idx]
            let dotRect = NSRect(
                x: segFrame.minX + leftPad,
                y: segFrame.midY - dotSize / 2,
                width: dotSize,
                height: dotSize
            )
            NSBezierPath(ovalIn: dotRect).fill()
        }
    }
}
```

Make sure `import Combine` is present at the top of the file; add it if not.

- [ ] **Step 3: Instantiate, lay out, and update the overlay in `PaneTabBar`**

In the `PaneTabBar` class, add an overlay property alongside `closeButtons`:

```swift
    /// Overlay that draws pulsing dots on segments whose tabs are executing.
    private let pulseOverlay = PaneTabBarPulseOverlay()
```

In `setup()` (after `segmentedControl` is added to the view hierarchy), add:

```swift
        pulseOverlay.translatesAutoresizingMaskIntoConstraints = true
        addSubview(pulseOverlay)
```

In `layoutSubviews()` — at the end of the method, after `layoutCloseButtons()` — add:

```swift
        // Overlay covers the same frame as the segmented control.
        pulseOverlay.frame = segmentedControl.frame
```

In `rebuildSegments()` — at the very end, after `needsDisplay = true` — add:

```swift
        refreshPulseOverlay()
```

Add the refresh method near the other private helpers:

```swift
    private func refreshPulseOverlay() {
        // Compute executing indexes.
        var executing: Set<Int> = []
        for (i, tab) in tabs.enumerated() where tab.isExecuting {
            executing.insert(i)
        }

        // Compute per-segment frames in overlay-local coordinates (overlay shares
        // segmentedControl's frame, so origin is zero-relative to the overlay).
        var frames: [NSRect] = []
        var x: CGFloat = 0
        let height = segmentedControl.bounds.height
        for i in 0..<segmentedControl.segmentCount {
            let w = segmentedControl.width(forSegment: i)
            frames.append(NSRect(x: x, y: 0, width: w, height: height))
            x += w
        }

        pulseOverlay.update(executingIndexes: executing, segmentFrames: frames)
    }
```

- [ ] **Step 4: Verify it compiles**

Run: `cd /Users/nfinn/Projects/aSideProjects/Pharos && xcodebuild -project Pharos.xcodeproj -scheme Pharos -configuration Debug build 2>&1 | tail -20`
Expected: Build succeeds.

- [ ] **Step 5: Commit**

```bash
git add Pharos/Views/PaneTabBar.swift
git commit -m "add-pulsing-dot-overlay-to-PaneTabBar"
```

---

### Task 9: Manual verification

**Files:**
- None (manual testing only).

- [ ] **Step 1: Run the app against a test database**

```bash
cd /Users/nfinn/Projects/aSideProjects/Pharos
xcodebuild -project Pharos.xcodeproj -scheme Pharos -configuration Debug build
open Pharos.xcodeproj   # then Cmd+R to launch
```

Connect to a PostgreSQL database.

- [ ] **Step 2: Happy path — single running query**

In a fresh tab, type:

```sql
SELECT pg_sleep(3);
```

Press Cmd+Return. Observe:

- The gutter bar for that segment pulses in accent color (blue breathing).
- The top separator line of the action bar (between editor and results) pulses in sync.
- The tab's dot appears in the tab bar and pulses in sync.
- After ~3s, all three fade out smoothly (no snap).

Expected: PASS if all three surfaces breathe together at ~1.2s period, synchronized.

- [ ] **Step 3: Multi-segment editor**

In one tab, type:

```sql
SELECT 1;

SELECT pg_sleep(3);

SELECT 2;
```

Click the run button on the middle segment (the `pg_sleep`). Observe:

- Only the middle segment's bar pulses.
- Other segment bars remain in their normal color.
- Action bar separator and tab dot pulse in sync.

Expected: PASS if pulse is scoped to only the running segment.

- [ ] **Step 4: Multi-pane concurrency**

Open a second editor pane (via the `+` pane button or existing UI). In each pane, in separate tabs, run `SELECT pg_sleep(5);` nearly simultaneously. Observe:

- Both gutters pulse independently.
- The action bar separator reflects only the focused pane — click into the other pane and the pulse should follow focus (or at least remain tied to the focused pane's active tab).
- Both tabs' dots pulse in the tab bar.

Expected: PASS.

- [ ] **Step 5: Background-tab awareness**

In a single pane with two tabs, start `SELECT pg_sleep(10);` in Tab 1, then click Tab 2. Observe:

- Tab 1's dot continues to pulse in the tab bar while Tab 2 is active.
- The gutter (now showing Tab 2's empty editor) is idle.
- The action bar separator is idle (Tab 2 is the focused tab, not executing).
- When you switch back to Tab 1 while it's still running, gutter + action bar resume pulsing.

Expected: PASS.

- [ ] **Step 6: Error path**

In a tab, run:

```sql
SELECT * FROM this_table_does_not_exist;
```

Observe: pulse fades out cleanly on error, red error dot appears, no stuck/frozen pulse.

Expected: PASS.

- [ ] **Step 7: Cancellation**

Run `SELECT pg_sleep(30);`, click the Stop Query button. Observe: pulse fades out cleanly on cancellation.

Expected: PASS.

- [ ] **Step 8: Reduce Motion**

Open `System Settings → Accessibility → Display → Reduce motion` and enable it. Without restarting the app, run `SELECT pg_sleep(3);`. Observe:

- All three surfaces show the peak accent color statically for the duration (no breathing).
- On completion, they disappear without fade.

Disable Reduce Motion and confirm pulse resumes on next query.

Expected: PASS.

- [ ] **Step 9: Idle CPU check**

With no queries running and the app visible/foregrounded, check Activity Monitor: Pharos CPU should be near zero (well under 1%). Reason: `PulseClock` should have observer count 0 when idle, and the `CVDisplayLink` should be stopped.

Expected: PASS if CPU is near idle. If the app is burning CPU at idle, there's a reference-counting bug in `PulseClock.stop()` — investigate.

- [ ] **Step 10: Final commit of any manual-verification tweaks**

If any step above surfaced a bug, fix it, re-verify, and commit with a descriptive message. If all steps pass cleanly, no final commit needed.

```bash
git log --oneline -n 10   # review the chain of commits
```

---

## Summary

This plan implements a coordinated three-surface query-running animation with minimal new infrastructure:

- **1 new file** (`PulseClock.swift`, ~80 lines)
- **5 modified files** (`QueryTab.swift`, `ContentViewController.swift`, `LineNumberGutter.swift`, `QueryEditorVC.swift`, `EditorPaneVC.swift`, `ResultsGridVC.swift`, `PaneTabBar.swift`)
- **9 atomic commits** (one per task)
- **Zero new dependencies**
- **Respects Reduce Motion** accessibility preference out of the box

All surfaces share a single `PulseClock` instance for phase-synchronized animation and zero-cost idle.
