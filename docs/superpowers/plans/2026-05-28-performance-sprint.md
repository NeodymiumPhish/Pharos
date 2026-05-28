# Performance Sprint Implementation Plan

**Date:** 2026-05-28
**Status:** In progress
**Source:** Findings from the 2026-05-28 performance audit (12 items).

## Goal

Eliminate the 12 audit findings as a single coordinated sprint. Each bundle below is one logical commit (sometimes split into ≤2 commits for clarity), built and verified before moving on.

## Bundle order

Bundles are sequenced by **risk × benefit**: cheap, isolated changes first; broader refactors last. Each bundle is independently shippable — if anything goes sideways mid-sprint, stop at the last green commit.

### Bundle 1 — Sidebar typing perf (#1, #2)

Symptom: typing in the sidebar filter stutters on large schemas and (when History tab is active) blocks the main thread on a sync FFI per keystroke.

Files:
- `Pharos/ViewControllers/SidebarViewController.swift` — debounce the search field's text changes (~150ms) before invoking `applyFilter` on the visible child VC.
- `Pharos/ViewControllers/QueryHistoryVC.swift` — make `requery()` async (or hop the FFI call off main via `Task.detached`/`withAsyncCallback`).

Out of scope for this bundle: `SchemaTreeNode` reuse refactor — debounce alone removes the visible jank without restructuring the model.

### Bundle 2 — Combine plumbing dedup (#5, #6, #11)

Three independent publishers refire too aggressively. All three converge on the same fix shape (`.removeDuplicates()` or scoped `.map` + dedup).

