---
gsd_state_version: 1.0
milestone: v1.0
milestone_name: milestone
current_plan: 0 of 0
status: idle
stopped_at: Completed quick task 260407-ew1
last_updated: "2026-04-07T15:00:00Z"
progress:
  total_phases: 1
  completed_phases: 1
  total_plans: 2
  completed_plans: 2
---

# Project State

## Project Reference

See: .planning/PROJECT.md (updated 2026-02-27)

**Core value:** Fast, native PostgreSQL exploration and querying on macOS
**Current focus:** No active phase — all milestones shipped, ready for new work

## Current Position

No active phase. All milestones (v1.0, v1.1, v2.0) shipped. Phase 02 (Sheets & Custom Views) removed.

## Accumulated Context

### Roadmap Evolution

- Phase 1 added: Fix results grid column sort/filter and cell selection

### Decisions

Full decision log in PROJECT.md Key Decisions table.
v2.0 decisions archived to .planning/milestones/v2.0-ROADMAP.md.
- Cell selection as overlay on NSTableView: row selection kept for inspector callbacks, visual highlighting driven by CellSelectionState
- backgroundStyle override suppresses default row highlighting; controlAccentColor for active cell border
- Sort state exposed via sortDirections dictionary pushed to header view, replacing setIndicatorImage
- Sort chevron always visible when active (not hover-dependent); filter icon remains hover/active conditional
- [Phase quick-2]: Per-connection dictionary caches in MetadataCache and SchemaBrowserVC for instant tab switching
- [Phase quick-3]: Custom pasteboard type for drag-drop; SaveQueryAction enum for create vs replace; batch FFI with parameterized IN clause
- [Phase quick-4]: Text storage replacement for code folding; unfold-all-on-edit strategy; shared chevron/error dot gutter column

### Pending Todos

None.

### Blockers/Concerns

None.

### Quick Tasks Completed

| # | Description | Date | Commit | Status | Directory |
|---|-------------|------|--------|--------|-----------|
| 2 | Per-tab sidebar and schema caching — eliminate refreshes on tab switch | 2026-03-11 | 262cac3 | | [2-per-tab-sidebar-and-schema-caching-elimi](./quick/2-per-tab-sidebar-and-schema-caching-elimi/) |
| 3 | Saved queries UX overhaul — multi-select, drag-drop, batch delete, Save As replace | 2026-03-11 | 87d4026 | | [3-saved-queries-ux-overhaul-multi-select-d](./quick/3-saved-queries-ux-overhaul-multi-select-d/) |
| 4 | Add code folding chevrons to query editor for SQL segments | 2026-03-12 | dd5a024 | Verified | [4-add-code-folding-chevrons-to-query-edito](./quick/4-add-code-folding-chevrons-to-query-edito/) |
| 260407-ew1 | Fix duplicate column name collision in query results | 2026-04-07 | bcbef35 | Needs Review | [260407-ew1-fix-duplicate-column-name-collision-in-q](./quick/260407-ew1-fix-duplicate-column-name-collision-in-q/) |
| 260407-i50 | Fix open transaction leaks — pool timeouts and after_connect hook | 2026-04-07 | f4df216 | | [260407-i50-fix-open-transaction-leaks-add-pool-time](./quick/260407-i50-fix-open-transaction-leaks-add-pool-time/) |

## Session Continuity

Last activity: 2026-04-07 - Completed quick task 260407-i50: Fix open transaction leaks
Stopped at: Completed quick task 260407-i50
Resume file: None
