---
layout: default
title: Data Export
nav_order: 10
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

Pharos provides two ways to get data out of the results grid: copying to the clipboard and exporting to a file. Both operations work on the current selection if rows are selected, or on all displayed rows if no selection is active.

## Copy to Clipboard

Click the **Copy** button in the results toolbar or right-click in the results grid to access copy formats. Available formats:

| Format | Description |
|--------|-------------|
| TSV | Tab-separated values (default for Cmd+C) |
| CSV | Comma-separated values with proper escaping |
| Markdown | Markdown table with header and alignment row |
| SQL INSERT | INSERT statements with type-aware value formatting |

Each format includes column headers. SQL INSERT statements use `table_name` as a placeholder and properly handle NULL values, numeric values (unquoted), boolean values (unquoted), and string values (single-quoted with escaping).

## Export to File

Click the **Export** button in the results toolbar to choose an export format. A save dialog (NSSavePanel) appears to choose the destination file.

### Results Export Formats

| Format | Extension | Description |
|--------|-----------|-------------|
| CSV | .csv | Comma-separated with proper quoting |
| TSV | .tsv | Tab-separated values |
| JSON | .json | Pretty-printed JSON array of objects |
| SQL INSERT | .sql | INSERT statements, one per row |
| Markdown | .md | Markdown table |

## Table Export

You can also export an entire table directly from the schema browser. Right-click a table or view in the [Schema Browser](schema-browser.md) and choose **Export Data** to open the export sheet.

The table export sheet provides additional options:

- **Format** -- CSV, TSV, JSON, JSON Lines, SQL INSERT, Markdown, or Excel (XLSX)
- **Include headers** -- Toggle column headers in the output
- **NULL values** -- Choose between empty string or "NULL" for null values
- **Column selection** -- Check or uncheck individual columns to include or exclude them, with All/None buttons for convenience

{: .tip }
Table export includes XLSX (Excel) format, which is not available when exporting from the results grid. Use table export from the schema browser context menu when you need Excel output.

## Context Menu

Right-click in the results grid to access a context menu with the same copy format options (TSV, CSV, Markdown, SQL INSERT). The menu labels adapt based on whether rows are selected -- showing "Copy selection as..." when rows are selected, or "Copy as..." when no selection is active.
