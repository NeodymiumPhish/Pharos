# Coding Conventions

**Analysis Date:** 2025-02-24

## Naming Patterns

### Swift Files

**Files:**
- PascalCase for types/classes/sheets: `AppDelegate.swift`, `ConnectionSheet.swift`, `AppStateManager.swift`
- PascalCase for ViewController files: `QueryEditorVC.swift`, `SchemaBrowserVC.swift`, `ResultsGridVC.swift`
- PascalCase for model structs: `QueryResult.swift`, `SavedQuery.swift`, `Connection.swift`
- `VC` suffix for ViewControllers (short convention used throughout)

**Classes/Types:**
- PascalCase: `AppStateManager`, `QueryTab`, `ConnectionConfig`, `SavedQuery`
- Enums: PascalCase with lowercase cases: `enum ConnectionStatus { case connected, disconnected }`
- Model structs: Simple PascalCase: `struct QueryResult {}`

**Functions:**
- camelCase for methods: `loadConnections()`, `saveConnection()`, `disconnect()`
- camelCase for computed properties: `activeTab`, `activeTabIndex`, `canReopenTab`
- `@discardableResult` decorator used for methods that return values but are often called for side effects: `createTab()`

**Variables:**
- camelCase for local/instance variables: `scrollView`, `textView`, `cancellables`
- private instance vars with underscore prefix not used; use `private let` instead
- Published properties: `@Published var activeConnectionId`, `@Published var settings`
- Use property observers (`didSet`, `willSet`) for reactive updates

**Types (Codable):**
- Struct names: PascalCase
- Property names: camelCase
- CodingKeys enum for snake_case JSON mapping: `case executionTimeMs = "execution_time_ms"`

### Rust Files

**Files:**
- snake_case for module files: `connection.rs`, `query_history.rs`, `postgres.rs`
- Files organized by feature/domain: `src/commands/`, `src/db/`, `src/models/`

**Structs/Enums:**
- PascalCase: `ConnectionConfig`, `QueryResult`, `SchemaInfo`
- Enum cases: PascalCase: `ConnectionStatus::Connected`
- Default derives: `#[derive(Debug, Clone, Serialize, Deserialize)]`

**Functions:**
- snake_case: `execute_query()`, `create_pool()`, `save_connection()`
- Public async functions: `pub async fn connect_postgres()`
- Helper functions (private): `fn build_connection_string()`, `fn sanitize_error()`
- Unsafe functions documented: `unsafe fn c_str_to_string()`

**Variables:**
- snake_case: `connection_id`, `query_id`, `backend_pid`
- Constants/statics: SCREAMING_SNAKE_CASE: `RUNTIME`, `APP_STATE`

**Serde Attributes:**
- Struct-level: `#[serde(rename_all = "camelCase")]` for most models (converts snake_case fields to camelCase JSON)
- Some models use default case without rename_all (backward compatibility)
- Field-level: `#[serde(default)]` for optional fields, `#[serde(skip_serializing_if = "Option::is_none")]` to omit nulls

## Code Style

### Swift Formatting

**Comments:**
- Documentation comments for public functions use triple-slash: `/// Format SQL with PostgreSQL conventions`
- MARK sections for organization: `// MARK: - Public API`, `// MARK: - Helpers`
- Inline comments explain "why", not "what": `// Save current schema selection for the old connection`

**Imports:**
- Foundation first, then framework imports: `import AppKit` then `import Combine`
- CPharosCore (C FFI) imported at top of bridge files: `import CPharosCore`

**Closures:**
- Trailing closure syntax: `$settings.receive(on: RunLoop.main).sink { [weak self] _ in ... }`
- Capture lists: `[weak self]` to avoid retain cycles
- Guard statements in closures for nil-coalescing: `guard let self else { return }`

**Properties:**
- Use `@Published` for observable state in `@ObservableObject`
- Use `@Published private(set)` to prevent external mutation: `@Published private(set) var connectionStatuses`
- Separate public API from internal implementation via access modifiers

