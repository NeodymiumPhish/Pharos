---
layout: default
title: DuckDB
nav_order: 20
---

# DuckDB
{: .no_toc }

<details open markdown="block">
  <summary>Table of contents</summary>
  {: .text-delta }
- TOC
{:toc}
</details>

---

## Overview

Pharos opens [DuckDB](https://duckdb.org) database files as well as PostgreSQL servers. DuckDB 1.5.6 is built into the app: there is nothing else to install, and the database runs inside Pharos.

A DuckDB file is a **connection**. Each file you open gets a connection record, named after the file, in the Connections Manager. Query cards, tabs, query history, Sessions, workspaces, variables and tags work the same way as for a PostgreSQL connection.

## Open or create a database

| To | Do this |
|---|---|
| Create a new database file | **File > New DuckDB Database…**, choose a folder and a name. The file is created when the connection opens. |
| Open an existing file | **File > Open DuckDB Database…** (**Cmd+Shift+O**), or double-click a `.duckdb` or `.ddb` file in Finder, or drop it on the Dock icon. |
| Open a file again | **File > Open Recent**. The Dock's recent list shows the same files. |
| Use an in-memory database | In the Connections Manager, set **Engine** to **DuckDB** and select **In-memory database**. |

Opening a file finds the connection that already names it, or makes a new one. The file opens in the tab you are in when that tab is empty, otherwise in a new tab.

{: .warning }
An in-memory database exists only while its connection is open. Its tables are lost when you disconnect or quit.

## The Connections Manager

Set **Engine** to **DuckDB**. The form then shows a **Database File** section instead of the Server, Authentication and SSH Tunnel sections:

- **File** — the database file. **Choose…** picks an existing file; **New…** picks where a new one goes.
- **In-memory database** — no file at all.
- **Read-only** (Session) — DuckDB refuses writes, and other apps can read the same file at the same time.
- **Test Connection** never creates or changes the file: it opens an existing file read-only, and passes a new file whose folder exists.

## A file another app has open

DuckDB lets one app write a database file at a time. When another app (for example the `duckdb` command-line tool) has the file open for writing, Pharos asks whether to open it **read-only**. Read-only applies to that connect only.

A file written by a newer DuckDB than the one in Pharos does not open; the message says so.

## What differs from PostgreSQL

| | PostgreSQL | DuckDB |
|---|---|---|
| Default schema | `public` | `main` |
| Other attached databases | — | Shown as `database.schema` in the schema browser |
| Cancel and the query timeout | Server cancel | DuckDB's interrupt |
| A card that fails inside a transaction | Undone alone (savepoint) | Can fail the transaction; roll it back from the transaction chip |
| Idle-transaction timeout | Set by the server | None |
| Editing result cells | Yes | No |
| Explain | PostgreSQL's plan | DuckDB's plan, with row counts and timings but no costs |
| Partitions, automatic ANALYZE | Yes | No (DuckDB keeps row counts itself) |
| Export | CSV, TSV, JSON, JSON Lines, SQL, Markdown, XLSX | The same, and **Export as Parquet…** in the schema browser |

Cells show DuckDB's own text for every type, including lists (`[1, 2]`), structs (`{'a': 1}`) and maps.

## Extensions

DuckDB downloads a known extension (time zones, `httpfs`, `postgres`, Excel…) the first time a query needs it. **Settings > Connections > DuckDB** controls this, and also the worker threads, the memory limit and the extension folder. These settings apply the next time a database opens.
