# Result-Tab Highlight Re-Resolve Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Keep a result tab's source-query highlight and gutter dot alive across unrelated editor edits by re-resolving the originally-executed SQL against the current parsed segments, debounced 250 ms on edit and flushed immediately on selection or editor-tab switch.

**Architecture:** A single pure helper (`ResultTabResolver`) locates the segment in the current parse whose text matches a result tab's stored SQL, picking the segment closest to the last known location on multiple matches. `ContentViewController` owns a debounced re-resolve pass that updates every result tab's `segmentIndex` / `lineRange` / `isStale` and repaints gutter colors and tab-bar staleness. Three call sites trigger it: editor edits (debounced), result-tab selection (immediate), and editor-tab switch (immediate). The blunt `markResultTabsStale()` path is deleted.

**Tech Stack:** Swift / AppKit. No Rust changes. No new dependencies.

**Spec reference:** `docs/superpowers/specs/2026-05-21-result-tab-highlight-resolve-design.md`

**Testing note:** This project has no XCTest target. Verification is build-clean + eyeball-check of the pure resolver against the table in Task 1 + manual smoke test pass against the spec checklist in Task 3.

---

### Task 1: `ResultTabResolver` pure helper

**Files:**
- Create: `Pharos/ViewControllers/ResultTabResolver.swift`

- [ ] **Step 1: Create the resolver**

Create `Pharos/ViewControllers/ResultTabResolver.swift`:

```swift
import Foundation

/// Pure helper that locates the SQL segment in the current editor parse
/// corresponding to a previously-executed result tab.
///
/// Match rule: a candidate segment matches when its `.sql` (already trimmed
/// by the parser) equals the result tab's stored SQL after the same
/// trim-whitespace normalization on both sides. On multiple candidates,
/// pick the one whose line midpoint is closest to the previous line range.
/// Ties go to the smaller `index` for deterministic behavior.
enum ResultTabResolver {

    struct Outcome: Equatable {
        let segmentIndex: Int
        let lineRange: ClosedRange<Int>
    }

    static func resolve(
        sql: String,
        previousLineRange: ClosedRange<Int>,
        in segments: [SQLSegment]
    ) -> Outcome? {
        let needle = sql.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !needle.isEmpty else { return nil }

        let matches = segments.filter {
            $0.sql.trimmingCharacters(in: .whitespacesAndNewlines) == needle
        }
        guard !matches.isEmpty else { return nil }

        if matches.count == 1 {
            let m = matches[0]
            return Outcome(segmentIndex: m.index, lineRange: m.startLine...m.endLine)
        }

        let prevMid = Double(previousLineRange.lowerBound + previousLineRange.upperBound) / 2.0

        let chosen = matches.min { a, b in
            let aMid = Double(a.startLine + a.endLine) / 2.0
            let bMid = Double(b.startLine + b.endLine) / 2.0
            let aDist = abs(aMid - prevMid)
            let bDist = abs(bMid - prevMid)
            if aDist != bDist { return aDist < bDist }
            return a.index < b.index
        }!

        return Outcome(segmentIndex: chosen.index, lineRange: chosen.startLine...chosen.endLine)
    }
}
```

- [ ] **Step 2: Register the new file with XcodeGen**

```bash
cd /Users/nfinn/Projects/aSideProjects/Pharos && xcodegen generate
```

Expected: `Created project at .../Pharos.xcodeproj`.

- [ ] **Step 3: Build**

```bash
cd /Users/nfinn/Projects/aSideProjects/Pharos && xcodebuild build -project Pharos.xcodeproj -scheme Pharos -configuration Debug -quiet
```

Expected: build succeeds.

- [ ] **Step 4: Eyeball-verify the resolver**

Walk through these cases against the function body:

| `sql` | `previousLineRange` | `segments` (index, sql, startLine, endLine) | Expected `Outcome` |
|---|---|---|---|
| `"SELECT 1"` | `1...1` | `[(0, "SELECT 1", 1, 1)]` | `(0, 1...1)` — single match |
| `"SELECT 1"` | `1...1` | `[(0, "SELECT 2", 1, 1)]` | `nil` — no match |
| `"SELECT 1"` | `1...1` | `[]` | `nil` — empty |
| `"SELECT 1"` | `6...6` | `[(0, "SELECT 1", 1, 1), (1, "SELECT 1", 9, 9)]` | `(1, 9...9)` — mid 6 distance 3 to mid 9, distance 5 to mid 1 |
| `"SELECT 1"` | `3...3` | `[(0, "SELECT 1", 1, 1), (1, "SELECT 1", 5, 5)]` | `(0, 1...1)` — both at distance 2; smaller `index` wins |
| `" SELECT 1 "` | `1...1` | `[(0, "SELECT 1", 1, 1)]` | `(0, 1...1)` — trim normalizes both sides |
| `""` | `1...1` | `[(0, "SELECT 1", 1, 1)]` | `nil` — empty needle guard |