### Swift Architecture Patterns

**View Controllers:**
- Override `loadView()` to build UI programmatically (not using Interface Builder or Storyboards)
- Store references to subviews as properties for later access: `private let scrollView: NSScrollView!`
- Use `NSViewController` subclasses with `NSView` construction
- Data source/delegate patterns for tables/outlines: `NSTableViewDataSource`, `NSTableViewDelegate`

**State Management:**
- Centralized state via singleton `AppStateManager.shared`
- Use Combine's `@Published` for reactive updates
- `ObservableObject` conformance enables SwiftUI-like reactivity in AppKit
- Store Combine subscriptions in `cancellables: Set<AnyCancellable>` property

**Enums as Namespaces:**
- `PharosCore` enum contains all Rust bridge functions (not a class, static methods only)
- `MainMenu` enum contains menu building logic
- `SettingsSheet` enum functions for theme application

### Rust Formatting

**Comments:**
- Documentation comments use `///`: `/// Load a PostgreSQL connection pool`
- Multi-line block comments for sections: `// -----------\n// Callbacks\n// -----------`
- Doc comments on enums, structs, and public functions required
- Inline comments explain complex logic: `// URL encode username and password to handle special characters safely`

**Error Handling:**
- Return `Result<T, String>` for most operations (error message as String)
- Use `.map_err(|e| e.to_string())` to convert sqlx/rusqlite errors to Strings
- `unwrap_or_default()` pattern for FFI string conversion (safe in C boundary)
- FFI callbacks use separate `callback_ok()` and `callback_err()` helpers

**Async/Await:**
- Use `async fn` for database operations
- Spawn tasks via `tokio` runtime stored in `OnceLock<Runtime>`
- Use `tokio::spawn()` for background work without blocking caller
- Callbacks invoked via `runtime().block_on()` or task spawning

**Attributes:**
- Serialization derives standard: `#[derive(Debug, Clone, Serialize, Deserialize)]`
- Database models: `#[serde(rename_all = "camelCase")]` (convert snake_case to camelCase for JSON)
- Optional fields: `#[serde(default)]` allows missing keys in JSON
- Field-level rename: `#[serde(rename = "latency_ms")]` for specific snake_case JSON keys

## Import Organization

### Swift

**Order:**
1. Foundation/system frameworks: `import Foundation`, `import AppKit`, `import Combine`
2. C FFI imports: `import CPharosCore`
3. Internal imports: rarely used, use fully qualified names instead

**Pattern:**
```swift
import Foundation
import AppKit
import Combine
import CPharosCore

// No relative imports — all access via module names
```

### Rust

**Order:**
1. Standard library: `use std::...;`
2. External crates: `use serde::{...};`, `use tokio::...;`, `use sqlx::...;`
3. Internal modules: `use crate::models::{...};`, `use crate::db::{...};`

**Pattern:**
```rust
use std::collections::{HashMap, HashSet};
use std::sync::{Mutex, Arc};
use serde::{Deserialize, Serialize};
use sqlx::{Row, Column};
use crate::models::{ConnectionConfig, ConnectionInfo};
use crate::state::AppState;
```

**Path Aliases:**
- No path aliases configured; use absolute paths from crate root
- Import groups separated by blank line by category (stdlib, external, internal)

## Error Handling

### Swift Patterns

**Do-Try-Catch:**
```swift
do {
    try PharosCore.saveConnection(config)
    loadConnections()
} catch {
    NSLog("Failed to save connection: \(error)")
}
```

**Task Errors:**
```swift
Task {
    do {
        let info = try await PharosCore.connect(connectionId: id)
        await MainActor.run {
            self.connectionStatuses[id] = info.status
        }
    } catch {
        NSLog("Connection failed: \(error)")
    }
}
```

**Throwing Functions:**
- Return `throws` for FFI bridge functions: `static func loadConnections() throws -> [ConnectionConfig]`
- Define custom error enum: `enum PharosCoreError: LocalizedError { case rustError(String), decodingError, nullResult }`
- Custom `errorDescription` property for user-facing messages

