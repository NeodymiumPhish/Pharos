# Codebase Concerns

**Analysis Date:** 2026-02-24

## Tech Debt

**C FFI Memory Management Complexity:**
- Issue: The C FFI layer in `pharos-core/src/ffi.rs` requires careful manual memory management for C strings. Each returned string must be freed by the caller via `pharos_free_string()` or it leaks. Swift wrapper in `src/lib/tauri.rs` handles this with `defer { pharos_free_string(result) }`, but this is a fragile contract.
- Files: `pharos-core/src/ffi.rs` (1025 lines), `Pharos/Core/PharosCore.swift`
- Impact: Memory leaks if caller forgets `defer` block. Easy mistake in future development. No compile-time safety.
- Fix approach: Consider wrapping string returns in a simple struct with custom deinit, or using a callback-based pattern instead of pointer returns. This would make the safety contract explicit at compile time.

**Global OnceLock Singletons Without Cleanup:**
- Issue: `pharos-core/src/ffi.rs` lines 13-14 use `OnceLock<Runtime>` and `OnceLock<AppState>` as global singletons. `pharos_shutdown()` closes pools but never drops these singletons (OnceLock values are never dropped). This works but is semantically awkward and could cause issues if Rust runtime cleanup becomes important in future.
- Files: `pharos-core/src/ffi.rs` (lines 13-22, 145-158)
- Impact: Incomplete cleanup on app termination. Potential file descriptor or thread leaks if Tokio runtime needs explicit cleanup.
- Fix approach: Consider using `parking_lot::Once` with manual drop registration, or restructuring to pass state through function parameters instead of globals.

**Keychain Credential Caching Without Encryption at Rest:**
- Issue: In-memory password cache stored in `AppState.password_cache: Mutex<HashMap<String, String>>` (`pharos-core/src/state.rs` line 33). Passwords are loaded from OS keychain once at startup and kept in plaintext in process memory. If process memory is dumped or swapped, credentials are exposed.
- Files: `pharos-core/src/state.rs` (line 33), `pharos-core/src/db/credentials.rs` (lines 15-26), `pharos-core/src/ffi.rs` (lines 120-137)
- Impact: Medium risk. Process memory introspection could expose all stored passwords. Accidental memory dumps/crash logs could leak credentials.
- Fix approach: Use a secure memory library (like `zeroize` crate) to clear sensitive memory after use. Consider only loading passwords on demand from keychain rather than all-at-once at startup.

**Large Monolithic View Controllers:**
- Issue: Swift view controllers in `Pharos/ViewControllers/` exceed single-responsibility principle. `ResultsGridVC.swift` (1429 lines), `SchemaBrowserVC.swift` (1009 lines), `ContentViewController.swift` (677 lines) contain data management, UI layout, event handling, and business logic in single classes.
- Files: `Pharos/ViewControllers/ResultsGridVC.swift`, `Pharos/ViewControllers/SchemaBrowserVC.swift`, `Pharos/ViewControllers/ContentViewController.swift`
- Impact: Difficult to test, difficult to modify without side effects, high cognitive load. Changes to one feature require understanding entire controller.
- Fix approach: Extract data management to dedicated model controllers. Extract UI construction to separate view builder classes. Create smaller, testable components.

**Synchronous JSON Parsing on Main Thread:**
- Issue: Several Swift-to-Rust boundary operations block the main thread during JSON decoding in `PharosCore.swift`. For large result sets (thousands of rows), JSON parsing could freeze UI. Example: `loadConnections()` (line 22-29) decodes full connections list before updating UI.
- Files: `Pharos/Core/PharosCore.swift` (multiple decode operations), `Pharos/Core/AppStateManager.swift` (line 67)
- Impact: Main thread blocking on large datasets → UI freezes during load. Particularly problematic for `loadQueryHistory()` with large result caches.
- Fix approach: Move JSON decoding to background thread via `DispatchQueue.global()` before updating `@Published` properties on main thread. Add progress indicators for long operations.

