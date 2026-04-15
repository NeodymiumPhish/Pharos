# Set Default Schema Per Connection — Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Allow users to set a default schema per connection, auto-applied to new query tabs.

**Architecture:** Add `default_schema` field to `ConnectionConfig` on both Rust and Swift sides, persisted via SQLite migration. Two UI touchpoints: schema selector dropdown ("Set as Default Schema" menu item) and Connection Sheet (dropdown populated after Test Connection). Default applied when creating new tabs.

**Tech Stack:** Rust (sqlx, serde, rusqlite), Swift/AppKit (NSPopUpButton, NSMenuItem), C FFI (JSON serialization)

---

### Task 1: Add `default_schema` to Rust ConnectionConfig

**Files:**
- Modify: `pharos-core/src/models/connection.rs:24-39`

- [ ] **Step 1: Add the field to ConnectionConfig**

In `pharos-core/src/models/connection.rs`, add the `default_schema` field after `color`:

```rust
#[derive(Debug, Clone, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct ConnectionConfig {
    pub id: String,
    pub name: String,
    pub host: String,
    pub port: u16,
    pub database: String,
    pub username: String,
    /// Password is stored securely in OS keychain, not in this struct for persistence.
    /// This field is only used for transit between frontend and backend.
    #[serde(default, skip_serializing_if = "String::is_empty")]
    pub password: String,
    #[serde(default)]
    pub ssl_mode: SslMode,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub color: Option<String>,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub default_schema: Option<String>,
}
```

- [ ] **Step 2: Verify it compiles**

Run: `cd pharos-core && cargo build --release`
Expected: Build succeeds (serde handles the new optional field with `default`)

- [ ] **Step 3: Commit**

```bash
git add pharos-core/src/models/connection.rs
git commit -m "feat: add default_schema field to Rust ConnectionConfig"
```

---

### Task 2: Add SQLite migration and update save/load

**Files:**
- Modify: `pharos-core/src/db/sqlite.rs:146-158` (after color migration), `304-342` (save), `344-371` (load)

- [ ] **Step 1: Add migration for default_schema column**

In `pharos-core/src/db/sqlite.rs`, after the `color` column migration (after line 158), add:

```rust
    // Migration: Add default_schema column if it doesn't exist
    let has_default_schema: bool = conn
        .prepare("SELECT COUNT(*) FROM pragma_table_info('connections') WHERE name = 'default_schema'")?
        .query_row([], |row| row.get::<_, i64>(0))
        .map(|count| count > 0)
        .unwrap_or(false);

    if !has_default_schema {
        conn.execute(
            "ALTER TABLE connections ADD COLUMN default_schema TEXT",
            [],
        )?;
    }
```

- [ ] **Step 2: Update save_connection to include default_schema**

Replace the `save_connection` function body (lines 315-340) with:

```rust
    conn.execute(
        r#"
        INSERT INTO connections (id, name, host, port, database, username, ssl_mode, sort_order, color, default_schema, updated_at)
        VALUES (?1, ?2, ?3, ?4, ?5, ?6, ?7, ?8, ?9, ?10, CURRENT_TIMESTAMP)
        ON CONFLICT(id) DO UPDATE SET
            name = excluded.name,
            host = excluded.host,
            port = excluded.port,
            database = excluded.database,
            username = excluded.username,
            ssl_mode = excluded.ssl_mode,
            color = excluded.color,
            default_schema = excluded.default_schema,
            updated_at = CURRENT_TIMESTAMP
        "#,
        (
            &config.id,
            &config.name,
            &config.host,
            config.port,
            &config.database,
            &config.username,
            &config.ssl_mode.to_string(),
            next_order,
            &config.color,
            &config.default_schema,
        ),
    )?;
```

- [ ] **Step 3: Update load_connections to read default_schema**

Replace the SELECT query (line 347) with:

```rust
        "SELECT id, name, host, port, database, username, COALESCE(ssl_mode, 'prefer') as ssl_mode, color, default_schema FROM connections ORDER BY sort_order, name",
```

And update the row mapping (lines 357-367) to include the new field:

