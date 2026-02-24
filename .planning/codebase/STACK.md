# Technology Stack

**Analysis Date:** 2025-02-24

## Languages

**Primary:**
- Swift 5.10 - macOS native application UI and AppKit integration
- Rust 1.77.2 - PostgreSQL client backend, schema introspection, SQL operations

**Secondary:**
- C - FFI layer for Swift ↔ Rust communication (`pharos-core.h`)

## Runtime

**Environment:**
- macOS 14.0+ (Deployment target)
- Xcode 16.0+

**Package Managers:**
- Cargo 1.77+ - Rust dependency management
- Xcode Package Manager - Swift/AppKit (built into Xcode)

## Frameworks

**Core UI:**
- AppKit (native macOS framework) - Window management, menus, sheets, views
- Foundation - Core utilities, JSON encoding/decoding, file system operations

**Async/Concurrency:**
- Swift async/await - Async operations from Rust backend
- Combine - Reactive state management in AppStateManager

**Database Access (Rust Backend):**
- sqlx 0.8 - PostgreSQL async driver with runtime-tokio, TLS support
  - Features: postgres, uuid, chrono, json, ipnetwork, mac_address, rust_decimal
  - Pool management with configurable timeouts and max connections
- rusqlite 0.32 - Local SQLite database for metadata cache and settings
  - Features: bundled (self-contained SQLite)

**Runtime (Rust):**
- tokio 1 - Async runtime with full feature set for multi-threaded execution
- futures 0.3 - Async utilities and combinators

## Key Dependencies

**Critical:**
- sqlx 0.8 - PostgreSQL introspection, query execution, statement execution
  - Provides type-safe query builders and connection pooling
  - Native TLS support for SSL mode configuration (disable/prefer/require)
- rusqlite 0.32 - Persistent local storage for connections, saved queries, settings, query history
  - Bundled SQLite removes external database dependency
- tokio 1 - Powers async execution of database operations across connection pools
- keyring 3 - macOS-native keychain integration for secure password storage
  - Features: apple-native for macOS Keychain API access

**Serialization:**
- serde 1.0 - JSON serialization/deserialization across FFI boundary
- serde_json 1.0 - JSON encoding/decoding for C ↔ Swift communication

**Data Types & Utilities:**
- uuid 1 - Connection and query IDs with serde support
- chrono 0.4 - Timestamp handling for query history and metadata
- rust_decimal 1 - Precise decimal number support for numeric columns
- ipnetwork 0.20 - Network type introspection for PostgreSQL network columns
- mac_address 1.1 - MAC address type support for PostgreSQL macaddr columns

**Export/Import:**
- rust_xlsxwriter 0.82 - Export query results to Excel/XLSX format
- csv 1.3 - CSV parsing and writing for data import/export

**Utilities:**
- thiserror 2 - Error type derivation and conversion
- log 0.4 - Structured logging across Rust backend
- env_logger 0.11 - Runtime log level configuration via RUST_LOG environment variable
- hex 0.4 - Hexadecimal encoding for credential serialization
- sqlformat 0.3 - SQL formatting with PostgreSQL conventions (uppercase keywords, indentation)
- urlencoding 2 - Connection string URL encoding for special characters in credentials

## Configuration

**Build Configuration:**
- CBuildGen 0.27 - Auto-generates `pharos_core.h` from Rust source (`src/ffi.rs`)
  - Config: `pharos-core/cbindgen.toml`
  - Generated header: `pharos-core/include/pharos_core.h`
- xcodegen - Generates Xcode project from `project.yml`
  - Run `xcodegen generate` after adding new Swift files to project structure

**Xcode Project (project.yml):**
- Bundle ID: `com.pharos.client`
- Deployment Target: macOS 14.0
- Swift Version: 5.10
- Hardened Runtime: Enabled for macOS app signing
- C Header Search Path: `$(SRCROOT)/Pharos/CPharosCore`
- Library Search Path: `$(SRCROOT)/pharos-core/target/release`
- Linked Frameworks:
  - Security.framework - Keychain access for password storage
  - SystemConfiguration.framework - Network configuration detection
  - CoreFoundation.framework - Low-level macOS APIs
- Linked System Libraries: libz, libiconv, libm, libresolv

**Rust Build (Cargo.toml):**
- Library Type: staticlib - Compiled as static library `libpharos_core.a`
- Edition: 2021
- Rust Version: 1.77.2 minimum

**Rust Pre-build Script:**
- Invoked from Xcode before building Pharos app
- Runs: `cargo build --release` in `pharos-core/` directory
- Outputs: `pharos-core/target/release/libpharos_core.a`

**Runtime Configuration:**
- App Support Directory: `~/Library/Application Support/com.pharos.client/`
  - Contains: `pharos.db` (SQLite metadata store)
  - Passwords: Stored in macOS Keychain, NOT on disk
  - Migrations: Auto-run on SQLite initialization

## Platform Requirements

**Development:**
- Xcode 16.0 or later
- Rust toolchain (1.77.2+) - Install via rustup
- macOS 14.0+ for building and running
- Cargo for Rust dependency management and building

**Production:**
- macOS 14.0 or later (Sonoma+)
- No external database required (SQLite is bundled)
- No network dependencies beyond target PostgreSQL servers
- Keychain access for password storage (native macOS feature)

---

*Stack analysis: 2025-02-24*
