# Technology Stack

**Analysis Date:** 2025-02-24

## Languages

**Primary:**
- TypeScript 5.9.3 - Frontend UI, Tauri command wrappers, type definitions
- Rust 1.93.0 - Backend services, database operations, Tauri commands

**Secondary:**
- CSS3 - Styling via Tailwind with CSS variables for theming
- SQL - PostgreSQL queries and DDL/DML operations

## Runtime

**Environment:**
- Node.js 22.22.0 - Development and build environment
- Tauri 2 - Native desktop application framework
- Tokio 1 (async runtime) - Rust async task execution

**Package Manager:**
- npm 11.10.1 - JavaScript/TypeScript dependency management
- Cargo - Rust dependency and build management
- Lockfile: package-lock.json (npm), Cargo.lock (Rust) - both present

## Frameworks

**Core:**
- Tauri 2.9.1 - Desktop app framework with React frontend + Rust backend
- React 19.2.4 - UI component framework
- Vite 7.3.1 - Frontend build tool and dev server
- Zustand 4.5.0 - Lightweight state management library

**UI & Components:**
- Monaco Editor (@monaco-editor/react 4.7.0) - SQL query editor
- Tailwind CSS 3.4.0 - Utility-first CSS framework
- Lucide React 0.469.0 - Icon component library
- TanStack Virtual (@tanstack/react-virtual 3.0.0) - Virtual scrolling for large result grids

**Data Management:**
- TanStack React Query (@tanstack/react-query 5.0.0) - Server state management
- sqlx 0.8 (async PostgreSQL driver) - Type-safe database access

**Build/Dev:**
- TypeScript 5.9.3 - Type safety
- Vite 7.3.1 - Module bundling and dev server
- @vitejs/plugin-react 5.1.2 - React JSX/Fast Refresh support
- Autoprefixer 10.4.0 - CSS vendor prefixing
- PostCSS 8.4.0 - CSS transformation pipeline
- Tauri CLI 2.9.6 - App bundling and development

## Key Dependencies

**Critical:**
- sqlx 0.8 - PostgreSQL connection pooling (PgPoolOptions with max 5 connections per config)
- tauri-plugin-dialog 2.6.0 - File dialogs for import/export operations
- tauri-plugin-window-state 2 - Window state persistence
- window-vibrancy 0.5 - macOS native vibrancy effects (Sidebar material)

**Database:**
- rusqlite 0.32 (with bundled SQLite) - Local SQLite storage for connections, saved queries, settings, query history
- keyring 3 (apple-native) - macOS Keychain integration for password storage

**Serialization & Utilities:**
- serde 1.0 + serde_json 1.0 - JSON serialization/deserialization
- uuid 1.0 - Connection ID generation
- chrono 0.4 - Timestamp handling
- sql-formatter 15.7.0 - SQL syntax formatting
- rust_xlsxwriter 0.82 - Excel export generation
- csv 1.3 - CSV import/export
- rust_decimal 1.0 - Precise decimal handling for numeric types
- ipnetwork 0.20, mac_address 1.1 - Network data type support
- hex 0.4 - Hexadecimal encoding
- urlencoding 2 - URL parameter encoding for connection strings
- thiserror 2 - Error type derivation
- log 0.4 - Logging framework

**Frontend Utilities:**
- clsx 2.0.0 - Conditional CSS class composition
- tailwind-merge 2.0.0 - Intelligent Tailwind class merging

**Async:**
- tokio 1 (full features) - Async runtime with full feature set
- futures 0.3 - Async utility combinators

## Configuration

**Environment:**
- Tauri configuration: `src-tauri/tauri.conf.json`
  - App identifier: `com.pharos.client`
  - Minimum macOS version: 10.15
  - Window: 1200x800 (resizable), transparent, overlay title bar
  - CSP allows: self, unsafe-eval (Monaco), blobs, cdn.jsdelivr.net
- Development URL: `http://localhost:5173` (Vite dev server)
- Keychain service: `com.pharos.client` - unified credentials storage

**Build:**
- TypeScript config: `tsconfig.json` - ES2020 target, strict mode, JSX support
- Vite config: `vite.config.ts` - React plugin, path alias (@/ → src/)
- Tailwind config: Default with theme variables (dark/light modes)
- PostCSS config: Autoprefixer integration

**Database Schema:**
- SQLite local database at `{app_data_dir}/pharos.db` with tables:
  - `connections` - Connection configurations (no passwords stored)
  - `saved_queries` - User-saved query library
  - `query_history` - Query execution history with results
  - `app_settings` - Application preferences

## Platform Requirements

**Development:**
- macOS 10.15+ (Catalina or later)
- Xcode Command Line Tools (for native build)
- Rust 1.77.2+ (configured in src-tauri/Cargo.toml)
- Node.js 22.x recommended
- npm 11.x

**Production:**
- Deployment target: macOS 10.15+ (native app bundle)
- Architecture: Intel x86_64 and Apple Silicon (universal binary)
- Native features: macOS Private API for enhanced window appearance, OS Keychain access

---

*Stack analysis: 2025-02-24*
