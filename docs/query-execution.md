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

## Overview

Pharos executes SQL queries against the active PostgreSQL connection and displays results in the grid below the editor. It supports both data-returning queries (SELECT, WITH, EXPLAIN, SHOW, TABLE, VALUES) and statements (INSERT, UPDATE, DELETE, CREATE, etc.).

## Running a Query

Press **Cmd+Enter** or choose **Query > Run Query** from the menu bar to execute the SQL in the active editor tab. The query runs against the connection shown in the server rail.

During execution, the tab indicates that a query is in progress. Results appear in the grid below the editor once the query completes.

## Cancelling a Query

Press **Cmd+.** or choose **Query > Cancel Query** to cancel a running query. Pharos sends a `pg_cancel_backend()` request to the PostgreSQL server, which terminates the query on the server side.

## Query Types

Pharos distinguishes between two types of SQL:

- **Data queries** (SELECT, WITH, EXPLAIN, SHOW, TABLE, VALUES) -- return a result set displayed in the results grid with column headers and rows
- **Statements** (INSERT, UPDATE, DELETE, CREATE, DROP, etc.) -- return an execution summary showing the number of affected rows

## Row Limit and Pagination

By default, data queries return a limited number of rows controlled by the **Row Limit** setting (default: 1,000). If the query produces more rows than the limit, a **Load More** button appears at the bottom of the results grid.

Click **Load More** to fetch the next page of rows. The additional rows are appended to the existing results, and sorting or filtering is reapplied automatically. This process can be repeated until all rows are loaded.

{: .tip }
You can change the default row limit in [Settings](settings.md) under the Query tab.

## Query Timeout

Queries are subject to a configurable timeout (default: 30 seconds). If a query exceeds the timeout, it is automatically cancelled. You can adjust the timeout in [Settings](settings.md) under the Query tab.

## Error Handling

When a query fails, the error message from PostgreSQL is displayed in the results area. If the error includes a character position, the editor highlights the error location with a red underline to help you find the problem.

## Query History

Every executed query is automatically recorded in the [Query History](query-history.md). You can revisit previous queries and their results from the History panel in the sidebar.
