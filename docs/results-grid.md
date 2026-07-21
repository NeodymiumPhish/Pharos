---
layout: default
title: Results Grid
nav_order: 8
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

The results grid displays query output in a native table below the SQL editor. It supports type-aware sorting, cell and row selection, inline find with highlighting, [column filters](column-filters.md), and copy/export in multiple formats. Every result lives in its own **result tab**, and any result can be flipped to a [chart](charts.md).

## Result Tabs

Each executed statement gets its own tab in the result tab bar (below the action bar). Tabs are labeled with the statement's line range and the table it touches (e.g., "L1-3: users"), or a preview of the SQL, and each tab's colored dot matches the statement's bar in the editor gutter.

- **Select** a tab to show its result; its source lines are highlighted in the editor, and the tab's grid state (sort, filters, column widths, scroll position, selection) is restored exactly.
- **Close** a tab with its ✕ button or right-click > **Close**.
- Right-click > **View SQL Query** shows the exact SQL that produced the result.
- If you edit the SQL a result came from, the tab dims to indicate it is **stale** — the result no longer matches the current editor text.

## Column Headers

Each column header has two rows: the **column name** on top and its **PostgreSQL data type** below (e.g., `INTEGER`, `TIMESTAMP WITH TIME ZONE`). Columns start at a content-aware width — sized to fit the name, type, and sampled cell content, up to 1000px — and can be resized or reordered by dragging. Double-click a column's right divider to auto-fit it.

The type row also hosts two overlay affordances on its right edge:

- a **▲/▼ sort triangle** while a sort is active
- a **funnel icon** — appears on hover, stays visible (filled, accent-colored) when the column has an active [filter](column-filters.md); click it to open the filter popover

## Column Sorting

Click a column header to sort. The sort cycles through **ascending → descending → original order**. Sorting is type-aware: numeric columns sort by value, booleans sort false before true, everything else uses localized string comparison, and **NULLs always sort to the end**. A **Reset Sort** button appears in the action bar while a sort is active.

## Selection

The grid supports both row and cell selection:

- **Rows** — click a row's number in the **#** column. **Shift-click** extends a range, **⌘-click** toggles individual rows in and out of the selection, and dragging on the # column selects a range.
- **Cells** — click any data cell, or click-drag to select a rectangular cell range. Arrow keys move the active cell, **Shift+arrows** extend the range, and **Tab**/**Return** step between cells.

Press **Esc** or click the **Clear Selection** button to clear. The selection drives the [Inspector](inspector.md) (row detail or aggregate statistics) and copy/export operations — copy uses the selected cells if any, otherwise the selected rows, otherwise all displayed rows.

## Find in Results

Press **Cmd+F** (or **Edit > Find…**) to open the find controls in the action bar. Type to highlight all matching cells, with a "N of M" match counter. Navigate matches with the Previous/Next buttons or **Enter**/**Shift+Enter** — the grid scrolls to each match. Press **Escape** to close.

## Filter Results

Press **Cmd+Shift+F** (or **Edit > Filter Results…**) to open the same controls in **filter mode** (funnel toggle active): only rows containing the search text are shown. Toggle the funnel to switch between highlight-only and filter modes. For per-column, type-aware filtering, see [Column Filters](column-filters.md).

## Value Rendering

Cell values are colored by type: numeric blue, temporal purple, JSON orange, booleans green (true) / red (false), formatted per the Bool Display setting. NULLs render per the NULL Display setting in italic gray. Newlines inside cells are flattened to `↵` for single-line display.

## Load More

When a query has more rows than the current page (see [Row Limit](query-execution.md#row-limit-and-load-more)), a **Load More Rows** bar appears at the bottom of the grid. Loading appends the next page and re-applies the active sort and filters.

## Pin Results

Click the **pin** button in the action bar to keep the current result visible while you switch editor tabs. The button turns orange and shows the pinned result's name; selecting any result tab unpins.

## Status Text

The action bar's status text summarizes the current result: row count and execution time (e.g., "1,000 rows in 0.42s"), plus visible-of-total counts and active filter counts when filters hide rows, match counts during a find, and "(more available)" when more rows can be loaded. Statements show "N rows affected".

## Copy and Export

See [Data Export](data-export.md) for copying results to the clipboard and exporting to files.
