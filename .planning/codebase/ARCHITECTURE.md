# Architecture

**Analysis Date:** 2025-02-24

## Pattern Overview

**Overall:** Tauri v2 desktop application with client-server separation between React frontend and Rust backend.

**Key Characteristics:**
- Frontend-backend communication via Tauri invoke commands over IPC
- State management in React via Zustand stores (no Redux/Context)
- Rust backend manages PostgreSQL connection pools and query lifecycle
- Local SQLite database for persistent metadata cache and settings
- Dual-platform support: React web frontend (main branch) and native Swift/AppKit frontend (appkit branch)

## Layers

**Presentation Layer (React + TypeScript):**
- Purpose: User interface rendering, form input, results visualization
- Location: `src/components/` (dialogs, editor, layout, results, saved queries, tree)
- Contains: React components using Tailwind CSS, Monaco Editor, TanStack Virtual, Lucide icons
- Depends on: Zustand stores, Tauri bridge, types
- Used by: App.tsx entry point

**State Management Layer (Zustand):**
- Purpose: Centralized client-side state for connections, queries, settings, history
- Location: `src/stores/`
- Contains:
  - `connectionStore.ts` - Active connection, connection list, selected schemas
  - `editorStore.ts` - Query tabs, active tab, tab content, execution state
  - `settingsStore.ts` - UI preferences, theme, column widths
  - `savedQueryStore.ts` - Saved queries (loaded from backend)
  - `queryHistoryStore.ts` - Query execution history
- Depends on: Types, Tauri bridge
- Used by: All React components

**Tauri Bridge Layer (IPC):**
- Purpose: Type-safe command invocation to Rust backend
- Location: `src/lib/tauri.ts`
- Contains: Wrapper functions around `invoke()` for all backend commands
- Depends on: Types
- Used by: React components and hooks

**Type Definitions:**
- Location: `src/lib/types.ts`
- Contains: TypeScript interfaces for connections, schema metadata, query results, settings
- Used by: Frontend and Tauri bridge (JSON serialization)

**Rust Backend (Tauri Commands + State):**
- Purpose: PostgreSQL connection management, query execution, metadata introspection
- Location: `src-tauri/src/`
- Entry: `lib.rs` (Tauri app setup, command registration)
- State: `state.rs` (AppState with connection pools, running queries, password cache)
- Commands: `commands/*.rs` (connection, query, metadata, table, settings, history)
- Database layer: `db/postgres.rs` (sqlx PostgreSQL operations), `db/sqlite.rs` (local metadata)
- Models: `models/*.rs` (data structures matching JSON schemas)
- Depends on: sqlx, tokio, serde, tauri
- Used by: Frontend via IPC

**Local Storage (SQLite):**
- Purpose: Persist connection configs, saved queries, settings, query history
- Location: Tauri app data directory (`~/.config/Pharos/` or similar)
- Initialized in: `src-tauri/src/db/sqlite.rs`
- Accessed from: AppState (all backend commands)

**Native Swift Backend (appkit branch only):**
- Purpose: macOS-native UI using AppKit, bridges to pharos-core Rust library
- Entry: `Pharos/App/AppDelegate.swift`
- Bridge: `Pharos/Core/PharosCore.swift` (C FFI wrapper)
- State: `Pharos/Core/AppStateManager.swift` (Combine publishers)
- ViewControllers: `Pharos/ViewControllers/` (AppKit UI hierarchy)
- Models: `Pharos/Models/` (Swift Codable structs)

## Data Flow

**Query Execution:**

1. User types SQL in QueryEditor (React)
2. User clicks Run or Cmd+Enter
3. QueryWorkspace calls `tauri.executeQuery()` with SQL text, connection ID, query ID
4. Rust `execute_query()` command receives request
5. Acquires connection from pool, registers query with backend PID
6. Sets search_path if schema specified
7. Streams results (limited by pagination)
8. Returns QueryResult with columns, rows, row count
9. Frontend receives in editorStore, renders in ResultsGrid
10. User can cancel mid-execution via `cancel_query()` → `pg_cancel_backend()`

**Connection Management:**

1. App startup: Frontend calls `tauri.loadConnections()` → SQLite
2. Frontend populates connectionStore with list
3. User clicks connection → Frontend calls `tauri.connectPostgres(connectionId)`
4. Rust creates pool via `db/postgres.rs::create_pool()`
5. Updates AppState.connections map
6. Frontend receives status, shows in ServerRail
7. On disconnect: Pool dropped, AppState.connections cleaned up

**Schema Metadata Load:**

1. User selects connection → DatabaseNavigator mounts
2. Calls `tauri.getSchemas(connectionId)`
3. Rust queries `information_schema` to list schemas
4. Frontend filters empty schemas based on settings
5. User expands schema → calls `tauri.getTables(connectionId, schemaName)`
6. Frontend caches result in local state, renders tree
7. User clicks table → context menu allows View Rows, Clone, Export, etc.

**Settings Persistence:**

