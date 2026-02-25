# Roadmap: Pharos Cleanup Milestone

## Overview

This milestone cleans up the Pharos codebase after the Tauri-to-AppKit migration. It starts with the most visible user-facing issue (faded editor text), then cleans the git history, removes dead code from both Swift and Rust layers, and finishes by restructuring the remaining code for maintainability. Each phase builds on the previous -- dead code removal precedes architecture work so we restructure clean code, not noisy code.

## Phases

**Phase Numbering:**
- Integer phases (1, 2, 3): Planned milestone work
- Decimal phases (2.1, 2.2): Urgent insertions (marked with INSERTED)

Decimal phases appear between their surrounding integers in numeric order.

- [x] **Phase 1: Editor Text Rendering Fix** - Resolve faded/washed-out text in SQL editor and line number gutter
- [x] **Phase 2: Git Cleanup** - Commit tracked-but-deleted Tauri files and update .gitignore for AppKit
- [x] **Phase 3: Swift Dead Code Removal** - Remove unused Swift types, functions, and protocols from Tauri era
- [x] **Phase 4: Rust FFI Dead Code Removal** - Remove unused FFI exports, internal Rust code, and stale dependencies
- [x] **Phase 5: View Controller Extraction** - Break apart monolithic view controllers into focused helper classes
- [ ] **Phase 6: FFI Layer Organization** - Organize PharosCore.swift and ffi.rs by domain with full verification

## Phase Details

### Phase 1: Editor Text Rendering Fix
**Goal**: SQL text and line numbers in the query editor display at full readability with proper contrast
**Depends on**: Nothing (first phase)
**Requirements**: EDIT-01, EDIT-02, EDIT-03
**Success Criteria** (what must be TRUE):
  1. SQL text in the query editor appears at full opacity with sharp, readable contrast in both light and dark themes
  2. Line numbers in the gutter display with full readability and proper contrast against the gutter background
  3. Syntax highlighting colors, bracket matching highlights, and error markers continue to render correctly after the fix
  4. The editor renders correctly across window resize, scroll, and tab switching without compositing artifacts
**Plans**: 2 plans

Plans:
- [x] 01-01-PLAN.md — Test NSSplitViewItem initializer fix in isolation, apply rendering fix + gutter
- [x] 01-02-PLAN.md — Xcode-like syntax theme, SF Mono default, accent cursor

### Phase 2: Git Cleanup
**Goal**: The git working tree is clean with no ghost files from the Tauri era polluting status output
**Depends on**: Phase 1
**Requirements**: GIT-01, GIT-02
**Success Criteria** (what must be TRUE):
  1. `git status` shows no tracked-but-deleted files from the Tauri era (src-tauri/, src/, docs/, etc.)
  2. `.gitignore` correctly excludes AppKit build artifacts, Xcode derived data, and Rust target directories
  3. `git status` on a clean checkout shows a clean working tree (no untracked noise from build artifacts)
**Plans**: 1 plan

Plans:
- [x] 02-01-PLAN.md — Remove Tauri-era files, build artifacts from tracking; update .gitignore for AppKit+Rust

### Phase 3: Swift Dead Code Removal
**Goal**: The Swift codebase contains only code that is actively used, with zero actionable Periphery warnings
**Depends on**: Phase 2
**Requirements**: SWFT-01, SWFT-02, SWFT-03
**Success Criteria** (what must be TRUE):
  1. Running `periphery scan` produces zero actionable warnings (false positives from responder chain / #selector excluded)
  2. All existing app functionality (connections, queries, schema browsing, saved queries, settings) works identically after removal
  3. The project builds with zero errors and zero new warnings after dead code removal
**Plans**: 2 plans

Plans:
- [x] 03-01-PLAN.md — Install Periphery, configure for AppKit, remove all Periphery-flagged dead code
- [x] 03-02-PLAN.md — Manual sweep beyond Periphery (stale imports, empty extensions), final zero-warning verification

### Phase 4: Rust FFI Dead Code Removal
**Goal**: The Rust FFI layer contains only functions actively called from Swift, with no stale exports or unused dependencies
**Depends on**: Phase 3
**Requirements**: RUST-01, RUST-02, RUST-03, RUST-04
**Success Criteria** (what must be TRUE):
  1. Every `pub extern "C"` function in ffi.rs has a corresponding caller in PharosCore.swift
  2. The regenerated C header (pharos_core.h) matches the current ffi.rs exports with no stale declarations
  3. `cargo clippy` reports no dead code warnings for internal Rust structs and functions
  4. `Cargo.toml` contains no dependencies that are unused after cleanup
  5. All app functionality works after FFI cleanup (three-way sync between ffi.rs, header, and PharosCore.swift verified)
**Plans**: 1 plan

Plans:
- [x] 04-01-PLAN.md — Remove 6 dead FFI exports, cascade into dead internal code, audit deps, verify three-way sync

### Phase 5: View Controller Extraction
**Goal**: Monolithic view controllers are split into focused, single-responsibility components
**Depends on**: Phase 4
**Requirements**: ARCH-01, ARCH-02
**Success Criteria** (what must be TRUE):
  1. ResultsGridVC is under 500 lines with data source, delegate, and export logic extracted into separate helper classes
  2. SchemaBrowserVC is under 500 lines with context menu handling and data source logic extracted
  3. All existing functionality (results display, pagination, schema browsing, context menus, table operations) works identically after extraction
**Plans**: 2 plans

Plans:
- [x] 05-01-PLAN.md — Extract ResultsGridVC into helper classes (DataSource, CopyExport, FindController, SortController) + PGTypeCategory utility
- [x] 05-02-PLAN.md — Extract SchemaBrowserVC into helper classes (DataSource, ContextMenu) + move SchemaTreeNode to Models/ and SchemaTreeCellView to Views/

### Phase 6: FFI Layer Organization
**Goal**: The FFI bridge code is organized by domain for navigability and maintainability
**Depends on**: Phase 5
**Requirements**: ARCH-03, ARCH-04, ARCH-05
**Success Criteria** (what must be TRUE):
  1. PharosCore.swift FFI wrapper methods are grouped into logical extensions by domain (connection, query, metadata, settings, etc.)
  2. ffi.rs is organized into domain-grouped submodules (or clearly separated sections) instead of one monolithic file
  3. All existing app functionality verified end-to-end after the complete architecture restructuring (connections, queries, schema browsing, saved queries, import/export, settings)
**Plans**: 2 plans

Plans:
- [ ] 06-01-PLAN.md — Split ffi.rs into ffi/ directory module with mod.rs + 9 domain submodules, verify cargo build and C header
- [ ] 06-02-PLAN.md — Split PharosCore.swift into base + 8 domain extension files, xcodegen + full Xcode build verification

## Progress

**Execution Order:**
Phases execute in numeric order: 1 -> 2 -> 3 -> 4 -> 5 -> 6

| Phase | Plans Complete | Status | Completed |
|-------|----------------|--------|-----------|
| 1. Editor Text Rendering Fix | 2/2 | Complete | 2026-02-25 |
| 2. Git Cleanup | 1/1 | Complete | 2026-02-25 |
| 3. Swift Dead Code Removal | 2/2 | Complete | 2026-02-25 |
| 4. Rust FFI Dead Code Removal | 1/1 | Complete | 2026-02-25 |
| 5. View Controller Extraction | 2/2 | Complete | 2026-02-25 |
| 6. FFI Layer Organization | 0/2 | Not started | - |
