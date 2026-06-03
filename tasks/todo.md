# Performance Pass — Plan

Audit findings F1–F16 (skipping #12 per user; F13 keeps lazy-decode portion only, no limit change).

> Previous codebase-review plan was overwritten — recoverable via `git log -- tasks/todo.md`.

## Phase 1 — Quick wins (low risk, low effort)

- [ ] **F10** — `removeDuplicates()` on `$connectionStatuses` sink (`SidebarViewController.swift:116-119`)
- [ ] **F2** — Async `formatSQL` (`PharosCore+Query.swift:9`, `QueryEditorVC.swift:136`); dispatch FFI off main, hop back for `setSQL`
- [ ] **F1** — Async copy/export. Move TSV/CSV/Markdown/SQL-INSERT/SQL-WITH string assembly to background `DispatchQueue`, set pasteboard on main. Same for export file writes. (`ResultsGrid/ResultsCopyExport.swift:145-244, 351-428`)
- [ ] **F5** — Pre-allocate highlight `cgColor`s in `ResultsDataSource` (`ResultsDataSource.swift:236-243`)

## Phase 2 — Medium effort, high impact

- [ ] **F3** — Coalesce `MetadataCache.loadDetails` publishing — publish `tables`/`columnsByTable` once at end, not on every schema iter (`MetadataCache.swift:160-201`)
- [ ] **F4** — *Verify only*: segment parser already debounced 100ms at `QueryEditorVC.swift:407-417`; document and skip
- [ ] **F8** — Diff settings-change reloads — already deduped at publisher but reloads on any change. Track a display signature (nullDisplay, boolDisplay) and only `reloadData()` if it actually changed (`ResultsDataSource.swift:143-149`)
- [ ] **F6** — Diff cell-selection drag updates (`ResultsDataSource.swift:261-287`). Track previous selection set; only touch cells whose membership flipped
- [ ] **F11** — `.removeDuplicates(by:)` on `EditorPaneVC` `$tabs` sink (`EditorPaneVC.swift:158-168`) comparing only the fields the sink uses (paneId membership, name, isDirty, isExecuting). No struct split needed
- [ ] **F9** — `QueryHistoryVC.requery` (`QueryHistoryVC.swift:159-181`): skip `reloadData()` when entries unchanged (same ids+order)

## Phase 3 — Higher effort

- [ ] **F16** — Coalesce `savedQueriesDidChange` / `queryHistoryDidChange` posts. Single coalesced helper, at most one post per run-loop tick
- [ ] **F14** — Differential saved-queries filtering. Track which nodes match, only `reloadItem(_:reloadChildren:)` affected nodes (`SavedQueriesVC.swift:154-179`)
- [ ] **F15** — Single-pass schema filter (`SchemaBrowserVC.swift:478-528`). Combine match-walk + expansion-hint into one pass
- [ ] **F7** — Merge `analyzeSchema` + `getTables` round-trip. Extend Rust `analyze_schema` to also return updated `Vec<TableInfo>`. Touches metadata.rs, ffi/schema.rs, PharosCore+Schema.swift, SchemaBrowserVC.swift
- [ ] **F13** — Eliminate `Data(json.utf8)` copy in `withAsyncCallback` / `callSync` decode path (`PharosCore.swift:44-46, 107-108, 119-120`). Use `Data(bytesNoCopy:count:deallocator:.none)` on the C buffer

## Self-review checks

- **F1** NSPasteboard ops are main-thread only — must hop back; format on bg.
- **F2** Capture pre-format text, format, then `setSQL` on main (current behavior is "replace everything" so race-safe).
- **F3** Defer publish to end-of-load: progressive cross-schema autocomplete is non-essential for typical use; mid-load typing on the loaded schemas still works because the user's active schema is loaded first via `prioritize`.
- **F6** Find-highlight precedence preserved by computing same `isFindHighlighted` test from `viewFor`.
- **F8** Verify nullDisplay/boolDisplay are the only AppSettings fields read in cell render. Other consumers (color, font) are computed from values, not settings.
- **F9** Compare new entry IDs against existing (cheap, O(n) of ≤200 entries).
- **F11** `.removeDuplicates(by:)` must include every field the sink reads. Concrete fields: per-tab `(id, name, isDirty, isExecuting, paneId)`. Pane membership comparison via `tabs.map { ... }`.
- **F14** Preserve outline expansion + selection across diff.
- **F15** `titleMatches` still cascades children unchanged.
- **F7** Keep permission-denied caching semantics; existing call sites unchanged when they only need `AnalyzeResult`.
- **F13** `Data(bytesNoCopy:)` safe inside callback (Rust frees after callback returns).

## Verification gate

- `cd pharos-core && cargo build --release` — Rust core builds clean
- `xcodebuild -project Pharos.xcodeproj -scheme Pharos build` — Swift compiles clean

## Review section

All 14 findings shipped. Builds clean: `cargo build --release` + `xcodebuild Pharos build`.

**Phase 1 (quick wins):**
- **F10** — `removeDuplicates()` on `SidebarViewController.$connectionStatuses` sink.
- **F2** — `PharosCore.formatSQL` is now async (off-main `Task.detached`); `QueryEditorVC.formatSQL` awaits it and bails if the editor text moved under us.
- **F1** — All copy formats (TSV/CSV/Markdown/SQL-INSERT/SQL-WITH) build strings on `DispatchQueue.global(.userInitiated)`; pasteboard set on main. Export-to-file generators and JSON export also moved off main.
- **F5** — Highlight backgrounds cached as `CGColor` (find-current/find-other static; selection bg refreshed only on appearance change).

**Phase 2 (medium effort):**
- **F3** — `MetadataCache.loadDetails` publishes `tables` / `columnsByTable` once at end (plus once right after the priority schema for fast active-schema autocomplete).
- **F4** — *Verified already debounced* (`recalculateSegments` 100ms, `recalculateFoldRegions` 200ms). No code change.
- **F8** — `ResultsDataSource` settings sink only calls `reloadData()` when the `DisplaySignature` (nullDisplay/boolDisplay) actually changed.
- **F6** — `updateVisibleCellSelectionAppearance` iterates `prev ∪ current` rect instead of all visible cells.
- **F11** — `EditorPaneVC.$tabs` sink uses `.removeDuplicates(by:)` comparing only `(id, name, isDirty, paneId, isExecuting, connectionId, schemaName, runningQueries.segmentIndex)`. Keystrokes that only change `sql` no longer fan out to the four UI rebuilds.
- **F9** — `QueryHistoryVC.requery` compares old vs. new entry IDs; skips `reloadData()` when identical.

**Phase 3:**
- **F16** — New `Utilities/NotificationCoalescer.swift`. Replaced all `NotificationCenter.default.post(name: .savedQueriesDidChange / .queryHistoryDidChange, object: nil)` sites with `NotificationCoalescer.post(...)` — collapses to one fan-out per main-loop tick.
- **F14** — `SavedQueriesVC` now skips `outlineView.reloadData()` + `expandAll()` when a filter keystroke produces a tree with the same fingerprint as before (no folder/query structural change).
- **F15** — `SchemaBrowserVC.filterNode` collects `expandList` inline; removed the second-pass `expandFilteredItems` recursion. One walk instead of two for filtered display.
- **F7** — Rust `AnalyzeResult` now carries `tables: Vec<TableInfo>` (refreshed after analyze). Swift `analyzeSchema` consumer in `SchemaBrowserVC.refreshRowCounts` drops the follow-up `getTables` round-trip. **Note: needed to regenerate the project via `xcodegen generate` to pick up `NotificationCoalescer.swift`.**
- **F13** — `withAsyncCallback` and `callSync` decode JSON via `Data(bytesNoCopy:count:deallocator:.none)` from the C buffer (synchronous decode before the Rust caller frees it). Eliminates two full-JSON allocations per FFI call on the hot path. Error messages still materialize the string lazily.

**Files touched:**
- `Pharos/ViewControllers/SidebarViewController.swift`
- `Pharos/Core/PharosCore+Query.swift`
- `Pharos/Core/PharosCore.swift`
- `Pharos/Core/MetadataCache.swift`
- `Pharos/ViewControllers/QueryEditorVC.swift`
- `Pharos/ViewControllers/ResultsGrid/ResultsCopyExport.swift`
- `Pharos/ViewControllers/ResultsGrid/ResultsDataSource.swift`
- `Pharos/ViewControllers/EditorPaneVC.swift`
- `Pharos/ViewControllers/QueryHistoryVC.swift`
- `Pharos/ViewControllers/SavedQueriesVC.swift`
- `Pharos/ViewControllers/SchemaBrowserVC.swift`
- `Pharos/ViewControllers/ContentViewController.swift`
- `Pharos/Models/Schema.swift`
- `Pharos/Utilities/NotificationCoalescer.swift` (new)
- `pharos-core/src/models/schema.rs`
- `pharos-core/src/db/postgres.rs`
- `Pharos.xcodeproj/...` (regenerated by xcodegen)

**Not tested at runtime** — no UI/integration tests in repo. The work compiles clean for both Debug Swift and Rust release. Sensible spots to smoke-check manually: copy/export on a large result set (no UI freeze), formatSQL on a 10k-line query (button stays responsive), filter typing in schema browser + saved queries (sub-tree changes only), connection status churn (sidebar doesn't reload on no-op flips).
