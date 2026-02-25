# Requirements: Pharos Cleanup Milestone

**Defined:** 2026-02-24
**Core Value:** Fast, native PostgreSQL exploration and querying on macOS

## v1 Requirements

### Editor Rendering

- [ ] **EDIT-01**: SQL text in the query editor displays at full opacity with no faded/washed-out appearance
- [ ] **EDIT-02**: Line numbers in the gutter display at full readability with proper contrast
- [ ] **EDIT-03**: Editor rendering fix does not break syntax highlighting, bracket matching, or error markers

### Dead Code Removal (Swift)

- [x] **SWFT-01**: Unused Swift types, functions, and protocols from Tauri-era migration are removed
- [x] **SWFT-02**: Periphery scan produces zero actionable warnings (false positives excluded)
- [x] **SWFT-03**: All existing functionality continues to work after Swift dead code removal

### Dead Code Removal (Rust FFI)

- [x] **RUST-01**: FFI functions in ffi.rs that have no Swift callers are removed
- [x] **RUST-02**: Corresponding C header declarations are regenerated to match
- [x] **RUST-03**: Unused Rust internal code (structs, functions not called by FFI) is removed
- [x] **RUST-04**: Cargo.toml dependencies are audited and unused ones removed

### Git Cleanup

- [x] **GIT-01**: Tracked-but-deleted Tauri-era files are committed as removed
- [x] **GIT-02**: .gitignore is updated for the native AppKit project structure

### Architecture Tidy

- [x] **ARCH-01**: ResultsGridVC (1429 lines) responsibilities extracted into helper classes
- [x] **ARCH-02**: SchemaBrowserVC (1009 lines) context menu and data source extracted
- [x] **ARCH-03**: PharosCore.swift FFI wrapper organized by domain (connection, query, metadata, etc.)
- [x] **ARCH-04**: ffi.rs organized into domain-grouped submodules
- [x] **ARCH-05**: All existing functionality verified after restructuring

## v2 Requirements

### Performance

- **PERF-01**: Move JSON decoding off main thread for large result sets
- **PERF-02**: Implement metadata caching with TTL-based invalidation

### Code Quality

- **QUAL-01**: Add integration tests for Swift-Rust FFI boundary
- **QUAL-02**: Implement SQLite migration versioning

## Out of Scope

| Feature | Reason |
|---------|--------|
| TextKit 2 migration | Known rendering bugs (FB9692714), rewrite required |
| swift-bridge/UniFFI migration | Working FFI layer, migration is a dedicated milestone |
| New features (transaction UI, query scheduling) | Cleanup milestone only |
| SwiftUI migration | AppKit is the chosen framework |
| ContentViewController extraction | At 677 lines, may be acceptable after other extractions |

## Traceability

| Requirement | Phase | Status |
|-------------|-------|--------|
| EDIT-01 | Phase 1 | Pending |
| EDIT-02 | Phase 1 | Pending |
| EDIT-03 | Phase 1 | Pending |
| GIT-01 | Phase 2 | Complete |
| GIT-02 | Phase 2 | Complete |
| SWFT-01 | Phase 3 | Complete |
| SWFT-02 | Phase 3 | Complete |
| SWFT-03 | Phase 3 | Complete |
| RUST-01 | Phase 4 | Complete |
| RUST-02 | Phase 4 | Complete |
| RUST-03 | Phase 4 | Complete |
| RUST-04 | Phase 4 | Complete |
| ARCH-01 | Phase 5 | Complete |
| ARCH-02 | Phase 5 | Complete |
| ARCH-03 | Phase 6 | Complete |
| ARCH-04 | Phase 6 | Complete |
| ARCH-05 | Phase 6 | Complete |

**Coverage:**
- v1 requirements: 17 total
- Mapped to phases: 17
- Unmapped: 0

---
*Requirements defined: 2026-02-24*
*Last updated: 2026-02-25 after Phase 2 completion*
