---
layout: default
title: Query Execution
nav_order: 6
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

## Running Queries

Click the green **Run** button or press `Cmd+Enter` to execute the SQL in the current tab. While a query is running, the button shows a spinner and the cancel button appears.

## Cancellation

Press `Escape` or click the stop button to cancel a running query. Pharos cancels queries server-side using PostgreSQL's `pg_cancel_backend()`, so the database stops processing immediately rather than just dropping the client connection.

## Result Limits

By default, Pharos limits results to **1000 rows** to keep the UI responsive. When a query returns more rows than the limit:

- A "has more" indicator appears in the results status bar
- Click **Load More** to fetch the next batch of rows
- Rows are appended to the existing results

The default limit is configurable in [Settings](settings) > Query (range: 100–10,000).

## Query Timeout

Queries have a configurable timeout (default: **30 seconds**). If a query exceeds the timeout, it is automatically cancelled. The timeout can be adjusted in Settings > Query from 10 seconds to no limit.

## Auto-Commit

By default, auto-commit is enabled — each query runs in its own implicit transaction that commits automatically. This can be toggled in Settings > Query.

## Destructive Query Confirmation

When **Confirm Destructive** is enabled (default: on), Pharos prompts for confirmation before executing statements that modify data:
- `DELETE`
- `DROP`
- `TRUNCATE`
- `ALTER`
- `UPDATE` (without WHERE clause)

This safeguard helps prevent accidental data loss.

## Schema Search Path

When a schema is selected in the Schema Browser dropdown, Pharos sets the PostgreSQL `search_path` to that schema before executing your query. This means you can write `SELECT * FROM my_table` instead of `SELECT * FROM "my_schema"."my_table"`.

## EXPLAIN Detection

Pharos automatically detects `EXPLAIN` queries and injects `FORMAT JSON` to enable visual plan rendering. This works with all EXPLAIN variants:

- `EXPLAIN SELECT ...` → `EXPLAIN (FORMAT JSON) SELECT ...`
- `EXPLAIN ANALYZE SELECT ...` → `EXPLAIN (ANALYZE, FORMAT JSON) SELECT ...`
- `EXPLAIN (ANALYZE, VERBOSE) SELECT ...` → `EXPLAIN (ANALYZE, VERBOSE, FORMAT JSON) SELECT ...`

If you already specify `FORMAT` in your query, Pharos leaves it unchanged. See [EXPLAIN Visualization](explain) for details on the visual plan view.
