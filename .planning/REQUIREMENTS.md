# Requirements: Pharos

**Defined:** 2026-02-26
**Core Value:** Fast, native PostgreSQL exploration and querying on macOS -- the app must feel like a first-class Mac citizen, not a web app in a wrapper.

## v2.0 Requirements

Requirements for v2.0 Docs & Release milestone. Each maps to roadmap phases.

### Branch

- [x] **BRANCH-01**: Appkit branch is merged to main via fast-forward, preserving all commit history

### CI/CD

- [x] **CI-01**: GitHub Actions workflow triggers on `v*` tag push and produces a build
- [x] **CI-02**: Workflow builds dual-architecture DMGs (arm64 via `macos-15`, x86_64 via `macos-15-intel`)
- [x] **CI-03**: Workflow creates a GitHub Release with both DMG artifacts attached
- [x] **CI-04**: Rust build is cached via `Swatinem/rust-cache` with per-architecture cache keys
- [x] **CI-05**: Version is stamped from git tag into Info.plist and Cargo.toml before build
- [x] **CI-06**: `project.yml` pre-build script has `PHAROS_CI` guard to prevent overwriting CI-built library

### Documentation

- [x] **DOC-01**: All existing doc pages are rewritten to describe the AppKit version (not Tauri/React)
- [x] **DOC-02**: Obsolete pages removed (inline-editing, explain)
- [x] **DOC-03**: New Inspector page documents single-row detail and multi-row aggregation
- [x] **DOC-04**: New Column Filters page documents per-column filter popovers
- [x] **DOC-05**: `_config.yml` updated to remove Tauri references from description/footer

### README

- [x] **README-01**: README reflects the native AppKit app with accurate description, build instructions, and download links

## Future Requirements

Deferred to future release. Tracked but not in current roadmap.

### Distribution

- **DIST-01**: Developer ID code signing and notarization for Gatekeeper-friendly distribution
- **DIST-02**: Universal binary (single DMG) via lipo instead of separate arch DMGs
- **DIST-03**: Homebrew cask tap auto-update on release
- **DIST-04**: Sparkle auto-update framework integration

### Documentation Enhancements

- **DOC-06**: Architecture page for contributors
- **DOC-07**: Changelog page (auto-generated or manual)

## Out of Scope

Explicitly excluded. Documented to prevent scope creep.

| Feature | Reason |
|---------|--------|
| Code signing + notarization | Requires $99/year Apple Developer Program enrollment |
| Universal binary | Start with separate DMGs, migrate once workflow is proven |
| Homebrew tap update | Only after release workflow is proven and tap repo checked |
| CI test suite | No tests exist in codebase; separate effort |
| Actions-based docs deployment | GitHub Pages branch-based deployment is sufficient |

## Traceability

Which phases cover which requirements. Updated during roadmap creation.

| Requirement | Phase | Status |
|-------------|-------|--------|
| BRANCH-01 | Phase 11 | Complete |
| CI-01 | Phase 11 | Complete |
| CI-02 | Phase 11 | Complete |
| CI-03 | Phase 11 | Complete |
| CI-04 | Phase 11 | Complete |
| CI-05 | Phase 11 | Complete |
| CI-06 | Phase 11 | Complete |
| DOC-01 | Phase 12 | Complete |
| DOC-02 | Phase 12 | Complete |
| DOC-03 | Phase 12 | Complete |
| DOC-04 | Phase 12 | Complete |
| DOC-05 | Phase 12 | Complete |
| README-01 | Phase 13 | Complete |

**Coverage:**
- v2.0 requirements: 13 total
- Mapped to phases: 13
- Unmapped: 0

---
*Requirements defined: 2026-02-26*
*Last updated: 2026-02-26 after roadmap creation*
