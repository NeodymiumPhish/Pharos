# Architecture

**Analysis Date:** 2025-02-24

## Pattern Overview

**Overall:** Native macOS app (Swift + AppKit) with a C FFI bridge to a Rust core library.

**Key Characteristics:**
- **Layered architecture**: UI (Swift/AppKit) ↔ FFI bridge ↔ Rust backend (commands, database)
- **Async/await pattern**: Swift `async/await` wraps Rust C callbacks
- **State management**: Singleton `AppStateManager` with Combine `@Published` properties
- **Type-erased callbacks**: C function pointers bridge Swift continuations through void* context
- **SQLite + PostgreSQL**: Local metadata DB + remote PostgreSQL connections

## Layers

**Presentation Layer (Swift UI):**
- Purpose: macOS AppKit window, views, user interaction, state observation
- Location: `Pharos/ViewControllers/`, `Pharos/Views/`, `Pharos/Sheets/`
- Contains: NSViewController subclasses (ContentViewController, SchemaBrowserVC, etc.), custom NSView implementations, NSTableView data sources
- Depends on: AppStateManager, MetadataCache, PharosCore
- Used by: AppDelegate (init)

**State Management Layer (Swift):**
- Purpose: Central Observable state for connections, tabs, settings, schema selection
- Location: `Pharos/Core/AppStateManager.swift`, `Pharos/Core/MetadataCache.swift`
- Contains: `@Published` properties, connection lifecycle, tab management, schema caching
- Depends on: PharosCore (async operations)
- Used by: All view controllers (via `@Published` subscription via Combine)

**Swift Bridge Layer (FFI):**
- Purpose: Type-safe Swift wrappers around C FFI, async/await integration
- Location: `Pharos/Core/PharosCore.swift`
- Contains: `enum PharosCore` with static methods wrapping C functions, `CallbackBox` for type erasure, JSON encoding/decoding
- Depends on: CPharosCore (C header), Foundation JSON codecs
- Used by: AppStateManager, view controllers for all database operations

**C FFI Boundary:**
- Purpose: Thin C interface exported from Rust static library
- Location: `Pharos/CPharosCore/module.modulemap` (declaration), `pharos-core/src/ffi.rs` (implementation)
- Contains: C function signatures (`pharos_init`, `pharos_execute_query`, etc.), callback type definition
- Depends on: Rust libpharos_core.a
- Used by: PharosCore.swift

**Rust Backend (Commands & Database):**
- Purpose: Database operations, SQL execution, metadata fetching, persistence
- Location: `pharos-core/src/commands/`, `pharos-core/src/db/`, `pharos-core/src/models/`
- Contains: Command handlers (connection, query, metadata, saved_query, query_history, table, settings), PostgreSQL + SQLite drivers, connection pooling
- Depends on: sqlx (PostgreSQL), rusqlite (SQLite), tokio (async runtime), serde (JSON)
- Used by: FFI layer (callbacks return JSON)

## Data Flow

**Connection Lifecycle:**

1. User clicks connection in popup → `connectionItemClicked` → `AppStateManager.activeConnectionId = id`
2. MainWindowController observes `$activeConnectionId`, calls `stateManager.connect(id:)`
3. `AppStateManager.connect()` → `Task { PharosCore.connect(connectionId) }`
4. `PharosCore.connect()` → `withAsyncCallback { pharos_connect(...) }`
5. Rust FFI spawns async task on tokio runtime: `commands::connection::connect()`
6. Upon completion, callback invokes Swift continuation with JSON result
7. `AppStateManager` updates `connectionStatuses` and posts `NSNotification`
8. MainWindowController observes `$connectionStatuses`, rebuilds connection popup UI
9. MetadataCache observes `$activeConnectionId`, loads schemas via `PharosCore.getSchemas()`

**Query Execution:**

1. User enters SQL in editor (synced to `activeTab.sql` via `textDidChange`)
2. User presses Cmd+Enter or clicks Run toolbar button
3. `ContentViewController.executeQuery(sql)` → `PharosCore.executeQuery(connectionId, sql, limit)`
4. Swift callback wraps continuation: `withAsyncCallback` → `pharos_execute_query()`
5. Rust command executes via sqlx: `commands::query::execute_query()`
   - Creates query ID, registers in `AppState.running_queries`
   - Executes with pagination limit (default 1000)
   - Caches first row in query history