```rust
        Ok(ConnectionConfig {
            id: row.get(0)?,
            name: row.get(1)?,
            host: row.get(2)?,
            port: row.get(3)?,
            database: row.get(4)?,
            username: row.get(5)?,
            password: String::new(), // Password loaded from keychain separately
            ssl_mode,
            color: row.get(7)?,
            default_schema: row.get(8)?,
        })
```

- [ ] **Step 4: Verify it compiles**

Run: `cd pharos-core && cargo build --release`
Expected: Build succeeds

- [ ] **Step 5: Commit**

```bash
git add pharos-core/src/db/sqlite.rs
git commit -m "feat: add default_schema SQLite migration and update save/load"
```

---

### Task 3: Add `defaultSchema` to Swift ConnectionConfig

**Files:**
- Modify: `Pharos/Models/Connection.swift:11-52`

- [ ] **Step 1: Add the field and update all initializers**

Add `defaultSchema` property to the struct (after `color`):

```swift
var defaultSchema: String?
```

Update the custom decoder (inside `init(from decoder:)`) to add after the `color` line:

```swift
defaultSchema = try c.decodeIfPresent(String.self, forKey: .defaultSchema)
```

Update the regular `init` signature and body:

```swift
init(id: String, name: String, host: String, port: UInt16, database: String,
     username: String, password: String = "", sslMode: SslMode = .prefer,
     color: String? = nil, defaultSchema: String? = nil) {
    self.id = id
    self.name = name
    self.host = host
    self.port = port
    self.database = database
    self.username = username
    self.password = password
    self.sslMode = sslMode
    self.color = color
    self.defaultSchema = defaultSchema
}
```

Update `CodingKeys` to include the new key:

```swift
private enum CodingKeys: String, CodingKey {
    case id, name, host, port, database, username, password, sslMode, color, defaultSchema
}
```

- [ ] **Step 2: Build in Xcode to verify**

Open Pharos.xcodeproj and build (Cmd+B). Fix any call sites that use the full `init` if the compiler flags them (the new parameter has a default value so existing callers should be fine).

- [ ] **Step 3: Commit**

```bash
git add Pharos/Models/Connection.swift
git commit -m "feat: add defaultSchema field to Swift ConnectionConfig"
```

---

### Task 4: Update Connection Sheet with Default Schema dropdown

**Files:**
- Modify: `Pharos/Sheets/ConnectionSheet.swift`

- [ ] **Step 1: Add the popup field and schema storage**

Add new properties after `testSpinner` (line 21):

```swift
private let defaultSchemaPopup = NSPopUpButton()
private var fetchedSchemas: [String] = []
```

- [ ] **Step 2: Add Default Schema row to the form grid**

In `loadView()`, after the `sslLabel`/`sslPopup` setup (around line 76), add:

```swift
let defaultSchemaLabel = NSTextField.formLabel("Default Schema")
defaultSchemaPopup.addItem(withTitle: "Test connection first")
defaultSchemaPopup.isEnabled = false
```

Update the grid (lines 95-103) to include the new row:

```swift
let grid = NSGridView(views: [
    [nameLabel, nameField],
    [hostLabel, hostField],
    [portLabel, portField],
    [databaseLabel, databaseField],
    [usernameLabel, usernameField],
    [passwordLabel, passwordField],
    [sslLabel, sslPopup],
    [defaultSchemaLabel, defaultSchemaPopup],
])
```

Update the container frame height (line 43) from 380 to 410 to accommodate the new row:

```swift
let container = NSView(frame: NSRect(x: 0, y: 0, width: 440, height: 410))
```

- [ ] **Step 3: Pre-fill defaultSchema for edit mode**

In the pre-fill block (after line 150, inside `if let config = existingConfig`), add:

```swift
// Default schema will be populated after Test Connection;
// store the existing value so we can restore the selection.
```

No popup pre-selection needed here — it happens when schemas are fetched after Test Connection.

- [ ] **Step 4: Fetch schemas after successful Test Connection**

In `testConnection()`, after the success UI update (after line 177 where `testStatusLabel.textColor = .systemGreen`), add schema fetching:

