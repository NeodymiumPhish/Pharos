# Testing Patterns

**Analysis Date:** 2025-02-24

## Test Framework

**Status: Minimal Testing Infrastructure**

Currently, the codebase has **no automated test suite** configured or in use:
- No Swift XCTest files found in `Pharos/` directory
- No Rust `#[test]` modules in `pharos-core/src/`
- No test runner configuration (XCTest, pytest, cargo test setup)
- No CI/CD pipeline configured for automated testing

### Build System

**Swift (Xcode):**
- Generated via `xcodegen` from `project.yml`: `xcodegen generate` required after adding Swift files
- Compile target: macOS 14.0+ with Swift 5.10
- No test target defined in `project.yml`

**Rust:**
- `cargo build --release` configured as pre-build script in Xcode
- Crate type: static library (`crate-type = ["staticlib"]`)
- No test configuration or test runner setup

## Manual Testing Patterns

### Application Testing Approach

**Swift Application:**
- Manual testing via app launch and UI interaction
- Use Xcode debugger to step through code
- Console output via `NSLog()` for debugging

**Rust Backend:**
- Database operations tested by calling from Swift frontend
- Connection lifecycle: manual validation in app UI
- Query execution tested through query editor

### Development Workflow

No formalized test-driven development (TDD) process. Testing happens through:
1. Building the app in Xcode
2. Running via `xcrun simctl` or direct launch
3. Manual verification of features
4. Console logging via `NSLog()`

## Test Data & Fixtures

**Connections:**
- Stored in SQLite at: `~/Library/Application Support/com.pharos.client/`
- Local test database typically: PostgreSQL instance on localhost
- Manual setup required for each testing session

**Sample Data:**
- Not versioned; test databases maintained manually
- SQL fixtures: None in repository
- Seed scripts: None present

## Error Testing

**Swift Error Handling:**
- Errors caught in `do-try-catch` blocks and logged: `NSLog("Failed: \(error)")`
- No assertions or error verification tests
- User-facing alerts for critical errors via `NSAlert()`

**Rust Error Propagation:**
- Functions return `Result<T, String>` with error message
- Errors sanitized before sending to frontend: `fn sanitize_error()` removes credentials
- Test via manual triggering (e.g., invalid connection string)

## Code Quality Verification

### Syntax Checking

**Swift:**
- Xcode build process validates syntax
- No linter (SwiftLint) configured
- No formatter (SwiftFormat) configured

**Rust:**
- `cargo build` validates Rust syntax
- No clippy (Rust linter) configured in build
- No explicit formatting enforcement

### Type Safety

**Swift:**
- Swift type system enforced at compile time
- Optional handling: explicit unwrapping and nil-coalescing
- No null safety linter

**Rust:**
- Rust type system and borrow checker enforced at compile
- Unsafe code blocks marked with `unsafe fn` and documented
- Example: `unsafe fn c_str_to_string()` with safety documentation

## Performance Testing

**Not Implemented**

No performance benchmarks configured. Monitoring happens through:
- Execution time tracking in query results: `executionTimeMs` field in `QueryResult`
- Manual timing of slow operations
- Connection latency measured during test: `latencyMs` field in `TestConnectionResult`

## Coverage

**Requirements:** Not enforced

No coverage targets or reporting configured.

## Integration Points

### FFI Testing

**C Boundary (Swift ↔ Rust):**
- Tested manually by calling FFI functions from Swift
- No automated C interface verification
- Callback patterns tested by executing queries and awaiting results

**Pattern Used:**
```swift
// Manual integration test pattern (not automated)
Task {
    do {
        let info = try await PharosCore.connect(connectionId: id)
        // Verify info.status == .connected
    } catch {
        // Error handling verified manually
    }
}
```

### Database Integration

**SQLite (Metadata):**
- Schema assumed correct (migrations not versioned)
- Manual testing of CRUD operations on connections/queries
- No automated schema migration tests

**PostgreSQL:**
- Connection tested via `PharosCore.testConnection()`
- Query execution tested through UI
- Manual verification of result formatting

## Common Testing Gaps

### Untested Areas

1. **Connection Lifecycle** (`src-tauri/Pharos/Core/PharosCore.swift`):
   - No automated tests for connect/disconnect sequences
   - Race conditions in status updates not covered
   - Error recovery (reconnect after failure) untested

2. **Query Execution** (`pharos-core/src/commands/query.rs`):
   - No tests for cancellation timing
   - No tests for invalid SQL error messages
   - Pagination (offset/limit) not verified automatically
   - Schema validation not tested at boundaries

3. **Data Serialization** (`pharos-core/src/models/`, `Pharos/Models/`):
   - JSON encoding/decoding not systematically tested
   - Missing field handling (`skip_serializing_if`) not verified
   - Snake_case/camelCase mapping manual verification only

4. **Saved Queries CRUD** (`pharos-core/src/commands/saved_query.rs`):
   - Create/update/delete operations untested
   - Folder nesting not verified
   - Error cases not covered

5. **UI State Management** (`Pharos/Core/AppStateManager.swift`):
   - Tab management (create/close/reopen) untested
   - Schema selection persistence untested
   - Connection status updates not verified

6. **Error Cases**:
   - Invalid connection strings: manual testing only
   - Network timeout behavior: untested
   - Concurrent query execution: untested
   - Memory exhaustion (large result sets): untested

### Rust-Side Test Coverage Gaps

- **Command Layer** (`pharos-core/src/commands/`):
  - No tests for sanitized error messages
  - No tests for connection pooling behavior
  - No tests for query registration/deregistration

- **Database Layer** (`pharos-core/src/db/`):
  - No tests for SQL injection protection (parameterized queries assumed safe)
  - No tests for connection string building
  - Credential handling untested at unit level

- **State Management** (`pharos-core/src/state.rs`):
  - Mutex locking behavior not tested
  - Concurrent access patterns untested

## Testing Strategy Recommendations

### To Add Comprehensive Testing

1. **Unit Tests** (Rust side):
   - `#[cfg(test)] mod tests { #[test] fn ... }` blocks in each command file
   - Test error sanitization, data transformations, validation logic
   - Mock SQLite and PostgreSQL via interfaces

2. **Integration Tests** (Swift side):
   - XCTest target in Xcode project
   - Mock `PharosCore` functions to test state management in isolation
   - Test UI state transitions without database

3. **E2E Tests** (App-level):
   - Launch app in UI testing mode
   - Execute predefined test sequences (connect, run query, save query, etc.)
   - Verify UI reflects backend state changes

4. **Fixtures & Factories**:
   - Rust: Builder pattern for test models (ConnectionConfig, QueryResult, etc.)
   - Swift: Factory methods for test data (AppStateManager setup, mock Connections)
   - Shared test database with known schema for integration tests

5. **CI/CD Pipeline**:
   - GitHub Actions for `cargo test` on every push
   - Xcode test runner for Swift tests
   - Code coverage reporting (threshold enforcement optional)

---

*Testing analysis: 2025-02-24*
