---
layout: default
title: Inspector
nav_order: 8
---

# Inspector
{: .no_toc }

<details open markdown="block">
  <summary>Table of contents</summary>
  {: .text-delta }
- TOC
{:toc}
</details>

---

## Overview

The Inspector pane provides a detailed view of selected data in the [results grid](results-grid.md). When a single row is selected, the Inspector shows every column as a labeled key-value pair with type-aware color coding. When multiple rows are selected, it displays per-column aggregate statistics. The Inspector appears as the rightmost pane in the workspace.

## Opening the Inspector

Toggle the Inspector with **Cmd+Opt+0**, via **View > Toggle Inspector** in the menu bar, or by clicking the Inspector button in the toolbar. The Inspector slides in from the right side of the workspace, alongside the results grid.

## Single-Row Detail

When exactly one row is selected in the results grid, the Inspector displays a **Row Detail** view.

### Header

The header shows "Row Detail" with a position counter (e.g., "3 of 150") indicating which row is selected out of the total row count.

### Column Layout

Every column from the result set appears as a key-value pair:

- **Key**: The column name in medium-weight text, with the PostgreSQL data type displayed in smaller text beside it
- **Value**: The cell value displayed in a monospaced font with type-aware color coding

### Value Colors

Values are colored by their PostgreSQL type category to make scanning easier:

| Type Category | Color | Notes |
|---------------|-------|-------|
| Numeric | Blue | Integers, decimals, money, serial types |
| Boolean (true) | Green | Formatted according to the Bool Display setting |
| Boolean (false) | Red | Formatted according to the Bool Display setting |
| Temporal | Purple | Dates, times, timestamps, intervals |
| JSON | Orange | json and jsonb values |
| Array | Secondary label color | Any array type |
| String | Default label color | Text, varchar, char, and other types |
| NULL | Italic, tertiary color | Displays according to the [NULL Display](settings.md) setting |
| Empty string | Tertiary color | Displays "(empty string)" to distinguish from NULL |

### Copying Values

- **Double-click** any value to copy it to the clipboard. A brief checkmark and "Copied" confirmation appears, then the original value is restored.
- **Right-click** any value to open a context menu with a "Copy" option that includes a preview of the value.

## Multi-Row Aggregation

When two or more rows are selected, the Inspector switches to a **Selection Summary** view that displays aggregate statistics.

### Header

The header shows "Selection Summary" with a count of selected rows (e.g., "42 rows").

### Summary Line

Below the header, a summary line displays the total row count and the number of columns in the result set.

### Per-Column Statistics

Each column is listed with its name and data type, followed by statistics that vary by type:

**All columns include:**

- **Count** -- number of non-null values in the selection
- **Distinct** -- number of unique values
- **NULL** -- count of null values (shown only if at least one null exists)

**Numeric columns additionally show:**

- **Min** and **Max** -- smallest and largest values (displayed in blue)
- **Sum** -- total of all values (displayed in blue)
- **Avg** -- arithmetic mean (displayed in blue)

**Temporal columns additionally show:**

- **Earliest** and **Latest** -- first and last values in chronological order (displayed in purple)
- Interval-type columns skip the earliest/latest statistics since chronological ordering does not apply to durations

**Boolean columns additionally show:**

- **True** count (displayed in green)
- **False** count (displayed in red)

**String, JSON, and Array columns** show count and distinct values only.

## No Selection

When no rows are selected in the results grid, the Inspector displays a centered "No Selection" placeholder message.

{: .tip }
> The Inspector updates live as you change the selection in the results grid. Click a single row for full detail, or select multiple rows to see aggregate statistics instantly.