**SQLite Migration Without Version Control:**
- Issue: `pharos-core/src/db/sqlite.rs` lines 14-111 perform migrations inline during `init_database()` but don't track schema version. Each startup checks for missing columns/tables and adds them ad-hoc. If future migrations are added, there's no way to know the current schema version or handle complex data transformations.
- Files: `pharos-core/src/db/sqlite.rs` (lines 6-111)
- Impact: Difficult to add breaking schema changes. No audit trail. Hard to debug data corruption.
- Fix approach: Implement a schema version table and migration registry. Number each migration and track which have run.

## Known Bugs

**Query Cancellation Race Condition:**
- Symptoms: Query cancellation may not work if `pg_cancel_backend()` is called after the query has already completed and rows have started being streamed.
- Files: `pharos-core/src/commands/query.rs` (lines 56, 84-89, 580-586)
- Trigger: Run a slow query, click "Cancel" while first batch of rows is being fetched
- Details: The race is between unregistering the query (line 87) and the cancellation flag being checked in the loop (line 85). If a row arrives between the check and the fetch, the cancellation is missed. The backend PID is also no longer valid after the query finishes.
- Workaround: User must wait for current batch to complete or disconnect entirely.

**ANALYZE Schema Query May Hang on Foreign Tables:**
- Symptoms: Clicking "Analyze" on a schema hangs for several minutes, then times out.
- Files: `pharos-core/src/db/postgres.rs` (lines 89-139), `pharos-core/src/commands/metadata.rs`
- Trigger: Database contains foreign tables pointing to unreachable servers
- Details: `ANALYZE` on a foreign table connects to the remote server, which may hang or timeout. The code silently ignores errors (line 131) but doesn't timeout the ANALYZE command itself.
- Workaround: Close app. In CLAUDE.md, note states "Foreign tables excluded from ANALYZE (can hang for minutes on foreign servers)" but code still attempts ANALYZE on all tables except those known to be denied.

**Metadata Cache Not Invalidated on Connection Disconnect:**
- Symptoms: After disconnecting and reconnecting to same database, schema navigator shows stale row count estimates and table list may be out of sync if schema changed.
- Files: `pharos-core/src/state.rs` (lines 131-158), `pharos-core/src/db/sqlite.rs` (schema_cache, table_cache tables)
- Trigger: Disconnect from DB, another app modifies schema, reconnect
- Details: The `analyze_denied` cache is cleared on disconnect (line 157), but `schema_cache` and `table_cache` tables in SQLite persist across disconnects and are not invalidated. No TTL on cached metadata.
- Workaround: Manually delete pharos.db and restart, or implement manual refresh in UI (if available).

**Swift String Encoding Assumes UTF-8:**
- Symptoms: Database column values containing non-UTF-8 bytes appear corrupted or are skipped.
- Files: `Pharos/Core/PharosCore.swift` (multiple locations where `String(cString: ptr)` is called), `pharos-core/src/ffi.rs` (lines 46-50, 62-70)
- Trigger: PostgreSQL column containing bytea or other non-text data
- Details: All C string conversion assumes valid UTF-8. If Rust returns non-UTF-8 bytes, Swift's `String(cString:)` will truncate or fail.
- Workaround: Ensure Rust side only returns valid UTF-8 JSON, or encode binary data as base64 in JSON.

## Security Considerations

**SQL Injection via Schema/Table Name Parameters:**
- Risk: While most query parameter binding is done correctly via sqlx parameter binding, schema and table names are manually escaped. Risk in `pharos-core/src/commands/query.rs` (lines 69-70), `pharos-core/src/commands/table.rs` (lines 122-124).
- Files: `pharos-core/src/commands/query.rs`, `pharos-core/src/commands/table.rs`
- Current mitigation: Schema names validated to be alphanumeric + underscores/hyphens (line 62), identifiers manually escaped with double-quote doubling (line 69). Table names validated in `validate_table_name()` (lines 1068-1080).
- Recommendations: Continue strict allowlist validation for schema/table names. Add SQL parser validation before executing DDL. Log all schema manipulation operations.