1. User changes theme, column widths, etc. in UI
2. settingsStore updates locally
3. On change: Frontend calls `tauri.saveSettings(settings)`
4. Rust writes to SQLite, returns success
5. On app startup: Frontend calls `tauri.loadSettings()` to restore

**State Management Pattern:**

- Each Zustand store is a single source of truth for that domain
- Actions mutate state synchronously (Zustand shallow merging)
- Side effects (async) happen in components via useEffect + hooks
- No action dispatching; direct state reads via selectors (e.g., `state.getActiveConnection()`)
- Stores are initialized empty; populated on mount via Tauri calls

## Key Abstractions

**Connection:**
- Purpose: Represents a PostgreSQL database connection with metadata
- Examples: `src/lib/types.ts` (ConnectionConfig, Connection interface)
- Pattern: Immutable config + mutable runtime status (connected/disconnected/error)

**QueryTab:**
- Purpose: Represents a query editor tab with execution state
- Examples: `src/stores/editorStore.ts` (QueryTab interface)
- Pattern: Tracks SQL text, cursor position, execution results, validation state
- Lifecycle: Create → Edit → Execute → Display Results → Close

**QueryResult:**
- Purpose: Columnar result set from query execution
- Examples: `src-tauri/src/commands/query.rs` (QueryResult struct)
- Pattern: Columns + rows (vec of JSON), pagination cursor, execution time
- Used by: Frontend ResultsGrid for virtualized display

**TreeNode:**
- Purpose: Schema browser hierarchy (schemas → tables → columns)
- Examples: `src/lib/types.ts` (TreeNode interface)
- Pattern: Recursive tree structure with expand/collapse state
- Rendered by: SchemaTree component using recursive React components

**AppState (Rust):**
- Purpose: Central state container for Tauri backend
- Examples: `src-tauri/src/state.rs` (AppState struct)
- Contains: Connection pools (HashMap), configs, running queries, password cache
- Pattern: All Mutex-wrapped for thread-safe access from async commands

## Entry Points

**Frontend Entry:**
- Location: `src/main.tsx`
- Triggers: App launch
- Responsibilities:
  1. Initialize React root and mount App component
  2. Set up QueryClient for @tanstack/react-query
  3. Attach global context menu handler (allow only in editable elements)

**App Component:**
- Location: `src/App.tsx`
- Triggers: React app initialization
- Responsibilities:
  1. Load connections and settings from backend
  2. Render main layout (sidebar + workspace)
  3. Handle dialog state (add connection, settings, etc.)
  4. Listen for menu events from Tauri
  5. Manage sidebar collapse state

**Rust Entry:**
- Location: `src-tauri/src/lib.rs`
- Triggers: Tauri app startup
- Responsibilities:
  1. Build Tauri app with plugins (dialog, window-state, logs)
  2. Initialize SQLite metadata database
  3. Load saved connections and password cache
  4. Apply window vibrancy (macOS)
  5. Register command handlers
  6. Initialize AppState

## Error Handling

**Strategy:** Result<T, String> for Tauri commands; error messages bubbled to frontend; UI shows error toast/dialog.

**Patterns:**
- Backend returns Err(message) for validation errors, database errors, connection errors
- Frontend receives error string and displays in tab error state or toast notification
- Query execution errors show in red box below editor
- Connection test shows error dialog
- Network errors timeout after 10 seconds (sqlx acquire_timeout)

**Specific Cases:**
- Connection refused: "Not connected to: {connection_id}"
- Schema validation: "Invalid schema name: only letters, numbers, underscores, and hyphens allowed"
- Query cancelled: Query marked cancelled in AppState, client-side query execution stops
- Permission denied: Command returns error, frontend records in analyze_denied cache to skip future ANALYZE

## Cross-Cutting Concerns

**Logging:**

- Frontend: `console.log()` for debug info, visible in browser dev tools
- Backend (debug builds): `tauri_plugin_log` configured in lib.rs, level=Info
- No structured logging; simple print statements in Rust

**Validation:**

- Frontend: React form inputs with inline error display (query validation in QueryEditor)
- Backend: Schema name validation (alphanumeric + underscore + hyphen), SQL validation (optional), file path validation for exports
- Type validation: TypeScript for frontend, serde for Rust JSON deserialization

**Authentication:**

- No user authentication; app assumes local machine access
- Password storage: Saved in system keychain, loaded once at startup into password_cache
- Password used in connection string, never persisted to disk
- Per-connection SSL mode configurable (disable, prefer, require)

**Theming:**

- CSS variables defined in `src/index.css` with `theme-*` classes
- Three modes: light, dark, auto (system)
- Applied via `useTheme()` hook setting `<html data-theme="">` attribute
- Tailwind consumes via `theme-*` class names in components

**Keyboard Shortcuts:**

- Defined in `src/lib/types.ts` (DEFAULT_SHORTCUTS)
- Customizable in settings
- Applied in QueryEditor via Monaco editor keybindings + browser addEventListener
- Common: Cmd+Enter (execute), Cmd+K (format), Cmd+/ (comment)

---

*Architecture analysis: 2025-02-24*
