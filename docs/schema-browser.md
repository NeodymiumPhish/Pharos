---
layout: default
title: Schema Browser
nav_order: 4
---

# Schema Browser
{: .no_toc }

<details open markdown="block">
  <summary>Table of contents</summary>
  {: .text-delta }
- TOC
{:toc}
</details>

---

## Overview

The schema browser is the **Database Navigation** navigator of the sidebar (the third icon of the navigator selector in the window toolbar, alongside Query Library and Results History; **View > Navigators > Database Navigation**, **Cmd+Opt+3**). It displays the connected database's structure as an expandable tree, letting you browse schemas, tables, views, partitions, and columns without writing SQL.

## Tree Hierarchy

Tables and views sit directly under their schema as siblings — there are no intermediate "Tables"/"Views" folders:

- **Schema** (e.g., `public`, `auth`)
  - **Tables** — base tables, foreign tables, and partitioned tables
    - **Partitions** folder — for partitioned tables, when enabled (see below)
    - **Columns**
  - **Views** — regular views and materialized views (shown identically)
    - **Columns**

Columns, partitions, and other deep levels load lazily on first expand. The `public` schema auto-expands on connect when it has 500 or fewer objects; larger schemas expand manually. Double-click a row to toggle expansion.

## Icons and Row Details

Every node has a type-specific icon: schemas, tables, partitioned tables, views, and partitions each get their own symbol, and **columns get icons based on their data type** — a key for primary keys, a calendar for dates and timestamps, a clock for times and intervals, braces for JSON and arrays, a network symbol for inet/cidr, and so on.

The tree is a **source list**: one line per row, at the row height you set in System Settings > Appearance > Sidebar icon size. Each row carries a short caption on the right of the same line:

- **Tables and views** — an estimated row count (e.g., "1.2K rows"), populated in the background after connecting
- **Partitioned tables** — the partition key and partition count (e.g., "by (created_at) · 12 partitions"), plus a colored RANGE/LIST/HASH badge
- **Columns** — the data type, plus "PK" and "NOT NULL" markers where applicable
- **Partitions** — the partition bound (e.g., "FOR VALUES FROM … TO …", or "DEFAULT")

When a name is too long for the row, the **name** truncates and the caption keeps its place — the caption is the only place a column's type is written on the tree.

**Hover a table** for its exact row count and its size on disk ("1,234,567 rows · 88 MB"); the [Inspector](inspector.md) shows the same figures, and lists the table's columns.

During a CSV import, the target table's row shows a live "Importing: N" progress counter.

## Nothing Connected

With no connection on the current tab, the panel shows **No Connection** — "Connect a tab to browse its schema." Connect the tab (see [Connections](connections.md)) and the tree loads in its place.

## Partitioned Tables

Partitioned tables are marked with a split-square icon and a RANGE/LIST/HASH badge. When **Show leaf partitions** is enabled in [Settings](settings.md), expanding a partitioned table reveals a **Partitions** folder listing each partition; sub-partitioned tables nest recursively, and each partition can be expanded to its own columns. Partitions get a read-only context menu (view contents, export, indexes, constraints) — destructive operations are intentionally reserved for the parent table.

## Schema Selector

The schema selector lives in the **editor toolbar** (next to the Save dropdown). Click it to open a popover with:

- A **Filter schemas…** search field
- A scrollable list of schemas, with **All Schemas** pinned at the top; the active schema is checkmarked and the connection's default schema is marked "★ default"
- A **Set as Default Schema** button that saves the current selection to the connection

Selecting a schema focuses the navigator on just that schema's tables and views; **All Schemas** restores the full tree. When you switch to a connection, its saved default schema (or `public`) is selected automatically.

## Filtering

Use the **Filter** field along the bottom of the sidebar (**Cmd+Opt+J**) to filter the schema tree. Its text is remembered per navigator, so a filter typed here is not carried into the Query Library or Results History. Matching is a case-insensitive substring match against schema, table, view, and column names, and matching branches auto-expand to reveal hits. Partition names are also indexed — a partitioned table whose partitions match shows "N matching" without needing to be expanded.

## Context Menu Actions

Right-click any node in the schema tree for context-specific actions.

### Table Context Menu

| Action | Description |
|--------|-------------|
| View All Contents | Runs `SELECT * FROM "schema"."table"` in the current tab |
| View Contents (Limit…) | Submenu with preset limits: 10, 100, 1,000, 10,000 |
| Copy Table Name | Copies the bare table name to the clipboard |
| Paste Name to Query Editor | Inserts the quoted, schema-qualified name into the active editor |
| View Table DDL… | Opens the [DDL sheet](table-operations.md#view-table-ddl), which also contains Clone Table |
| Import Data… | Opens the CSV import sheet |
| Export Data… | Opens the export sheet |
| Truncate Table | Removes all rows (with confirmation, if enabled in Settings) |
| Drop Table | Drops the table (with confirmation, if enabled in Settings) |
| View Indexes | Shows the table's indexes in a detail sheet |
| View Constraints | Shows the table's constraints in a detail sheet |

### View Context Menu

Views (including materialized views) get: **View All Contents**, **View Contents (Limit…)**, **Copy Table Name**, **Paste Name to Query Editor**, **Export Data…**, **Drop View**, and **View Constraints**.

### Partition Context Menu

Partitions get a read-only subset: **View All Contents**, **View Contents (Limit…)**, **Copy Table Name**, **Paste Name to Query Editor**, **Export Data…**, **View Indexes**, and **View Constraints**.

### Schema Context Menu

| Action | Description |
|--------|-------------|
| View Functions | Shows the schema's functions in a detail sheet |
| Copy Name | Copies the schema name to the clipboard |

### Column Context Menu

| Action | Description |
|--------|-------------|
| Copy Name | Copies the column name to the clipboard |

## Refreshing

The tree refreshes automatically when you connect, and after operations that change structure (clone, import, truncate, drop). To refresh manually — for example after running your own DDL — choose **File > Refresh Metadata** (**Cmd+Shift+R**), or open the **connection pull-down in the window toolbar** and choose **Refresh Metadata**.

The tree is cached per connection, so switching between connections restores instantly. Row-count estimates are gathered in the background (Pharos runs `ANALYZE` on unanalyzed tables where permitted) and fill in as they arrive.
