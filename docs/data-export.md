---
layout: default
title: Data Export
nav_order: 9
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

Pharos supports exporting data in seven formats, from both query results and directly from tables.

## Export Formats

| Format | Extension | Description |
|:-------|:----------|:------------|
| CSV | `.csv` | Comma-separated values |
| TSV | `.tsv` | Tab-separated values |
| JSON | `.json` | Array of objects |
| JSON Lines | `.jsonl` | One JSON object per line |
| SQL INSERT | `.sql` | INSERT statements |
| Markdown | `.md` | Markdown table |
| XLSX | `.xlsx` | Excel spreadsheet |

## Export from Results

After running a query, use the export dropdown in the results toolbar:

1. Click the **Export** dropdown button in the results toolbar
2. Select a format
3. For text formats (CSV, TSV, JSON, JSON Lines, SQL INSERT, Markdown), the file downloads directly through the browser
4. For XLSX, a save dialog appears to choose the file location

The results export includes all currently loaded rows with their column headers.

## Export from Schema Browser

Right-click a table, view, or foreign table in the Schema Browser and select **Export Data**:

1. The Export dialog opens with the table pre-selected
2. Choose an export format
3. Select which columns to include (all selected by default)
4. Configure options:
   - **Include headers** — Add column names as the first row (CSV/TSV)
   - **NULL as empty** — Export NULL values as empty strings instead of "NULL"
5. Choose a save location
6. Click **Export**

The row count is displayed after export completes.

## Export Options

| Option | Applies To | Default |
|:-------|:-----------|:--------|
| Column selection | Table export | All columns |
| Include headers | CSV, TSV | On |
| NULL as empty | All formats | Off |

## Technical Details

- **Text formats** (CSV, TSV, JSON, JSON Lines, SQL INSERT, Markdown) are generated client-side as blob downloads for maximum speed
- **XLSX** files are generated on the backend using `rust_xlsxwriter` for proper Excel formatting and large file support
- File paths for backend exports are restricted to your home directory, `/tmp/`, and `/var/folders/` for security

## CSV Import

Pharos also supports importing CSV data into existing tables. See [Table Operations](table-operations) for details on CSV import.
