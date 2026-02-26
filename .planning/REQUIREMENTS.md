# Requirements: Pharos

**Defined:** 2026-02-25
**Core Value:** Fast, native PostgreSQL exploration and querying on macOS — the app must feel like a first-class Mac citizen, not a web app in a wrapper.

## v1.1 Requirements

Requirements for v1.1 Polish & Detail milestone. Each maps to roadmap phases.

### Inspector

- [x] **INSP-01**: User can toggle a right inspector sidebar via toolbar button
- [x] **INSP-02**: User can toggle inspector sidebar via keyboard shortcut
- [x] **INSP-03**: User can view column names and values for a selected row in the inspector
- [ ] **INSP-04**: User can see type-aware aggregated data when multiple rows are selected (count/distinct for all, min/max/sum/avg for numeric, earliest/latest for temporal, unique count for inet, true/false counts for boolean)
- [x] **INSP-05**: Inspector collapses and expands with smooth animation

### Sidebar

- [x] **SIDE-01**: Left sidebar has consistent border styling on both left and right edges
- [x] **SIDE-02**: Library/History segmented control uses modern macOS capsule appearance

### Library

- [ ] **LIB-01**: Library list items display table names parsed from each saved query's SQL
- [ ] **LIB-02**: Library list has refined, modern visual appearance
- [ ] **LIB-03**: Library panel has bottom action bar with New, Save, Save As, and Delete buttons
- [ ] **LIB-04**: Query tabs opened from library are linked to the saved query entry
- [ ] **LIB-05**: User can Save (overwrite linked query) or Save As (create new entry) from the action bar

### History

- [ ] **HIST-01**: User can multi-select history items
- [ ] **HIST-02**: User can batch delete selected history items

### Grid

- [ ] **GRID-01**: User can open a filter popover from a filter icon in each column header
- [ ] **GRID-02**: Filter popover provides type-specific operators (contains/starts-with for text, comparison operators for numeric, before/after for timestamps, true/false toggle for boolean)
- [ ] **GRID-03**: Active column filters are visually indicated in the column header
- [ ] **GRID-04**: Column filters compose correctly with existing find bar and sort

## v2 Requirements

Deferred to future release. Tracked but not in current roadmap.

### Inspector Enhancements

- **INSP-06**: JSON tree viewer in inspector for JSON/JSONB columns
- **INSP-07**: Inline cell editing in inspector with transaction management

### Grid Enhancements

- **GRID-05**: Server-side column filtering via WHERE clause injection

## Out of Scope

Explicitly excluded. Documented to prevent scope creep.

| Feature | Reason |
|---------|--------|
| Inline cell editing in results grid | Requires transaction management, out of scope for polish milestone |
| Server-side filtering | Changes query semantics; client-side is correct for inspection |
| JSON tree viewer | Pretty-printed text sufficient for v1.1 inspection |
| Tab dirty-state indicators | Related to Save/Save As but adds significant UI complexity; defer |

## Traceability

Which phases cover which requirements. Updated during roadmap creation.

| Requirement | Phase | Status |
|-------------|-------|--------|
| INSP-01 | Phase 7 | Complete |
| INSP-02 | Phase 7 | Complete |
| INSP-03 | Phase 8 | Complete |
| INSP-04 | Phase 8 | Pending |
| INSP-05 | Phase 7 | Complete |
| SIDE-01 | Phase 7 | Complete |
| SIDE-02 | Phase 7 | Complete |
| LIB-01 | Phase 9 | Pending |
| LIB-02 | Phase 9 | Pending |
| LIB-03 | Phase 9 | Pending |
| LIB-04 | Phase 9 | Pending |
| LIB-05 | Phase 9 | Pending |
| HIST-01 | Phase 9 | Pending |
| HIST-02 | Phase 9 | Pending |
| GRID-01 | Phase 10 | Pending |
| GRID-02 | Phase 10 | Pending |
| GRID-03 | Phase 10 | Pending |
| GRID-04 | Phase 10 | Pending |

**Coverage:**
- v1.1 requirements: 18 total
- Mapped to phases: 18
- Unmapped: 0

---
*Requirements defined: 2026-02-25*
*Last updated: 2026-02-25 after roadmap creation*
