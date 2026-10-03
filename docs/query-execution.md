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

Pharos runs the SQL of a [query card](query-editor.md#query-cards) against the editor tab's active connection and shows the output in the results area below the editor. Each card owns its own results. Each editor tab has its [own database connection](#one-connection-per-editor-tab), so the cards of a tab run one at a time, in order, and share session state the way psql does. Tabs run at the same time as each other, and long-running queries can notify you when they finish.

## Running Cards

- **Cmd+Return** (or **Query > Run Card**, or the card's **Run** button) runs the **focused card**.
- **Cmd+Shift+Return** (**Query > Run and Replace Results**) runs the focused card and replaces its results in place, even after an edit. A plain run after an edit keeps the old results in a locked card and makes a new version (see [Versions](query-editor.md#versions)).
- **Cmd+Opt+Return** (**Query > Run All Cards**) runs the tab's cards in order, one at a time. Run All stops at the first failure, and a message offers to continue.

With **⌘↩ runs** set to **The selection, else the statement** in [Settings > Query](settings.md#query-pane), a selection inside a card runs as a new, generated card below it. The card you selected from does not change.

When a run ends, its results take over the results area. To keep looking at other results while cards run, turn off **Show new results automatically** in [Settings > Results](settings.md#results-pane). A card's **View Results** button always shows that card's results (see [Card Results](results-grid.md#card-results)).

## Running Several Queries

The cards of one tab run on the tab's one connection, so they run one at a time: a card you run while another card of the same tab runs waits for it. Running a card that is already running or waiting does nothing. Cards in different tabs run at the same time. While queries run:

- The connection dot on the tab pulses.
- The running card shows **Cancel** in its name row, in place of **Run**, until its query completes. A waiting card also shows **Cancel**.
- **Query ▸ Cancel All Queries** (Cmd+Opt+.) cancels every query of the tab.

## One Connection per Editor Tab

Each editor tab gets its **own PostgreSQL connection**, opened at the tab's first run. All of the tab's cards run on it, in order. So these work across several cards, as they do in psql:

- `SET` statements
- temporary tables
- prepared statements
- a `BEGIN` … `COMMIT` spread over several cards (see [Transactions](#transactions))

Before, each run used any connection from a shared pool, and Pharos reset that connection after the run.

What Pharos keeps on a tab connection:

- **Row limit.** Rows are read through a cursor, so a result cut at the [row limit](#row-limit-and-load-more) keeps the tab's connection and its settings. A data-modifying `WITH` query still runs to completion — all of its rows are written — even if only the first page is shown.
- **Query timeout.** Pharos keeps the [query timeout](#query-timeout) itself on a tab connection, so your own `SET statement_timeout` stays in force.
- **Search path.** The schema pop-up button in the tab's [context row](query-editor.md#the-context-row) changes `search_path` only when you pick another schema, so your own `SET search_path` stays in force until then.

**Load More**, **Load All**, **Explain**, chart aggregation, validation and cell edits run on the tab's connection when it has one. So they see its temporary tables and uncommitted rows, and they never end or break your transaction.

Refused on a tab connection:

- psql meta-commands (such as `\set`), which Pharos shows as cards but does not run;
- `COPY … FROM STDIN` and `COPY … TO STDOUT`. Use [Import](table-operations.md) and [Export](data-export.md) instead.

### Limits and shared connections

**Editor tab connections per server** in [Settings > Connections](settings.md#connections-pane) sets how many tab connections one server may hold (default 8; 0 is no limit). When a server already has that many, a card runs on a shared connection, and Pharos says once that `SET`, temporary tables and transactions do not carry from card to card. A server that cannot hold a tab connection (some PostgreSQL-compatible servers) also falls back to shared connections.

{: .warning }
PgBouncer in **transaction pooling** mode cannot keep session state between statements, and Pharos cannot detect it. `SET`, temporary tables and transactions over several cards do not work through it. Use session pooling, or connect directly, for multi-card transactions.

### A reset connection

If the tab's connection is lost — the Mac slept, the network dropped, the server restarted, or the idle limit ended it — the next run opens a new one. The tab's [context row](query-editor.md#the-context-row) shows a **Connection reset** chip. Its tooltip, and the first line of its menu, say that the connection was reset and that its settings, temporary tables and any open transaction are gone. Choose **OK** in its menu to remove the chip. Pharos never sends a statement again that was in flight when the connection was lost.

## Transactions

Pharos does **not** end a transaction that you leave open. Run `BEGIN` in one card, and the cards after it run inside that transaction until you commit or roll back.

### The transaction chip

While a transaction is open, the tab's [context row](query-editor.md#the-context-row) shows an orange chip: "Transaction open · 2 min". The time counts up. Rest the pointer on the chip for the full message, which also counts down the server's idle limit. Click the chip to open a menu: the message, then **Roll Back** and **Commit**. **Query > Commit Transaction** and **Query > Roll Back Transaction** do the same.

After an error inside the transaction, the chip turns red and reads "Transaction failed". Its menu offers only **Roll Back**. As in psql, only `ROLLBACK` works in a failed transaction.

### Savepoints

Inside an open transaction, each card runs inside a savepoint:

- **Cancel** or a timeout undoes only that card. The transaction stays open.
- An SQL error leaves the transaction failed.

### Cell edits

[Cell edits](results-grid.md#editing-cells) that you apply while a transaction is open become part of it. They are saved when you **Commit**, and a message says so.

### The idle limit

**Idle transaction timeout for query cards** in [Settings > Connections](settings.md#connections-pane) sets how long a tab's transaction may sit idle (default 600 seconds; 0 turns it off). When the time passes, the server ends the tab's connection, and the next run [opens a new one](#a-reset-connection).

### Closing with an open transaction

These ask first while a tab has a transaction open:

- closing the tab or its window — **Roll Back and Close**;
- quitting Pharos — **Roll Back and Quit**;
- disconnecting — **Roll Back and Disconnect**;
- switching the tab to another connection.

Switching the connection offers **Roll Back and Switch**. Each also offers **Cancel**. Pharos always rolls back, and never commits for you. To keep the changes, cancel, then choose **Commit** from the tab's transaction chip.

## Read-only Connections

On a [read-only connection](connections.md#read-only-connections), Pharos refuses statements that turn read-only off, such as `SET default_transaction_read_only` and `BEGIN READ WRITE`. If a card manages to turn read-only off, Pharos turns it back on.

## A lost connection

When a query fails because the **connection** is gone — the server closed it, the SSH tunnel stopped, the socket broke — the connection moves to **Error** in the tab's context row (**Could not connect**, with **Try Again**), on the tab's dot (red) and in the Database Navigator, and **Connect** becomes available again. Before this, a failed query never changed a connection's status, so a dead tunnel kept a green glyph and Connect appeared to do nothing until you pressed Disconnect first.

A statement timeout and a query you cancelled are **not** a lost connection. Those kill the statement, not the session, so the connection stays connected.

## Cancelling

Press **Cmd+.** (or **Query > Cancel Query**) to cancel the most recent running query, or use a card's **Cancel** button to cancel that card. Cancellation sends `pg_cancel_backend()` to the server, terminating the query server-side. Inside an open transaction, a cancel undoes only that card (see [Savepoints](#savepoints)).

## Explain

**Cmd+Shift+E** (**Query > Explain Query**) asks PostgreSQL how it intends to run the focused card's statement — the same statement **Cmd+Return** would run, with query variables substituted — and shows the answer in that card's **Plan** view. Explain adds no card.

The plan is a tree. Each row shows the node (its type, and the relation or index it reads), the estimated rows, the cost range, and a bar giving that node's share of the whole plan. The tree opens fully expanded with the heaviest node already selected, so the first thing you see is where the work goes. A row's tooltip shows its filter, index condition, or hash condition. **Copy Plan JSON** puts the server's own `EXPLAIN (FORMAT JSON)` output on the clipboard for another tool.

**Cmd+Opt+Shift+E** (**Query > Explain Analyze Query**) runs the statement and reports what actually happened: measured times, measured row counts, and loop counts. The Time column multiplies a node's per-loop time by its loop count, so a cheap-looking inner scan that ran ten thousand times is ranked by the work it really did. The header line adds the planning and execution times.

{: .warning }
Explain Analyze *executes* the statement. Pharos runs it inside a transaction it always rolls back, so an `INSERT` or `UPDATE` explained this way leaves nothing behind — but a statement containing `DROP`, `DELETE`, or `TRUNCATE` is refused outright rather than confirmed, because a rollback cannot undo the locks and the effect on concurrent sessions. Use Explain Query for those.

On a tab with an open transaction, Explain and Explain Analyze run on the tab's connection and do not end or break the transaction.

The plan is a view of the card's results: switch between it and the results with the **Grid | Chart | Plan** control in the result action bar (see [Card Results](results-grid.md#card-results)). Explaining a card never locks it or makes a new version. A plan is not recorded in [query history](query-history.md) or restored with a workspace. Ask for it again; it costs nothing on the plain form.

Explain works on one statement at a time. Selecting a script reports "Explain one statement at a time" rather than silently explaining only its first statement.

## Query Types

- **Data queries** (`SELECT`, `WITH`, `EXPLAIN`, `SHOW`, `TABLE`, `VALUES`) return a result set displayed in the results grid.
- **Statements** (`INSERT`, `UPDATE`, `DELETE`, `CREATE`, …) return an execution summary showing the number of affected rows.

## Row Limit and Load More

Data queries return up to the **Row Limit** setting per page (default 1,000). When more rows exist, the status text notes "(more available)" and a **Load More Rows** bar appears below the grid. Loading more appends rows and re-applies any active sort and filters. On a tab connection, rows are read through a cursor, so a result cut at the limit keeps the connection and its settings (see [One Connection per Editor Tab](#one-connection-per-editor-tab)). [Charts](charts.md) offer a separate "Load all rows" shortcut, and server-side chart aggregation avoids loading rows entirely.

{: .tip }
You can change the row limit in [Settings](settings.md) under the Query tab.

## Query Timeout

Each query runs with a timeout, set from the **Statement timeout** setting (default 300 seconds). On a shared connection, Pharos applies it as PostgreSQL's `statement_timeout`: a query that exceeds it is cancelled by the server and reports a "canceling statement due to statement timeout" error. On a tab connection, Pharos keeps the timeout itself and cancels the query when the time passes, so a `SET statement_timeout` of your own stays in force on that connection. Inside an open transaction, a timeout undoes only that card (see [Savepoints](#savepoints)). Adjust the timeout in [Settings > Query](settings.md#query-pane) to suit your workload.

## Destructive Query Confirmation

When **Confirm queries that change the database** is enabled in [Settings](settings.md) (the default), running SQL that contains a `DROP`, `DELETE`, `TRUNCATE`, `UPDATE`, `ALTER`, `INSERT` or `GRANT` keyword shows a confirmation dialog with a preview of the statement before it executes. The dialog says "Run destructive query?" for `DROP`, `DELETE` and `TRUNCATE`, and "Run query that changes the database?" for the rest. Detection ignores keywords inside string literals, comments, and quoted identifiers, and catches data-modifying CTEs (e.g., `WITH x AS (DELETE …)`). The same setting guards Truncate and Drop in the [schema browser](table-operations.md#destructive-operations).

## Completion Notifications

Pharos can post a macOS notification when a query finishes (successfully or with an error) so you don't have to babysit long runs. A notification fires when the query ran at least the configured minimum duration (default 5 seconds) **and** either Pharos is in the background or the query's tab isn't the one you're looking at — both conditions are individually toggleable in [Settings](settings.md). A tab is not the one you're looking at when another tab of its window is showing, when its window is minimised, or when it has closed. Clicking the notification brings Pharos forward and focuses the originating tab. Queries you cancelled yourself don't notify.

Separately, the Dock icon shows a badge counting how many queries finished while Pharos was in the background — even ones too quick to trigger a notification — and clears as soon as you switch back to Pharos.

## Error Handling

When a query fails, the PostgreSQL error message is displayed in the results area. If the error includes a character position, the card underlines the location in red to help you find the problem.

The first failure you have not read appears as a one-line banner above the results, not as a dialog: the editor stays usable behind it. The banner carries **Go to Error** (move the editor to the failing text), **Details…** (open the full error sheet on that entry) and a close button. If a second failure arrives while the first is still unread, the error sheet opens as before — at that point there is a list to read rather than a single message. The banner stays with its own tab when you switch to another tab; the tab's error button still holds every failure.

A cancelled query is never a banner. It opens the cancellation dialog when **Show cancelled query dialog** is on, and nothing at all when it is off.

## History

Successful queries are recorded automatically — grouped into workspaces per editor tab — in [Query History](query-history.md).