```swift
// Fetch schemas to populate Default Schema dropdown
Task {
    do {
        // Use a temporary connection to fetch schemas
        let schemas = try await PharosCore.testAndFetchSchemas(config)
        await MainActor.run { [weak self] in
            guard let self else { return }
            self.fetchedSchemas = schemas
            self.defaultSchemaPopup.removeAllItems()
            self.defaultSchemaPopup.addItem(withTitle: "None")
            for schema in schemas {
                self.defaultSchemaPopup.addItem(withTitle: schema)
            }
            self.defaultSchemaPopup.isEnabled = true
            // Restore previous selection if editing
            if let existing = self.existingConfig?.defaultSchema,
               let idx = schemas.firstIndex(of: existing) {
                self.defaultSchemaPopup.selectItem(at: idx + 1) // +1 for "None"
            }
        }
    } catch {
        NSLog("Failed to fetch schemas for default schema picker: \(error)")
    }
}
```

Note: `PharosCore.testAndFetchSchemas` doesn't exist yet. We'll create it in Task 5. For now, we can use the existing `PharosCore.getSchemas` if we have a connected pool. However, since TestConnection creates a temporary pool, we need a combined operation. See Task 5.

**Alternative approach (simpler):** After test connection succeeds, temporarily connect, fetch schemas, then disconnect. But this is wasteful. Instead, we'll add a new FFI function in Task 5 that returns schemas alongside the test result.

For now, use a simpler approach — fetch schemas from an active connection if one exists, or show a text field fallback:

Replace the schema fetching block above with this simpler version that works without a new FFI call:

```swift
// Populate Default Schema dropdown from test connection
// We create a temporary full connection to fetch schemas
Task {
    do {
        // Connect temporarily to fetch schemas
        let connId = "__test_schema_fetch_\(UUID().uuidString)"
        var tempConfig = config
        tempConfig.id = connId
        try PharosCore.saveConnection(tempConfig)
        let _ = try await PharosCore.connect(connectionId: connId)
        let schemas: [SchemaInfo] = try await PharosCore.getSchemas(connectionId: connId)
        try await PharosCore.disconnect(connectionId: connId)
        try PharosCore.deleteConnection(id: connId)

        await MainActor.run { [weak self] in
            guard let self else { return }
            self.fetchedSchemas = schemas.map { $0.name }
            self.defaultSchemaPopup.removeAllItems()
            self.defaultSchemaPopup.addItem(withTitle: "None")
            for schema in schemas {
                self.defaultSchemaPopup.addItem(withTitle: schema.name)
            }
            self.defaultSchemaPopup.isEnabled = true
            // Restore previous selection if editing
            if let existing = self.existingConfig?.defaultSchema,
               let idx = self.fetchedSchemas.firstIndex(of: existing) {
                self.defaultSchemaPopup.selectItem(at: idx + 1) // +1 for "None"
            }
        }
    } catch {
        NSLog("Failed to fetch schemas for default schema picker: \(error)")
    }
}
```

- [ ] **Step 5: Update buildConfig() to include defaultSchema**

Replace `buildConfig()` (lines 215-235) with:

```swift
private func buildConfig() -> ConnectionConfig {
    let sslMode: SslMode = {
        switch sslPopup.indexOfSelectedItem {
        case 1: return .require
        case 2: return .disable
        default: return .prefer
        }
    }()

    let defaultSchema: String? = {
        if defaultSchemaPopup.isEnabled,
           defaultSchemaPopup.indexOfSelectedItem > 0 {
            return defaultSchemaPopup.titleOfSelectedItem
        }
        // Preserve existing default if popup wasn't populated
        return existingConfig?.defaultSchema
    }()

    return ConnectionConfig(
        id: existingConfig?.id ?? UUID().uuidString,
        name: nameField.stringValue.isEmpty ? "Untitled" : nameField.stringValue,
        host: hostField.stringValue.isEmpty ? "localhost" : hostField.stringValue,
        port: UInt16(portField.stringValue) ?? 5432,
        database: databaseField.stringValue.isEmpty ? "postgres" : databaseField.stringValue,
        username: usernameField.stringValue.isEmpty ? "postgres" : usernameField.stringValue,
        password: passwordField.stringValue,
        sslMode: sslMode,
        color: existingConfig?.color,
        defaultSchema: defaultSchema
    )
}
```

