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

Pharos provides several operations accessible from the Schema Browser context menu.

## Clone Table

Clone an existing table to create a copy with the same structure.

1. Right-click a table in the Schema Browser
2. Select **Clone Table**
3. Configure the clone:
   - **Target schema** — Destination schema (defaults to source schema)
   - **Target table name** — Name for the new table
   - **Include data** — Copy all rows from the source table, or create an empty clone with structure only
4. Click **Clone**

The clone creates a new table using `CREATE TABLE ... (LIKE source_table INCLUDING ALL)`, which copies columns, constraints, indexes, and defaults. When "Include data" is enabled, rows are copied with `INSERT INTO ... SELECT * FROM`.

After cloning, the Schema Browser refreshes automatically to show the new table.

## Import CSV

Import data from a CSV file into an existing table.

1. Right-click a table in the Schema Browser
2. Select **Import Data**
3. In the Import dialog:
   - Click **Choose File** to select a CSV file
   - Toggle **Has Headers** if the first row contains column names
   - Pharos validates the file before importing:
     - Checks that the number of CSV columns matches the table
     - Displays the row count and column count
     - Shows column name matches when headers are present
4. Click **Import**

The import shows a progress summary with the number of rows imported.

{: .tip }
Ensure your CSV column order matches the table's column order. When headers are present, Pharos validates that column names align.

## View Rows

Quickly browse table data without writing SQL:

1. Right-click a table, view, or foreign table in the Schema Browser
2. Choose one of:
   - **View 1000 Rows** — Opens a new tab with `SELECT * FROM "schema"."table" LIMIT 1000`
   - **View All Rows** — Opens a new tab with `SELECT * FROM "schema"."table"` (no limit)

The query is automatically executed and results appear in the results grid.

## Copy DDL

Generate and copy SQL definitions to the clipboard:

### Copy CREATE TABLE

Right-click a table, view, or foreign table and select **Copy CREATE TABLE**. Pharos generates the full DDL including:
- Column definitions with data types and defaults
- Primary key and unique constraints
- Foreign key references
- Check constraints
- Indexes

The DDL is copied to the clipboard, ready to paste into another tool or query tab.

### Copy CREATE INDEX

Right-click an index (expand a table, then the Indexes folder) and select **Copy CREATE INDEX**. The full index definition is copied to the clipboard.

### Copy SELECT *

Right-click a table and select **Copy SELECT \*** to copy a ready-to-use query:

```sql
SELECT * FROM "schema"."table" LIMIT 1000;
```
