# Roadmap: Pharos

## Milestones

- ✅ **v1.0 Cleanup** — Phases 1-6 (shipped 2026-02-25)
- **v1.1 Polish & Detail** — Phases 7-10 (in progress)

## Phases

<details>
<summary>v1.0 Cleanup (Phases 1-6) — SHIPPED 2026-02-25</summary>

- [x] Phase 1: Editor Text Rendering Fix (2/2 plans) — completed 2026-02-25
- [x] Phase 2: Git Cleanup (1/1 plan) — completed 2026-02-25
- [x] Phase 3: Swift Dead Code Removal (2/2 plans) — completed 2026-02-25
- [x] Phase 4: Rust FFI Dead Code Removal (1/1 plan) — completed 2026-02-25
- [x] Phase 5: View Controller Extraction (2/2 plans) — completed 2026-02-25
- [x] Phase 6: FFI Layer Organization (2/2 plans) — completed 2026-02-25

</details>

### v1.1 Polish & Detail

- [ ] **Phase 7: Three-Pane Foundation** — Add collapsible right inspector pane, toolbar toggle, sidebar visual polish
- [ ] **Phase 8: Inspector Content** — Single-row detail view and multi-row type-aware aggregation
- [ ] **Phase 9: Library & History** — Parsed table names, action bar, Save/Save As workflow, multi-select batch delete
- [ ] **Phase 10: Column Filters** — Per-column filter popovers with type-specific operators composing with find and sort

## Phase Details

### Phase 7: Three-Pane Foundation
**Goal**: Users can toggle a right inspector sidebar that collapses and expands smoothly alongside a visually polished left sidebar
**Depends on**: Phase 6 (v1.0 complete)
**Requirements**: INSP-01, INSP-02, INSP-05, SIDE-01, SIDE-02
**Success Criteria** (what must be TRUE):
  1. User can click a toolbar button to show/hide the right inspector pane
  2. User can press a keyboard shortcut to show/hide the right inspector pane
  3. Inspector pane collapses and expands with smooth animation (no jump cuts)
  4. Editor text remains fully opaque (no vibrancy regression from the third pane)
  5. Left sidebar has consistent border styling on both edges, and Library/History toggle uses modern capsule appearance
**Plans**: 2 plans
  - [ ] 07-01-PLAN.md — Inspector pane infrastructure + toolbar + keyboard shortcut
  - [ ] 07-02-PLAN.md — Sidebar visual polish + full visual verification

### Phase 8: Inspector Content
**Goal**: Users can inspect row data in the right sidebar — single-row detail and multi-row aggregation
**Depends on**: Phase 7
**Requirements**: INSP-03, INSP-04
**Success Criteria** (what must be TRUE):
  1. Selecting a single row in the results grid shows all column names and their values in the inspector
  2. Selecting multiple rows shows type-aware aggregated data (count/distinct for all types, min/max/sum/avg for numeric, earliest/latest for temporal, unique count for inet, true/false counts for boolean)
  3. Inspector updates immediately when selection changes (no manual refresh)
  4. NULL values are visually distinguishable from empty strings in the inspector
**Plans**: TBD

### Phase 9: Library & History
**Goal**: Users have a modernized library panel with parsed table names and a Save/Save As workflow, plus history batch delete
**Depends on**: Phase 7 (sidebar polish landed)
**Requirements**: LIB-01, LIB-02, LIB-03, LIB-04, LIB-05, HIST-01, HIST-02
**Success Criteria** (what must be TRUE):
  1. Library list items display parsed table names extracted from each saved query's SQL (not raw SQL snippets)
  2. Library panel has a bottom action bar with New, Save, Save As, and Delete buttons
  3. Opening a saved query from the library creates a tab linked to that query entry, enabling Save to overwrite it and Save As to create a new entry
  4. Library panel has a refined, modern visual appearance
  5. User can multi-select history items and batch delete them
**Plans**: TBD

### Phase 10: Column Filters
**Goal**: Users can filter results grid data per-column with type-aware operators that compose with existing find and sort
**Depends on**: Phase 7 (stable results grid — Phases 8 and 9 do not touch grid filtering)
**Requirements**: GRID-01, GRID-02, GRID-03, GRID-04
**Success Criteria** (what must be TRUE):
  1. User can click a filter icon in any column header to open a filter popover
  2. Filter popover provides type-specific operators (contains/starts-with for text, comparison operators for numeric, before/after for timestamps, true/false toggle for boolean, NULL/NOT NULL for all)
  3. Columns with active filters have a visual indicator in their header
  4. Column filters compose correctly with the existing find bar and sort — applying a column filter does not break find, and closing find does not clear column filters
**Plans**: TBD

## Progress

**Execution Order:** 7 > 8 > 9 > 10 (Phases 8 and 9 can proceed in parallel after 7)

| Phase | Milestone | Plans Complete | Status | Completed |
|-------|-----------|----------------|--------|-----------|
| 1. Editor Text Rendering Fix | v1.0 | 2/2 | Complete | 2026-02-25 |
| 2. Git Cleanup | v1.0 | 1/1 | Complete | 2026-02-25 |
| 3. Swift Dead Code Removal | v1.0 | 2/2 | Complete | 2026-02-25 |
| 4. Rust FFI Dead Code Removal | v1.0 | 1/1 | Complete | 2026-02-25 |
| 5. View Controller Extraction | v1.0 | 2/2 | Complete | 2026-02-25 |
| 6. FFI Layer Organization | v1.0 | 2/2 | Complete | 2026-02-25 |
| 7. Three-Pane Foundation | v1.1 | 0/2 | Planned | - |
| 8. Inspector Content | v1.1 | 0/0 | Not started | - |
| 9. Library & History | v1.1 | 0/0 | Not started | - |
| 10. Column Filters | v1.1 | 0/0 | Not started | - |
