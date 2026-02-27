---
layout: default
title: Table Operations
nav_order: 13
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

Pharos provides several table-level operations accessible from the schema browser context menu. These operations let you clone tables, import data, export data, and inspect table metadata without writing SQL.

## Clone Table

Right-click a table in the [Schema Browser](schema-browser.md) and choose **Clone Table DDL** to open the clone sheet.

The clone operation creates a new table with the same structure (DDL) as the source table. Options include:

- **Target name** -- The name for the new table (created in the same schema)
- **Include data** -- Optionally copy all rows from the source table into the clone

After cloning, a confirmation dialog shows the result. If data was included, it reports the number of rows copied. The schema browser refreshes automatically to show the new table.

## Import CSV

Right-click a table and choose **Import Data** to open the import sheet.

The import operation reads a CSV file and inserts its rows into the selected table. Options include:

- **File path** -- The CSV file to import
- **Has headers** -- Whether the first row of the CSV contains column headers

After import, a confirmation dialog reports the number of rows imported.

{: .warning }
The CSV columns must match the table's column structure. Mismatched columns will cause the import to fail.

## Export Table Data

Right-click a table or view and choose **Export Data** to open the export sheet. See [Data Export](data-export.md) for full details on the export sheet options.

The table export supports the following formats: CSV, TSV, JSON, JSON Lines, SQL INSERT, Markdown, and Excel (XLSX). You can select which columns to include and configure header and NULL value options.

## View Indexes

Right-click a table and choose **View Indexes** to display the table's indexes in a detail sheet. This shows index names, types, and the columns they cover.

## View Constraints

Right-click a table or view and choose **View Constraints** to display constraints in a detail sheet. This includes primary keys, foreign keys, unique constraints, and check constraints.

## View Functions

Right-click a schema node and choose **View Functions** to display all functions defined in that schema.

## Destructive Operations

Two destructive operations are available from the table context menu:

- **Truncate Table** -- Removes all rows from the table while preserving the table structure
- **Drop Table** (or **Drop View**) -- Permanently deletes the table/view and all its data

{: .warning }
Both truncate and drop operations are irreversible. If the **Confirm before DROP / DELETE / TRUNCATE** setting is enabled (the default), Pharos displays a confirmation dialog before proceeding.
