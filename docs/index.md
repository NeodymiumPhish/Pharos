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

Pharos is a native macOS PostgreSQL client built with Swift and Rust. It provides a fast, focused environment for exploring databases, writing SQL, and analyzing query results -- all within a native AppKit interface that feels at home on macOS.

## Features

- **[Getting Started](getting-started.md)** -- Install Pharos and connect to your first database
- **[Connections](connections.md)** -- Manage multiple PostgreSQL server connections with SSL support
- **[Schema Browser](schema-browser.md)** -- Navigate schemas, tables, views, and columns in a tree browser
- **[Query Editor](query-editor.md)** -- Write SQL with syntax highlighting, auto-completion, and bracket matching
- **[Query Execution](query-execution.md)** -- Run queries with cancellation support and paginated results
- **[Results Grid](results-grid.md)** -- View results in a native table with sorting, find, and filter
- **[Data Export](data-export.md)** -- Copy and export data in multiple formats including CSV, JSON, and Excel
- **[Saved Queries](saved-queries.md)** -- Organize and reuse queries with folder-based organization
- **[Query History](query-history.md)** -- Browse and revisit previously executed queries
- **[Table Operations](table-operations.md)** -- Clone tables, import CSV data, and export table contents
- **[Settings](settings.md)** -- Configure appearance, editor preferences, and query behavior
- **[Keyboard Shortcuts](keyboard-shortcuts.md)** -- Complete reference for all keyboard shortcuts

## Architecture

Pharos combines a Swift frontend with a Rust core library for database operations. The user interface is built entirely with AppKit, providing native macOS controls, sheets, popovers, and system appearance support. The Rust core (pharos-core) handles PostgreSQL connections, query execution, and data processing via a C FFI bridge.

## System Requirements

- macOS 14.0 (Sonoma) or later
- A PostgreSQL server to connect to (local or remote)