6. Callback returns JSON `QueryResult` (columns, rows, rowCount, hasMore)
7. Swift decoder deserializes → `ResultsGridVC` displays in NSTableView
8. User clicks "Load More" → `PharosCore.fetchMoreRows(offset)` for next batch

**Metadata Loading:**

1. Connection established → MetadataCache loads schemas
2. `MetadataCache.load(connectionId)` calls `PharosCore.getSchemas()`
3. Schema list returned, immediately published to UI (schema popup usable)
4. Background task loads tables + columns per schema via `getSchemaColumns()`
5. Data cached in-memory for SQL autocomplete (SQLCompletionProvider)
6. User selects schema in dropdown → `MetadataCache.prioritize(schema)` reorders load
7. If analyze requested, `PharosCore.analyzeSchema()` populates row count estimates

**Settings & Persistence:**

1. AppDelegate calls `AppStateManager.loadConnections()` at startup
2. `PharosCore.loadConnections()` reads from local SQLite DB
3. User edits settings → `SettingsSheet` calls `stateManager.saveSettings()`
4. `PharosCore.saveSettings()` writes to SQLite
5. Settings also cached in-memory in `AppStateManager.@Published settings`

## Key Abstractions

**AppState (Rust):**
- Purpose: Central mutable state holding connection pools, running queries, SQLite DB
- Examples: `pharos-core/src/state.rs`
- Pattern: Mutex-protected HashMap for thread-safe access, Arc for shared ownership
- Used by: All command handlers

**CallbackBox (Swift):**
- Purpose: Type-erased box to carry generic closures through void* context
- Examples: `Pharos/Core/PharosCore.swift` lines 441-445
- Pattern: Class wrapper preserving closure capturing, Unmanaged for opaque pointer conversion
- Rationale: C function pointers cannot be generic; boxing preserves type info at runtime

**SchemaTreeNode (Swift):**
- Purpose: Tree node for schema browser outline view (NSOutlineView requires class types)
- Examples: `Pharos/ViewControllers/SchemaBrowserVC.swift`
- Pattern: Parent/child relationships, lazy loading of table/column children, row count tracking
- Used by: SchemaBrowserVC outline view data source

**PGTypeCategory (Swift):**
- Purpose: Classify PostgreSQL data types for cell formatting (numeric right-align, etc.)
- Examples: `Pharos/ViewControllers/ResultsGridVC.swift` lines 46-82
- Pattern: Enum with init(dataType:) parsing
- Used by: ResultsGridVC for column alignment and display formatting

**QueryTab (Swift Model):**
- Purpose: In-memory representation of an editor tab (SQL text, connection, execution state)
- Examples: `Pharos/Models/QueryTab.swift`
- Pattern: Codable struct with unique ID, captures at point in time (not persisted between sessions)
- Used by: AppStateManager tab management, ContentViewController tab switching

## Entry Points

**App Launch:**
- Location: `Pharos/App/main.swift`
- Triggers: System launches app
- Responsibilities: Create NSApplication, set AppDelegate, call `app.run()`

**Initialization:**
- Location: `Pharos/App/AppDelegate.swift`, `applicationDidFinishLaunching`
- Triggers: App startup
- Responsibilities:
  1. Call `pharos_init(appSupportDir)` (Rust: initialize tokio runtime, SQLite DB)
  2. Load connections, settings from Rust via PharosCore
  3. Apply theme
  4. Build main menu
  5. Create and show MainWindowController

**Window Setup:**
- Location: `Pharos/Windows/MainWindowController.swift`
- Triggers: AppDelegate init
- Responsibilities:
  1. Create NSWindow with unified toolbar
  2. Create toolbar with connection/schema popups and action buttons
  3. Install PharosSplitViewController (NSSplitViewController with sidebar + content)
  4. Observe AppStateManager published properties, rebuild UI on changes

