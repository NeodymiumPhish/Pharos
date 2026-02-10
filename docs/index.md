---
layout: default
title: Home
nav_order: 1
---

# Pharos

**A high-performance PostgreSQL client for macOS.**
{: .fs-6 .fw-300 }

Pharos is a native macOS database client built for speed and simplicity. It combines a Rust-powered backend with a modern React interface to deliver fast query execution, rich schema browsing, and a polished editing experience.

---

## Key Features

- **[Schema Browser](schema-browser)** — Navigate schemas, tables, views, foreign tables, functions, indexes, and constraints in an expandable tree with row count estimates and table sizes.

- **[Query Editor](query-editor)** — Write SQL with Monaco-powered autocomplete, live validation, and automatic formatting.

- **[Results Grid](results-grid)** — Browse results with virtual scrolling, column sorting, filtering, find-in-results, and aggregate calculations.

- **[EXPLAIN Visualization](explain)** — Visualize query plans with an interactive tree showing costs, timing, buffer stats, and row accuracy warnings.

- **[Data Export](data-export)** — Export to CSV, TSV, JSON, JSON Lines, SQL INSERT, Markdown, or XLSX from results or directly from tables.

- **[Inline Editing](inline-editing)** — Edit cell values and delete rows directly in the results grid, with transaction-safe commits.

---

## Architecture

Pharos is built with:

| Layer | Technology |
|:------|:-----------|
| Desktop framework | [Tauri v2](https://tauri.app/) |
| Backend | Rust with [sqlx](https://github.com/launchbadge/sqlx) |
| Frontend | [React 19](https://react.dev/) |
| State management | [Zustand](https://github.com/pmndrs/zustand) |
| Code editor | [Monaco Editor](https://microsoft.github.io/monaco-editor/) |
| Virtual scrolling | [TanStack Virtual](https://tanstack.com/virtual) |
| Local storage | SQLite (connections, saved queries, settings, history) |

---

## Getting Started

New to Pharos? Start with the [Getting Started](getting-started) guide for installation, your first connection, and a quick tour of the interface.