- [ ] **Step 6: Commit**

```bash
git add Pharos/Sheets/ConnectionSheet.swift
git commit -m "feat: add Default Schema dropdown to Connection Sheet"
```

---

### Task 5: Add "Set as Default Schema" to schema selector dropdown

**Files:**
- Modify: `Pharos/ViewControllers/EditorPaneVC.swift:615-654` (rebuildSchemaMenu), and add new action method

- [ ] **Step 1: Update rebuildSchemaMenu() to add default badge and menu item**

Replace `rebuildSchemaMenu()` (lines 615-654) with:

```swift
private func rebuildSchemaMenu() {
    schemaPopup.removeAllItems()

    let schemas = metadataCache.schemas
    let activeSchema = tabSchemaName

    let isConnected: Bool
    if let activeId = tabConnectionId {
        isConnected = stateManager.status(for: activeId) == .connected
    } else {
        isConnected = false
    }

    guard isConnected, !schemas.isEmpty else {
        schemaPopup.addItem(withTitle: "No Schema")
        schemaPopup.isEnabled = false
        return
    }

    schemaPopup.isEnabled = true

    // Get default schema for the active connection
    let defaultSchema: String? = {
        guard let connId = tabConnectionId else { return nil }
        return stateManager.connections.first(where: { $0.id == connId })?.defaultSchema
    }()

    let titleText = activeSchema ?? "All Schemas"
    schemaPopup.addItem(withTitle: titleText)

    let allItem = NSMenuItem(title: "All Schemas", action: #selector(schemaItemClicked(_:)), keyEquivalent: "")
    allItem.target = self
    allItem.representedObject = nil
    if activeSchema == nil { allItem.state = .on }
    schemaPopup.menu?.addItem(allItem)

    schemaPopup.menu?.addItem(.separator())

    for schema in schemas {
        var title = schema.name
        if schema.name == defaultSchema {
            title += "  \u{2605} default"  // ★ default
        }
        let item = NSMenuItem(title: title, action: #selector(schemaItemClicked(_:)), keyEquivalent: "")
        item.target = self
        item.representedObject = schema.name
        if activeSchema == schema.name { item.state = .on }
        schemaPopup.menu?.addItem(item)
    }

    // Separator + "Set as Default Schema" action
    schemaPopup.menu?.addItem(.separator())
    let setDefaultItem = NSMenuItem(
        title: "Set as Default Schema",
        action: #selector(setDefaultSchemaClicked),
        keyEquivalent: ""
    )
    setDefaultItem.target = self
    schemaPopup.menu?.addItem(setDefaultItem)
}
```

- [ ] **Step 2: Add the setDefaultSchemaClicked action method**

Add this method in the "Connection / Schema Actions" section (after `schemaItemClicked` around line 779):

```swift
@objc private func setDefaultSchemaClicked() {
    guard let connId = tabConnectionId else { return }
    guard var config = stateManager.connections.first(where: { $0.id == connId }) else { return }

    // Current schema selection becomes the default (nil = "All Schemas" = clear default)
    let currentSchema = tabSchemaName
    config.defaultSchema = currentSchema
    stateManager.saveConnection(config)

    // Rebuild menu to update the badge
    rebuildSchemaMenu()
}
```

- [ ] **Step 3: Build in Xcode to verify**

Open Pharos.xcodeproj and build (Cmd+B).
Expected: Build succeeds

- [ ] **Step 4: Commit**

```bash
git add Pharos/ViewControllers/EditorPaneVC.swift
git commit -m "feat: add Set as Default Schema to schema selector dropdown"
```

---

### Task 6: Apply default schema to new tabs

**Files:**
- Modify: `Pharos/Core/AppStateManager.swift:301-322` (createTab), `112-140` (connect)

- [ ] **Step 1: Update createTab to apply default schema**

Replace the `createTab` method (lines 301-322) with:

