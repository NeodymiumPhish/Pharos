# Set Default Schema Per Connection

**Date:** 2026-04-15
**Status:** Approved

## Overview

Add the ability to set a default schema per connection. When a new query tab is opened on a connection with a default schema, that schema is automatically selected. Users can set the default from two places: the schema selector dropdown in the editor toolbar, and the Default Schema field in the Connection Sheet.

## Data Model

### Rust (`pharos-core/src/models/connection.rs`)

Add to `ConnectionConfig`:

```rust
#[serde(default, skip_serializing_if = "Option::is_none")]
pub default_schema: Option<String>,
```

`None` means "All Schemas" / no default.

### Swift (`Pharos/Models/Connection.swift`)

Add to `ConnectionConfig`:

```swift
var defaultSchema: String?
```

### SQLite Migration (`pharos-core/src/db/sqlite.rs`)

Add column migration in `init_database()` using the same pattern as the `color` column:

```sql
ALTER TABLE connections ADD COLUMN default_schema TEXT
```

Update `save_connection()` and `load_connections()` to include the new column.

## UI: Schema Selector Dropdown

**File:** `Pharos/ViewControllers/EditorPaneVC.swift`

Modify `rebuildSchemaMenu()` to add two things:

1. **"Set as Default Schema" menu item** at the bottom of the dropdown, separated by a divider. Action: saves the currently-selected schema as the default for the active connection. Persists via `PharosCore.saveConnection()`.

2. **"default" badge** on the menu item matching the connection's `defaultSchema`. Rendered as a dimmed suffix (e.g., " - default") on the menu item title via attributed string.

### Clearing the default

If "All Schemas" is the current selection when "Set as Default Schema" is clicked, the default is cleared (`defaultSchema` set to `nil`).

## UI: Connection Sheet

**File:** `Pharos/Sheets/ConnectionSheet.swift`

Add a "Default Schema" row to the form grid, positioned below SSL Mode:

- **Control:** `NSPopUpButton`
- **Disabled state:** Shows placeholder "Test connection first", grayed out. This is the initial state for new connections and for editing when the user hasn't tested yet.
- **After successful Test Connection:** Enables and populates with:
  - "None" (first item, represents no default / All Schemas)
  - All schema names returned by querying `information_schema.schemata` via a temporary pool created during the test
- **Pre-selection:** When editing an existing connection with a `defaultSchema`, that value is pre-selected after Test Connection succeeds.
- **Saving without testing:** The field remains disabled. Any previously saved `defaultSchema` is preserved unchanged in the saved config.

### Schema fetching during test

The existing `testConnection()` flow creates a temporary pool. After the latency test succeeds, use that pool to also fetch schemas before closing it. Pass the schema list back alongside the latency result so the Connection Sheet can populate the dropdown.

## New Tab Behavior

**File:** `Pharos/Core/AppStateManager.swift`

When a new `QueryTab` is created for a connection that has `defaultSchema` set:
- Initialize `tab.schemaName` to `config.defaultSchema`
- Set `activeSchema` to match

Existing tabs are not affected. Per-tab schema overrides work normally after the tab is created.

## Files to Modify

| File | Change |
|------|--------|
| `pharos-core/src/models/connection.rs` | Add `default_schema: Option<String>` field |
| `pharos-core/src/db/sqlite.rs` | Migration + update save/load queries |
| `Pharos/Models/Connection.swift` | Add `defaultSchema: String?` field |
| `Pharos/Sheets/ConnectionSheet.swift` | Add Default Schema popup, populate after test |
| `Pharos/ViewControllers/EditorPaneVC.swift` | Add "Set as Default Schema" menu item + badge |
| `Pharos/Core/AppStateManager.swift` | Apply default schema on new tab creation |

## Out of Scope

- Schema validation (checking if saved default still exists on the server)
- Per-tab persistence of schema selection across app restarts
- Default schema for connections that don't support `information_schema`
