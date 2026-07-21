---
layout: default
title: Pharos
nav_order: 1
---

# Pharos
{: .no_toc }

<details open markdown="block">
  <summary>Table of contents</summary>
  {: .text-delta }
- TOC
{:toc}
</details>

---

## Overview

Pharos is a native macOS PostgreSQL client built with Swift and Rust. It provides a fast, focused environment for exploring databases, writing SQL, and analyzing query results — all within a native AppKit interface that feels at home on macOS.

## Features

### Connect and Explore

- **[Getting Started](getting-started.md)** — Install Pharos and run your first query
- **[Connections](connections.md)** — Manage PostgreSQL connections with SSL support and per-tab connection switching
- **[Schema Browser](schema-browser.md)** — Navigate schemas, tables, views, partitions, and columns with type icons and row counts

### Write SQL

- **[Query Editor](query-editor.md)** — Syntax highlighting, auto-completion, code folding, SQL file support, and split panes
- **[Query Variables](query-variables.md)** — Parameterize queries with `{{placeholders}}` and typed values
- **[Query Execution](query-execution.md)** — Run statements individually or all at once, concurrently, with cancellation and completion notifications

### Analyze Results

- **[Results Grid](results-grid.md)** — Per-statement result tabs with type-aware sorting, cell selection, and find
- **[Column Filters](column-filters.md)** — Excel-style value pickers with counts, plus operator-based filters
- **[Charts](charts.md)** — Visualize results as bar, line, area, pie, scatter, gantt, or heatmap charts, with server-side aggregation and drill-down
- **[Inspector](inspector.md)** — Row detail and instant aggregate statistics for any selection
- **[Data Export](data-export.md)** — Copy and export in TSV, CSV, JSON, Markdown, SQL, and Excel formats

### Organize Your Work

- **[Saved Queries](saved-queries.md)** — A folder-organized query library with drag-and-drop
- **[History & Workspaces](query-history.md)** — Every session recorded as a restorable workspace with cached results
- **[Table Operations](table-operations.md)** — View DDL, clone tables, import CSV, and export table contents
- **[Settings](settings.md)** — Appearance, editor, and query behavior preferences
- **[Keyboard Shortcuts](keyboard-shortcuts.md)** — Complete shortcut reference

## Architecture

Pharos combines a Swift frontend with a Rust core library. The interface is built entirely with AppKit (plus Swift Charts for visualization), providing native macOS controls, sheets, and system appearance support. The Rust core (`pharos-core`) handles PostgreSQL connections, query execution, and data processing via a C FFI bridge. Connection passwords live in the macOS Keychain; everything else is stored locally in SQLite.

## System Requirements

- macOS 15.0 (Sequoia) or later
- A PostgreSQL server to connect to (local or remote)
