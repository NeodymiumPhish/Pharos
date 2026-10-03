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

The results grid displays query output in a native table below the SQL editor. It supports type-aware sorting, cell and row selection, inline find with highlighting, [column filters](column-filters.md), and copy/export in multiple formats. Every result belongs to the [query card](query-editor.md#query-cards) that produced it, and any result can be flipped to a [chart](charts.md).

## Card Results

The results area shows **one card's results at a time**. A header above them shows:

- the card's color swatch;
- the card's name and version;
- the metadata of the run: when it ran, how long it took, and how many rows it returned;
- **Go to Card**, which scrolls the cards to the one these results belong to.

The view control at the front of the result action bar is **Grid | Chart | Plan**. **Plan** shows the card's query plan after **Explain** (Cmd+Shift+E) or **Explain Analyze** (Cmd+Opt+Shift+E); see [Explain](query-execution.md#explain).

### Choosing whose results are on screen

- Click a card's **View Results** button to show its results. The button then reads **Showing Results · N rows** and is filled. So you can look at one card's results while you type in another.
- **Cmd+Opt+]** / **Cmd+Opt+[** (**View > Show Results of Next Card** / **Show Results of Previous Card**) show the results of the next or previous card that has results.
- When a run ends, its results take over the results area. Turn off **Show new results automatically** in [Settings > Results](settings.md#results-pane) to keep the results you are looking at.

Showing a card's results again restores its grid state (sort, filters, column widths, scroll position, selection) exactly.

### The result limit

**Results kept per tab** in [Settings > Results](settings.md#results-pane) sets how many cards of one editor tab hold their results in memory. Over the limit, Pharos removes the **oldest results you have not looked at**, and says so. The card stays and says **Results removed**: run it again to get them back.

## Column Headers

Each column header has two rows: the **column name** on top and its **PostgreSQL data type** below (e.g., `INTEGER`, `TIMESTAMP WITH TIME ZONE`). Columns start at a content-aware width — sized to fit the name, type, and sampled cell content, up to 1000px — and can be resized or reordered by dragging. Double-click a column's right divider to auto-fit it.

The resize cursor appears a few points either side of a divider, and that whole band grabs it. Dragging a divider wider than the pane scrolls the grid underneath, so the edge you are dragging stays in view at the pane's edge instead of disappearing behind the scroll bar. When the columns are wider than the pane, the grid also scrolls a little past the last one, so the end of the table always comes to rest clear of the scroll bar where its divider can be grabbed.

When a column runs off the **right edge of the grid**, its divider is out of reach — so the grid's right edge becomes that column's handle: drag it and the column's edge follows your pointer, which pulls the column back into view. Double-click there to auto-fit the same column.

**Right-click a header** for the column menu: **Hide Column**, one checkmark item per column to show or hide it, and **Show All Columns**. Hidden columns keep their width and position and come back where they were. The row-number column and the last visible column cannot be hidden, and hidden columns stay out of copy, export, share and drag — what leaves the grid is the table you see.

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

### Quick Look

Press **Space** with a selection (or choose **Quick Look** from the right-click menu) to preview the selected cells in the system Quick Look panel. JSON values are shown pretty-printed with sorted keys, `bytea` values that hold a PNG, JPEG, GIF, WebP or PDF are shown as that image or document, and everything else is shown as text. With several cells selected, the panel's arrow keys step between them, and moving the grid selection while the panel is open updates it. Press Space again to close.

### Drag Out

Drag a selected cell block or selected rows out of the grid. Dropped on a text field or editor, the selection lands as tab-separated text (with an HTML table for rich-text targets); dropped on the Finder, it lands as a **CSV file** named after the result's table. Start the drag on a cell that is already selected — a drag from an unselected cell selects instead.

## Editing Cells

Change a value in the grid, collect the changes, read the exact `UPDATE` statements, then apply them all in one transaction.

**What can be edited.** A cell is editable only when every one of these holds, and Pharos can answer all of them from the result it already has:

- the result comes from **exactly one table** — a join is read-only;
- that table has a **primary key**, or a NOT NULL **unique index**, and every one of its columns is in the result;
- **this row's** key value is not NULL (an outer join's unmatched row names nothing);
- the column is a real column **of that table** — an aggregate, an expression, a literal or a column of another table has nothing to write to;
- the column's type is one of **text, numeric, boolean, date, timestamp or uuid**. Arrays, JSON, `bytea`, ranges, intervals and composite types are read-only in v1, because a wrong text cast on one of them would change data silently.

Everything else is read-only, and silently so: a double-click on a read-only cell just selects it, as a single click does.

**The gesture.** **Double-click** a cell, or press **⌘Return** on it, and the cell becomes an editable field. **Return** commits and moves down a row, **Tab** commits and moves right, **Shift+Tab** moves left, and **Esc** abandons the edit. Clicking away commits, as inline fields do everywhere in macOS. Plain **Return** on a cell that is not being edited still moves down a row, exactly as before.

An empty field means the **empty string**. For a **NULL**, right-click the cell and choose **Set NULL**. **Revert Edit**, in the same menu, drops one cell's pending change.

**Pending marks.** A cell holding an uncommitted change shows the value that *will* be written, with a 2pt accent rule down its leading edge; with **Differentiate Without Color** on, the text is italic as well. A screen reader reads the cell as `edited, was <old value>`. A pending NULL draws as the italic `NULL` the grid already uses.

Nothing is written to the database at this point. Pending changes stay with their card's results, survive sorting, filtering and **Load More**, and are kept when you show another card's results and come back.

**Review Changes.** While anything is pending, a bar above the action bar reads `3 changes in public.users` with two buttons:

- **Review Changes…** opens a sheet with the exact statements — one `UPDATE` per row, the key it is matched on in the `WHERE` clause, and the value as loaded guarding each edited column. A footnote names the key: `Rows are matched on the primary key (id).`, or `…on the unique index (email).` when a unique index stood in for a missing primary key. The sheet is always shown, whatever the "Confirm destructive queries" setting says — it is not a confirmation, it is the only place this SQL is visible, because you did not write it.
- **Discard** asks once, then puts every cell back to the value the query returned.

**Apply.** **Apply** in the sheet sends the changes to the core, which runs them in **one transaction** with every value bound as a parameter and every identifier quoted — the statements on screen are rendered inline for reading and are never executed.

**The rollback rule.** Each row's `UPDATE` must match **exactly one** row. Nought means the row is gone or its key changed; more than one means the key is not unique after all. Either way the **whole transaction is rolled back** and nothing is written, and the message names the row of the request that failed. The `WHERE` clause also carries the value as it was loaded (`AND "email" IS NOT DISTINCT FROM 'old'`), so if someone else changed that column since the query ran, the row matches nothing and the same rollback happens — your changes are kept and you can look again.

After a successful apply the rows are re-read from the server, so what is on screen is what the table holds, including anything a trigger or a default changed on the way in. The write appears in [Query History](query-history.md) like any other statement. There is **no undo** for an applied change.

**In an open transaction.** Cell edits run on the tab's connection when it has one. Edits applied while the tab has a [transaction open](query-execution.md#transactions) become part of that transaction: they are saved when you **Commit**, and a message says so.

## Find in Results

Press **Cmd+F** (or **Edit > Find > Find…**) to open the find controls in the action bar — ⌘F finds in whichever view has focus, so click into the grid first. Type to highlight all matching cells, with a "N of M" match counter. Navigate matches with the Previous/Next buttons, **Cmd+G**/**Cmd+Shift+G**, or **Enter**/**Shift+Enter** — the grid scrolls to each match. Press **Escape** to close.

## Filter Results

Press **Cmd+Shift+F** (or **Edit > Filter Results…**) to open the same controls in **filter mode** (funnel toggle active): only rows containing the search text are shown. Toggle the funnel to switch between highlight-only and filter modes. For per-column, type-aware filtering, see [Column Filters](column-filters.md).

## Value Rendering

Cell values are colored by type: numeric blue, temporal purple, JSON orange, booleans green (true) / red (false), formatted per the Bool Display setting. NULLs render per the NULL Display setting in italic gray. Newlines inside cells are flattened to `↵` for single-line display.

## Load More

When a query has more rows than the current page (see [Row Limit](query-execution.md#row-limit-and-load-more)), a **Load More Rows** bar appears at the bottom of the grid. Loading appends the next page and re-applies the active sort and filters.

## Load All Rows

The same bar carries a **Load All Rows** button. It re-runs the statement through a server-side cursor inside one transaction and replaces the result with a single consistent snapshot of every row, up to 500,000. Paging with **Load More** re-executes the statement per page, so without an outermost `ORDER BY` the pages can repeat or skip rows; one cursor reads one execution, so the rows line up.

A long load reports its progress: the bar shows a progress indicator, a running count ("Loaded 45,000 rows", updated every 5,000 rows) and a **Cancel** button. Cancelling stops the load on the server and leaves the page already on screen untouched. If the result is larger than 500,000 rows, the count says the limit was reached and the grid keeps the first 500,000.

## Empty States

The grid says which kind of empty it is. **No Results** — with a **Run Query** button — means there are no results to show yet. **No Rows** means a query did run and returned nothing.

## Editor and Results toggles

The two buttons at the right of the action bar show and hide the editor area and the results area, the way Xcode's debug-area button does. Each is lit while its area is on screen; both lit is the normal split. Deselect **Results** and the editor fills the pane, with the action bar left as a status strip along the bottom edge holding the status text and the two toggles (the result tools come back with the results). Deselect **Editor** and the results fill the pane. The last visible area cannot be hidden — its toggle is disabled — so the pane is never empty. Clicking anywhere in the blank stretch of the action bar while an area is hidden restores the split at its previous ratio, with a short haptic tap; hiding an area does not tap.

## Status Text

The action bar's status text summarizes the current result: row count and execution time (e.g., "1,000 rows in 0.42s"), plus visible-of-total counts and active filter counts when filters hide rows, match counts during a find, and "(more available)" when more rows can be loaded. Statements show "N rows affected".

## Copy and Export

See [Data Export](data-export.md) for copying results to the clipboard and exporting to files.