```swift
/// Create a tab in a specific pane (defaults to focused pane).
@discardableResult
func createTab(inPane paneId: String? = nil, sql: String = "", name: String? = nil) -> QueryTab {
    let targetPaneId = paneId ?? focusedPaneId ?? panes.first?.id
    guard let targetPaneId, let paneIdx = panes.firstIndex(where: { $0.id == targetPaneId }) else {
        // Fallback: create without pane (backward compat)
        let tabName = name ?? "Query \(tabs.count + 1)"
        var tab = QueryTab(name: tabName, sql: sql)
        applyDefaultSchema(&tab)
        tabs.append(tab)
        activeTabId = tab.id
        return tab
    }

    let tabName = name ?? "Query \(tabs.count + 1)"
    var tab = QueryTab(name: tabName, sql: sql, paneId: targetPaneId)
    applyDefaultSchema(&tab)
    tabs.append(tab)
    panes[paneIdx].tabIds.append(tab.id)
    panes[paneIdx].activeTabId = tab.id
    focusedPaneId = targetPaneId
    activeTabId = tab.id
    return tab
}
```

- [ ] **Step 2: Add the applyDefaultSchema helper**

Add this private method after `createTab`:

```swift
/// Apply the active connection's default schema to a new tab.
private func applyDefaultSchema(_ tab: inout QueryTab) {
    guard let connId = activeConnectionId else { return }
    if let config = connections.first(where: { $0.id == connId }),
       let defaultSchema = config.defaultSchema {
        tab.connectionId = connId
        tab.schemaName = defaultSchema
    }
}
```

- [ ] **Step 3: Update connect() to use default schema instead of hardcoded "public"**

In the `connect` method (lines 112-140), replace the default schema logic (lines 121-131):

```swift
// Apply default schema from connection config, falling back to "public"
let defaultSchema: String = {
    if let config = self.connections.first(where: { $0.id == id }),
       let ds = config.defaultSchema {
        return ds
    }
    return "public"
}()
if self.schemaSelections[id] == nil {
    self.activeSchema = defaultSchema
}
// Also update the active tab's schema to match
if let tabId = self.activeTabId {
    self.updateTab(id: tabId) { tab in
        if tab.connectionId == id && tab.schemaName == nil {
            tab.schemaName = self.activeSchema ?? defaultSchema
        }
    }
}
```

- [ ] **Step 4: Build in Xcode to verify**

Open Pharos.xcodeproj and build (Cmd+B).
Expected: Build succeeds

- [ ] **Step 5: Commit**

```bash
git add Pharos/Core/AppStateManager.swift
git commit -m "feat: apply default schema to new tabs and on connect"
```

---

### Task 7: Manual testing

- [ ] **Step 1: Build and run the app**

Build the Rust library and regenerate the Xcode project:
```bash
cd pharos-core && cargo build --release
```
Then build and run from Xcode (Cmd+R).

- [ ] **Step 2: Test Connection Sheet — new connection**

1. Click "New Connection"
2. Verify "Default Schema" dropdown is present, disabled, showing "Test connection first"
3. Fill in connection details and click "Test Connection"
4. After success, verify the Default Schema dropdown enables and shows "None" + schema list
5. Select a schema (e.g., "public")
6. Save the connection

- [ ] **Step 3: Test Connection Sheet — edit connection**

1. Right-click the saved connection, choose "Edit"
2. Verify Default Schema dropdown shows "Test connection first" (disabled)
3. Click "Test Connection"
4. After success, verify the dropdown shows the previously saved default selected
5. Change it and save

- [ ] **Step 4: Test schema selector — set default**

1. Connect to a database
2. Select a schema from the dropdown
3. Verify "Set as Default Schema" appears at bottom of dropdown
4. Click it
5. Reopen dropdown — verify the "★ default" badge appears on that schema

- [ ] **Step 5: Test schema selector — clear default**

1. Select "All Schemas" from the dropdown
2. Click "Set as Default Schema"
3. Reopen dropdown — verify no schema has the "★ default" badge

- [ ] **Step 6: Test new tab default**

1. Set a default schema (e.g., "whois")
2. Open a new tab (Cmd+T or +)
3. Verify the new tab starts with "whois" selected in the schema dropdown

- [ ] **Step 7: Test existing tabs unaffected**

1. Have a tab with schema "public" selected
2. Set default to "whois"
3. Verify the existing tab still shows "public"