**File Path Traversal in Export/Import:**
- Risk: Users could potentially export data to sensitive locations or import from unexpected places.
- Files: `pharos-core/src/commands/table.rs` (lines 10-47)
- Current mitigation: `validate_file_path()` canonicalizes paths, checks for "..", and restricts to $HOME/, /tmp/, /var/folders/ on macOS.
- Recommendations: This is good. Ensure the allowlist covers all user-accessible locations. Consider prompting user to confirm file path in UI before proceeding.

**Keychain Access Without User Consent Prompt:**
- Risk: On macOS, accessing OS keychain triggers a system permission dialog. If the app is running under a compromised process, it could silently read all stored passwords.
- Files: `pharos-core/src/db/credentials.rs` (lines 15-26), `pharos-core/src/ffi.rs` (lines 120-137)
- Current mitigation: Keychain access is restricted by OS-level permissions. Each app gets its own keychain entry namespace.
- Recommendations: Only load keychain passwords once at startup (already done). Consider requiring user re-authentication for sensitive operations. Add audit logging for credential access.

**JSON Deserialization Could Panic on Malformed Rust Response:**
- Risk: If Rust returns invalid JSON, Swift's `JSONDecoder` will throw, but the error handling in `PharosCore.swift` may not cover all decode paths. A subtle decode error could crash the app.
- Files: `Pharos/Core/PharosCore.swift` (lines 450-480)
- Current mitigation: All async operations wrap decoding in error callbacks. Sync operations use standard error throwing.
- Recommendations: Add integration tests that send malformed JSON from Rust and verify graceful failure. Use structured error logging for decode failures.

## Performance Bottlenecks

**Metadata Introspection Queries Not Cached by Connection:**
- Problem: Every time user expands a schema in the navigator, `get_schemas()`, `get_tables()`, and `get_columns()` run full information_schema queries. No query result caching per connection.
- Files: `pharos-core/src/db/postgres.rs` (lines 62-83, 141-180, etc.), `pharos-core/src/commands/metadata.rs`
- Cause: The SQLite metadata cache (`schema_cache`, `table_cache`, `column_cache` tables) exists but is never populated. User-facing metadata loads hit PostgreSQL directly every time.
- Improvement path: Populate SQLite cache on first schema load. Implement TTL-based invalidation (e.g., 5 minutes). Add manual "Refresh Metadata" button to invalidate cache.

**Row Count Estimates Require Manual ANALYZE:**
- Problem: `pg_class.reltuples` is -1 for un-analyzed tables. Users must click "Analyze" to populate row counts, but this is a blocking I/O operation that can hang on foreign tables.
- Files: `pharos-core/src/db/postgres.rs` (lines 89-139), `pharos-core/src/commands/metadata.rs`
- Cause: ANALYZE must be explicit. No automatic statistics gathering.
- Improvement path: Run ANALYZE asynchronously in background after schema load, with timeout (10 seconds). Skip foreign tables automatically. Cache results in SQLite.

**Large Query Results Loaded Entirely Into Memory:**
- Problem: `execute_query()` fetches all rows up to limit into a Vec before returning. For 10,000-row results with large text fields, this allocates large buffers.
- Files: `pharos-core/src/commands/query.rs` (lines 80-125)
- Cause: Streaming results into JSON requires buffering rows to build the JSON structure.
- Improvement path: Implement true pagination at the Rust level. Return only requested page size. Track cursor for "fetch more" operations.

**UI Redraw on Every State Change in ResultsGridVC:**
- Problem: ResultsGridVC (1429 lines) uses NSTableView but redraws entire table on any data update.
- Files: `Pharos/ViewControllers/ResultsGridVC.swift`
- Cause: No granular row/column update tracking. `reloadData()` refreshes everything.
- Improvement path: Implement `reloadRows(atIndexes:)` for partial updates. Add change batching before UI update.

## Fragile Areas