**Sidebar/Navigator:**
- Location: `Pharos/ViewControllers/SidebarViewController.swift`
- Triggers: User views sidebar (visible by default)
- Responsibilities:
  1. NSSegmentedControl to switch between Navigator (schema browser) and Library (saved/history)
  2. Container view swaps between SchemaBrowserVC, SavedQueriesVC, QueryHistoryVC

**Editor & Results:**
- Location: `Pharos/ViewControllers/ContentViewController.swift`
- Triggers: Tab selection, connection change
- Responsibilities:
  1. Manage QueryTabBar (tab list with drag-reorder)
  2. Swap QueryEditorVC in/out when tab changes
  3. Execute query and pass results to ResultsGridVC
  4. Handle tab lifecycle (create, close, rename, reopen)

## Error Handling

**Strategy:** Errors from C/Rust are returned as JSON via callback, decoded to Swift exceptions.

**Patterns:**

1. **Async Callback Errors:**
   ```swift
   // PharosCore.swift: withAsyncCallback checks error_msg parameter
   if let errorMsg {
       continuation.resume(throwing: PharosCoreError.rustError(error))
   }
   ```
   - Rust FFI returns error via callback; Swift continuation throws
   - View controllers catch with `try`/`catch`, display NSAlert

2. **Synchronous Operation Errors:**
   ```swift
   // saveConnection, deleteConnection, etc.
   let error = pharos_save_connection(json)
   if let error { throw PharosCoreError.rustError(String(cString: error)) }
   ```
   - C function returns null on success, error string on failure
   - Swift wraps in enum, throws immediately

3. **Decoding Errors:**
   ```swift
   do {
       let decoded = try JSONDecoder.pharos.decode(T.self, from: Data(json.utf8))
   } catch {
       continuation.resume(throwing: PharosCoreError.decodingError(json, error))
   }
   ```
   - JSON parsing failures are caught, context preserved (JSON snippet in error)

4. **User-Facing Error Display:**
   - View controllers wrap async calls in try/catch
   - Errors displayed as NSAlert or logged to console
   - No automatic retry (user must fix and re-execute)

5. **Rust Error Propagation:**
   - Command handlers return `Result<T, Box<dyn std::error::Error>>`
   - Error converted to JSON with message field
   - FFI callback receives as `error_msg` parameter

## Cross-Cutting Concerns

**Logging:**
- Approach: NSLog (standard Apple logging) for events; tokio runtime logs via env_logger
- Uses: Connection errors, failed queries, metadata load issues
- Location: Each command handler uses `log::error!` or `log::info!`, Swift uses `NSLog()`

**Validation:**
- Approach: SQL syntax validation via `PharosCore.validateSQL()` before execution (debounced, typed in editor)
- Uses: Client-side syntax check before server-side execution
- Location: QueryEditorVC triggers async validation on text change, displays error inline

**Authentication:**
- Approach: Passwords loaded from macOS Keychain on app init into memory cache
- Uses: Connection pooling authenticates with cached password (no re-prompt per query)
- Location: `pharos-core/src/db/credentials.rs` loads from Keychain, `AppState.password_cache` holds in-memory copy
- Limitation: Password not re-prompted if keychain entry updated mid-session

**Connection Pooling:**
- Approach: sqlx PgPool for each connection ID (pooling is per-connection, not global)
- Uses: Connection reuse across queries, automatic reconnect on pool exhaustion
- Location: `AppState.connections` HashMap<String, PgPool>, managed by Rust commands

**Query Cancellation:**
- Approach: Running query registered in `AppState.running_queries` with backend PID, cancellable via PostgreSQL `pg_cancel_backend()`
- Uses: User clicks cancel button in results, stops long-running query
- Location: `commands::query::cancel_query()` uses registered PID

**Transaction Isolation:**
- Approach: Not explicitly managed; each query is auto-commit or respects explicit `BEGIN/COMMIT`
- Uses: User can execute multi-statement transactions if SQL contains BEGIN/COMMIT
- Limitation: No transaction state tracking in UI (user must manage via SQL)

---

*Architecture analysis: 2025-02-24*