Each row should match what the algorithm produces by hand. If any disagrees, fix the function before committing.

- [ ] **Step 5: Commit**

```bash
git add Pharos/ViewControllers/ResultTabResolver.swift Pharos.xcodeproj
git commit -m "add ResultTabResolver pure helper for re-locating result-tab source segments"
```

---

### Task 2: Wire re-resolve into ContentViewController

**Files:**
- Modify: `Pharos/ViewControllers/ContentViewController.swift`

This task replaces the existing "any edit → all stale" path with the new debounced-re-resolve path. There are five interconnected edits, so this is a single task to avoid landing the codebase in an inconsistent intermediate state.

- [ ] **Step 1: Add the `pendingReResolveWorkItem` property and `reResolveAllResultTabs` method**

Find the existing `// MARK: - Result Tab Management` section in `Pharos/ViewControllers/ContentViewController.swift` (around line 1122). Locate the `private func markResultTabsStale()` method (around line 1213). Replace `markResultTabsStale()` (the entire method, lines 1212–1219) with:

```swift
    /// Pending debounced re-resolve work item, cancellable when a new edit
    /// arrives or when a caller wants an immediate flush.
    private var pendingReResolveWorkItem: DispatchWorkItem?

    /// Re-resolve every result tab's source segment against the current
    /// parsed editor segments. Updates each tab's `segmentIndex`, `lineRange`,
    /// and `isStale`, then repaints gutter colors and the result-tab bar.
    ///
    /// - Parameter immediate: when `true`, runs synchronously and cancels any
    ///   pending debounce; when `false`, schedules a 250 ms debounced run.
    private func reResolveAllResultTabs(immediate: Bool = false) {
        pendingReResolveWorkItem?.cancel()
        pendingReResolveWorkItem = nil

        let body: () -> Void = { [weak self] in
            guard let self else { return }
            let text = self.focusedPaneVC?.getSQL() ?? ""
            let segments = SQLSegmentParser.parse(text)

            for i in self.resultTabs.indices {
                let tab = self.resultTabs[i]
                if let outcome = ResultTabResolver.resolve(
                    sql: tab.sql,
                    previousLineRange: tab.lineRange,
                    in: segments
                ) {
                    self.resultTabs[i].segmentIndex = outcome.segmentIndex
                    self.resultTabs[i].lineRange = outcome.lineRange
                    self.resultTabs[i].isStale = false
                } else {
                    self.resultTabs[i].isStale = true
                }
            }

            self.focusedPaneVC?.clearSegmentColors()
            for tab in self.resultTabs where !tab.isStale {
                self.focusedPaneVC?.setSegmentColor(tab.color, forSegmentIndex: tab.segmentIndex)
            }

            self.resultTabBar.update(tabs: self.resultTabs, activeTabId: self.activeResultTabId)
        }

        if immediate {
            body()
        } else {
            let item = DispatchWorkItem(block: body)
            pendingReResolveWorkItem = item
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.25, execute: item)
        }
    }
```

- [ ] **Step 2: Switch `editorPane(_:didEditText:)` to the debounced re-resolve**

Find this method (search for `editorPane(_ pane: EditorPaneVC, didEditText paneId:`, around line 1374):

```swift
    func editorPane(_ pane: EditorPaneVC, didEditText paneId: String) {
        markResultTabsStale()
```

Replace its `markResultTabsStale()` call with `reResolveAllResultTabs()`. The method should now look like:

```swift
    func editorPane(_ pane: EditorPaneVC, didEditText paneId: String) {
        reResolveAllResultTabs()
```

