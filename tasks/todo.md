# Pharos Codebase Review - Remediation Plan

Full codebase review completed 2026-03-26. Findings organized into themed phases, ordered by severity and impact. Each phase groups related fixes to minimize context-switching.

---

## Phase 1: Critical Safety (FFI + Panic Boundaries)

These are undefined behavior or crash risks that can bring down the app.

- [ ] **1.1 Add `catch_unwind` to all FFI entry points**
  - Every `extern "C" fn` in `pharos-core/src/ffi/` can panic across the C boundary (UB)
  - Sources: `app_state().expect()`, `runtime().expect()`, `.lock().unwrap()` on poisoned mutexes
  - Fix: Create `ffi_sync!` and `ffi_async!` macros that wrap bodies in `std::panic::catch_unwind`
  - This also fixes silent callback drops on panic (spawned tasks that panic never invoke the callback, leaving Swift hanging)
  - Files: all `pharos-core/src/ffi/*.rs`, new macro in `pharos-core/src/ffi/mod.rs`

- [ ] **1.2 Fix Mutex poisoning cascade in `AppState`**
  - All `.lock().unwrap()` calls in `state.rs` will panic if any thread panics while holding a lock
  - Fix: Change to `.lock().unwrap_or_else(|e| e.into_inner())` on all 17 lock sites
  - File: `pharos-core/src/state.rs`

- [ ] **1.3 Fix `UnicodeScalar` force-unwrap crash on surrogate pairs**
  - `NSString.character(at:)` returns UTF-16; force-unwrapping `UnicodeScalar(surrogateHalf)` crashes on emoji
  - Affects: auto-close brackets, delete-backward, bracket matching
  - Fix: Guard with `guard let scalar = UnicodeScalar(...) else { return }`
  - File: `Pharos/Editor/SQLTextView.swift` lines 239, 244, 329, 331, 647, 681, 692

- [ ] **1.4 Fix connection string injection via unencoded host/database**
  - `build_connection_string` URL-encodes username/password but not host/database
  - A malformed host like `evil.com/otherdb?sslmode=disable&` can inject connection params
  - Fix: `urlencoding::encode(&config.host)` and `urlencoding::encode(&config.database)`
  - File: `pharos-core/src/db/postgres.rs` lines 9-23

- [ ] **1.5 Fix `unwrap()` in gzip compression helpers**
  - `compress_data` panics on encoder failure; called in fire-and-forget path
  - Fix: Return `Result`, propagate errors, fallback to uncompressed storage
  - File: `pharos-core/src/db/sqlite.rs` lines 13-14

---

## Phase 2: Thread Safety (Swift Concurrency)

Data races on `@Published` properties and shared mutable state.

- [ ] **2.1 Add `@MainActor` to `AppStateManager`**
  - `@Published` properties mutated off main thread (e.g., `connectionStatuses` in `connect()`)
  - Fix: Annotate class `@MainActor`, remove internal `MainActor.run` blocks
  - File: `Pharos/Core/AppStateManager.swift`

- [ ] **2.2 Add `@MainActor` to `MetadataCache`**
  - `connectionCaches` mutated both inside and outside `MainActor.run` -- data race
  - `self.schemas` read off MainActor in `prioritize()`
  - Fix: Same pattern as 2.1
  - File: `Pharos/Core/MetadataCache.swift`

- [ ] **2.3 Fix shared `JSONDecoder`/`JSONEncoder` instances (not thread-safe)**
  - Static `let` instances used from both main and background threads concurrently
  - Fix: Change to computed properties returning fresh instances: `static var pharos: JSONDecoder { JSONDecoder() }`
  - File: `Pharos/Core/PharosCore.swift` lines 87-94

- [ ] **2.4 Fix `ResultTab.nextColor()` static mutable state**
  - `colorIndex` is a `static var` with no synchronization
  - Fix: Add `@MainActor` or use `os_unfair_lock`
  - File: `Pharos/Models/ResultTab.swift` lines 74-86

---

## Phase 3: Memory Leaks (Retain Cycles)

Strong reference captures in closures that prevent deallocation.

