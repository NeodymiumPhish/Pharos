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

Pharos automatically logs every query you execute, creating a searchable history.

## Automatic Logging

Every query execution is recorded with:
- **SQL** — The full query text
- **Connection** — Which database connection was used
- **Row count** — Number of rows returned
- **Execution time** — Duration in milliseconds
- **Timestamp** — When the query was run
- **Cached results** — Whether the result data is available for replay

## Browsing History

Switch to the **History** tab in the left sidebar to view your query history. Entries are grouped by date:

| Group | Contents |
|:------|:---------|
| Today | Queries from today |
| Yesterday | Queries from yesterday |
| This Week | Queries from the current week |
| This Month | Queries from the current month |
| Older | Everything else |

Each entry shows a preview of the SQL, the connection name, row count, and execution time.

## Infinite Scroll

History entries load progressively as you scroll down, keeping the initial load fast even with thousands of history entries.

## Search

Use the search bar at the top of the History panel to filter entries by SQL content. Matching is performed across the full query text.

## Loading Cached Results

History entries with cached results show a results indicator. Click an entry to:
1. Open the SQL in a new query tab
2. Automatically load the cached results without re-executing the query

This lets you review previous query outputs without running the query again.

## Context Menu

Right-click a history entry for options:

| Action | Description |
|:-------|:------------|
| Copy SQL | Copy the query text to clipboard |
| Delete | Remove the entry from history |

## Connection Filtering

When you're connected to a specific database, the history panel shows entries from that connection. This helps you find relevant queries for the current database.

## Storage

Query history is stored in the local SQLite database. Results are cached alongside history entries for later retrieval.
