# Codebase Concerns

**Analysis Date:** 2025-02-24

## Tech Debt

**FFI Memory Management:**
- Issue: C string callbacks in FFI layer use `unwrap_or_default()` on CString creation, silently dropping strings containing null bytes instead of propagating errors
- Files: `pharos-core/src/ffi.rs` (lines 63, 74, 80)
- Impact: Silent data loss on invalid UTF-8 or null bytes in error messages/results; difficult to debug since failures are masked
- Fix approach: Change `unwrap_or_default()` to explicit error handling that logs and returns empty string only as last resort. Consider validation at string entry points

**Mutex Lock Panics on Poisoning:**
- Issue: All Mutex access in state.rs uses `.unwrap()` without poison recovery strategy. If any thread panics while holding a lock, subsequent threads will panic
- Files: `pharos-core/src/state.rs` (16 instances), `pharos-core/src/ffi.rs` (multiple instances)
- Impact: Single thread panic cascades to crash entire app; state becomes inaccessible
- Fix approach: Implement `poison_recovery()` helper that uses `lock().unwrap_or_else(|e| e.into_inner())` for all Mutex operations, or migrate to parking_lot::Mutex which doesn't poison

**Large File Handling Without Memory Limits:**
- Issue: Query result serialization to JSON happens in-memory with hardcoded 5MB limit but no streaming or chunking for pagination
- Files: `pharos-core/src/commands/query.rs` (lines 176-187)
- Impact: Large result sets (>50K rows) consume significant memory; potential OOM on very large exports; no protection against malicious queries returning millions of rows
- Fix approach: Implement result streaming to disk for pagination, add row count limit on query execution, implement progress reporting for large result sets

**Query Cancellation Race Condition:**
- Issue: Query ID registration (`register_query`) and actual PostgreSQL execution are separate steps; cancellation signal arrives in window before PID is registered
- Files: `pharos-core/src/commands/query.rs` (lines 56, 85-88), `pharos-core/src/state.rs` (lines 108-117)
- Impact: Cancel command might succeed without actually cancelling the query if timing is unlucky; stale query PIDs accumulate in running_queries map if connection drops
- Fix approach: Atomically register query before acquiring connection, or use connection context to handle PID tracking. Implement cleanup on connection loss

**Keychain Integration Single Point of Failure:**
- Issue: All connection passwords stored as single JSON blob in macOS keychain under one entry. If that entry becomes corrupted, all passwords are lost
- Files: `pharos-core/src/db/credentials.rs` (lines 7-26)
- Impact: Single keychain entry corruption wipes out all saved credentials; no per-connection backup; migration from old format is one-time only
- Fix approach: Implement per-connection keychain entries as fallback, add corruption detection with checksum, provide manual password re-entry on load failure

## Known Bugs

**Schema Name Validation Bypass:**
- Symptoms: Schema names with hyphens are validated but then used in PostgreSQL identifier context where they need quoting
- Files: `pharos-core/src/commands/query.rs` (lines 62-70)
- Trigger: Execute query with schema name containing hyphen (e.g., "my-schema")
- Workaround: Use alphanumeric and underscore characters only; hyphen validation is permissive but escaping is not applied consistently

**CSV Import Column Mismatch Silent Skip:**
- Symptoms: Importing CSV with extra columns silently ignores unmapped columns without warning user
- Files: `pharos-core/src/commands/table.rs` (lines 230-299)
- Trigger: Import CSV with more columns than target table
- Workaround: Manually drop extra columns from CSV before import; UI should show column mapping

**Query History Result Caching Size Overflow:**
- Symptoms: Query history entries >5MB are cached without results, but history view doesn't indicate this difference
- Files: `pharos-core/src/commands/query.rs` (lines 176-187)
- Trigger: Execute query returning >5MB of data
- Workaround: Re-run query to see results; history shows only metadata

## Security Considerations

