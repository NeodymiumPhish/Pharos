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

Each executed statement gets its own result tab, labeled with the statement's line range and the table it touches (e.g., "L1-3: users"), or a preview of the SQL. Each tab's colored dot matches the statement's bar in the editor gutter.

- **Select** a tab to show its result; its source lines are highlighted in the editor, and the tab's grid state (sort, filters, column widths, scroll position, selection) is restored exactly.
- **Close** a tab with its ✕ button or right-click > **Close**.
- Right-click > **View SQL Query** shows the exact SQL that produced the result.
- Right-click > **Rename…** gives the result a name of your own — useful once several tabs read "L4-9: orders" and the line range no longer tells them apart. The name is saved with the result, so [reopening the workspace](query-history.md) brings it back, and the same name appears for that result in the Results History preview list. Leave the field empty to restore the name taken from the query, which then follows the statement again as you edit the SQL.
- If you edit the SQL a result came from, the tab dims to indicate it is **stale** — the result no longer matches the current editor text. Selecting a stale tab still shows its result, but no longer highlights lines in the editor, because the statement has moved.

### Where the tabs appear

Two layouts are available, chosen by **Show result tabs in a vertical panel, not a horizontal bar** in [Settings > General](settings.md#general-tab). Only one is ever shown.

**Vertical panel (default).** Result tabs list down a panel at the right edge of each editor pane, to the right of the [Query Variables](query-variables.md) panel. Each row shows the colored dot, the label, and the result's size as columns×rows. This is the layout to prefer when you run many statements in one tab: a long list scrolls in place instead of pushing tabs off the edge of the window.

- Toggle the panel per editor tab with the **Result Tabs** button at the right of the pane's toolbar, next to the Query Variables toggle. Your last choice becomes the default for new tabs.
- Drag the panel's left edge to resize it. The width is shared by every pane and survives a relaunch. The panel keeps the width you chose while the editor has room to give, down to about 200pt of editor. Below that the panel gives way — the result tabs panel first, then the Query Variables panel, and neither below its own minimum width. Your chosen widths are never overwritten, so they come back when the window widens.
- With the editor [split into panes](query-editor.md#tab-and-pane-management), each pane lists the result tabs of its own active tab, and highlights the one that tab holds. Clicking a row in an unfocused pane focuses that pane first, then shows the result.
- Collapsing the panel hides the result tabs. The grid keeps showing the current result, and a new query still shows its own result.

**Horizontal bar.** Result tabs run along a bar between the action bar and the results grid. With many results the bar scrolls sideways.

## Column Headers

Each column header has two rows: the **column name** on top and its **PostgreSQL data type** below (e.g., `INTEGER`, `TIMESTAMP WITH TIME ZONE`). Columns start at a content-aware width — sized to fit the name, type, and sampled cell content, up to 1000px — and can be resized or reordered by dragging. Double-click a column's right divider to auto-fit it.

The resize cursor appears a few points either side of a divider, and that whole band grabs it. When a column runs off the **right edge of the grid**, its divider is out of reach behind the scroll bar — so the grid's right edge becomes that column's handle: drag it and the column's edge follows your pointer, which pulls the column back into view. Double-click there to auto-fit the same column.

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

Click the **pin** button in the action bar to keep the current result visible while you switch editor tabs. The button turns orange and shows the pinned result's name.

The pin releases as soon as you ask the grid to show something else: selecting any result tab, or running a query in any tab. A query that finishes in a **background** tab does not release it — that result is deposited into its own tab without touching the grid, so the pinned rows stay on screen.

## Status Text

The action bar's status text summarizes the current result: row count and execution time (e.g., "1,000 rows in 0.42s"), plus visible-of-total counts and active filter counts when filters hide rows, match counts during a find, and "(more available)" when more rows can be loaded. Statements show "N rows affected".

## Copy and Export

See [Data Export](data-export.md) for copying results to the clipboard and exporting to files.
