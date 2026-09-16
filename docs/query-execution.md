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

Pharos executes SQL against the editor tab's active connection and shows the output in the results area below the editor, with one [result tab](results-grid.md#result-tabs) per statement. Multiple queries can run concurrently, each statement gets its own result tab, and long-running queries can notify you when they finish.

## Running Queries

The editor splits your SQL into individual statements. There are three ways to run:

- **Cmd+Return** (or **Query > Run Query**) runs the **statement under the cursor** and opens a result tab for it. If nothing parses as a statement, the entire editor text is sent as one batch.
- **Gutter bands** — each statement has a coloured band behind its line numbers; hover it to turn it into a run button, and click to run that statement.
- **Run All Queries** — **Query > Run All Queries** (**Cmd+Opt+Return**): runs every statement, up to 3 at a time, in order. Run All pauses if you switch away from the tab and resumes when you return.

Each result tab is color-matched to its source statement's bar in the editor gutter, so you can always tell which result came from which SQL.

## Concurrent Execution

Queries run concurrently — starting a second statement doesn't wait for the first. While queries run:

- The toolbar **Run** button shows a **badge with the count** of running queries, and the **Cancel** button next to it becomes enabled. With one running, Cancel stops it; with several, Cancel opens a popover listing each in-flight query with its elapsed time and a per-query cancel button.
- Each running statement's gutter bar **pulses** until its query completes.
- Re-running SQL that is already in flight is skipped, with a toast pointing at the running query.

## Cancelling

Press **Cmd+.** (or **Query > Cancel Query**) to cancel the most recent running query, or use the running-queries popover to cancel a specific one. Cancellation sends `pg_cancel_backend()` to the server, terminating the query server-side.

## Explain

**Cmd+Shift+E** (**Query > Explain Query**) asks PostgreSQL how it intends to run the statement under the cursor — the same statement **Cmd+Return** would run, with query variables substituted — and opens the answer as a result tab named "Plan …".

The plan is a tree. Each row shows the node (its type, and the relation or index it reads), the estimated rows, the cost range, and a bar giving that node's share of the whole plan. The tree opens fully expanded with the heaviest node already selected, so the first thing you see is where the work goes. A row's tooltip shows its filter, index condition, or hash condition. **Copy Plan JSON** puts the server's own `EXPLAIN (FORMAT JSON)` output on the clipboard for another tool.

**Cmd+Opt+Shift+E** (**Query > Explain Analyze Query**) runs the statement and reports what actually happened: measured times, measured row counts, and loop counts. The Time column multiplies a node's per-loop time by its loop count, so a cheap-looking inner scan that ran ten thousand times is ranked by the work it really did. The header line adds the planning and execution times.

{: .warning }
Explain Analyze *executes* the statement. Pharos runs it inside a transaction it always rolls back, so an `INSERT` or `UPDATE` explained this way leaves nothing behind — but a statement containing `DROP`, `DELETE`, or `TRUNCATE` is refused outright rather than confirmed, because a rollback cannot undo the locks and the effect on concurrent sessions. Use Explain Query for those.

Plan tabs behave like any other result tab — select, rename, close — with two differences: the Grid/Chart toggle is hidden (a plan is neither), and a plan is not recorded in [query history](query-history.md) or restored with a workspace. Ask for it again; it costs nothing on the plain form.

Explain works on one statement at a time. Selecting a script reports "Explain one statement at a time" rather than silently explaining only its first statement.

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

Separately, the Dock icon shows a badge counting how many queries finished while Pharos was in the background — even ones too quick to trigger a notification — and clears as soon as you switch back to Pharos.

## Error Handling

When a query fails, the PostgreSQL error message is displayed in the results area. If the error includes a character position, the editor underlines the location in red to help you find the problem.

The first failure you have not read appears as a one-line banner above the results, not as a dialog: the editor stays usable behind it. The banner carries **Go to Error** (move the editor to the failing text), **Details…** (open the full error sheet on that entry) and a close button. If a second failure arrives while the first is still unread, the error sheet opens as before — at that point there is a list to read rather than a single message. Switching editor tabs takes the banner away; the tab's error button still holds every failure.

A cancelled query is never a banner. It opens the cancellation dialog when **Show cancelled query dialog** is on, and nothing at all when it is off.

## History

Successful queries are recorded automatically — grouped into workspaces per editor tab — in [Query History](query-history.md).
