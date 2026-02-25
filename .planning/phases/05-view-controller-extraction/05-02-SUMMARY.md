---
phase: 05-view-controller-extraction
plan: 02
subsystem: ui
tags: [swift, appkit, nsviewcontroller, nsoutlineview, refactoring, schema-browser]

# Dependency graph
requires:
  - phase: 04-rust-ffi-dead-code-removal
    provides: clean Rust FFI layer with only active exports
provides:
  - SchemaBrowserVC reduced from 1009 to 383 lines via helper extraction
  - SchemaDataSource helper (NSOutlineViewDataSource + NSOutlineViewDelegate)
  - SchemaContextMenu helper (all context menu actions + NSMenuDelegate)
  - SchemaTreeNode moved to Models/ directory
  - SchemaTreeCellView moved to Views/ directory (non-private)
  - Delegate protocols co-located with helper classes
affects: [06-final-polish]

# Tech tracking
tech-stack:
  added: []
  patterns: [helper-class-with-delegate, one-class-per-file, vc-as-orchestrator]

key-files:
  created:
    - Pharos/Models/SchemaTreeNode.swift
    - Pharos/Views/SchemaTreeCellView.swift
    - Pharos/ViewControllers/SchemaBrowser/SchemaDataSource.swift
    - Pharos/ViewControllers/SchemaBrowser/SchemaContextMenu.swift
  modified:
    - Pharos/ViewControllers/SchemaBrowserVC.swift

key-decisions:
  - "Used didSet on rootNodes to sync state to SchemaDataSource (clean, no extra method calls needed)"
  - "All menu items use explicit target = self on helper (not responder chain) since helper is not in responder chain"
  - "SchemaContextMenu owns its own stateManager reference (avoids passing through delegate)"
  - "Pre-existing 05-01 ResultsGridVC build errors excluded from verification (parallel plan, not caused by this work)"

patterns-established:
  - "Helper extraction: NSObject subclass with delegate protocol, co-located in same file"
  - "VC as orchestrator: view setup + public API + data loading, helpers handle display + interaction"
  - "Delegate for VC callbacks: connectionId, reload, presentSheet, window access"

requirements-completed: [ARCH-01, ARCH-02]

# Metrics
duration: 7min
completed: 2026-02-25
---

# Phase 5 Plan 2: SchemaBrowserVC Extraction Summary

**SchemaBrowserVC refactored from 1009 to 383 lines by extracting SchemaDataSource, SchemaContextMenu helpers and moving SchemaTreeNode/SchemaTreeCellView to proper directories**

## Performance

- **Duration:** 7 min
- **Started:** 2026-02-25T19:19:35Z
- **Completed:** 2026-02-25T19:26:50Z
- **Tasks:** 4
- **Files modified:** 5

## Accomplishments
- SchemaBrowserVC reduced from 1009 to 383 lines (62% reduction, well under 500-line target)
- SchemaDataSource extracted with NSOutlineViewDataSource + NSOutlineViewDelegate + double-click handling (79 lines)
- SchemaContextMenu extracted with all 13 context menu actions + NSMenuDelegate + alert helpers (488 lines)
- SchemaTreeNode moved to Models/ and SchemaTreeCellView moved to Views/ with proper access modifiers
- All SidebarViewController public API calls preserved unchanged
- All menu items correctly target helper object via explicit `target = self`

## Task Commits

Each task was committed atomically:

1. **Task 1: Move SchemaTreeNode to Models/ and SchemaTreeCellView to Views/** - `cb10dec` (refactor)
2. **Task 2: Extract SchemaDataSource** - `32314de` (refactor)
3. **Task 3: Extract SchemaContextMenu** - `f0454a3` (refactor)
4. **Task 4: Final cleanup and verification** - no changes needed (verification only)

## Files Created/Modified
- `Pharos/Models/SchemaTreeNode.swift` - Schema tree node data model (moved from SchemaBrowserVC)
- `Pharos/Views/SchemaTreeCellView.swift` - Custom outline view cell with icon and labels (moved, private removed)
- `Pharos/ViewControllers/SchemaBrowser/SchemaDataSource.swift` - NSOutlineViewDataSource + Delegate + double-click
- `Pharos/ViewControllers/SchemaBrowser/SchemaContextMenu.swift` - All context menu actions + NSMenuDelegate
- `Pharos/ViewControllers/SchemaBrowserVC.swift` - Reduced to orchestrator: view setup, public API, filtering, lazy loading

## Decisions Made
- Used `didSet` on `rootNodes` property to automatically sync state to SchemaDataSource (eliminates manual sync calls)
- All menu items use explicit `target = self` on the helper (21 instances) since the helper is not in the responder chain
- SchemaContextMenu keeps its own `AppStateManager.shared` reference for destructive confirmation checks
- Pre-existing 05-01 build errors in ResultsGridVC excluded from build verification (parallel plan, out of scope)

## Deviations from Plan

None - plan executed exactly as written.

## Issues Encountered
- Pre-existing build errors in ResultsGridVC.swift from parallel 05-01 plan execution. These are unrelated to SchemaBrowserVC extraction. Verified by filtering error output: zero errors in SchemaBrowser-related files.
- Build database lock on first build attempt (concurrent xcodebuild processes). Resolved on retry.

## User Setup Required

None - no external service configuration required.

## Next Phase Readiness
- SchemaBrowserVC extraction complete, all helpers follow the established pattern
- Phase 5 Plan 1 (ResultsGridVC extraction) may still be in progress on this branch
- Phase 6 (final polish) can proceed once both plans complete

## Self-Check: PASSED

All 6 expected files found on disk. All 3 task commits verified in git history.

---
*Phase: 05-view-controller-extraction*
*Completed: 2026-02-25*
