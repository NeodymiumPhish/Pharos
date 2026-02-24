# Codebase Structure

**Analysis Date:** 2025-02-24

## Directory Layout

```
Pharos/
├── App/                        # Application entry point and lifecycle
│   ├── main.swift             # App initialization
│   ├── AppDelegate.swift       # Rust init, state load, menu setup
│   └── MainMenu.swift          # Main menu bar actions
├── Core/                       # State & bridge to Rust
│   ├── AppStateManager.swift   # Central @Published state (singleton)
│   ├── MetadataCache.swift     # Schema/table/column cache
│   └── PharosCore.swift        # C FFI bridge with async/await
├── Models/                     # Data structures (Codable)
│   ├── Connection.swift        # ConnectionConfig, ConnectionStatus, TestResult
│   ├── QueryResult.swift       # QueryResult, ExecuteResult, ValidationResult
│   ├── QueryTab.swift          # In-memory tab representation
│   ├── Schema.swift            # SchemaInfo, TableInfo, ColumnInfo
│   ├── SavedQuery.swift        # SavedQuery, CreateSavedQuery
│   ├── QueryHistory.swift      # QueryHistoryEntry, QueryHistoryFilter
│   └── Settings.swift          # AppSettings (theme, font, etc.)
├── ViewControllers/            # AppKit NSViewController subclasses
│   ├── MainWindowController.swift     # Window setup, toolbar, popups
│   ├── PharosSplitViewController.swift # NSSplitViewController (sidebar + content)
│   ├── SidebarViewController.swift     # Navigator/Library tab switching
│   ├── ContentViewController.swift     # Tab bar + editor + results
│   ├── QueryEditorVC.swift            # SQL text editor with line numbers
│   ├── ResultsGridVC.swift            # NSTableView for result rows
│   ├── SchemaBrowserVC.swift          # Outline view of schemas/tables/columns
│   ├── SavedQueriesVC.swift           # Outline view of saved query folders
│   └── QueryHistoryVC.swift           # NSTableView of recent queries
├── Views/                      # Custom NSView implementations
│   └── QueryTabBar.swift       # Custom tab bar with drag-reorder
├── Sheets/                     # Modal dialog sheets (NSViewController)
│   ├── ConnectionSheet.swift   # New/edit connection dialog
│   ├── ExportDataSheet.swift   # Export query results
│   ├── ImportDataSheet.swift   # Import CSV into table
│   ├── SaveQuerySheet.swift    # Save current query to library
│   ├── SchemaDetailSheet.swift # View schema DDL/details
│   ├── SettingsSheet.swift     # App settings (theme, font)
│   └── CloneTableSheet.swift   # Clone table structure/data
├── Editor/                     # SQL editor components
│   ├── SQLTextView.swift       # Custom NSTextView with syntax highlighting
│   ├── SQLCompletionProvider.swift # Autocomplete provider
│   └── LineNumberGutter.swift  # Line number ruler
├── Utilities/                  # Helpers (empty dir in current state)
├── Resources/                  # Assets (icons, localization)
├── CPharosCore/                # C FFI declaration
│   └── module.modulemap        # Bridging module for Pharos-core.h
└── Windows/                    # Window controllers
    └── MainWindowController.swift # Moved from elsewhere

pharos-core/                    # Rust static library (libpharos_core.a)
├── src/
│   ├── lib.rs                  # Module declarations
│   ├── ffi.rs                  # C FFI entry points (pharos_init, pharos_execute_query, etc.)
│   ├── state.rs                # AppState struct (connection pools, running queries, SQLite DB)
│   ├── commands/               # FFI command handlers
│   │   ├── mod.rs
│   │   ├── connection.rs       # pharos_connect, pharos_disconnect, pharos_test_connection
│   │   ├── query.rs            # pharos_execute_query, pharos_cancel_query, pharos_validate_sql
│   │   ├── metadata.rs         # pharos_get_schemas, pharos_get_tables, pharos_get_columns
│   │   ├── query_history.rs    # pharos_load_query_history, pharos_delete_query_history_entry
│   │   ├── saved_query.rs      # pharos_create_saved_query, pharos_update_saved_query
│   │   ├── settings.rs         # pharos_load_settings, pharos_save_settings
│   │   └── table.rs            # pharos_clone_table, pharos_export_table, pharos_import_csv
│   ├── db/                     # Database drivers
│   │   ├── mod.rs
│   │   ├── postgres.rs         # sqlx PostgreSQL operations
│   │   ├── sqlite.rs           # rusqlite local DB (connections, saved queries, settings)
│   │   └── credentials.rs      # Keychain password loading
│   └── models/                 # Shared data structures (Codable to JSON)
│       ├── mod.rs
│       ├── connection.rs       # ConnectionConfig, ConnectionInfo
│       ├── query_history.rs    # QueryHistoryEntry
│       ├── saved_query.rs      # SavedQuery
│       ├── schema.rs           # SchemaInfo, TableInfo, ColumnInfo
│       └── settings.rs         # AppSettings
├── Cargo.toml                  # Rust dependencies
├── Cargo.lock
└── target/                     # Build output (debug/ and release/)
    ├── release/
    │   └── libpharos_core.a    # Linked by Xcode into app binary
    └── debug/

project.yml                    # xcodegen config (generates Pharos.xcodeproj)
Pharos.xcodeproj/              # Generated Xcode project (do not edit)
```

