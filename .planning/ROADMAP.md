# Roadmap: Pharos

## Milestones

- ✅ **v1.0 Cleanup** -- Phases 1-6 (shipped 2026-02-25)
- ✅ **v1.1 Polish & Detail** -- Phases 7-10 (shipped 2026-02-26)
- [ ] **v2.0 Docs & Release** -- Phases 11-13 (in progress)

## Phases

<details>
<summary>v1.0 Cleanup (Phases 1-6) -- SHIPPED 2026-02-25</summary>

- [x] Phase 1: Editor Text Rendering Fix (2/2 plans) -- completed 2026-02-25
- [x] Phase 2: Git Cleanup (1/1 plan) -- completed 2026-02-25
- [x] Phase 3: Swift Dead Code Removal (2/2 plans) -- completed 2026-02-25
- [x] Phase 4: Rust FFI Dead Code Removal (1/1 plan) -- completed 2026-02-25
- [x] Phase 5: View Controller Extraction (2/2 plans) -- completed 2026-02-25
- [x] Phase 6: FFI Layer Organization (2/2 plans) -- completed 2026-02-25

</details>

<details>
<summary>v1.1 Polish & Detail (Phases 7-10) -- SHIPPED 2026-02-26</summary>

- [x] Phase 7: Three-Pane Foundation (2/2 plans) -- completed 2026-02-26
- [x] Phase 8: Inspector Content (2/2 plans) -- completed 2026-02-26
- [x] Phase 9: Library & History (2/2 plans) -- completed 2026-02-26
- [x] Phase 10: Column Filters (2/2 plans) -- completed 2026-02-26

</details>

### v2.0 Docs & Release

- [x] **Phase 11: Build Pipeline** -- Merge appkit to main and establish automated CI/CD producing dual-architecture DMGs
- [ ] **Phase 12: Documentation** -- Rewrite all doc pages for the AppKit version with new feature pages
- [ ] **Phase 13: Release** -- Update README and ship v2.0.0

## Phase Details

### Phase 11: Build Pipeline
**Goal**: The appkit branch is merged to main and a GitHub Actions workflow produces dual-architecture DMGs on tag push with automated GitHub Releases
**Depends on**: Nothing (first phase of v2.0)
**Requirements**: BRANCH-01, CI-01, CI-02, CI-03, CI-04, CI-05, CI-06
**Success Criteria** (what must be TRUE):
  1. Running `git log main` shows the full 63-commit appkit branch history (no squash)
  2. Pushing a `v*` tag to main triggers a GitHub Actions workflow that completes successfully
  3. The workflow produces two DMG files -- one arm64, one x86_64 -- both containing a launchable Pharos.app
  4. A GitHub Release is automatically created with both DMGs attached and auto-generated release notes
  5. Subsequent workflow runs use cached Rust dependencies (build time under 5 minutes per architecture on warm cache)
**Plans**: 2 plans

Plans:
- [x] 11-01-PLAN.md -- Merge appkit to main (ff-only) and add PHAROS_CI guard to project.yml
- [x] 11-02-PLAN.md -- Create GitHub Actions release workflow for dual-arch DMG builds

### Phase 12: Documentation
**Goal**: The GitHub Pages documentation site accurately describes the native AppKit version of Pharos with all current features documented
**Depends on**: Phase 11 (merge must land so docs deploy from main)
**Requirements**: DOC-01, DOC-02, DOC-03, DOC-04, DOC-05
**Success Criteria** (what must be TRUE):
  1. Every page on the docs site describes AppKit UI and workflows -- zero references to Tauri, React, Monaco, or web technologies remain
  2. The Inspector page documents single-row detail view and multi-row aggregation with type-aware behavior
  3. The Column Filters page documents per-column filter popovers with type-specific operators
  4. Navigating to removed features (inline editing, explain) returns 404 or redirects -- no dead content
  5. The site footer and description identify Pharos as a native macOS PostgreSQL client
**Plans**: 2 plans

Plans:
- [ ] 12-01-PLAN.md -- Create site infrastructure and rewrite all existing documentation pages for native AppKit version
- [ ] 12-02-PLAN.md -- Write new Inspector and Column Filters pages, full verification sweep

### Phase 13: Release
**Goal**: The project README accurately represents the native app and v2.0.0 is tagged and released
**Depends on**: Phase 11, Phase 12
**Requirements**: README-01
**Success Criteria** (what must be TRUE):
  1. README.md describes Pharos as a native AppKit + Rust application with accurate feature list, build-from-source instructions, and download links pointing to GitHub Releases
  2. The v2.0.0 tag is pushed, triggering a successful build, and the GitHub Release page has downloadable arm64 and x86_64 DMGs
**Plans**: TBD

Plans:
- [ ] 13-01: TBD

## Progress

**Execution Order:** 11 -> 12 -> 13

| Phase | Milestone | Plans Complete | Status | Completed |
|-------|-----------|----------------|--------|-----------|
| 1. Editor Text Rendering Fix | v1.0 | 2/2 | Complete | 2026-02-25 |
| 2. Git Cleanup | v1.0 | 1/1 | Complete | 2026-02-25 |
| 3. Swift Dead Code Removal | v1.0 | 2/2 | Complete | 2026-02-25 |
| 4. Rust FFI Dead Code Removal | v1.0 | 1/1 | Complete | 2026-02-25 |
| 5. View Controller Extraction | v1.0 | 2/2 | Complete | 2026-02-25 |
| 6. FFI Layer Organization | v1.0 | 2/2 | Complete | 2026-02-25 |
| 7. Three-Pane Foundation | v1.1 | 2/2 | Complete | 2026-02-26 |
| 8. Inspector Content | v1.1 | 2/2 | Complete | 2026-02-26 |
| 9. Library & History | v1.1 | 2/2 | Complete | 2026-02-26 |
| 10. Column Filters | v1.1 | 2/2 | Complete | 2026-02-26 |
| 11. Build Pipeline | v2.0 | Complete    | 2026-02-26 | 2026-02-26 |
| 12. Documentation | 1/2 | In Progress|  | - |
| 13. Release | v2.0 | 0/0 | Not started | - |
