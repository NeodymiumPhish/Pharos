# Schema Selector — Scrollable, Searchable Popover

**Date:** 2026-06-16
**Status:** Approved (design)

## Problem

The schema selector in the editor toolbar is an `NSPopUpButton` (`schemaPopup`,
`EditorPaneVC.swift:44`). `rebuildSchemaMenu()` (`EditorPaneVC.swift:786`)
populates its native `NSMenu` with one item per schema. With 50-100 schemas the
menu shows scroll arrows, and `NSMenu`'s scroll-arrow mechanism advances in large
increments — a minor scroll-wheel turn jumps most of the way down the list.
`NSMenu` exposes no API to tune this scroll sensitivity, so the list never feels
like a normal scrollable list.

Every other long list in the app (the schema browser `NSOutlineView`, the column
filter value picker `FilterValueListView`) lives inside an `NSScrollView` and
scrolls naturally. The schema selector should do the same.

## Goal

Replace the schema selector's native menu with a real scrollable list inside an
`NSScrollView`/`NSTableView`, presented in an `NSPopover`, with a live search
field. Preserve the existing toolbar appearance and all current behaviors:
- Pick a schema → set it for the active tab.
- "All Schemas" option (clears the schema filter).
- `★ default` badge on the connection's configured default schema.
- Checkmark on the currently active schema.
- "Set as Default Schema" action.

## Non-Goals

- No change to how schemas are loaded/cached (`metadataCache`).
- No change to the connection popup or any other toolbar control.
- No multi-select — schema selection stays single-choice.

## Components

### 1. `SchemaSelectorPopoverVC.swift` (new)

An `NSViewController` that provides the popover content. Self-contained: it knows
nothing about `EditorPaneVC` internals. It is handed its data and reports user
actions through a delegate (or closures).

**Inputs (set by the presenter before/at show time):**
- `schemas: [String]` — schema names, in display order.
- `activeSchema: String?` — currently selected schema (`nil` = All Schemas).
- `defaultSchema: String?` — the connection's configured default, for the badge.

**UI:**
- `NSSearchField` pinned at the top. Filters rows case-insensitively as the user
  types (same idiom as `FilterValueListView.applySearch`). Filtering only changes
  which rows are visible; it does not alter selection.
- `NSScrollView` + `NSTableView` below it. Rows:
  - A pinned **"All Schemas"** row at the top (always visible; not filtered out).
  - One row per schema. The active schema shows a checkmark; the default schema
    shows the `★ default` badge appended to its name.
- A footer **"Set as Default Schema"** button.

**Behavior:**
- Single-click on a schema row (or the "All Schemas" row) commits the selection
  and dismisses the popover — matching the current menu's click-to-select feel.
- The "Set as Default Schema" button reports the request and dismisses.

**Outputs (delegate / closures):**
- `didSelectSchema(_ schema: String?)` — `nil` means All Schemas.
- `didRequestSetDefault()` — set the current selection as the connection default.

### 2. `SchemaPopUpButton.swift` (new)

A minimal `NSPopUpButton` subclass. It overrides mouse-down (and keyboard
activation) to present the `SchemaSelectorPopoverVC` in an `NSPopover` anchored to
itself, **instead of** showing the native menu. The recessed, borderless,
arrow-at-bottom appearance is unchanged, so the control looks identical to the
adjacent connection popup — only the dropdown behavior changes.

The button still displays a single title item (the current schema name / "All
Schemas" / "No Schema" / "Loading…"), set by the existing title logic.

### 3. `EditorPaneVC.swift` (edits)

- Change `schemaPopup`'s declared type to `SchemaPopUpButton`.
- `rebuildSchemaMenu()` keeps its title/enabled-state logic
  (`No Schema` / `Loading…` / connected states) but **no longer appends the
  per-schema menu items, the "All Schemas" item, separators, or the
  "Set as Default" item.** It just sets the displayed title and enabled state.
- The popover is populated on demand when the button is activated, pulling the
  current `metadataCache.schemas`, `tabSchemaName`, and the connection's
  `defaultSchema`.
- The popover's callbacks reuse the existing logic:
  - `didSelectSchema` → existing `setTabSchema(_:)`.
  - `didRequestSetDefault` → existing `setDefaultSchemaClicked` logic.

## Data Flow

1. User clicks `schemaPopup` (`SchemaPopUpButton`).
2. The button asks its presenter (`EditorPaneVC`) to build and show the popover,
   handing over `schemas`, `activeSchema`, `defaultSchema`.
3. `SchemaSelectorPopoverVC` renders the searchable list.
4. User searches/scrolls/clicks a row (or "All Schemas", or "Set as Default").
5. The VC fires the matching callback and dismisses.
6. `EditorPaneVC` applies it via `setTabSchema(_:)` / the set-default logic, which
   updates tab + global state; the existing reactive bindings rebuild the title.

## Error / Edge Handling

- **Not connected / no schemas:** `rebuildSchemaMenu()` already shows "No Schema"
  and disables the control; the popover is never presented in that state.
- **Loading:** `updateSchemaLoading(true)` shows "Loading…" and disables the
  button, as today.
- **Empty search result:** the table shows only the pinned "All Schemas" row.
- **Active schema not in list** (e.g. stale): no checkmark shown; selection still
  reflected in the button title. No crash.
- **Stale row indices** during reload: guard table accesses against the current
  visible-row count, mirroring `FilterValueListView`.

## Testing

- Manual: with a connection exposing 50-100 schemas, confirm the popover scrolls
  smoothly (no large jumps), search narrows the list, clicking selects and
  dismisses, the `★ default` badge and active checkmark render correctly, and
  "Set as Default Schema" updates the badge.
- Manual: verify the toolbar appearance is unchanged next to the connection popup.
- Regression: "All Schemas" clears the filter; switching connections still resets
  schema to the connection default; disabled/"No Schema"/"Loading…" states behave
  as before.
- A standalone `swiftc` AppKit harness can exercise `SchemaSelectorPopoverVC`'s
  filtering and selection callbacks headlessly if desired (per the project's test
  harness notes).