**CSV Import Type Inference:**
- Files: `pharos-core/src/commands/table.rs` (lines 250-340)
- Why fragile: Import infers column types from first N rows. If first few rows have NULLs, type detection fails and entire column is treated as text. No fallback to explicit type hints from user.
- Safe modification: Any changes to CSV parsing logic could silently accept bad data. Add regression tests for edge cases (all NULLs in first rows, mixed types).
- Test coverage: CSV import has no visible test fixtures in codebase. Recommend adding test data files.

**Query Validation via Parsing Only:**
- Files: `pharos-core/src/commands/query.rs` (validation calls `pharos_parser` crate)
- Why fragile: Validation doesn't execute the query. Parser may accept syntax that PostgreSQL rejects. No way to catch permission errors, missing tables, etc., until execution.
- Safe modification: Changes to validation logic could cause invalid queries to be presented as "valid". Always test against real PostgreSQL database.
- Test coverage: Validation tests likely missing. Add integration tests against real DB.

**Async Callback Bridge via Unmanaged Pointers:**
- Files: `Pharos/Core/PharosCore.swift` (lines 438-480)
- Why fragile: `withAsyncCallback<T>()` creates a `CallbackBox`, converts to `Unmanaged`, passes as void pointer to C, and later reconstructs from opaque pointer. If pointer is corrupted or callback fires twice, memory safety is violated.
- Safe modification: Do not modify callback passing logic without deep understanding of Unmanaged semantics. Always test with ASAN (Address Sanitizer).
- Test coverage: Callback safety should be tested with stress tests (many concurrent queries).

**SettingsSheet Parameter Binding:**
- Files: `Pharos/Sheets/SettingsSheet.swift` (contains UI for connection settings)
- Why fragile: Connection parameters (host, port, SSL mode) are entered as raw text. No validation before passing to Rust. Invalid port number could crash or hang.
- Safe modification: Always validate parameters in Swift before sending to Rust. Use structured types (e.g., UInt16 for port) instead of String.

**AppStateManager Singleton State Mutations:**
- Files: `Pharos/Core/AppStateManager.swift` (303 lines)
- Why fragile: Central `@Published` singleton is mutated from multiple async tasks. If two `connect()` calls race for the same connection ID, state could become inconsistent.
- Safe modification: Add concurrency guards. Use actors instead of Mutex for Swift concurrency. Ensure idempotency of state updates.
- Test coverage: Concurrency tests missing. Add race condition detection tests.

## Scaling Limits

**Maximum Connections Per Pool:**
- Current capacity: 5 connections per PostgreSQL pool (`pharos-core/src/db/postgres.rs` line 30)
- Limit: If 6+ queries run concurrently, 5th and 6th will block waiting for a connection to become available. 11th+ will timeout at 10 seconds (line 31).
- Scaling path: Increase `max_connections` pool size. Benchmark impact on memory and server connection limits. Consider connection pooling proxy (pgbouncer).

**SQLite Local Database Single-Writer Limitation:**
- Current capacity: One writer at a time. If two operations try to save connection config simultaneously, second blocks for timeout period.
- Limit: High concurrency (many simultaneous edits) could deadlock.
- Scaling path: SQLite handles moderate concurrency fine for this app (not many concurrent writers). If parallelism needed, migrate to PostgreSQL local cache or use WAL mode.

**Result Set Size in Memory:**
- Current capacity: Query results buffered entirely in memory. Default limit 1000 rows. Very large text columns × 1000 rows = ~10-100 MB per query.
- Limit: Fetching 10,000+ row results or queries with mega-byte text fields could OOM on older Macs.
- Scaling path: Implement server-side cursor + pagination. Return first N rows, track offset for next page.

**Metadata Cache Disk Usage:**
- Current capacity: SQLite metadata cache unbounded. Large databases with thousands of tables could create multi-MB pharos.db.
- Limit: Database startup I/O could slow down if cache grows very large. No cleanup mechanism.
- Scaling path: Implement cache eviction (LRU by timestamp). Add manual "Clear Cache" function. Archive old cache files periodically.

## Dependencies at Risk

