---
layout: default
title: Query History
nav_order: 12
---

# Query History
{: .no_toc }

<details open markdown="block">
  <summary>Table of contents</summary>
  {: .text-delta }
- TOC
{:toc}
</details>

---

## Overview

The Query History panel lives in the Library section of the sidebar, accessed by clicking the **History** tab next to **Saved**. Every query you execute is automatically recorded here, giving you a searchable log of past work.

## History Display

Each history entry shows two lines of information:

1. **Primary line** -- Column count and parsed table names (e.g., "6 Columns -- users"), or the first line of SQL as a fallback
2. **Secondary line** -- Row count, relative timestamp (e.g., "1h ago"), and connection name

Entries are listed in reverse chronological order, with the most recent queries at the top.

## Opening a History Entry

Double-click a history entry to open it in a new editor tab. The SQL is loaded into the editor, and if cached results are available, they are displayed in the results grid immediately without re-executing the query.

History tabs display additional context showing the schema and timestamp of the original execution.

## Context Menu

Right-click a history entry for additional options:

| Action | Description |
|--------|-------------|
| Copy SQL | Copies the query's SQL text to the clipboard |
| Delete | Removes the entry from history |

## Deleting History

You can delete history entries in two ways:

- **Single entry** -- Right-click and choose Delete
- **Batch delete** -- Select multiple entries (using Cmd+Click or Shift+Click), then click the Delete button in the action bar. A confirmation dialog appears showing how many entries will be deleted.

## Filtering

Use the search field at the top of the sidebar to filter history entries. The filter matches against the SQL text of each entry.

## Automatic Recording

Query history is recorded automatically every time a query is executed. Both successful queries and failed queries are captured. The history retains up to 200 entries per view.