**Password Cache In-Memory Exposure:**
- Risk: All connection passwords held in plaintext HashMap in process memory for entire app lifetime; if process is dumped, all passwords exposed
- Files: `pharos-core/src/state.rs` (lines 32-33), `pharos-core/src/ffi.rs` (lines 120-137)
- Current mitigation: Passwords stored in OS keychain at rest; only loaded at startup once
- Recommendations:
  - Implement memory encryption for password cache (e.g., using xor with derived key)
  - Clear password cache on app background (if supported by macOS integration)
  - Add option for per-session passwords without caching
  - Document in security guide that memory dumps expose credentials

**SQL Injection via Schema Name Edge Cases:**
- Risk: Schema validation allows identifiers but error messages may expose schema names in uncaught exceptions
- Files: `pharos-core/src/commands/query.rs` (lines 59-75), `pharos-core/src/commands/table.rs` (lines 246-248)
- Current mitigation: `validate_identifier()` function exists; double-quote escaping for schema in SET search_path
- Recommendations:
  - Add integration tests specifically for schema names with quotes, semicolons, and unicode
  - Audit all error paths that include identifiers for safe escaping
  - Use prepared statement parameters for identifier types where sqlx supports it

**File Path Validation Incomplete for Symlinks:**
- Risk: `validate_file_path()` canonicalizes but doesn't check for symlinks that might escape restrictions
- Files: `pharos-core/src/commands/table.rs` (lines 13-47)
- Current mitigation: Restricts to `$HOME/`, `/tmp/`, `/var/folders/`; canonicalization prevents `..` traversal
- Recommendations:
  - Add `is_symlink()` check and reject symlinks explicitly
  - Use `fs::Metadata::file_type()` to verify target is regular file
  - Add tests for symlink escape attempts

**Error Messages May Leak Connection Details:**
- Risk: Connection error messages sometimes include partial credentials or database names
- Files: `pharos-core/src/commands/connection.rs` (lines 7-40)
- Current mitigation: `sanitize_error()` function masks postgres:// URLs
- Recommendations:
  - Extend sanitization to host:port pairs that might reveal infrastructure
  - Audit all error paths for accidental credential leakage (check for "password", "user", "secret")
  - Consider adding error code instead of full messages for sensitive operations

## Performance Bottlenecks

**Metadata Loading Sequential N+1 Pattern:**
- Problem: Schema list loaded first, then for each schema, tables loaded separately, then columns loaded separately (3+ round-trips per schema)
- Files: `Pharos/Core/MetadataCache.swift` (lines 103-142)
- Cause: Separate async calls to `PharosCore.getTables()` and `PharosCore.getSchemaColumns()` per schema
- Improvement path: Implement batch query combining schemas, tables, and columns in single DB query; or cache at Rust layer with pre-fetched data

**Large Result Set Rendering Without Virtualization:**
- Problem: Results grid attempts to render all visible cells immediately; scrolling lag with >10K rows even with TableView virtualization
- Files: `Pharos/ViewControllers/ResultsGridVC.swift` (1429 lines) — custom cell configuration happens per-visible-row
- Cause: Cell formatting (type detection, font styling, truncation) computed on-demand for every visible row during scroll
- Improvement path: Pre-compute cell formatting metadata during query result processing, cache formatting decisions, implement row batching in scroll handler

**Query Validation Synchronous Call Blocking UI:**
- Problem: SQL validation waits for full response before unblocking editor; editor is unresponsive during validation of complex queries
- Files: `Pharos/Editor/SQLTextView.swift` (503 lines) — validation likely triggered on every keystroke
- Cause: Async call without timeout; no debouncing between keystrokes
- Improvement path: Add 500ms debounce on keystroke, implement validation timeout (2-3s max), fall back to syntax-only validation on timeout