- [ ] **3.1 Fix retain cycle in `EditorPaneVC.deleteConnection` alert closure**
  - `beginSheetModal` closure captures `self` strongly
  - Fix: `{ [weak self] response in ... self?.stateManager... }`
  - File: `Pharos/ViewControllers/EditorPaneVC.swift` line 778

- [ ] **3.2 Fix retain cycle in `ContentViewController` delayed sheet**
  - `DispatchQueue.main.asyncAfter` closure captures strong `self` after `guard let self`
  - Fix: Capture `[weak self]` in the `asyncAfter` closure
  - File: `Pharos/ViewControllers/ContentViewController.swift` line 1186

- [ ] **3.3 Fix retain cycle in `ConnectionSheet.testConnection()` Task**
  - `Task { ... }` captures `self` strongly via UI property access
  - Fix: `[weak self]` in `Task` closure, guard before UI updates
  - File: `Pharos/Sheets/ConnectionSheet.swift` line 161

- [ ] **3.4 Fix leaked NotificationCenter observers in `SidebarViewController`**
  - Block-based `addObserver(forName:)` tokens never stored or removed
  - Fix: Store tokens, remove in `deinit`
  - File: `Pharos/ViewControllers/SidebarViewController.swift` lines 137-154

---

## Phase 4: Editor Performance

Full-document operations on every keystroke are the biggest UX bottleneck.

- [ ] **4.1 Cache compiled `NSRegularExpression` objects**
  - 6 regexes recompiled on every keystroke in `highlightSyntax()`
  - Fix: Store as static/lazy properties
  - File: `Pharos/Editor/SQLTextView.swift` lines 495-515

- [ ] **4.2 Implement incremental syntax highlighting**
  - Currently re-highlights entire document on every keystroke (6 full-text regex passes)
  - Fix: Use `NSTextStorageDelegate` edited range, only re-highlight affected paragraph + window
  - File: `Pharos/Editor/SQLTextView.swift`

- [ ] **4.3 Fix PostgreSQL string literal pattern**
  - Single-quote pattern uses backslash escaping; PostgreSQL uses `''` (doubled quotes)
  - Also: keywords highlighted inside strings/comments (only first char checked)
  - Fix: Pattern `'(?:[^']|'')*'`; check full match range against existing coloring
  - File: `Pharos/Editor/SQLTextView.swift` lines 523-530, 601-621

- [ ] **4.4 Fix `stateMap` O(N) memory in `SQLFoldingParser`**
  - Allocates one enum (with heap String) per UTF-16 code unit
  - Fix: Use range-based representation with binary search
  - File: `Pharos/Editor/SQLFoldingParser.swift` line 93

- [ ] **4.5 Cache line-start offsets for O(1) line number lookups**
  - `lineNumber(at:)` counts newlines from doc start on every mouse move
  - `selectionDidChange` does the same via `reduce` on every cursor move
  - Fix: Maintain cached line-starts array, rebuild on text change, binary search
  - Files: `Pharos/Editor/LineNumberGutter.swift` lines 154-167, 319-345

- [ ] **4.6 Add tagged dollar-quote highlighting**
  - Only `$$...$$` matched; `$body$...$body$` and `$fn$...$fn$` are missed
  - Fix: Backreference pattern or dedicated lexer pass
  - File: `Pharos/Editor/SQLTextView.swift` line 530

- [ ] **4.7 Fix nested block comment handling**
  - Regex terminates at first `*/`; PostgreSQL supports nested `/* /* */ */`
  - `SQLSegmentParser` already handles this correctly -- reuse that logic
  - File: `Pharos/Editor/SQLTextView.swift` line 523

---

## Phase 5: Excessive Combine Firing + Event Overhead

Unnecessary work on every keystroke/event across all panes.

- [ ] **5.1 Fix `NSWindow.didUpdateNotification` performance hotspot**
  - Fires on every event loop pass; each `EditorPaneVC` walks responder chain
  - Fix: Filter with `object: view.window`, add early-return when `focusedPaneId` unchanged
  - File: `Pharos/ViewControllers/EditorPaneVC.swift` lines 213-216

