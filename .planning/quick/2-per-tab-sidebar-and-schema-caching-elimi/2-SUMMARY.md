---
phase: quick-2
plan: 01
subsystem: core/ui
tags: [caching, performance, tab-switching]
dependency_graph:
  requires: []
  provides: [multi-connection-metadata-cache, per-connection-tree-cache]
  affects: [sidebar, editor-toolbar-schema-selector, autocomplete]
tech_stack:
  added: []
  patterns: [per-connection-dictionary-cache, cache-hit-instant-restore]
key_files:
  created: []
  modified:
    - Pharos/Core/MetadataCache.swift
    - Pharos/ViewControllers/SchemaBrowserVC.swift
    - Pharos/ViewControllers/SidebarViewController.swift
    - Pharos/ViewControllers/ContentViewController.swift
decisions:
  - "Cache tree state in SchemaBrowserVC.clear() so switching away and back restores instantly"
  - "Use clearConnection() for disconnect vs clear() for display-only reset"
  - "Update cache incrementally during table load and row count refresh"
metrics:
  duration: "3m 9s"
  completed: "2026-03-11"
  tasks_completed: 2
  tasks_total: 2
---

# Quick Task 2: Per-Tab Sidebar and Schema Caching Summary

Multi-connection dictionary caches in MetadataCache and SchemaBrowserVC eliminate all FFI calls on tab switch.

## What Changed

### Task 1: Multi-connection MetadataCache (4ce2d46)

Refactored `MetadataCache` from single-connection storage to a per-connection dictionary cache (`connectionCaches: [String: ConnectionMetadata]`). When `load(connectionId:)` is called without `force`:
- If the connection has cached data (`isLoaded == true`), published properties are restored instantly from the dictionary -- zero FFI calls, zero loading spinners.
- If no cache exists, the full fetch cycle runs and results are stored in the dictionary.
- `force=true` always clears the specific connection's cache and re-fetches.

Added `clearConnection(_ id:)` to remove only one connection's cache on disconnect, preserving all other connections. `ContentViewController` now calls this for disconnected/errored connections instead of `clear()`.

### Task 2: Multi-connection SchemaBrowserVC tree cache (3cffbb4)

Added `treeCaches: [String: CachedTreeState]` dictionary to `SchemaBrowserVC` that stores the full tree node hierarchy and refreshed-schemas set per connection. On tab switch:
- Cache hit: saves current tree, restores target tree, calls `rebuildDisplayTree()` -- no FFI calls.
- Cache miss or force: proceeds with full schema fetch, stores result in cache after completion.
- Cache is updated incrementally during `loadTablesForSchema` and `refreshRowCounts` so partially-loaded trees are also preserved.

`clear()` now saves the current tree to cache before clearing the display (so switching back restores it). `clearConnection()` destroys the cache entry for a disconnected connection.

## Deviations from Plan

None -- plan executed exactly as written.

## Decisions Made

1. **Cache-on-clear pattern**: `SchemaBrowserVC.clear()` saves tree to cache before clearing display. This means switching to a tab with no connection (nil activeConnectionId) preserves the previous connection's tree for instant restoration.

2. **Incremental cache updates**: Rather than only caching the final tree state, cache updates happen after each schema's tables load and after row count refreshes. This ensures even partially-loaded trees are preserved during fast tab switching.

## Verification

- Xcode Debug build succeeds with zero warnings on modified files.
- Rust core builds successfully.
- Manual verification needed: tab switching between same-connection and different-connection tabs.