### Rust Patterns

**Result Returns:**
- Functions return `Result<T, String>` consistently
- Lock errors converted to strings: `.map_err(|e| e.to_string())?`
- Database errors converted: `.map_err(|e| e.to_string())?`

**FFI Boundary:**
- C functions return raw pointers (null signals error)
- Swift side checks for null and converts to throws
- Error messages are C strings passed back as `*const c_char` via callback

**Cancellation:**
- Queries tracked with `Arc<AtomicBool>` flag in `RunningQuery`
- Check `cancelled.load(Ordering::Relaxed)` before long operations
- Cancel via PostgreSQL `pg_cancel_backend(pid)` (may race with natural completion)

## Logging

### Framework: Console/NSLog

**Swift:**
- Use `NSLog()` for startup/shutdown and error logging
- No structured logging framework; plain text messages
- Pattern: `NSLog("Failed to load connections: \(error)")`

### Rust Patterns

**Log Levels:**
- Initialize with `env_logger::try_init()` in FFI init
- Controlled via `RUST_LOG` environment variable (not implemented in app yet)
- Not actively used in application code (errors returned to caller instead)

## Comments

### When to Comment

**Swift:**
- Comment public API with `///` doc comments
- Explain non-obvious algorithmic decisions: `// Save current schema selection for the old connection`
- Mark sections clearly with `// MARK: -`
- Avoid commenting obvious code: `let x = 5  // set x to 5` (don't do this)

**Rust:**
- Document all public functions with `///` comments
- Explain complex lock patterns: `// Acquire a dedicated connection from the pool so that SET search_path and the query run on the same connection`
- Document safety preconditions for unsafe code: `/// Convert a C string to a Rust String. Returns empty string for NULL.`

### JSDoc/TSDoc

**Not used** — This is native Swift/Rust, not TypeScript/JavaScript. Use `///` doc comments instead.

## Function Design

### Swift

**Size:** Prefer small focused functions (under 30 lines)
- Large functions broken into MARK sections
- Each MARK section could be extracted to helper if reused

**Parameters:**
- Explicit parameter names in call site: `disconnect(id: connectionId)`
- Use named parameters for clarity: `executeQuery(connectionId:, sql:, limit:)`
- Avoid boolean parameters; use named cases instead

**Return Values:**
- Return optional for "may not exist" cases: `var activeTab: QueryTab?`
- Return bool for success/failure: `func deleteConnection(id:) -> Bool`
- Use result builders for UI construction (not used; all manual NSView)

### Rust

**Size:** Functions range 15-100 lines depending on complexity
- Database operations tend toward 40-60 lines
- Small utility functions 5-15 lines

**Parameters:**
- State reference last: `fn execute_query(..., state: &AppState) -> Result<T, String>`
- Pool/connection accessed from state, not passed separately
- Use references for borrowed data: `&ConnectionConfig`

**Return Values:**
- `Result<T, String>` for fallible operations
- `Result<(), String>` for side-effect-only functions
- Options for "may not exist": `Option<T>`

## Module Design

### Swift Exports

**Visibility:**
- Use `private` for internal state: `private var cancellables = Set<AnyCancellable>()`
- Use `private(set)` for published state that shouldn't be externally mutated: `@Published private(set) var connectionStatuses`
- Use `public` sparingly; most code is internal

**Barrel Files:**
- Not used; models imported directly: `import Models.Connection`
- No index files aggregating exports

### Rust Exports

**Module Structure:**
- `lib.rs` re-exports public modules: `pub mod commands; pub mod db; pub mod models;`
- FFI functions use `#[no_mangle]` to expose to C: `pub extern "C" fn pharos_connect(...)`
- Internal helper functions marked `fn` (private to module)

**Visibility:**
- `pub` for command functions and model types
- `pub async fn` for async operations
- Internal state management (locking, caching) marked `pub` but treated as internal API

---

*Convention analysis: 2025-02-24*
