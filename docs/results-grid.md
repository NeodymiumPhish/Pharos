---
layout: default
title: Results Grid
nav_order: 7
---

# Results Grid
{: .no_toc }

<details open markdown="block">
  <summary>Table of contents</summary>
  {: .text-delta }
- TOC
{:toc}
</details>

---

The Results Grid displays query output with virtual scrolling for smooth performance even with large result sets.

## Virtual Scrolling

Results use [TanStack Virtual](https://tanstack.com/virtual) for row virtualization. Only the visible rows are rendered in the DOM, keeping the grid responsive even with tens of thousands of rows.

## Column Features

### Sorting

Click a column header to sort:
1. **First click** — Sort ascending
2. **Second click** — Sort descending
3. **Third click** — Remove sort (return to original order)

Sorting is performed client-side on the loaded data.

### Column Resizing

- **Drag** the edge of a column header to manually resize
- **Double-click** the edge to auto-fit the column to its content width
- Column widths are calculated automatically on initial load based on content

### Column Filtering

Click the filter icon on a column header to open the filter popover. Filter types vary by data:

**Text columns:**
- Contains
- Equals
- Starts with
- Ends with

**Numeric columns:**
- Equals (=)
- Not equals (!=)
- Greater than (>)
- Less than (<)
- Greater than or equal (>=)
- Less than or equal (<=)
- Between (two values)

**Boolean columns:**
- True
- False

**All columns:**
- Is NULL
- Is not NULL

Active filters show as chips below the toolbar. The status bar shows the filtered row count (e.g., "Showing 42 of 1,000 rows"). Click the X on a chip to remove that filter.

## Find in Results

Press `Cmd+F` to open the find bar. Type to search across all visible columns:

- Matches are highlighted in yellow throughout the grid
- Use the up/down arrows or `Enter`/`Shift+Enter` to navigate between matches
- The match count is displayed (e.g., "3 of 15 matches")
- Press `Escape` to close the find bar

## Cell Interaction

### Selection

Click a cell to select it. The selected cell is highlighted with a border.

### Copy

With a cell selected, press `Cmd+C` to copy the cell value to the clipboard.

### Aggregates

When a cell in a numeric column is selected, the status bar shows aggregate calculations:
- **Count** — Number of non-null values in the column
- **Sum** — Total of all values
- **Average** — Mean value
- **Min** / **Max** — Range of values

## Display Options

The results toolbar provides several display toggles:

| Option | Description | Default |
|:-------|:------------|:--------|
| Wrap | Wrap long cell content instead of truncating | Off |
| Lines | Show cell borders / grid lines | Off |
| Row Numbers | Show row index numbers | Off |
| Zebra | Alternate row background colors | On |

Additional display settings configurable in [Settings](settings) > Appearance:

| Setting | Options | Default |
|:--------|:--------|:--------|
| NULL Display | `NULL`, `null`, `(null)`, empty, `∅` | `NULL` |
| Results Font Size | Any size | 11 |
| Zebra Striping | On/Off | On |

## Pin Results

Click the pin icon in the results toolbar to **pin** the current tab's results. When results are pinned:
- Switching to another tab keeps the pinned results visible
- This is useful for comparing query outputs side by side
- Click the pin icon again to unpin

## Expand / Collapse

Use the expand button in the results toolbar to make the results grid fill the entire workspace, hiding the editor. Click again to restore the split view.

## Status Bar

The bottom of the results grid shows:
- Row count (e.g., "1,000 rows")
- Execution time (e.g., "42ms")
- Filter status when filters are active
- "Has more rows" indicator with Load More button
- Aggregate values when a numeric cell is selected