## Directory Purposes

**App/:**
- Purpose: Application entry point, lifecycle, initialization
- Contains: NSApplication setup, AppDelegate with Rust initialization, main menu configuration
- Key files: `main.swift` (app entry), `AppDelegate.swift` (Rust init via pharos_init), `MainMenu.swift` (menu bar actions)

**Core/:**
- Purpose: State management and Rust/C bridge
- Contains: Singleton AppStateManager with @Published properties (connections, tabs, settings), MetadataCache for schema caching, PharosCore enum with all C FFI wrappers
- Key files: `AppStateManager.swift` (central state), `PharosCore.swift` (C function wrappers + async/await bridge), `MetadataCache.swift` (schema/table/column cache)

**Models/:**
- Purpose: Data structures matching Rust models, Codable for JSON transport
- Contains: Connection configs, query results, schema metadata, saved queries, query history, settings
- Pattern: Struct + enum with custom CodingKeys for snake_case ↔ camelCase conversion
- Key files: `Connection.swift` (ConnectionConfig, ConnectionStatus), `QueryResult.swift` (result rows + metadata), `Schema.swift` (metadata tree)

**ViewControllers/:**
- Purpose: UI presentation logic, view hierarchy management
- Contains: NSViewController subclasses managing windows, split views, tabs, editors, tables, outlines
- Key files:
  - `MainWindowController.swift` - Window, toolbar setup, connection/schema popups
  - `ContentViewController.swift` - Tab bar, editor/results split, query execution
  - `SchemaBrowserVC.swift` - Outline view of database schemas
  - `ResultsGridVC.swift` - NSTableView for query results with filtering/copying

**Views/:**
- Purpose: Custom UI components (not view controllers)
- Contains: Custom NSView implementations
- Key files: `QueryTabBar.swift` (tab bar with drag-to-reorder via CALayer snapshots)

**Sheets/:**
- Purpose: Modal dialog windows
- Contains: Modal NSViewController subclasses for user input (new connection, export, import, save query, settings, etc.)
- Key files: `ConnectionSheet.swift` (connection form), `SettingsSheet.swift` (app settings), `ExportDataSheet.swift` (export options)

**Editor/:**
- Purpose: SQL editor components (text view, syntax, completion, line numbers)
- Contains: Custom NSTextView with Monaco-style editing, SQL keyword highlighting, autocomplete provider, line number gutter
- Key files: `SQLTextView.swift` (main editor), `SQLCompletionProvider.swift` (autocomplete from metadata), `LineNumberGutter.swift` (line number ruler)

**CPharosCore/:**
- Purpose: C language module bridging for Rust FFI
- Contains: `module.modulemap` which tells Swift compiler where the C header (pharos_core.h) is located
- Note: Header generated by cbindgen from `pharos-core/src/ffi.rs`

**pharos-core/src/commands/:**
- Purpose: FFI command handlers (Rust side of C boundary)
- Contains: Functions invoked via C callbacks, perform database operations, return JSON results
- Key files:
  - `connection.rs` - Connect/disconnect/test PostgreSQL
  - `query.rs` - Execute queries with cancellation, validation
  - `metadata.rs` - Fetch schemas, tables, columns, indexes, constraints
  - `saved_query.rs` - CRUD for saved queries (local SQLite)
  - `query_history.rs` - Load/delete query history (local SQLite)
  - `settings.rs` - Load/save app settings (local SQLite)
  - `table.rs` - Clone table, export to CSV/XLSX, import from CSV

**pharos-core/src/db/:**
- Purpose: Database drivers and credential management
- Contains: PostgreSQL operations via sqlx, local SQLite operations via rusqlite, Keychain password loading
- Key files:
  - `postgres.rs` - All sqlx queries for PostgreSQL introspection and execution
  - `sqlite.rs` - Connection configs, saved queries, settings storage
  - `credentials.rs` - Load passwords from macOS Keychain on app startup

**pharos-core/src/models/:**
- Purpose: Data structures shared between Rust and Swift (via JSON)
- Contains: Codable structs with serde serialization
- Key files: `connection.rs`, `schema.rs`, `saved_query.rs`, `query_history.rs`, `settings.rs`

## Key File Locations

**Entry Points:**
- `Pharos/App/main.swift`: NSApplication entry
- `Pharos/App/AppDelegate.swift`: App initialization (Rust pharos_init, load state, show window)
- `Pharos/Windows/MainWindowController.swift`: Main window setup

**Configuration:**
- `project.yml`: xcodegen config (deployment target, bundle ID, Rust build pre-script)
- `pharos-core/Cargo.toml`: Rust dependencies
- `Pharos/App/Info.plist`: App bundle configuration

