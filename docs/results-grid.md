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

## Overview

The results grid displays query output in a native table view below the SQL editor. It supports column sorting, row selection, inline search with highlighting, and result filtering.

## Column Sorting

Click a column header to sort the results by that column. The sort cycles through three states:

1. **Ascending** -- indicated by an upward chevron
2. **Descending** -- indicated by a downward chevron
3. **Original order** -- removes the sort and restores the query's original row order

Sorting is type-aware:

- **Numeric** columns sort by numeric value
- **Boolean** columns sort false before true
- **All other** columns sort by localized string comparison
- **NULL** values always sort to the end regardless of direction

A **Reset Sort** button appears when any sort is active, allowing you to clear the sort in one click.

## Row Selection

Click a row to select it. Hold **Cmd** and click to add individual rows to the selection, or hold **Shift** and click to select a range. Selected rows are used for copy and export operations -- if no rows are selected, copy and export operate on all displayed rows.

## Find in Results

Press **Cmd+F** or choose **Edit > Find** to open the find bar above the results grid. Type a search term to highlight all matching cells across the results.

The find bar provides:

- **Match counter** showing "N of M" matches
- **Previous/Next** navigation buttons to jump between matches (or press Enter/Shift+Enter)
- **Scroll to match** -- the grid automatically scrolls to reveal the current match
- **Clear** button to reset the search

Press **Escape** to close the find bar.

## Filter Results

Press **Cmd+Shift+F** or choose **Edit > Filter Results** to open the find bar in filter mode. In filter mode, the funnel icon toggle is active, and only rows containing the search term are displayed -- non-matching rows are hidden.

Toggle the funnel icon to switch between highlight-only and filter modes while the find bar is open.

## Copy and Export

See [Data Export](data-export.md) for details on copying results to the clipboard and exporting to files.

## Pin Results

Results can be pinned to keep them visible while switching between tabs. When results are pinned, switching to another tab does not replace the displayed results. Unpin to restore the default behavior where each tab shows its own results.

## Status Bar

The bottom of the results area displays a status bar with information about the current result set, including row count and query execution time.
