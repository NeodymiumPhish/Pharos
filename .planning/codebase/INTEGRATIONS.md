# External Integrations

**Analysis Date:** 2025-02-24

## APIs & External Services

**PostgreSQL Database Servers:**
- Service: Any PostgreSQL server (9.6+ inferred from feature support)
  - What it's used for: Primary data source - schema introspection, query execution, table/schema/index/function metadata
  - SDK/Client: sqlx 0.8 (async PostgreSQL driver)
  - Configuration: Connection configs stored in SQLite, managed via UI sheets (`Pharos/Sheets/ConnectionSheet.swift`)
  - Auth: Credentials via connection config (username/password), stored securely in macOS Keychain

## Data Storage

**Databases:**

**PostgreSQL (Remote):**
- Connection: Via `ConnectionConfig` (host, port, database, username, ssl_mode)
  - Client: sqlx with configurable connection pooling (max 5 connections per pool)
  - Async: tokio runtime for non-blocking database operations
  - Timeout: 10-second acquire timeout per connection
  - SSL Modes: disable, prefer (default), require
  - All connections tracked in `AppState.connections` HashMap keyed by connection ID

**SQLite (Local Metadata Cache):**
- Path: `~/Library/Application Support/com.pharos.client/pharos.db`
- Client: rusqlite 0.32 with bundled SQLite
- Tables:
  - `connections` - Connection configurations (passwords NOT stored, referenced in keychain)
    - Columns: id, name, host, port, database, username, ssl_mode, sort_order, created_at, updated_at
  - `saved_queries` - User-saved query templates
  - `query_history` - Historical queries with cached result metadata
  - `app_settings` - Application preferences and UI state
- Migrations: Auto-run on app startup via `pharos-core/src/db/sqlite.rs:init_database()`
  - Legacy password migration: Old per-connection keychain entries merged to unified entry

**File Storage:**
- Location: User-selected directories only (no automatic cloud sync)
- Export Formats:
  - CSV: Via `rust_xlsxwriter` (table export to `/tmp/`, `$HOME/`, `/var/folders/`)
  - Excel/XLSX: Via `rust_xlsxwriter 0.82`
  - Path validation: `validate_file_path()` restricts to `$HOME/`, `/tmp/`, `/var/folders/` for security
- Import:
  - CSV ingestion via `importCsv()` command

**Caching:**
- Metadata Cache: SQLite local database caches schema metadata (schemas, tables, columns, indexes, functions, constraints)
- Query Result Cache: Query history entries optionally cache result metadata for UI display without re-execution
- No distributed caching (single-machine app)

## Authentication & Identity

**Auth Provider:**
- Custom implementation via direct PostgreSQL username/password authentication
  - Location: `pharos-core/src/commands/connection.rs` (connect, test, disconnect)
  - No OAuth or external identity provider

**Credential Storage:**
- Secure Storage: macOS Keychain (native `Security.framework`)
  - Implementation: `pharos-core/src/db/credentials.rs`
  - Service Name: `com.pharos.client`
  - Credentials Key: Single unified JSON entry `connection-passwords` (one entry for all connections)
  - Format: HashMap<connection_id, password> serialized as JSON
  - Lifecycle: Loaded at startup (`pharos_init()`), updated on connection save/delete, merged from legacy per-connection entries
- Transient: Password field in `ConnectionConfig` only present during transport (not persisted to disk)

## Monitoring & Observability

**Error Tracking:**
- None - Errors bubble up through C FFI callback pattern to Swift error handling
- Location: `pharos-core/src/ffi.rs` - AsyncCallback with error_msg parameter

**Logs:**
- Framework: env_logger 0.11 (log 0.4 facade)
- Configuration: RUST_LOG environment variable
- Output: stderr by default (captured by macOS process logs)
- Initialization: Called in `pharos_init()` via `env_logger::try_init()`
- Usage: Throughout Rust backend via `log::info!()`, `log::warn!()`, `log::error!()`

**Performance Monitoring:**
- Connection latency: Measured during test connection and returned in `ConnectionInfo.latency_ms`
  - Implementation: `pharos-core/src/db/postgres.rs:test_connection()` measures elapsed time
  - Displayed in UI for connection health assessment

## CI/CD & Deployment

**Hosting:**
- Distribution: macOS App (native binary)
- Code Signing: Hardened runtime enabled in Xcode project
  - Entitlements: Requires network access to PostgreSQL servers

**Build Pipeline:**
- No CI service detected - Manual build via Xcode or `npm run tauri build` (outdated, Tauri branch only)
- Pre-build Script: Xcode invokes `cargo build --release` before linking app binary
- Output: Universal or Intel binary depending on build architecture

**Deployment:**
- Manual: Build in Xcode, code sign, distribute via App Store or direct download
- No automatic updates detected

## Environment Configuration

**Required Environment Variables:**
- `RUST_LOG` - Optional, controls log level for debug builds (e.g., `RUST_LOG=pharos_core=debug`)

**No Environment-Based Config Files:**
- All configuration stored in SQLite (connections, saved queries, settings)
- No `.env` or `.env.local` files

**Secrets Location:**
- macOS Keychain - All connection passwords stored via Security.framework
- No plaintext secrets on disk or in environment
- Credentials encrypted by OS when stored in Keychain

## Webhooks & Callbacks

**Incoming:**
- None - App does not expose any HTTP endpoints

**Outgoing:**
- C FFI Callbacks: `AsyncCallback` function pointer pattern in `pharos-core/src/ffi.rs`
  - Signature: `extern "C" fn(context: *mut c_void, result_json: *const CChar, error_msg: *const CChar)`
  - Used for all async operations (connect, query, metadata fetch)
  - Swift wraps via `PharosCore.swift:withAsyncCallback()` with Swift continuations

**Database Notifications:**
- PostgreSQL LISTEN/NOTIFY: Not detected - Pharos does not listen for database events
- Query Cancellation: via `pg_cancel_backend()` SQL function (called from `pharos_cancel_query()`)

## PostgreSQL Feature Requirements

**Introspection:**
- information_schema tables for schema/table/column metadata
- pg_catalog system catalog for indexes, constraints, functions
- Foreign table exclusion: ANALYZE skipped on foreign tables (can hang indefinitely)

**SQL Formatting:**
- sqlformat 0.3 - PostgreSQL SQL formatter for query normalization
- Applied in `PharosCore.formatSQL()` (Swift wrapper)

**Version Compatibility:**
- SSL/TLS: Native TLS via sqlx (libc TLS, not rustls)
- Connection string: PostgreSQL URI format with URL-encoded credentials
- No version locks detected - Compatible with modern PostgreSQL versions

---

*Integration audit: 2025-02-24*