- [ ] **5.2 Coalesce duplicate `$tabs` subscriptions**
  - Two separate subscriptions fire on every tab mutation (including every keystroke)
  - Fix: Merge into single subscription, or filter to only react when active tab changes
  - File: `Pharos/ViewControllers/EditorPaneVC.swift` lines 151-158, 188-195

- [ ] **5.3 Debounce `rebuildConnectionMenu()` calls**
  - Three Combine subs each rebuild the full menu; often fire in rapid succession
  - Fix: `Publishers.CombineLatest3(...).debounce(for: .milliseconds(50), ...)`
  - File: `Pharos/ViewControllers/EditorPaneVC.swift` lines 182-199

---

## Phase 6: Error Handling + User Feedback

Silent failures that leave users with no feedback.

- [ ] **6.1 Surface errors in `AppStateManager` instead of `NSLog`**
  - 7 `catch` blocks just `NSLog()` -- user never sees save/delete failures
  - Fix: Add `@Published var lastError: String?` or make methods `throws`
  - File: `Pharos/Core/AppStateManager.swift`

- [ ] **6.2 Fix JSON injection in FFI error formatting**
  - `format!("{{\"error\":\"{}\"}}", e)` breaks on quotes/backslashes in errors
  - Fix: Use `serde_json::json!({"error": e.to_string()})`
  - Files: `pharos-core/src/ffi/connection.rs`, `settings.rs`, `saved_queries.rs`, `query_history.rs`

- [ ] **6.3 Fix fragile string-prefix error detection in QueryHistory FFI**
  - `json.hasPrefix("{\"error\":")` depends on exact JSON key ordering
  - Fix: Decode as error struct first, fall through to success decode
  - File: `Pharos/Core/PharosCore+QueryHistory.swift` lines 36, 52

- [ ] **6.4 Show user-facing errors in `SaveQuerySheet`**
  - `replaceQuery`/`createNewQuery` catch errors but only NSLog them
  - Fix: Show `NSAlert` on failure
  - File: `Pharos/Sheets/SaveQuerySheet.swift` lines 180-188

- [ ] **6.5 Fix dead validation in `ConnectionSheet`**
  - `buildConfig()` replaces empty fields with defaults before validation runs
  - Fix: Validate raw field values before calling `buildConfig()`
  - File: `Pharos/Sheets/ConnectionSheet.swift` lines 195-224

---

## Phase 7: Rust Backend Improvements

Correctness and efficiency in the core data layer.

- [ ] **7.1 Fix `export_table` loading entire table into memory**
  - Uses `fetch_all`; `export_query` already uses pagination
  - Fix: Refactor to use streaming/pagination
  - File: `pharos-core/src/commands/table.rs` lines 519-523

- [ ] **7.2 Batch ANALYZE calls instead of N+1**
  - One `ANALYZE` per unanalyzed table; PG 11+ supports batching
  - Fix: Single `ANALYZE schema.t1, schema.t2, ...` statement
  - File: `pharos-core/src/db/postgres.rs` lines 114-133

- [ ] **7.3 Run history pruning periodically, not on every query**
  - DELETE runs after every `save_query_history` call
  - Fix: Prune once at startup or with timestamp-gated check
  - File: `pharos-core/src/db/sqlite.rs` lines 596-601

- [ ] **7.4 Relax identifier validation (too restrictive for international schemas)**
  - ASCII-only allowlist rejects valid quoted identifiers with Unicode/dots/spaces
  - Fix: Rely on existing `escape_identifier` quoting; reject only empty/null-byte names
  - Files: `pharos-core/src/commands/query.rs` lines 17-28, `table.rs` lines 1049-1072

- [ ] **7.5 Fix empty string treated as NULL in JSON/JSONL export**
  - `text_to_json_value` returns `Null` for empty string TEXT columns
  - Fix: Use `Option<String>` to distinguish null from empty
  - File: `pharos-core/src/commands/table.rs` lines 1199-1201

- [ ] **7.6 Fix `parse_identifier` not handling escaped quotes (`""`) in identifiers**
  - Stops at first `"` instead of handling `"my""table"`
  - File: `pharos-core/src/commands/query.rs` lines 667-669