**Connection Pool Max Size Fixed at 5:**
- Problem: Only 5 concurrent queries per connection; 6th query blocks until previous completes
- Files: `pharos-core/src/db/postgres.rs` (line 30)
- Cause: Hard-coded `max_connections(5)` in PgPoolOptions
- Improvement path: Make pool size configurable, increase default based on use case, implement connection waiting queue with timeout

## Fragile Areas

**C FFI Async Callback Memory Safety:**
- Files: `pharos-core/src/ffi.rs` (lines 72-82, 400+), `Pharos/Core/PharosCore.swift` (lines 311-330)
- Why fragile: CallbackBox holds continuation; if task is cancelled and context pointer is freed, callback invocation crashes; context usize cast can overflow on 32-bit systems
- Safe modification:
  - Never modify callback invocation order without thorough testing
  - Document that cancelling a task invalidates the Rust callback context
  - Add tests for callback + cancellation races
- Test coverage: Minimal; async callback cancellation not tested

**Schema/Table Name Escaping in Multiple Layers:**
- Files: `pharos-core/src/commands/query.rs` (lines 69-70), `pharos-core/src/commands/table.rs` (lines 246-248), `pharos-core/src/db/postgres.rs` (multiple)
- Why fragile: Escaping logic duplicated; inconsistent between direct SQL and dynamic SQL generation; easy to add new query path without proper escaping
- Safe modification:
  - Create single `sql::ident()` function for identifier escaping
  - Replace all `format!()` identifier uses with function
  - Add SQL linting to catch unquoted identifiers in string literals
- Test coverage: No dedicated identifier escaping tests

**Keychain Credential Migration One-Time Only:**
- Files: `pharos-core/src/db/credentials.rs` (lines 71-103)
- Why fragile: Migration from old per-connection format to unified format only runs once per startup; if migration fails, retry only after app restart; no resume capability
- Safe modification:
  - Add migration status tracking (flag in SQLite)
  - Implement retry on next startup if previous failed
  - Add manual migration trigger in settings
- Test coverage: Migration tested in isolation but not with real keychain state transitions

**Query Result History Serialization Round-trip:**
- Files: `pharos-core/src/commands/query.rs` (lines 154-198)
- Why fragile: Results converted to JSON twice (for caching and for result display); if JSON format changes, cached history becomes unreadable; no schema versioning
- Safe modification:
  - Store query result schema version in history table
  - Add migration logic when reading old format
  - Implement forward/backward compatibility layer
- Test coverage: No tests for schema evolution of cached results

## Scaling Limits

**PostgreSQL Connection Pool Exhaustion:**
- Current capacity: 5 concurrent connections per app instance
- Limit: With 6+ simultaneous queries, queue forms with 10s timeout; app hangs waiting
- Scaling path: Increase pool size to 10-20 based on testing, add queue position indicator in UI, implement graceful degradation with warning on queue buildup

**Query Result Memory Unbounded:**
- Current capacity: 5MB cached in SQLite for history, no pagination limit on fetch
- Limit: Queries returning >1M rows consume >100MB memory; no limit on total memory used by result sets
- Scaling path: Implement row-by-row streaming instead of in-memory collection, add per-session memory limit, implement pagination UI showing row count

**SQLite Local Database No Cleanup:**
- Current capacity: Query history grows unbounded; pharos.db can reach 100MB+ with years of queries
- Limit: App startup slows with large history; no automatic cleanup or archiving
- Scaling path: Implement history retention policy (delete >90 days old), add manual cleanup UI, implement incremental vacuum on startup

**Metadata Cache Unbounded Growth:**
- Current capacity: Tables and columns dictionaries store all schemas ever loaded
- Limit: Switching between many connections accumulates all metadata in memory without cleanup
- Scaling path: Implement LRU cache with max entries, clear cache on manual reset, implement per-connection limits

## Dependencies at Risk

