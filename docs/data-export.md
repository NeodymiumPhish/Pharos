---
layout: default
title: Data Export
nav_order: 12
---

# Data Export
{: .no_toc }

<details open markdown="block">
  <summary>Table of contents</summary>
  {: .text-delta }
- TOC
{:toc}
</details>

---

## Overview

Pharos offers three ways to get data out: copying results to the clipboard, exporting results to a file, and exporting an entire table from the schema browser. Copy and export operate on the current selection (cell range or rows) if one exists, otherwise on all displayed rows.

## Copy to Clipboard

**Cmd+C** copies the selection as TSV. The **Copy** button in the action bar and the grid's right-click menu offer all formats, with an **Include Headers** toggle (remembered between uses):

| Format | Description |
|--------|-------------|
| TSV | Tab-separated values (the Cmd+C default) |
| CSV | Comma-separated values with proper escaping |
| Markdown | Markdown table with header and separator row |
| SQL INSERT | INSERT statements with type-aware value formatting |
| SQL WITH | CTE with a VALUES clause and type casting on the first row |

Menu labels adapt to the selection — "Copy selection as…" when cells or rows are selected, "Copy as…" otherwise. SQL INSERT output uses `table_name` as a placeholder and handles NULLs, numerics, and booleans unquoted, with strings single-quoted and escaped.

## Export Results to File

The **Export** button in the action bar offers **CSV**, **TSV**, **JSON** (pretty-printed array of objects), **SQL INSERT**, and **Markdown** — each opens a save dialog.

When the result is showing as a [chart](charts.md), the same button switches to chart exports: **Export Chart as PNG…**, **Export Chart as PDF…**, and **Copy Chart as Image**.

## Export a Table

Right-click a table, view, or partition in the [Schema Browser](schema-browser.md) and choose **Export Data…**. The table export sheet offers:

- **Format** — CSV, TSV, JSON, JSON Lines, SQL INSERT, Markdown, or Excel (XLSX)
- **Include headers** — toggle column headers
- **NULL values** — write nulls as an empty string or as `NULL`
- **Columns** — check or uncheck individual columns, with All/None buttons

{: .tip }
JSON Lines and Excel (XLSX) are only available in the table export sheet — use it from the schema browser when you need those formats.