(Leave any other lines in the method's body untouched.)

- [ ] **Step 3: Make `selectResultTab` flush re-resolve immediately**

Find `private func selectResultTab(_ tabId: String)` (around line 1140). Add `reResolveAllResultTabs(immediate: true)` as the very first line of the method body, before any other code:

```swift
    private func selectResultTab(_ tabId: String) {
        reResolveAllResultTabs(immediate: true)

        // Capture outgoing result tab's grid state
        ... existing body unchanged ...
    }
```

Do NOT remove the existing `if !tab.isStale { focusedPaneVC?.highlightLines(tab.lineRange) }` guard around line 1165 — it still correctly skips highlighting on truly-stale tabs (and `isStale` is now accurate because re-resolve just ran).

- [ ] **Step 4: Replace the editor-tab-switch segment-color loop**

Find the block around line 483–487 (inside the editor-tab-switch handler — search for `clearSegmentColors()` to locate it):

```swift
        // Restore segment colors in the gutter
        focusedPaneVC?.clearSegmentColors()
        for rt in resultTabs where !rt.isStale {
            focusedPaneVC?.setSegmentColor(rt.color, forSegmentIndex: rt.segmentIndex)
        }
```

Replace those four lines with:

```swift
        // Re-resolve and restore segment colors in the gutter.
        reResolveAllResultTabs(immediate: true)
```

- [ ] **Step 5: Verify `markResultTabsStale` is fully gone**

Search the file for any remaining references:

```bash
grep -n "markResultTabsStale" Pharos/ViewControllers/ContentViewController.swift
```

Expected: no results. (Step 1 deleted the definition; Step 2 was its only call site.)

- [ ] **Step 6: Build**

```bash
cd /Users/nfinn/Projects/aSideProjects/Pharos && xcodebuild build -project Pharos.xcodeproj -scheme Pharos -configuration Debug -quiet
```

Expected: build succeeds.

- [ ] **Step 7: Commit**

```bash
git add Pharos/ViewControllers/ContentViewController.swift
git commit -m "re-resolve result tabs against current segments on edit (debounced), selection, and tab switch"
```

---

### Task 3: Manual smoke-test pass

**Files:** (none; verification only)

- [ ] **Step 1: Run the spec's smoke test checklist**

Build & run the app (Cmd+R in Xcode). Connect to any database and walk through these scenarios from the spec's testing section:

1. **Basic preserve.** Type `SELECT 1;` on line 1, ⌘↩ to run → result tab A. Add `SELECT 2;` on line 3, ⌘↩ → result tab B. Click A → line 1 highlights, A's dot full. Click B → line 3 highlights, B's dot full.
2. **Migrate on insert above.** Continuing from (1): place cursor at the start of line 1 and press Enter to push everything down. Wait ¼ s. Click A → highlights the line where `SELECT 1;` now lives. Click B → highlights the line where `SELECT 2;` now lives.
3. **Go stale on edit.** Edit `SELECT 1;` to `SELECT 1, 2;`. Wait ¼ s. A's tab-bar dot dims; clicking A no longer highlights.
4. **Stale on delete.** Delete the line containing `SELECT 2;`. Wait ¼ s. B's tab-bar dot dims; clicking B no longer highlights.
5. **Recover on paste.** Paste `SELECT 2;` back at a different line. Wait ¼ s. B's dot brightens; clicking B highlights the new location.
6. **Closest-match wins.** With `SELECT 1, 2;` from (3) reverted to `SELECT 1;`, duplicate `SELECT 1;` to line 20. Click A → line 1 still highlights (closer to A's previous `lineRange` than line 20).
7. **Immediate flush on selection.** Type rapidly in the editor; within the 250 ms window, click result tab A. Re-resolve flushes immediately, highlight is correct, no flicker.
8. **Editor-tab switch.** Open a second editor tab (⌘T), type some queries there, switch back to the first tab. Gutter dots and highlight on the first tab are correct without waiting for a debounce.

Each scenario should match the expected behavior described. If any scenario fails, return to Task 2 (the wiring) and diagnose — the resolver is pure and was eyeball-verified in Task 1.

- [ ] **Step 2: No-op commit if needed**

Any fixes that emerge from Step 1 should be amended into Task 2 with their own commits. This task itself produces no commit if all scenarios pass on the first run.

---

## Self-Review Notes

- **Spec coverage:**
  - Match semantics (exact + segment-aligned + trim normalization): Task 1 resolver + Task 3 scenario 6.
  - Closest-match disambiguation: Task 1 eyeball table rows 4–5 + Task 3 scenario 6.
  - Debounced eager re-resolve on edit (250 ms): Task 2 step 2.
  - Immediate flush on result-tab selection: Task 2 step 3.
  - Immediate flush on editor-tab switch: Task 2 step 4.
  - Gutter color repaint: Task 2 step 1 (inside `body` closure).
  - Tab-bar staleness indicator update: Task 2 step 1 (`resultTabBar.update`).
  - Deletion of `markResultTabsStale`: Task 2 step 1 (replaced by the new method) + step 5 (verify).
- **No placeholders:** every step has concrete code or concrete commands.
- **Type consistency:** `ResultTabResolver.Outcome.segmentIndex` and `lineRange` map directly to existing `ResultTab.segmentIndex` and `ResultTab.lineRange`. `SQLSegment.sql` / `index` / `startLine` / `endLine` match the parser's public API as verified pre-plan.
- **No XCTest target:** consistent with the project's existing pattern; pure-helper verification is by eyeball table.