**Core Logic:**
- `Pharos/Core/AppStateManager.swift`: Central state with tab/connection/settings management
- `Pharos/Core/PharosCore.swift`: All C FFI wrappers (sync + async)
- `Pharos/Core/MetadataCache.swift`: Schema cache for autocomplete and navigator
- `pharos-core/src/ffi.rs`: C function definitions and callback routing to Rust commands
- `pharos-core/src/state.rs`: Rust AppState with connection pools and query tracking

**UI Components:**
- `Pharos/ViewControllers/ContentViewController.swift`: Tab bar + editor + results layout
- `Pharos/ViewControllers/SchemaBrowserVC.swift`: Database schema outline view
- `Pharos/ViewControllers/ResultsGridVC.swift`: Result grid with filtering, sorting, export
- `Pharos/Views/QueryTabBar.swift`: Custom tab bar with drag-reorder

**Testing:**
- Not yet implemented (no test files found)

## Naming Conventions

**Files:**
- Swift: `PascalCase.swift` (e.g., `AppDelegate.swift`, `QueryEditorVC.swift`)
- Rust: `snake_case.rs` (e.g., `connection.rs`, `query_history.rs`)
- Custom suffixes:
  - `*VC.swift` - NSViewController subclass
  - `*Sheet.swift` - Modal NSViewController dialog
  - `*Provider.swift` - Delegate/data source helper

**Directories:**
- Swift: PascalCase (e.g., `ViewControllers`, `Models`, `Sheets`)
- Rust: snake_case (e.g., `commands`, `db`, `models`)

**Code:**
- Swift: camelCase for functions/properties (e.g., `loadConnections()`, `activeConnectionId`)
- Rust: snake_case for functions/variables (e.g., `load_connections()`, `active_connection_id`)
- Models: Match Rust camelCase via CodingKeys (e.g., `executionTimeMs` ↔ `execution_time_ms`)

## Where to Add New Code

**New Feature:**
- Primary code: `pharos-core/src/commands/{module}.rs` (Rust handler)
- FFI declaration: `pharos-core/src/ffi.rs` (C function + callback routing)
- Swift bridge: `Pharos/Core/PharosCore.swift` (async wrapper)
- UI: `Pharos/ViewControllers/{Feature}VC.swift` or `Pharos/Sheets/{Feature}Sheet.swift`
- Models: Add to `pharos-core/src/models/{domain}.rs` and mirror in `Pharos/Models/{Domain}.swift`

**New View Controller:**
- Create: `Pharos/ViewControllers/{Name}VC.swift` subclassing NSViewController
- Register: Add as child VC in parent controller via `addChild()` and view hierarchy
- State: Subscribe to `AppStateManager` @Published properties via Combine sinks
- Actions: Define callbacks or actions linking back to state/Rust via PharosCore

**New Modal Dialog:**
- Create: `Pharos/Sheets/{Name}Sheet.swift` extending NSViewController
- Present: Call `presentAsSheet()` on parent window controller
- Callbacks: Accept completion handlers for user input, call back to AppStateManager/PharosCore
- Example: `ConnectionSheet` (new/edit connection form) calls `stateManager.saveConnection(config)`

**Rust Command:**
- File: `pharos-core/src/commands/{module}.rs` (or extend existing module)
- Function: `async fn handle_{action}(...) -> Result<T, Box<dyn Error>>`
- FFI Wrapper: Add `pub extern "C" fn pharos_{action}(..., callback, context)` in `ffi.rs`
- Routing: In `ffi.rs`, spawn task on runtime and invoke callback with result JSON
- Models: Add types to `pharos-core/src/models/{module}.rs`, ensure Codable/Serialize

**Shared Model:**
- Rust: Add to `pharos-core/src/models/{domain}.rs` with `#[derive(Serialize, Deserialize)]`
- Swift: Mirror in `Pharos/Models/{Domain}.swift` with `Codable`, custom `CodingKeys` for key conversion
- Key pattern: Rust uses snake_case, Swift uses camelCase, CodingKeys maps between them

## Special Directories

**pharos-core/target/:**
- Purpose: Build output
- Generated: Yes (cargo build)
- Committed: No (.gitignored)
- Includes: `release/libpharos_core.a` (linked into app) and `debug/` variant

**Pharos.xcodeproj/:**
- Purpose: Xcode project (generated, do not edit by hand)
- Generated: Yes (xcodegen generates from `project.yml`)
- Committed: No (in most projects)
- Regenerate: Run `xcodegen generate` after adding Swift files to project

**Pharos/CPharosCore/:**
- Purpose: C FFI module bridge for Swift compiler
- Contains: `module.modulemap` only (declares header location)
- Header location: `pharos-core/include/pharos_core.h` (generated by cbindgen from FFI code)
- Regenerate: `cbindgen` run automatically in Rust build script

**Pharos/Resources/:**
- Purpose: Assets (icons, localization, etc.)
- Generated: No
- Committed: Yes

---

*Structure analysis: 2025-02-24*
