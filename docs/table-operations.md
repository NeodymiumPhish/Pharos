---
layout: default
title: Table Operations
nav_order: 15
---

# Table Operations
{: .no_toc }

<details open markdown="block">
  <summary>Table of contents</summary>
  {: .text-delta }
- TOC
{:toc}
</details>

---

## Overview

Pharos provides table-level operations from the [Schema Browser](schema-browser.md) context menu: view and copy DDL, clone tables, import CSV data, export data, inspect indexes and constraints, and run truncate/drop with confirmation.

## View Table DDL

Right-click a table and choose **View Table DDL…** to open the DDL sheet. It shows the generated `CREATE TABLE` statement in a read-only, scrollable monospaced view, with three detail levels selectable in the sidebar:

- **Columns** — column definitions only
- **+ Constraints** — adds primary key, foreign key, unique, and check constraints
- **Full (+ Indexes)** — adds index definitions

A partitioned table's statement ends with its `PARTITION BY` clause, and a table that other tables inherit from ends with `INHERITS (…)`, naming every parent. Inherited columns stay in the column list: naming a column the parent already has is legal, and it is what the table holds.

Click **Copy DDL** to copy the displayed statement to the clipboard.

## Clone Table

Cloning lives inside the DDL sheet: click **Clone Table…** to reveal an inline clone section with:

- **New table name** — defaults to `<table>_copy`; the clone is created in the same schema
- **Include table rows** — optionally copy all rows into the clone (off by default)

After cloning, an alert reports the result ("Table structure cloned." or "Table cloned with N rows.") and the schema browser refreshes to show the new table.

## Import CSV

Right-click a table and choose **Import Data…** to open the import sheet, or **drop a `.csv` or `.tsv` file from the Finder onto the table's row** in the schema browser — the same sheet opens with the file already chosen. A drop is accepted on tables only (not views, partitions or columns), one file at a time, and only while the browser has a connection.

The import sheet:

- **CSV File** — choose the file to import
- **CSV file has headers** — whether the first row contains column headers (on by default)

The import runs in a single transaction and reports the number of rows imported. While it runs, the table's row in the schema browser shows a live "Importing: N" counter.

{: .warning }
Import is positional: the CSV must have exactly as many columns as the table, in table-column order. A mismatch fails the import and rolls back the transaction. Empty CSV fields are inserted as NULL. There is no delimiter option — files must be comma-separated.

## Export Table Data

Right-click a table, view, or partition and choose **Export Data…** to open the export sheet:

- **Format** — CSV, TSV, JSON, JSON Lines, SQL INSERT, Markdown, or Excel (XLSX)
- **Include headers** — toggle column headers in the output
- **NULL values** — render nulls as an empty string or as `NULL`
- **Columns** — check or uncheck individual columns, with **All** / **None** buttons

Click **Export…** to choose a destination file; an alert reports the number of rows exported. See [Data Export](data-export.md) for exporting from the results grid instead.

## View Indexes

Right-click a table (or partition) and choose **View Indexes** to see the table's indexes in a detail sheet: name, covered columns, index type, and whether each is unique or the primary key.

## View Constraints

Right-click a table, view, or partition and choose **View Constraints** to see its constraints: name, type, columns, and referenced table for foreign keys.

## View Functions

Right-click a schema and choose **View Functions** to see all functions defined in that schema, with their arguments, return types, and language.

## Destructive Operations

Two destructive operations are available from the table context menu:

- **Truncate Table** — removes all rows while preserving the table structure
- **Drop Table** / **Drop View** — permanently deletes the object and its data

{: .warning }
Both operations are irreversible. When **Confirm queries that change the database** is enabled in [Settings](settings.md) (the default), Pharos shows a confirmation dialog first; with the setting off, they execute immediately.

{: .warning }
**Truncating a table that others inherit from empties every one of them.** `TRUNCATE` reaches the whole tree unless it is asked for `ONLY`, and Pharos does not ask: truncating the root of an inheritance tree (see [Inherited Tables](schema-browser.md#inherited-tables)) removes every row below it as well. The confirmation says so, whether or not **Group inherited tables** is on. Dropping such a parent is refused by PostgreSQL itself while a child still inherits from it.
