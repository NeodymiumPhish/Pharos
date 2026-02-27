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

The query editor is a native text view built on NSTextView, providing SQL editing with syntax highlighting, auto-completion, bracket matching, and multi-tab support. It occupies the top portion of the content area, above the results grid.

## Syntax Highlighting

The editor highlights SQL syntax in real time using regex-based pattern matching. The following elements are color-coded:

| Element | Color | Examples |
|---------|-------|----------|
| Keywords | Blue | `SELECT`, `FROM`, `WHERE`, `JOIN` |
| Functions | Teal | `count()`, `avg()`, `now()` |
| Strings | Green | `'hello'`, `$$body$$` |
| Numbers | Orange | `42`, `3.14` |
| Comments | Gray | `-- comment`, `/* block */` |
| Types | Purple | `INTEGER`, `TEXT`, `BOOLEAN` |

Highlighting is applied via temporary attributes, so it does not interfere with undo history.

## Auto-Completion

The editor provides context-aware auto-completion for database objects:

- **Trigger with Ctrl+Space** to open the completion list at any time
- **Type a dot** (e.g., `public.`) to automatically trigger completion with objects from that schema
- **Navigate** the completion list with Up/Down arrow keys
- **Accept** a suggestion with Return or Tab
- **Dismiss** the list with Escape

Completion suggestions are populated from the connected database's schema metadata, including schema names, table names, and column names.

## Bracket Matching

When you place the cursor next to a bracket -- `(`, `)`, `[`, `]`, `{`, or `}` -- the editor highlights the matching bracket with a subtle yellow background. This works for nested brackets and skips brackets inside strings and comments.

## Auto-Close Brackets

The editor automatically inserts matching closing characters when you type:

- `(` inserts `()`
- `[` inserts `[]`
- `'` inserts `''` (except after alphanumeric characters, where it is treated as an apostrophe)

Typing the closing character when it already follows the cursor skips over it instead of inserting a duplicate. Pressing Backspace on an opening bracket deletes both characters if the matching close is adjacent.

## Tab Management

Pharos supports multiple editor tabs for working on different queries simultaneously.

| Action | Shortcut |
|--------|----------|
| New Tab | Cmd+T |
| Close Tab | Cmd+W |
| Reopen Closed Tab | Cmd+Shift+T |
| Switch to Tab 1-9 | Cmd+1 through Cmd+9 |

Double-click a tab to rename it. Each tab preserves its own SQL text, cursor position, and query results independently.

## Indentation

- **Tab** inserts spaces (configurable size: 2, 4, or 8 in Settings)
- **Shift+Tab** removes one indent level from the current line or selected lines
- **Tab with multi-line selection** indents all selected lines
- **Return** auto-indents the new line to match the previous line's leading whitespace
- **Backspace** at an indent boundary removes a full indent level

## Indent-Aware Paste

When pasting multi-line text, the editor preserves the relative indentation of the pasted block while adjusting it to match the cursor's current position. The first line is inserted at the cursor, and subsequent lines are re-indented to maintain their structure.

## Current Line Highlight

The editor subtly highlights the line containing the cursor, making it easier to track your position in longer queries.

## Format SQL

Press **Ctrl+I** or choose **Query > Format SQL** from the menu bar to format the SQL in the active editor tab.

## Error Markers

When a query fails with a PostgreSQL error that includes a character position, the editor underlines the error location with a red marker, helping you quickly locate syntax errors.