**sqlx Compile-Time Verification:**
- Risk: sqlx does compile-time SQL verification against DATABASE_URL. If the target database schema changes, code may compile but fail at runtime. CI must test against real database schema.
- Impact: Silent failures in production if database schema drifts from test database.
- Migration plan: Ensure CI runs against snapshot of production schema. Use feature flags to skip compile-time verification in development if needed.

**CBIndgen Header Generation:**
- Risk: `pharos-core/src/ffi.rs` exports C functions that are bound to Swift via generated headers. If Rust code changes without regenerating headers, Swift will call with wrong signatures.
- Impact: Memory corruption, crashes.
- Migration plan: Make header generation part of build process. Validate generated headers in CI.

**Keyring Crate Platform-Specific Behavior:**
- Risk: `keyring` crate has different implementations per OS (macOS uses Security.framework). Bugs in the crate could expose or lose credentials.
- Impact: Credential loss, security breach.
- Migration plan: Use `security-framework` crate directly for tighter control. Lock `keyring` to known-good version in Cargo.lock. Monitor crate for security updates.

## Missing Critical Features

**No Query Timeout Enforcement:**
- Problem: Long-running queries (hours) can block connection indefinitely. No server-side timeout.
- Blocks: Users cannot safely explore large tables. Ad-hoc CROSS JOINs hang forever.
- Fix: Add query timeout parameter to `execute_query()`. Default 5 minutes, configurable in settings.

**No Data Editing Beyond Table Cloning:**
- Problem: Results are read-only except for inline cell editing (if implemented). Cannot edit multiple rows or run UPDATE scripts.
- Blocks: Quick data fixes require external tools.
- Fix: Implement batch edit mode for results. Run UPDATE scripts in isolation.

**No Transaction Support in UI:**
- Problem: Multiple mutations (inserts, deletes, updates) are auto-committed individually. No way to batch changes or rollback.
- Blocks: Complex schema refactors or data corrections requiring multi-step consistency.
- Fix: Add transaction control in editor (BEGIN/COMMIT/ROLLBACK).

**No Query Scheduling or Automation:**
- Problem: User cannot schedule queries to run at specific times or on intervals.
- Blocks: Periodic data exports, scheduled analytics.
- Fix: Add job scheduler (cron-like interface) for saved queries.

## Test Coverage Gaps

**CSV Import Edge Cases Not Tested:**
- What's not tested: Empty files, mismatched column counts, NULL handling, type inference with null-heavy first rows, very large files (>1GB).
- Files: `pharos-core/src/commands/table.rs` (lines 200-400+)
- Risk: Silent data corruption or incomplete imports without user awareness.
- Priority: High — affects data integrity.

**Query Cancellation Concurrency:**
- What's not tested: Rapid cancel/re-run of same query, cancellation after query completes, cancellation on dropped connection.
- Files: `pharos-core/src/commands/query.rs`, `pharos-core/src/state.rs`
- Risk: Race conditions, hung connections, incorrect status reporting.
- Priority: High — affects stability.

**Keychain Migration:**
- What's not tested: Migration from old per-connection keychain entries to unified entry. What happens if migration fails midway?
- Files: `pharos-core/src/db/credentials.rs` (lines 71-103)
- Risk: Password loss if migration fails. No rollback mechanism.
- Priority: Medium — only runs once per upgrade.

**Large Result Set Handling:**
- What's not tested: Queries returning 100K+ rows, results with binary data, very wide tables (100+ columns).
- Files: `pharos-core/src/commands/query.rs` (result building), `Pharos/ViewControllers/ResultsGridVC.swift` (rendering)
- Risk: Out-of-memory crashes, UI freezes, incorrect rendering.
- Priority: Medium — edge case but catastrophic if it happens.

**Swift-Rust Boundary Errors:**
- What's not tested: Rust returning invalid JSON, NULL when string expected, missing required fields, network errors during async operations.
- Files: `Pharos/Core/PharosCore.swift`, `pharos-core/src/ffi.rs`
- Risk: Decoding panics, app crashes, data loss.
- Priority: High — core infrastructure.

---

*Concerns audit: 2026-02-24*