---

## Phase 8: Code Duplication + Architecture

Reduce maintenance burden and improve code health.

- [ ] **8.1 Extract shared `SQLLexer` for editor components**
  - Dollar-tag scanning, string/comment state duplicated across SQLTextView, SQLSegmentParser, SQLFoldingParser
  - Fix: Single tokenizer reused by highlighting, folding, and segmenting
  - Files: `Pharos/Editor/SQLTextView.swift`, `SQLSegmentParser.swift`, `SQLFoldingParser.swift`

- [ ] **8.2 Extract FFI boilerplate into macros (Rust side)**
  - ~15 async wrappers follow identical pattern; ~10 sync wrappers do too
  - Fix: `ffi_sync!` and `ffi_async!` macros (combines with Phase 1.1)
  - Files: all `pharos-core/src/ffi/*.rs`

- [ ] **8.3 Extract FFI boilerplate helpers (Swift side)**
  - Repeated encode/call/decode pattern across all `PharosCore+*.swift` files
  - Fix: Generic `callSync<T,A>` and `callAsync<T>` helpers
  - Files: all `Pharos/Core/PharosCore+*.swift`

- [ ] **8.4 Break up `ContentViewController` (~1600 lines)**
  - 3 duplicated query execution paths, action bar setup, result tab management all in one VC
  - Fix: Extract `QueryExecutionController`, `ResultTabController`, `ActionBarBuilder`
  - File: `Pharos/ViewControllers/ContentViewController.swift`

- [ ] **8.5 Deduplicate `export_table` and `export_query` format dispatch**
  - Nearly identical CSV/JSON/JSONL/Markdown/SQL/XLSX logic in both
  - Fix: Extract `FormatWriter` trait or shared helper functions
  - File: `pharos-core/src/commands/table.rs`

- [ ] **8.6 Extract shared `makeLabel` helper from 4 sheets**
  - Same function copy-pasted in ConnectionSheet, ExportDataSheet, SaveQuerySheet, SettingsSheet
  - Fix: `NSTextField` extension or shared utility
  - Files: 4 sheet files

---

## Phase 9: Miscellaneous Fixes (Low Severity)

- [ ] **9.1 Fix word wrap toggle bug** -- both branches set identical properties; `else` should disable wrap
  - File: `Pharos/ViewControllers/QueryEditorVC.swift` lines 260-268
- [ ] **9.2 Replace deprecated `lockFocus`/`unlockFocus`** in `ResultTabBar` and `FilterableHeaderView`
- [ ] **9.3 Fix `.secondaryLabelColor` deprecated usage** in `InspectorViewController`
- [ ] **9.4 Fix `PaneTabBar` context menu bypassing callback pattern** -- calls `AppStateManager.shared` directly
- [ ] **9.5 Fix hardcoded `.white` bezel color** in `PaneTabBar` (broken in dark mode)
- [ ] **9.6 Remove `has_pool` TOCTOU guard** in `delete_connection` -- redundant with `remove_pool`
- [ ] **9.7 Remove async from sync-only functions** in `saved_query.rs`, `settings.rs`
- [ ] **9.8 Fix `escape_csv_field` missing `\r` handling** per RFC 4180
- [ ] **9.9 Add port field `NumberFormatter`** in ConnectionSheet (currently accepts non-numeric input)

---

## Summary

| Phase | Items | Theme | Impact |
|-------|-------|-------|--------|
| 1 | 5 | Critical Safety (UB, crashes, injection) | Prevents crashes and security issues |
| 2 | 4 | Thread Safety | Eliminates data races |
| 3 | 4 | Memory Leaks | Fixes retain cycles |
| 4 | 7 | Editor Performance | Major UX improvement on large files |
| 5 | 3 | Event Overhead | Reduces per-keystroke overhead |
| 6 | 5 | Error Handling | Users actually see failures |
| 7 | 6 | Rust Backend | Correctness + efficiency |
| 8 | 6 | Architecture | Long-term maintainability |
| 9 | 9 | Misc Fixes | Polish |
| **Total** | **49** | | |
