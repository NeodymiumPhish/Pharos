---
phase: quick-3
plan: 01
subsystem: ui
tags: [appkit, nsoutlineview, drag-drop, multi-select, ffi, rusqlite]

# Dependency graph
requires: []
provides:
  - Multi-select saved queries with Cmd/Shift-click
  - Drag-and-drop queries between folders
  - Batch delete via FFI
  - Save As duplicate name detection with Replace prompt
affects: []

# Tech tracking
tech-stack:
  added: []
  patterns:
    - NSOutlineView drag-and-drop with custom pasteboard type
    - Batch FFI operations with parameterized SQL IN clauses
    - SaveQueryAction enum for distinguishing create vs replace outcomes

key-files:
  created: []
  modified:
    - Pharos/ViewControllers/SavedQueriesVC.swift
    - Pharos/Sheets/SaveQuerySheet.swift
    - Pharos/ViewControllers/ContentViewController.swift
    - Pharos/Core/PharosCore+SavedQueries.swift
    - pharos-core/src/commands/saved_query.rs
    - pharos-core/src/ffi/saved_queries.rs
    - pharos-core/src/db/sqlite.rs

key-decisions:
  - "Custom pasteboard type (com.pharos.savedQuery) for drag-and-drop to avoid conflicts with generic string drags"
  - "SaveQueryAction enum instead of modifying callback signature with Bool to keep type-safe distinction between create and replace"
  - "Batch delete uses parameterized IN clause matching existing query history batch delete pattern"

patterns-established:
  - "Batch FFI pattern: JSON array input, count string output"

requirements-completed: [SAVED-MULTI-SELECT, SAVED-DRAG-DROP, SAVED-SAVE-AS-REPLACE, SAVED-BATCH-OPS]

# Metrics
duration: 5min
completed: 2026-03-11
---

# Quick Task 3: Saved Queries UX Overhaul Summary

**Multi-select with Cmd/Shift-click, drag-and-drop between folders, batch delete via Rust FFI, and Save As duplicate name detection with Replace/Save as New prompt**

## Performance

- **Duration:** 5 min
- **Started:** 2026-03-11T13:39:58Z
- **Completed:** 2026-03-11T13:44:55Z
- **Tasks:** 3
- **Files modified:** 7

## Accomplishments
- Saved queries outline view now supports multi-select (Cmd-click, Shift-click) with adapted context menu
- Drag-and-drop moves queries between folders or to root (no folder) via PharosCore.updateSavedQuery
- Batch delete FFI added end-to-end: sqlite.rs -> commands -> FFI -> Swift wrapper
- Save As detects duplicate names in same folder and offers Replace/Save as New/Cancel alert
- Delete key binding triggers deletion of selected queries
- Folder delete now uses efficient batch delete instead of individual calls

## Task Commits

Each task was committed atomically:

1. **Task 1: Rust batch delete FFI + Swift wrappers** - `fff5d4c` (feat)
2. **Task 2: Multi-select, drag-and-drop, and batch delete in SavedQueriesVC** - `5dfdf58` (feat)
3. **Task 3: Save As duplicate name detection and replace prompt** - `87d4026` (feat)

## Files Created/Modified
- `pharos-core/src/db/sqlite.rs` - Added batch_delete_saved_queries with parameterized IN clause
- `pharos-core/src/commands/saved_query.rs` - Added batch_delete_saved_queries command
- `pharos-core/src/ffi/saved_queries.rs` - Added pharos_batch_delete_saved_queries FFI wrapper
- `Pharos/Core/PharosCore+SavedQueries.swift` - Added batchDeleteSavedQueries Swift wrapper
- `Pharos/ViewControllers/SavedQueriesVC.swift` - Multi-select, drag-and-drop, batch delete, Delete key binding
- `Pharos/Sheets/SaveQuerySheet.swift` - SaveQueryAction enum, duplicate detection, Replace/Save as New alert
- `Pharos/ViewControllers/ContentViewController.swift` - Updated presentSaveQuerySheet to handle SaveQueryAction

## Decisions Made
- Used custom pasteboard type `com.pharos.savedQuery` instead of `.string` to avoid conflicts with generic string drags
- Created `SaveQueryAction` enum (created/replaced) for type-safe callback distinction
- Batch delete follows the same parameterized IN clause pattern as existing batch_delete_query_history_entries

## Deviations from Plan

None - plan executed exactly as written.

## Issues Encountered
None.

## User Setup Required
None - no external service configuration required.

## Next Phase Readiness
- All saved query UX improvements complete and building successfully
- Manual smoke test recommended: multi-select, drag queries between folders, Save As with duplicate name

---
*Phase: quick-3*
*Completed: 2026-03-11*
