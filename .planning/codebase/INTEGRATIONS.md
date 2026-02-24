# External Integrations

**Analysis Date:** 2025-02-24

## APIs & External Services

**PostgreSQL Database:**
- Service: PostgreSQL server (user-configured, any version supporting information_schema)
- What it's used for: Primary query execution, schema introspection, metadata collection
  - SDK/Client: sqlx 0.8 with native-tls
  - Auth: Custom ConnectionConfig (username/password with optional SSL)
  - Connection pooling: 5 max connections per database via PgPoolOptions
  - Supported SSL modes: disable, prefer (default), require

**Monaco Editor CDN:**
- Service: cdn.jsdelivr.net (Monaco Editor language workers)
- What it's used for: SQL syntax highlighting, autocomplete, editor functionality
  - SDK/Client: @monaco-editor/react 4.7.0
  - CSP allowance: script-src and style-src for jsdelivr.net

## Data Storage

**Databases:**
- PostgreSQL (external)
  - Connection: User-provided host:port/database with authentication
  - Client: sqlx with connection pooling (max 5 per config)
  - Query execution: Full SQL support with result streaming

- SQLite (local)
  - Storage: `{app_data_dir}/pharos.db` (file-based)
  - Client: rusqlite with bundled SQLite
  - Purpose: Connection configs, saved queries, query history, app settings
  - Schema migrations: Handled automatically on startup (password removal, ssl_mode, sort_order, color columns)

**File Storage:**
- Local filesystem only
  - Exports: CSV, JSON, XLSX (via rust_xlsxwriter)
  - Imports: CSV validation and import
  - File dialogs: Tauri plugin-dialog for file picker
  - Validation: Restricted to `$HOME/`, `/tmp/`, `/var/folders/` (validate_file_path in table.rs)

**Caching:**
- In-memory
  - Password cache: HashMap<String, String> loaded from macOS Keychain at startup
  - Connection pools: HashMap<String, PgPool> in AppState
  - React Query: 5-minute stale time for schema metadata

## Authentication & Identity

**Auth Provider:**
- Custom (no external auth service)
  - Implementation: Direct PostgreSQL connection authentication (username/password)
  - Password storage: macOS Keychain only (Service: `com.pharos.client`)
  - Keychain entry structure: Single unified JSON entry with all connection passwords as key-value pairs
  - Legacy migration: migrate_legacy_passwords() converts old per-connection entries to unified format on startup

**Session Management:**
- Per-connection basis via AppState.connections (HashMap<String, PgPool>)
- No user accounts; each connection is independent

## Monitoring & Observability

**Error Tracking:**
- None detected (no third-party service)

**Logs:**
- Framework: Tauri plugin-log (conditionally enabled in debug builds)
- Level: Info and above
- Output: Tauri logs directory
- Custom logging: log crate 0.4 (used throughout Rust backend)

**Query Performance:**
- Connection latency: Measured on test connection via INSTANT::elapsed()
- Query tracking: Running queries registered with unique queryId and PostgreSQL backend_pid
- Cancellation: Via pg_cancel_backend(backend_pid) in backend state

## CI/CD & Deployment

**Hosting:**
- Desktop app (macOS native)
- Distribution: App bundle (.app) via Tauri bundle
- Build target: Universal binary (Intel + Apple Silicon)

**CI Pipeline:**
- None detected (no GitHub Actions or similar configured)
- Manual build: `npm run tauri build`

## Environment Configuration

**Required env vars:**
- None required at runtime
- Development: Uses hardcoded localhost:5173 for dev server URL
- No .env file detected in codebase

**Secrets location:**
- macOS Keychain (Service: `com.pharos.client`)
  - Entry key: `connection-passwords`
  - Format: JSON string of connection_id -> password pairs
  - Access: Only via keyring crate with apple-native feature
  - Startup: migrate_legacy_passwords() loads all at once, cached in AppState.password_cache
  - Subsequent access: From in-memory cache only (no repeated Keychain lookups)

## Webhooks & Callbacks

**Incoming:**
- None

**Outgoing:**
- None

**Event System (Internal):**
- Tauri event emission: From Tauri backend to React frontend
  - menu-about: Settings panel trigger
  - menu-settings: Settings panel trigger
  - Custom events: Applications can emit generic events via window.listen()

## Data Synchronization

**Frontend ↔ Backend:**
- Command-response pattern: All communication via Tauri `invoke()`
  - Types: `src/lib/tauri.ts` wraps all Rust command invocations
  - Serialization: JSON via serde/serde_json
  - Async: All commands return Promises

**State Management:**
- Zustand stores in React: connectionStore, editorStore, savedQueryStore, settingsStore, queryHistoryStore
- Local persistence: Queries cached in SQLite (query_history table)
- Remote persistence: Saved queries and connections stored in local SQLite

## Export/Import Integrations

**Export Formats:**
- CSV (via csv crate 1.3)
- JSON (via serde_json)
- XLSX (via rust_xlsxwriter 0.82)
- Plain text SQL
- File saving: Via Tauri plugin-dialog (save_dialog)

**Import Formats:**
- CSV with validation (CsvValidationResult, CsvImportOptions)
- File picking: Via Tauri plugin-dialog (open_dialog)

## Connection Management

**ConnectionConfig Structure:**
- id: String (UUID v4 generated on creation)
- name, host, port, database, username: Connection details
- password: Transient (only in-transit), stored in Keychain
- ssl_mode: SSL preference (disable/prefer/require)
- color: Optional visual indicator for connections
- All configs cached in AppState.connection_configs on startup

**Connection Pool Lifecycle:**
1. User connects → create_pool() via sqlx PgPoolOptions
2. Pool stored in AppState.connections with connection_id key
3. Test connection: Temporary pool (1 connection, 10s timeout)
4. Disconnect: Pool closed and removed from state
5. Analyze denied tables tracked in AppState.analyze_denied (cleared on disconnect)

---

*Integration audit: 2025-02-24*
