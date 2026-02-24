# Codebase Structure

**Analysis Date:** 2025-02-24

## Directory Layout

```
/Users/nfinn/Projects/Pharos/
├── src/                              # React frontend source code
│   ├── components/                   # React UI components (organized by feature)
│   │   ├── dialogs/                  # Modal dialogs (connection, settings, export, etc.)
│   │   ├── editor/                   # Query editor (Monaco), SQL autocomplete
│   │   ├── layout/                   # Main layout (toolbar, sidebar, workspace)
│   │   ├── results/                  # Results grid (virtualized), explain view
│   │   ├── saved/                    # Saved queries panel
│   │   ├── tree/                     # Schema tree browser
│   │   ├── ui/                       # Utility components (status bar, etc.)
│   │   └── history/                  # Query history panel
│   ├── stores/                       # Zustand state management
│   │   ├── connectionStore.ts        # Connection list, active connection, schema selection
│   │   ├── editorStore.ts            # Query tabs, execution state, results
│   │   ├── settingsStore.ts          # UI preferences, theme, column widths
│   │   ├── savedQueryStore.ts        # Saved queries from backend
│   │   └── queryHistoryStore.ts      # Query execution history
│   ├── hooks/                        # Custom React hooks
│   ├── lib/                          # Utilities and types
│   │   ├── tauri.ts                  # Tauri command wrappers (IPC bridge)
│   │   ├── types.ts                  # TypeScript interfaces (connections, schema, query results)
│   │   └── cn.ts                     # Classname utility
│   ├── assets/                       # Icons, images
│   ├── App.tsx                       # Root component
│   ├── main.tsx                      # Entry point
│   ├── index.css                     # Global styles, theme CSS variables
│   └── vite-env.d.ts                 # Vite type definitions
│
├── src-tauri/                        # Rust backend
│   ├── src/
│   │   ├── lib.rs                    # Tauri app setup, plugin config, command registration
│   │   ├── main.rs                   # Binary entry (empty, uses lib.rs)
│   │   ├── state.rs                  # AppState: connection pools, queries, password cache
│   │   ├── commands/                 # Tauri command handlers
│   │   │   ├── mod.rs                # Command module exports
│   │   │   ├── connection.rs         # Connect, disconnect, test, list connections
│   │   │   ├── query.rs              # Execute query, cancel, fetch more rows
│   │   │   ├── metadata.rs           # Get schemas, tables, columns, indexes, constraints
│   │   │   ├── table.rs              # Clone table, import/export CSV/XLSX/SQL, data editing
│   │   │   ├── saved_query.rs        # CRUD for saved queries
│   │   │   ├── settings.rs           # Load/save app settings
│   │   │   └── query_history.rs      # Load/delete query history
│   │   ├── db/                       # Database operations
│   │   │   ├── mod.rs                # Database module exports
│   │   │   ├── postgres.rs           # sqlx PostgreSQL: create pool, run queries, introspection
│   │   │   ├── sqlite.rs             # SQLite: init, load/save configs, saved queries, history
│   │   │   └── credentials.rs        # Keychain password migration and management
│   │   └── models/                   # Data structures (Serde)
│   │       ├── mod.rs                # Model module exports
│   │       ├── connection.rs         # ConnectionConfig, ConnectionInfo
│   │       ├── schema.rs             # SchemaInfo, TableInfo, ColumnInfo, TableType
│   │       ├── saved_query.rs        # SavedQuery, CreateSavedQuery
│   │       ├── query_history.rs      # QueryHistoryEntry, QueryHistoryResultData
│   │       └── settings.rs           # AppSettings, UISettings
│   │
│   ├── Cargo.toml                    # Rust dependencies
│   ├── tauri.conf.json               # Tauri configuration
│   ├── icons/                        # App icons
│   └── capabilities/                 # Permission configurations
│
├── Pharos/                           # Swift/AppKit native frontend (appkit branch only)
│   ├── App/
│   │   ├── AppDelegate.swift         # NSApplicationDelegate, app lifecycle
│   │   └── MainMenu.swift            # macOS menu bar
│   ├── Core/
│   │   ├── PharosCore.swift          # C FFI bridge to pharos-core Rust library
│   │   ├── AppStateManager.swift     # Singleton state with Combine publishers
│   │   └── MetadataCache.swift       # Local schema metadata cache
│   ├── Models/
│   │   ├── Connection.swift          # Codable connection config/status
│   │   ├── Schema.swift              # Codable schema metadata
│   │   ├── QueryResult.swift         # Codable query results
│   │   ├── SavedQuery.swift          # Codable saved query
│   │   ├── QueryHistory.swift        # Codable history entry
│   │   ├── Settings.swift            # Codable app settings
│   │   └── QueryTab.swift            # Codable query tab state
│   ├── ViewControllers/
│   │   ├── PharosSplitViewController.swift  # NSSplitViewController (sidebar + content)
│   │   ├── SidebarViewController.swift      # NSSegmentedControl (Navigator, Library)
│   │   ├── SchemaBrowserVC.swift           # NSOutlineView for schema tree
│   │   ├── SavedQueriesVC.swift            # NSOutlineView for saved queries
│   │   ├── QueryHistoryVC.swift            # NSTableView for history
│   │   ├── QueryEditorVC.swift             # WebKit WKWebView for React editor
│   │   ├── ContentViewController.swift      # Container for editor + results
│   │   └── ResultsGridVC.swift             # Results table display
│   ├── Windows/
│   │   └── MainWindowController.swift      # NSWindowController, toolbar setup
│   ├── Sheets/
│   │   ├── ConnectionSheet.swift           # Add/edit connection dialog
│   │   ├── SettingsSheet.swift             # Settings/preferences dialog
│   │   ├── SaveQuerySheet.swift            # Save query as named query
│   │   ├── ExportDataSheet.swift           # Export table/results dialog
│   │   ├── ImportDataSheet.swift           # Import CSV/JSON dialog
│   │   ├── CloneTableSheet.swift           # Clone table dialog
│   │   └── SchemaDetailSheet.swift         # Show schema/table details
│   ├── Views/
│   │   └── QueryTabBar.swift               # Drag-and-drop query tab bar
│   ├── Editor/
│   │   └── CodeEditor.swift                # Web-based SQL editor (Monaco in WKWebView)
│   ├── Utilities/
│   │   └── Extensions, helpers, utils
│   ├── Resources/
│   │   └── Localization, assets
│   └── CPharosCore/
│       └── Bridging header for C FFI
│
├── pharos-core/                      # Rust static library (shared by appkit)
│   ├── src/
│   │   ├── lib.rs                    # Library entry, FFI exports
│   │   ├── ffi.rs                    # C FFI function declarations
│   │   ├── db/                       # Database operations (sqlx PostgreSQL, rusqlite SQLite)
│   │   ├── models/                   # Data structures
│   │   └── commands/                 # Business logic
│   ├── Cargo.toml                    # Rust dependencies
│   └── include/
│       └── pharos_core.h             # Generated C header (cbindgen)
│
├── package.json                      # npm dependencies (React, Tauri, Vite, Tailwind, etc.)
├── tsconfig.json                     # TypeScript configuration
├── vite.config.ts                    # Vite build configuration
├── tailwind.config.js                # Tailwind CSS configuration
├── postcss.config.js                 # PostCSS configuration
├── index.html                        # HTML entry point (loads React into #root)
├── project.yml                       # Xcode project generator config
└── Pharos.xcodeproj/                 # Generated Xcode project
```

