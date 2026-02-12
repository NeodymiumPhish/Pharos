<p align="center">
  <img src="src-tauri/icons/icon.png" width="128" height="128" alt="Pharos">
</p>

<h1 align="center">Pharos</h1>

<p align="center">A PostgreSQL client for macOS.</p>

---

Pharos is a native macOS database client built with Tauri v2 and Rust. It's designed to be fast, stay out of your way, and handle the things you actually need a database client to do.

## Install

```
brew tap NeodymiumPhish/Pharos
brew install pharos
```

Or grab a `.dmg` from [Releases](https://github.com/NeodymiumPhish/Pharos/releases). - This method requires running `xattr -c Pharos.app` to get around Mac's unsigned application security measure.

Requires macOS 10.15+ and PostgreSQL 10+.

## What it does

**Schema browser** — Expandable tree with tables, views, foreign tables, functions, indexes, and constraints. Row count estimates, table sizes, and a search bar. Right-click for context menus (view rows, clone, import, export, copy DDL).

**Query editor** — Monaco-based editor with PostgreSQL syntax highlighting, schema-aware autocomplete, live SQL validation, and auto-formatting. Multi-tab support with `Cmd+T`/`Cmd+W` and `Cmd+1`–`Cmd+9` tab switching.

**Results grid** — Virtualized scrolling, click-to-sort columns, column filtering (text, numeric, boolean, null), find-in-results (`Cmd+F`), cell copy, and an aggregates footer. Display options for wrap, grid lines, row numbers, zebra striping, and configurable NULL format.

**EXPLAIN visualization** — Run `EXPLAIN` or `EXPLAIN ANALYZE` and get an interactive plan tree with cost bars, timing breakdowns, buffer stats, and row estimate accuracy warnings. Toggle to raw JSON when you need it.

**Data export** — Export results or full tables to CSV, TSV, JSON, JSON Lines, SQL INSERT, Markdown, or XLSX.

**Inline editing** — Edit cells and delete rows directly in the results grid for single-table queries with a primary key. Changes are staged and committed in a transaction.

**Query library** — Save queries into folders, drag-and-drop to reorganize. Full query history with search, date grouping, and cached result replay.

**Connections** — SSL support (disable/prefer/require), color-coded server icons, connection testing with latency display.

## Build from source

```
git clone https://github.com/NeodymiumPhish/Pharos.git
cd Pharos
npm install
npm run tauri dev
```

Production build:

```
npm run tauri build
```

## Stack

Tauri v2 / Rust / sqlx / React 19 / Zustand / Monaco Editor / TanStack Virtual / SQLite (local storage)

## Docs

Full documentation at **[neodymiumphish.github.io/Pharos](https://neodymiumphish.github.io/Pharos/)**.

## License

[MIT with Non-Commercial Clause](LICENSE) — free to use, modify, and distribute, but the software and derivatives may not be sold or commercially monetized without permission.
