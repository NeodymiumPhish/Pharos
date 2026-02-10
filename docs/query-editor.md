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

Pharos uses [Monaco Editor](https://microsoft.github.io/monaco-editor/) — the same editor that powers VS Code — for writing SQL queries.

## Syntax Highlighting

The editor provides full PostgreSQL syntax highlighting with custom themes:
- **Dark mode** — A Dracula-inspired color scheme with distinct colors for keywords, strings, numbers, operators, and comments
- **Light mode** — A high-contrast light theme optimized for readability

## Schema-Aware Autocomplete

As you type, the editor suggests:
- **Table names** from the current schema (or all schemas if none is selected)
- **Column names** when typing after a table reference
- **SQL keywords** (SELECT, FROM, WHERE, JOIN, etc.)
- **Functions** available in the database

Autocomplete metadata is loaded when you connect and updates when you switch schemas.

## Live SQL Validation

Pharos validates your SQL in real time by sending it to PostgreSQL via `PREPARE` statements. The validation status appears in the toolbar:

| Status | Indicator | Meaning |
|:-------|:----------|:--------|
| Valid | Green checkmark | SQL parses successfully |
| Invalid | Red X with message | Syntax or reference error (message shown on hover) |
| Checking | Spinner | Validation in progress |

Validation is debounced to avoid excessive server calls while typing.

## SQL Formatting

Press `Shift+Alt+F` or click the format button (wand icon) in the toolbar to auto-format your SQL. Formatting uses the PostgreSQL dialect and handles:
- Keyword capitalization
- Indentation of subqueries and JOIN clauses
- Line breaks for readability

## Multi-Tab Editing

Work with multiple queries simultaneously using tabs:

- **New tab** — `Cmd+T` or click the **+** button
- **Close tab** — `Cmd+W` or click the X on the tab
- **Switch tabs** — `Cmd+]` / `Cmd+[` for next/previous, or `Cmd+1` through `Cmd+9` for direct access
- **Reopen closed tab** — `Cmd+Shift+T` restores the last closed tab with its SQL content

Tab names auto-update to reflect the table being queried. Tabs opened from saved queries preserve the saved query name.

## Editor Configuration

Customize the editor under [Settings](settings) > Editor:

| Setting | Default | Options |
|:--------|:--------|:--------|
| Font Size | 13 | Any size |
| Font Family | JetBrains Mono, Monaco, Menlo, monospace | Any font |
| Tab Size | 2 | Any size |
| Word Wrap | Off | On/Off |
| Minimap | Off | On/Off |
| Line Numbers | On | On/Off |

## Cursor Position

The current cursor position (line and column) is displayed in the toolbar status area, useful for locating errors reported by line number.
