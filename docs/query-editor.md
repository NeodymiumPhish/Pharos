---
layout: default
title: Query Editor
nav_order: 5
---

# Query Editor
{: .no_toc }

<details open markdown="block">
  <summary>Table of contents</summary>
  {: .text-delta }
- TOC
{:toc}
</details>

---

## Overview

The query editor is a native text view providing SQL editing with syntax highlighting, auto-completion, bracket matching, code folding, [query variables](query-variables.md), and multi-tab, multi-pane support. It occupies the top portion of the content area, above the results.

## Editor Toolbar

Each editor pane has its own toolbar: **Format** (SQL formatter), a **Save** dropdown (Save / Save As… / Export as SQL File…), the **Run/Stop** button, the **connection** pull-down, the **schema** selector, and — pinned to the right — the **Query Variables** toggle. A contextual **Format as SQL list** button appears after pasting a bare list of values (see below).

## Syntax Highlighting

The editor highlights SQL in real time:

| Element | Color | Examples |
|---------|-------|----------|
| Keywords | Blue | `SELECT`, `FROM`, `WHERE`, `JOIN` |
| Functions | Teal | `count()`, `avg()`, `now()` |
| Strings | Green | `'hello'`, `$$body$$` |
| Numbers | Orange | `42`, `3.14` |
| Comments | Gray | `-- comment`, `/* block */` |
| Types | Purple | `INTEGER`, `TEXT`, `BOOLEAN` |
| Variables | Indigo (defined), Red (undefined) | `{{start_date}}` |

## Auto-Completion

The editor provides context-aware auto-completion for database objects:

- **Trigger with Ctrl+Space** to open the completion list at any time
- **Type a dot** (e.g., `public.`) to automatically trigger completion with objects from that schema
- **Navigate** the list with Up/Down, **accept** with Return or Tab, **dismiss** with Escape

Suggestions come from the connected database's schema metadata: schema, table, and column names.

## Brackets and Quotes

- **Matching**: placing the cursor next to `(`, `)`, `[`, `]`, `{`, or `}` highlights the matching bracket, skipping brackets inside strings and comments.
- **Context-aware auto-close**: typing `(`, `[`, or `'` inserts the closing character — but only when the cursor is at the end of a line or before whitespace or a closing delimiter, so typing in front of existing text doesn't inject stray pairs. An apostrophe typed after a letter or digit stays a single `'`.
- **Selection wrapping**: with text selected, typing `(`, `[`, or `'` wraps the selection instead of replacing it.
- **Skip-over**: typing a closing character that's already under the cursor steps over it; Backspace on an opening bracket removes both characters when the close is adjacent.

## Opening and Saving SQL Files

- **File > Open…** (**Cmd+O**) opens `.sql` or plain-text files in new tabs; you can also double-click SQL files in Finder or drop them on the Dock icon. Files over 50 MB prompt before opening.
- A tab opened from a file stays linked to it: **Cmd+S** writes straight back to the file, and the tab shows a dirty indicator for unsaved edits.
- **File > Export Query as SQL File…** (**Cmd+Opt+S**) saves any tab's SQL to a new `.sql` file (with [query variables](query-variables.md) rendered into the output).

## Tab and Pane Management

Pharos supports multiple editor tabs, and multiple side-by-side editor panes each with their own tabs.

| Action | Shortcut |
|--------|----------|
| New Tab | Cmd+T |
| Close Tab | Cmd+W |
| Reopen Closed Tab | Cmd+Shift+T |
| Switch to Tab 1–9 | Cmd+1 through Cmd+9 |

Double-click a tab to rename it. Each tab keeps its own SQL text, connection, variables, and results.

To split the editor, use the **add-pane** button in the pane's tab bar; each pane gets its own toolbar, tabs, and connection selection. Panes can be expanded to fill the editor area or closed from the same tab bar. Run and save actions target the pane you last clicked into.

## Indentation

- **Tab** inserts spaces (2, 4, or 8, configurable in Settings)
- **Shift+Tab** removes one indent level from the current or selected lines
- **Tab with a multi-line selection** indents all selected lines
- **Return** auto-indents to match the previous line
- **Backspace** at an indent boundary removes a full indent level
- **Pasting** multi-line text re-indents the block to match the cursor position while preserving its internal structure

## Format as SQL List (Smart Paste)

Paste a bare list of values (e.g., a column of IDs copied from a spreadsheet) and Pharos offers to convert it: a **Format as SQL list** button appears in the toolbar. Press **Tab** or click it to turn the lines into a quoted, comma-separated list ready for an `IN (...)` clause — numeric, boolean, and NULL values stay unquoted; strings are quoted with apostrophes escaped. Press **Esc** or keep typing to dismiss; the conversion is a single undo step. You can also select any lines and choose **Format as SQL list** from the right-click menu.

## Code Folding

The editor supports collapsing regions of SQL that span at least 3 lines:

| Region | Example |
|--------|---------|
| Parenthetical blocks | Multi-line `VALUES` lists, `IN (...)`, column definitions |
| Subqueries | `( SELECT ... )` |
| CTEs | `WITH name AS ( ... )` |
| CASE blocks | `CASE ... END` |
| BEGIN/END blocks | `BEGIN ... END` |
| CREATE bodies | `CREATE FUNCTION ... AS $$ ... $$` |

Click the fold indicator in the line-number gutter to collapse or expand a region. Collapsed regions render as an inline pill showing the hidden line count (e.g., " ▸ 4 lines "); the underlying text is untouched. Folds survive edits elsewhere in the document and are removed automatically if an edit overlaps them.

## Format SQL

Press **Ctrl+I**, choose **Query > Format SQL**, or click the toolbar Format button to format the SQL in the active tab.

## Statements and the Gutter

The editor parses the buffer into individual SQL statements ("segments"). The line-number gutter shows a **run button per statement**, and each statement's results get a matching colored bar in the gutter and [result tab](results-grid.md#result-tabs). While a statement runs, its gutter bar pulses. See [Query Execution](query-execution.md) for run semantics.

## Error Markers

When a query fails with a PostgreSQL error that includes a character position, the editor underlines the error location in red and marks the line in the gutter.