## Directory Purposes

**src/components/dialogs/:**
- Purpose: Modal dialogs for user interaction
- Contains:
  - `AddConnectionDialog.tsx` - New connection form
  - `EditConnectionDialog.tsx` - Edit existing connection
  - `SettingsDialog.tsx` - App preferences (theme, shortcuts, columns)
  - `SaveQueryDialog.tsx` - Save query with name/folder
  - `ExportResultsDialog.tsx` - Export query results to file
  - `ExportDataDialog.tsx` - Export table to CSV/XLSX/SQL
  - `ImportDataDialog.tsx` - Import CSV/JSON to table
  - `CloneTableDialog.tsx` - Clone table structure
  - `AboutDialog.tsx` - About screen

**src/components/editor/:**
- Purpose: Query SQL editing and input
- Contains:
  - `QueryEditor.tsx` - Monaco editor with syntax highlighting, keybindings
  - `QueryTabs.tsx` - Tab bar for multiple queries
  - `SqlAutocomplete.ts` - Autocomplete provider for PostgreSQL

**src/components/layout/:**
- Purpose: Main application layout and organization
- Contains:
  - `QueryWorkspace.tsx` - Query editor + results grid + saved queries panel
  - `DatabaseNavigator.tsx` - Schema tree sidebar with search
  - `ServerRail.tsx` - Connection selector with status
  - `Toolbar.tsx` - Top toolbar with buttons