Files:
- `Pharos/ViewControllers/ContentViewController.swift` — restructure the `CombineLatest3(tabs, panes, focusedPaneId)` sink that updates `actionBar.isPulsing` (#5); add `.removeDuplicates()` (or scope to `connectionStatuses[activeId]`) on the connection-status sink (#6).
- `Pharos/Models/Settings.swift` (or wherever `AppSettings` lives) — make `AppSettings: Equatable`.
- `Pharos/ViewControllers/QueryEditorVC.swift` — add `.removeDuplicates()` to the `$settings` sink; only rehighlight when font/tabSize/wordWrap actually changed; route `theme` assignment through `scheduleDebouncedHighlight()`.
- `Pharos/Editor/SQLTextView.swift` — `theme.didSet` should schedule debounced highlight instead of sync.

### Bundle 3 — Drag-tick downstream (#3, #4)

Cell-drag selection still triggers per-tick work in two consumers: the inspector and the filterable header view.

Files:
- `Pharos/ViewControllers/ContentViewController.swift` — debounce `updateInspector(selectedIndices:)` (~50ms) so only the settled selection drives the inspector.
- `Pharos/ViewControllers/ResultsGrid/FilterableHeaderView.swift` — cache two pre-rendered tinted images (active accent + hover tertiary). Use `setNeedsDisplay(headerRect(ofColumn:))` for hover changes instead of `needsDisplay = true`.

### Bundle 4 — Schema initial-load flicker (#8)

Files:
- `Pharos/ViewControllers/SchemaBrowserVC.swift` — `refreshAfterLoad` replaces full `reloadData` + collapse-all + re-expand with `outlineView.reloadItem(schemaNode, reloadChildren: true)`. Keep the full rebuild path for filter changes.

### Bundle 5 — Results `viewFor` hot path (#7)

Files:
- `Pharos/ViewControllers/ResultsGrid/ResultsDataSource.swift`:
  - Cache `nullDisplayString`, `boolTrueString`, `boolFalseString`, and prebuilt fonts (regular + italic) as ivars. Refresh from a single `stateManager.$settings.removeDuplicates()` sink (depends on Bundle 2).
  - Compute `isFindHighlighted` and `colIndex` once per cell render; reuse for both branches.
  - Add a `colId → index` dict; refresh when columns change. Replace `tableView.column(withIdentifier:)`.
  - Only call `.flattenedForCell` for `.string` / `.json` categories.

### Bundle 6 — Editor hot paths (#9, #10)

Two larger items. Doing the gutter first (smaller surface, isolated) before the off-main highlighter.

Files:
- `Pharos/Editor/LineNumberGutter.swift` — incremental `lineStarts` update using `pendingEditRange` + `changeInLength`. Cache digit-width per `lineAttributes` change. Skip `recalculateWidth` when digit count is unchanged.
- `Pharos/Editor/SQLTextView.swift` — `highlightSyntax()` moves to `Task.detached`: compute `(range, color)` tuples off-main; apply on `MainActor` in one batched `addAttribute` pass inside `CATransaction.setDisableActions(true)`. Use `withContiguousStorageIfAvailable` to avoid the `Array(text.utf16)` copy.

### Bundle 7 — Completion provider caching (#12)

Files:
- `Pharos/Editor/SQLCompletionProvider.swift` — cache `keywordCompletions` / `functionCompletions` as stored properties built once. Build a flat all-tables `[Completion]` once per schema-metadata change; the context branch slices instead of rebuilds. Cap `filterCompletions` at 200 matches (the popover window).

## Verification per bundle

After each bundle's edits:
1. `xcodebuild -scheme Pharos -configuration Debug -quiet build` — must succeed.
2. Commit with a descriptive message naming the bundle.
3. Move to the next bundle.

## Done criteria

- All 12 audit findings closed by their bundle.
- All 7 bundles committed cleanly on `main`.
- Build is green at the final commit.
- A short review note appended to this file summarising what shipped vs deferred.

## Review (2026-05-28)

All 7 bundles landed green on `main`; final build is clean. Commits:

| Bundle | Findings | Commit |
| --- | --- | --- |
| 1 | #1, #2 | `9d8fcd7` |
| 2 | #5, #6, #11 | `b741dd5` |
| 3 | #3, #4 | `24619dc` |
| 4 | #8 | `a8ef4e8` |
| 5 | #7 | `2941a41` |
| 6a | #10 | `cd78b0b` |
| 6b | #9 | `71d345a` |
| 7 | #12 | `7914a64` |

12 / 12 audit findings closed.

**Notable scope deviations / deferrals:**

- **#10 (line gutter — incremental lineStarts):** Shipped the cached
  digit-width + digit-count guard, which kills the per-keystroke
  `NSAttributedString.size()` allocation and the spurious
  `onWidthChange → layout pass` cascade. Deferred the splice-based
  `lineStarts` update — UTF-16 integer comparison over realistic
  document sizes is sub-millisecond, and an incremental splice via
  `NSTextStorageDelegate` adds bug surface for marginal gain. If a
  >100KB document ever surfaces as a complaint, revisit.

- **#11 (theme.didSet → debounced):** Verified `SQLTextView.theme` is
  never reassigned anywhere in the codebase today, so the
  audit-flagged sync rehighlight is dead code. Skipped the defensive
  rewrite. The real cost — every `$settings` publish triggering
  `applySettings → highlightSyntax` — is fixed by Bundle 2's dedup +
  signature gate.

- **#5 (actionBar.isPulsing):** Implemented as a derived publisher
  with `.map → .removeDuplicates`. Did not promote `isExecuting` to
  its own published property on the tab — felt premature given the
  publisher-level fix is sufficient and keeps the data model clean.

- **Bundle 5 follow-up:** `viewFor` now reloads on settings change via
  a sink in the data source's init. This means the data source
  observes settings independently of the VC. If a future refactor
  unifies settings flow, fold this into the VC's path.

**Recent context the audit didn't see** (already shipped before the
sprint): drag-tick deduplication in `ResultsCellSelection.
handleMouseDragged` (`4dbe824`), `ResultCellView` selection-appearance
ownership (`aac9ea7`), plain-bg drawing below the last data row
(`72cbaec`).