**sqlx Offline Mode Unsupported:**
- Risk: No build-time schema verification; runtime SQL parsing errors discovered at query time
- Impact: Typos in SQL only caught when query executes (could break production workflow)
- Migration plan: Implement build script to verify SQL against test database schema, or switch to compile-checked queries if sqlx supports

**Keyring Crate Platform Dependency:**
- Risk: macOS keychain integration depends on `keyring` crate; if crate unmaintained or has breaking changes, password access breaks
- Impact: Users unable to save/load connection passwords; no fallback mechanism
- Migration plan: Evaluate `security-framework` crate as direct macOS alternative, implement fallback to plaintext (with warning) if keychain unavailable

**rustls TLS Library Selection:**
- Risk: PostgreSQL connection uses platform TLS selection; on macOS may switch between native and rustls depending on feature flags
- Impact: Unexpected TLS failures if dependencies inadvertently change
- Migration plan: Explicitly pin TLS backend in Cargo.toml, document TLS requirements, test on CI/CD with explicit backend

## Missing Critical Features

**Query Cancellation Progress Indication:**
- Problem: Cancel command is fire-and-forget; user doesn't know if cancellation succeeded or if query still running
- Blocks: Long-running queries (15+ mins) with no feedback on cancel status; user thinks app is hanging
- Solution: Return cancellation status from backend, implement progress indicator showing cancelled status, fallback to connection reset if cancel timeout

**Result Export Streaming:**
- Problem: Large exports to CSV/Excel must fit in memory; no progress indication
- Blocks: Exporting result sets >100MB fails silently or crashes
- Solution: Implement streaming export with progress callback, show file size estimate before export, allow cancellation mid-export

**Connection Pooling Visibility:**
- Problem: No way to see pool status, queue depth, or connection count
- Blocks: Debugging "why is my query hanging" — unknown if pool exhausted
- Solution: Add connection statistics view showing pool utilization, queue size, oldest waiting query, per-connection idle time

**Per-Schema Password Support:**
- Problem: All schemas in database use same connection credentials
- Blocks: Can't connect as different users to same database (e.g., admin vs read-only schema)
- Solution: Allow per-schema connection override, implement rls_user parameter for PostgreSQL RLS, swap connections mid-session

## Test Coverage Gaps

**FFI Memory Leak Tests:**
- What's not tested: Callback memory cleanup after task cancellation, CString allocation with null bytes, Mutex poison recovery
- Files: `pharos-core/src/ffi.rs`, `pharos-core/src/state.rs`
- Risk: Silent memory leaks or crashes on edge cases; no regression detection
- Priority: High — memory safety is critical for native app

**Identifier Escaping Edge Cases:**
- What's not tested: Schema/table/column names with quotes, unicode, mixed case, keyword collisions, 63-char limit
- Files: `pharos-core/src/commands/query.rs`, `pharos-core/src/commands/table.rs`
- Risk: SQL injection on unusual identifiers, silent query failures
- Priority: High — identifier handling is security boundary

**Query Cancellation Race Conditions:**
- What's not tested: Rapid cancel requests before query starts, connection drop mid-cancel, multiple cancellations of same query
- Files: `pharos-core/src/commands/query.rs`, `pharos-core/src/state.rs`
- Risk: Stale query state, resource leaks, incorrect cancellation feedback
- Priority: High — cancellation affects user experience

**Keychain Migration and Corruption Scenarios:**
- What's not tested: Keychain entry corrupted mid-migration, partial migration recovery, per-connection fallback
- Files: `pharos-core/src/db/credentials.rs`
- Risk: Silent credential loss, users locked out after app crash
- Priority: High — credential access is critical

**Large Result Set Memory Behavior:**
- What's not tested: Result sets >10M rows, serialization failures on huge results, memory pressure during export
- Files: `pharos-core/src/commands/query.rs`
- Risk: OOM crashes, silent data loss, degraded performance
- Priority: Medium — impacts power users but not common case

---

*Concerns audit: 2025-02-24*