**src/components/results/:**
- Purpose: Display and interact with query results
- Contains:
  - `ResultsGrid.tsx` - Virtualized table showing rows/columns with editing, filtering
  - `ExplainView.tsx` - Display EXPLAIN ANALYZE output as tree

**src/components/saved/:**
- Purpose: Saved queries library
- Contains: `SavedQueriesPanel.tsx` - Browse, search, execute saved queries

**src/components/tree/:**
- Purpose: Schema hierarchy visualization
- Contains: `SchemaTree.tsx` - Recursive tree component for schemas → tables → columns

**src/components/history/:**
- Purpose: Query execution history
- Contains: `QueryHistoryPanel.tsx` - Chronological list of executed queries with result caching

**src/stores/:**
- Purpose: Zustand state containers for frontend
- Key pattern: `create<StateInterface>((set, get) => ({ ... }))`
- No middleware; shallow updates; no immer

**src/lib/:**
- Purpose: Shared utilities, types, and bridge layer
- `tauri.ts` - All Tauri `invoke()` calls centralized here
- `types.ts` - TypeScript interfaces for data serialization (must match Rust models)
- `cn.ts` - Classname merging utility (classnames/clsx)

**src-tauri/src/commands/:**
- Purpose: Tauri command handlers (async functions invocable from frontend)
- Pattern: Each takes AppState, validates input, returns Result<T, String>
- Database access through db/* modules
- Results serialized to JSON via serde

**src-tauri/src/db/:**
- Purpose: Low-level database operations
- `postgres.rs` - sqlx abstractions for PostgreSQL (connection pools, queries, introspection)
- `sqlite.rs` - rusqlite for local metadata storage (connections, saved queries, history)
- `credentials.rs` - System keychain integration for password management

**src-tauri/src/models/:**
- Purpose: Serializable data structures
- Must match `src/lib/types.ts` for JSON interop
- Uses `#[serde(rename_all = "camelCase")]` or snake_case per convention

**Pharos/ (appkit branch):**
- Parallel to src/ but Swift/AppKit instead of React
- ViewControllers manage NSView hierarchy
- Sheets are NSViewController modals
- Core/PharosCore.swift bridges to pharos-core Rust library via C FFI

**pharos-core/:**
- Shared Rust library for both Tauri and AppKit builds
- Contains database logic, connection pooling, query execution
- Compiled to `libpharos_core.a` static library
- C header generated by cbindgen for Swift bridging

## Key File Locations

**Entry Points:**
- Frontend: `src/main.tsx` (React DOM mount) → `src/App.tsx` (root component)
- Backend: `src-tauri/src/lib.rs` (Tauri setup, command registration)

**Configuration:**
- `tsconfig.json` - TypeScript (strict mode, lib=dom.es2020, paths alias @/)
- `vite.config.ts` - Vite (SvelteKit plugin, define.TAURI_*)
- `tailwind.config.js` - Tailwind (theme CSS variables)
- `src-tauri/Cargo.toml` - Rust dependencies (tauri, sqlx, tokio, serde)
- `package.json` - npm dependencies (react, tauri, monaco-editor, tanstack/react-virtual, etc.)

**Core Logic:**
- Connection pooling: `src-tauri/src/db/postgres.rs::create_pool()`
- Query execution: `src-tauri/src/commands/query.rs::execute_query()`
- Schema introspection: `src-tauri/src/db/postgres.rs::get_schemas/tables/columns()`
- Settings persistence: `src-tauri/src/db/sqlite.rs::load/save_settings()`

**Testing:**
- No test files in current codebase (no `*.test.ts`, `*.spec.ts`)
- Manual testing only

**Theming:**
- Global styles: `src/index.css` (CSS variables for light/dark)
- Component styles: Tailwind classes with `theme-*` variable references

## Naming Conventions

**Files:**
- React components: `PascalCase.tsx` (e.g., `QueryEditor.tsx`, `DatabaseNavigator.tsx`)
- Hooks: `camelCase.ts` (e.g., `useTheme.ts`, `useConnectionActions.ts`)
- Utilities: `camelCase.ts` (e.g., `cn.ts`, `tauri.ts`)
- Stores: `camelCase.ts` (e.g., `connectionStore.ts`)
- Rust modules: `snake_case.rs` (e.g., `connection.rs`, `query.rs`, `postgres.rs`)
- Rust binaries: `snake_case` (e.g., `tauri`, `pharos-core`)

**Directories:**
- React feature dirs: `camelCase/` (e.g., `components/`, `dialogs/`, `editor/`)
- Rust modules: `snake_case/` (e.g., `commands/`, `models/`, `db/`)
- Swift classes: `PascalCase.swift` (e.g., `AppDelegate.swift`, `MainWindowController.swift`)

**Functions:**
- Frontend: `camelCase` (e.g., `getActiveConnection()`, `executeQuery()`)
- Backend (Rust): `snake_case` (e.g., `execute_query()`, `get_schemas()`)
- Backend (Swift): `camelCase` (e.g., `loadConnections()`, `saveSettings()`)

**Variables:**
- Frontend: `camelCase` (e.g., `activeConnectionId`, `tabName`)
- Backend (Rust): `snake_case` (e.g., `connection_id`, `query_id`)
- Swift: `camelCase` (e.g., `appDelegate`, `mainWindow`)

**Types:**
- TypeScript interfaces: `PascalCase` (e.g., `ConnectionConfig`, `QueryTab`, `SchemaInfo`)
- Rust structs: `PascalCase` (e.g., `ConnectionConfig`, `AppState`, `QueryResult`)
- Swift classes: `PascalCase` (e.g., `AppDelegate`, `PharosCore`)

**Constants:**
- Frontend: `UPPER_SNAKE_CASE` (e.g., `DEFAULT_SHORTCUTS`, `MIN_COLUMN_WIDTH`)
- Backend: `UPPER_SNAKE_CASE` (e.g., `DEFAULT_POOL_SIZE`)

## Where to Add New Code

**New Query/Metadata Feature:**
- Backend command: `src-tauri/src/commands/query.rs` or new `src-tauri/src/commands/feature.rs`
- Register in: `src-tauri/src/lib.rs` invoke_handler array
- TypeScript wrapper: `src/lib/tauri.ts`
- Types: `src/lib/types.ts` (if new data structure needed)
- Frontend component: `src/components/` (new folder if major feature)

**New Dialog:**
- Component file: `src/components/dialogs/FeatureDialog.tsx`
- Add open/close state to `src/App.tsx`
- Register trigger in App (button click, menu, etc.)

**New Settings/Preference:**
- Add field to `AppSettings` in `src-tauri/src/models/settings.rs`
- Add field to `settingsStore.ts` state interface
- Add UI in `src/components/dialogs/SettingsDialog.tsx`
- Add load/save in `src-tauri/src/commands/settings.rs`

**New Component Utility:**
- Hooks: `src/hooks/useFeature.ts`
- Helpers: `src/lib/` or component-local folder
- Styles: Tailwind classes (avoid new CSS files unless absolutely necessary)

**New PostgreSQL Operation:**
- Query logic: `src-tauri/src/db/postgres.rs`
- Command wrapper: `src-tauri/src/commands/` (appropriate module)
- Frontend call: `src/lib/tauri.ts` + component usage

## Special Directories

**node_modules/:**
- Purpose: npm dependencies
- Generated: Yes (npm install)
- Committed: No

**dist/:**
- Purpose: Built frontend assets
- Generated: Yes (npm run build)
- Committed: No
- Created by: Vite build

**src-tauri/target/:**
- Purpose: Rust build artifacts
- Generated: Yes (cargo build)
- Committed: No

**Pharos.xcodeproj/:**
- Purpose: Xcode project file
- Generated: Yes (xcodegen generate from project.yml)
- Committed: Partially (some files, mostly build outputs excluded)
- Modification: Never edit directly; edit project.yml and run xcodegen

**src-tauri/tauri-plugin-native-chrome/:**
- Purpose: Custom Tauri plugin for native window chrome (sidebar, toolbar, vibrancy)
- Purpose: Experimental; currently on appkit branch
- Committed: Yes (in-tree plugin development)

**.planning/codebase/:**
- Purpose: GSD analysis documents (generated by orchestrator)
- Committed: Yes (documentation)
- Contents: ARCHITECTURE.md, STRUCTURE.md, CONVENTIONS.md, TESTING.md, CONCERNS.md, STACK.md, INTEGRATIONS.md

---

*Structure analysis: 2025-02-24*
