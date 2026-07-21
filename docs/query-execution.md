---
layout: default
title: Query Execution
nav_order: 7
---

# Query Execution
{: .no_toc }

<details open markdown="block">
  <summary>Table of contents</summary>
  {: .text-delta }
- TOC
{:toc}
</details>

---

## Overview

Pharos executes SQL against the editor tab's active connection and shows the output in [result tabs](results-grid.md#result-tabs) below the editor. Multiple queries can run concurrently, each statement gets its own result tab, and long-running queries can notify you when they finish.

## Running Queries

The editor splits your SQL into individual statements. There are three ways to run:

- **Cmd+Return** (or **Query > Run Query**) runs the **statement under the cursor** and opens a result tab for it. If nothing parses as a statement, the entire editor text is sent as one batch.
- **Gutter run buttons** — each statement has its own run button in the line-number gutter.
- **Run All Queries** — from the toolbar Run button's menu (shown when the tab has multiple statements): runs every statement, up to 3 at a time, in order. Run All pauses if you switch away from the tab and resumes when you return.

Each result tab is color-matched to its source statement's bar in the editor gutter, so you can always tell which result came from which SQL.

## Concurrent Execution

Queries run concurrently — starting a second statement doesn't wait for the first. While queries run:

- The Run button becomes a **red progress ring showing the count** of running queries. With one running, clicking it cancels; with several, it opens a popover listing each in-flight query with its elapsed time and a per-query cancel button.
- Each running statement's gutter bar **pulses** until its query completes.
- Re-running SQL that is already in flight is skipped, with a toast pointing at the running query.

## Cancelling

Press **Cmd+.** (or **Query > Cancel Query**) to cancel the most recent running query, or use the running-queries popover to cancel a specific one. Cancellation sends `pg_cancel_backend()` to the server, terminating the query server-side.

## Query Types

- **Data queries** (`SELECT`, `WITH`, `EXPLAIN`, `SHOW`, `TABLE`, `VALUES`) return a result set displayed in the results grid.
- **Statements** (`INSERT`, `UPDATE`, `DELETE`, `CREATE`, …) return an execution summary showing the number of affected rows.

## Row Limit and Load More

Data queries return up to the **Row Limit** setting per page (default 1,000). When more rows exist, the status text notes "(more available)" and a **Load More Rows** bar appears below the grid. Loading more appends rows and re-applies any active sort and filters. [Charts](charts.md) offer a separate "Load all rows" shortcut, and server-side chart aggregation avoids loading rows entirely.

{: .tip }
You can change the row limit in [Settings](settings.md) under the Query tab.

## Query Timeout

Each query runs with a server-side timeout (PostgreSQL's `statement_timeout`), set from the **Timeout** setting (default 300 seconds). A query that exceeds it is cancelled by the server and reports a "canceling statement due to statement timeout" error. Adjust the timeout in [Settings](settings.md) to suit your workload.

## Destructive Query Confirmation

When **Confirm before DROP / DELETE / TRUNCATE** is enabled in [Settings](settings.md) (the default), running SQL that contains a `DROP`, `DELETE`, or `TRUNCATE` keyword shows a confirmation dialog with a preview of the statement before it executes. Detection ignores keywords inside string literals, comments, and quoted identifiers, and catches data-modifying CTEs (e.g., `WITH x AS (DELETE …)`). The same setting guards Truncate and Drop in the [schema browser](table-operations.md#destructive-operations).

## Completion Notifications

Pharos can post a macOS notification when a query finishes (successfully or with an error) so you don't have to babysit long runs. A notification fires when the query ran at least the configured minimum duration (default 5 seconds) **and** either Pharos is in the background or the query's tab isn't the one you're looking at — both conditions are individually toggleable in [Settings](settings.md). Clicking the notification brings Pharos forward and focuses the originating tab. Queries you cancelled yourself don't notify.

## Error Handling

When a query fails, the PostgreSQL error message is displayed in the results area. If the error includes a character position, the editor underlines the location in red to help you find the problem.

## History

Successful queries are recorded automatically — grouped into workspaces per editor tab — in [Query History](query-history.md).
