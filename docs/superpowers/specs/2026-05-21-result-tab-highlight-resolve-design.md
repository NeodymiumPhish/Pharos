# Result-Tab Highlight Re-Resolve — Design

**Date:** 2026-05-21
**Status:** Draft for review

## Goal

Selecting a result tab in the results panel should continue to highlight the source query in the editor as long as that exact query (as a parsed SQL segment) still exists somewhere in the editor — regardless of unrelated edits.

Today, any edit anywhere in the editor flips every result tab to `isStale`, which suppresses both the line highlight (`highlightLines(tab.lineRange)`) and the gutter dot. Result tabs become "useless" as a navigation aid after the first keystroke.

## Non-Goals

- Persisting result tabs across sessions.
- "Smart" partial matching (substring, fuzzy, whitespace-normalized, token-level).
- Eagerly re-resolving on every keystroke without debounce.
- Reworking how queries are executed or how segments are parsed.

## User-Facing Behavior

- A result tab is **non-stale** (full-color dot, clickable highlight) iff the editor currently contains a parsed SQL segment whose text exactly matches the SQL that produced the result.
- Selecting a non-stale result tab scrolls to and highlights the lines that currently contain the matching segment — even if those lines have shifted because of edits elsewhere.
- If the matching SQL has been deleted or modified, the result tab becomes stale: its dot dims in the tab bar, and selection no longer highlights anything.
- If the matching SQL is re-introduced (e.g., paste it back), the result tab becomes non-stale again on the next re-resolve.
- Re-resolve runs **eagerly** with a 250 ms debounce after edits, and **immediately** on result-tab selection and editor-tab switch.

## Architecture

### Match Semantics

Two design questions, locked:

1. **What counts as "the same SQL"?** Exact-string match, with the constraint that the match must align with a parsed SQL statement (a segment). `EXPLAIN ANALYZE SELECT * FROM users;` is a different segment from `SELECT * FROM users;` — they do not match.
2. **Disambiguation on multiple matches:** Pick the segment whose line range is closest (by midpoint distance) to the result tab's previous `lineRange`. Ties broken by smaller segment `index`.

### Components Touched

| Component | Change |
|---|---|
| **New** `Pharos/ViewControllers/ResultTabResolver.swift` | Pure resolver — input: SQL text + previous line range + parsed segments; output: new `(segmentIndex, lineRange)` or `nil` if stale |
| `Pharos/ViewControllers/ContentViewController.swift` | Add `reResolveAllResultTabs(immediate:)` method, debounced re-resolve scheduling on edit, call sites in `selectResultTab` and the editor-tab-switch path; delete `markResultTabsStale()` |
| `Pharos/Models/ResultTab.swift` | No structural change — `segmentIndex`, `lineRange`, and `isStale` already exist and are mutated by the resolver call sites |

No Rust changes. No new dependencies. No FFI.

### The Pure Resolver

`Pharos/ViewControllers/ResultTabResolver.swift`:

```swift
import Foundation

enum ResultTabResolver {
    struct Outcome: Equatable {
        let segmentIndex: Int
        let lineRange: ClosedRange<Int>
    }

    /// Locate the segment in `segments` whose text matches `sql` and that is
    /// closest to `previousLineRange`. Returns `nil` if no segment matches.
    static func resolve(
        sql: String,
        previousLineRange: ClosedRange<Int>,
        in segments: [SQLSegment]
    ) -> Outcome?
}
```

**Algorithm:**

1. Normalize `sql` (trim leading/trailing whitespace). Apply the same normalization to each `segment.text`. Anything more aggressive (whitespace collapse, comment stripping) is out of scope.
2. Filter `segments` to those whose normalized text equals normalized `sql`.
3. If zero matches → return `nil` (result tab is truly stale).
4. If one match → return its `(index, startLine...endLine)`.
5. If >1, compute midpoint distance: `abs(midpoint(segment) − midpoint(previousLineRange))`. Pick the smallest. On ties, the segment with smaller `index` wins (deterministic, stable even when two segments share line ranges).
6. Return the chosen segment's `(index, startLine...endLine)`.

### Debounced Re-Resolve

`ContentViewController` gains:

