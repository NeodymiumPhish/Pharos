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

The schema browser lives in the Navigator section at the bottom of the sidebar. It displays the connected database's structure as an expandable tree, letting you browse schemas, tables, views, and columns without writing SQL.

## Tree Hierarchy

The schema tree organizes objects in the following hierarchy:

- **Schemas** (e.g., `public`, `auth`)
  - **Tables** -- with column details
  - **Views** -- including materialized views
  - **Foreign Tables** -- tables from foreign data wrappers
    - **Columns** -- with data type information

Click the disclosure triangle next to any node to expand or collapse it. Column nodes display both the column name and its PostgreSQL data type.

## Filtering

Use the search field at the top of the sidebar to filter the schema tree. Type any text to narrow the tree to matching schemas, tables, views, and columns. Clear the search field to restore the full tree.

## Context Menu Actions

Right-click any node in the schema tree to access context-specific actions.

### Table Context Menu

| Action | Description |
|--------|-------------|
| View All Contents | Opens a new tab with `SELECT * FROM table` and runs it |
| View Contents (Limit...) | Opens a submenu with preset limits: 10, 100, 1,000, 10,000 |
| Copy Table Name | Copies the table name to the clipboard |
| Paste Name to Query Editor | Inserts the schema-qualified name into the active editor tab |
| Clone Table DDL | Opens a sheet to clone the table structure (optionally with data) |
| Import Data | Opens a sheet to import CSV data into the table |
| Export Data | Opens the export sheet to save table data to a file |
| Truncate Table | Removes all rows (with confirmation if enabled in settings) |
| Drop Table | Drops the table entirely (with confirmation if enabled in settings) |
| View Indexes | Displays the table's indexes in a detail sheet |
| View Constraints | Displays the table's constraints in a detail sheet |

### View Context Menu

| Action | Description |
|--------|-------------|
| View All Contents | Opens a new tab with `SELECT * FROM view` and runs it |
| View Contents (Limit...) | Opens a submenu with preset limits |
| Copy Table Name | Copies the view name to the clipboard |
| Paste Name to Query Editor | Inserts the schema-qualified name into the active editor tab |
| Export Data | Opens the export sheet for the view's data |
| Drop View | Drops the view (with confirmation if enabled in settings) |
| View Constraints | Displays the view's constraints in a detail sheet |

### Schema Context Menu

| Action | Description |
|--------|-------------|
| View Functions | Displays the schema's functions in a detail sheet |
| Copy Name | Copies the schema name to the clipboard |

### Column Context Menu

| Action | Description |
|--------|-------------|
| Copy Name | Copies the column name to the clipboard |

## Refreshing

The schema tree refreshes automatically when you connect to a database or switch connections. Schema changes made by your queries (such as creating or dropping tables) are reflected after the tree reloads.
