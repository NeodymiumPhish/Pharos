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

The Schema Browser (Database Navigator) is the left-side panel that displays the full structure of your connected database.

## Schema Dropdown

At the top of the navigator, a dropdown lets you filter by schema:

- **All Schemas** — Show every schema in the tree
- **Specific schema** — Show only tables, views, and functions from that schema

When a single schema is selected, the tree flattens to show tables directly without the schema wrapper node. The selected schema also sets the `search_path` for query execution.

## Search

The search bar below the dropdown filters the tree in real time. Matching is performed against table, view, and column names. Schemas containing matches auto-expand.

## Tree Structure

The tree is organized hierarchically:

```
Schema
├── Tables
│   └── table_name
│       ├── column_name (data_type)
│       ├── Indexes (count)
│       │   └── index_name (columns)
│       └── Constraints (count)
│           └── constraint_name
├── Views
│   └── view_name
├── Foreign Tables
│   └── foreign_table_name
└── Functions
    └── function_name(arg_types)
```

### Tables

Each table node displays:
- **Row count estimate** — Shown as a badge (e.g., "~1.2K rows"). Estimates come from `pg_class.reltuples` and are refreshed via background `ANALYZE` when stale.
- **Table size** — Total size including indexes, shown on hover.

Expand a table to see its columns, indexes, and constraints.

### Columns

Each column shows:
- Column name
- Data type (e.g., `int4`, `varchar`, `timestamptz`)
- Primary key indicator (key icon)

### Indexes

Expand the Indexes folder to see each index with:
- Index name and included columns
- Index type (btree, hash, gin, gist, etc.)
- Unique indicator
- Size

### Constraints

Expand the Constraints folder to see:
- Primary keys
- Foreign keys (with referenced table shown as `constraint_name -> referenced_table`)
- Unique constraints
- Check constraints

### Views and Foreign Tables

Views and foreign tables appear alongside regular tables with distinct icons. They support the same context menu options for viewing rows and exporting data.

### Functions

The Functions folder is lazy-loaded. Expand it to see all functions and procedures in the schema, each displaying:
- Function name with argument types
- Return type
- Language (plpgsql, sql, etc.)

## Context Menu

Right-click any table, view, or foreign table to access:

| Action | Description |
|:-------|:------------|
| View 1000 Rows | Opens a new query tab with `SELECT * ... LIMIT 1000` |
| View All Rows | Opens a new query tab with `SELECT *` (no limit) |
| Clone Table | Opens the Clone Table dialog (tables only) |
| Import Data | Opens the CSV Import dialog (tables only) |
| Export Data | Opens the Export dialog |
| Copy CREATE TABLE | Generates and copies the full `CREATE TABLE` DDL to clipboard |
| Copy SELECT * | Copies a `SELECT * FROM "schema"."table" LIMIT 1000;` statement |

Right-click an **index** to access:

| Action | Description |
|:-------|:------------|
| Copy CREATE INDEX | Generates and copies the `CREATE INDEX` DDL to clipboard |

Right-click a **column** to access:

| Action | Description |
|:-------|:------------|
| Copy Column Name | Copies the column name |
| Copy Qualified Name | Copies `schema.table.column` |

## Lazy Loading

Table columns, indexes, and constraints are loaded on demand when you expand a table node. Functions are loaded when you expand the Functions folder. This keeps initial load times fast even for databases with hundreds of tables.

## Background ANALYZE

When the schema tree loads, Pharos runs `ANALYZE` in the background for any schemas with stale statistics. This updates row count estimates without blocking the UI. Tables where `ANALYZE` is denied (e.g., due to permissions on foreign tables) are tracked per-session and skipped on subsequent refreshes.

## Refresh

The schema tree automatically refreshes when you connect to a database. To manually refresh after schema changes, use the refresh mechanism tied to table operations (clone, import, etc.).