```swift
private var pendingReResolveWorkItem: DispatchWorkItem?

private func reResolveAllResultTabs(immediate: Bool = false) {
    pendingReResolveWorkItem?.cancel()
    pendingReResolveWorkItem = nil

    let body: () -> Void = { [weak self] in
        guard let self else { return }
        let text = self.focusedPaneVC?.getSQL() ?? ""
        let segments = SQLSegmentParser.parse(text)  // existing parser

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

        // Repaint gutter colors.
        self.focusedPaneVC?.clearSegmentColors()
        for tab in self.resultTabs where !tab.isStale {
            self.focusedPaneVC?.setSegmentColor(tab.color, forSegmentIndex: tab.segmentIndex)
        }

        // Refresh tab-bar dot states.
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

### Call Sites

| Trigger | Call |
|---|---|
| `editorPane(_:didEditText:)` | `reResolveAllResultTabs()` *(debounced)* — replaces the existing `markResultTabsStale()` call |
| `selectResultTab(_:)` (first statement) | `reResolveAllResultTabs(immediate: true)` |
| Editor-tab switch path (currently around line 484, where `clearSegmentColors()` + `setSegmentColor` loop runs) | `reResolveAllResultTabs(immediate: true)` — this *replaces* the existing loop because the resolver call handles gutter color repainting |

The `if !tab.isStale` guard around `focusedPaneVC?.highlightLines(tab.lineRange)` at line 1166 is **kept** — re-resolve has just run with `immediate: true`, so `isStale` accurately reflects current editor state. The guard ensures we don't highlight a stale tab.

### Deleted Code

- `markResultTabsStale()` — its responsibility is fully owned by the re-resolve path.
- The body of the segment-color restoration loop in the editor-tab-switch path (`for rt in resultTabs where !rt.isStale { ... }`) — replaced by the call to `reResolveAllResultTabs(immediate: true)`.

## Error Handling

| Situation | Behavior |
|---|---|
| `SQLSegmentParser.parse` returns `[]` (empty editor) | Every tab resolves to `nil` → all stale. Gutter blanks. No alert. |
| Parser throws or asserts (shouldn't — pure) | Defensive: treat as empty segment list. No alert. |
| Result tab whose SQL contains only whitespace | Tab.sql was captured at execution; if it normalizes to empty, the resolver returns `nil` (no segment normalizes to empty). Stale. Edge case unlikely in practice. |
| Re-resolve runs while a query is executing | `runningSegmentIndex` and `segmentIndex` are independent fields. Only `segmentIndex` is updated. The pulsing-segment effect (driven by `runningSegmentIndex`) is unaffected. |
| Window closed / view torn down before debounce fires | `DispatchWorkItem` captures `weak self`; the body short-circuits. No crash. |

## Edge Cases Worth Calling Out

- **Same SQL appears at two locations near the original** — closest-by-midpoint wins; ties go to the smaller `startLine`.
- **Same SQL appears once but at a wildly distant line** — match wins anyway (single match is unambiguous), `lineRange` updates accordingly.
- **User deletes the SQL and pastes it back** — within 250 ms the tab transitions stale → non-stale → stale → non-stale depending on intermediate states; the final state at debounce flush is what the user sees.
- **Two result tabs from the same SQL** — both resolve to the same segment; both apply their color to the same gutter slot; last-applied color wins (same as existing behavior — no regression).
- **User opens a `.sql` file and the editor wholesale changes** — the re-resolve sees a totally different segment list; every result tab goes stale on next debounce flush. Correct.

## Testing

### Resolver eyeball-check table

| `sql` | `previousLineRange` | Segments in editor | Expected Outcome |
|---|---|---|---|
| `"SELECT 1;"` | `1...1` | `[(idx 0, "SELECT 1;", 1...1)]` | `(0, 1...1)` |
| `"SELECT 1;"` | `1...1` | `[(0, "SELECT 2;", 1...1)]` | `nil` |
| `"SELECT 1;"` | `1...1` | `[]` | `nil` |
| `"SELECT 1;"` | `5...5` | `[(0, "SELECT 1;", 1...1), (1, "SELECT 1;", 9...9)]` | `(1, 9...9)` (mid-5 closer to mid-9 than mid-1) |
| `"SELECT 1;"` | `1...1` | `[(0, "SELECT 1;", 1...1), (1, "SELECT 1;", 1...1)]` | `(0, 1...1)` (tie → smaller `index`) |
| `"SELECT 1;"` | `1...1` | `[(0, " SELECT 1; ", 1...1)]` | `(0, 1...1)` (normalization trims whitespace) |

Implementer should inspect the resolver against this table; no XCTest target exists in the project.

### Manual smoke tests

Run with a connection that returns trivial result sets (e.g., `SELECT 1;`).

1. **Basic preserve:** Run `SELECT 1;` on line 1 (result A). Add `SELECT 2;` on line 3 and run (result B). Click A → line 1 highlights, A's dot full. Click B → line 3 highlights, B's dot full.
2. **Migrate on insert above:** After (1), press Enter at the start of line 1 to push everything down. Wait ¼ s. Click A → highlights the line where `SELECT 1;` now lives. B likewise.
3. **Go stale on edit:** Edit `SELECT 1;` to `SELECT 1, 2;`. Wait ¼ s. A's tab-bar dot dims; clicking A no longer highlights.
4. **Stale on delete:** Delete the `SELECT 2;` segment entirely. Wait ¼ s. B goes stale.
5. **Recover on paste:** Paste `SELECT 2;` back at a different line. Wait ¼ s. B's dot brightens; clicking B highlights the new location.
6. **Closest-match wins:** Duplicate `SELECT 1;` to line 20. Click A → line 1 still highlights (closer to A's previous `lineRange`).
7. **Immediate flush on selection:** Type rapidly in the editor; while typing, click result tab A. Re-resolve flushes immediately; highlight is correct, no flicker.
8. **Editor-tab switch:** Open a second editor tab, make some edits, switch back. Gutter dots and highlight on the first tab are correct without waiting for a debounce.

## Out of Scope (Future Work)

- Whitespace-tolerant or token-equivalent matching.
- Persisting result tabs and their re-resolve state across sessions.
- Visual indication during the 250 ms debounce window (e.g., a subtle "computing…" affordance).
- Animating gutter-dot migration.
