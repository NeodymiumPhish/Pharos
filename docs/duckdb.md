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

A DuckDB file is a **connection**. Each file you open gets a connection record, named after the file, in the Connections Manager. When another connection already has that name, Pharos adds the folder name, for example "data (Reports)". Query cards, tabs, query history, Sessions, workspaces, variables and tags work the same way as for a PostgreSQL connection.

## Open or create a database

| To | Do this |
|---|---|
| Create a new database file | **File > New DuckDB Database…**, choose a folder and a name. The file is created when the connection opens. In the Connections Manager, **New…** and then **Save** creates it. |
| Open an existing file | **File > Open DuckDB Database…** (**Cmd+Shift+O**) opens a file with any extension, for example `.db`. **File > Open…** (**Cmd+O**) opens `.duckdb` and `.ddb` files as well as SQL files. You can also double-click a `.duckdb` or `.ddb` file in Finder, or drop it on the Dock icon. |
| Open a file again | **File > Open Recent**. A file moves to the top of the list each time a tab uses it or it connects. Two files with the same name show their folder, for example "data.duckdb — Reports". The Dock's recent list shows the same files, so the Dock menu lists only PostgreSQL connections and in-memory databases. |
| Find the file on disk | **File > Show in Finder** shows the tab's database file. The Connections Manager has a **Show in Finder** button beside **New…**. |
| Use an in-memory database | In the Connections Manager, set **Engine** to **DuckDB** and select **In-memory database**. |

Opening a file finds the connection that already names it, or makes a new one. When a tab already shows the file, Pharos brings that tab forward. Otherwise the file opens in the tab you are in when that tab is empty and not on another DuckDB database, else in a new tab. Opening three files at once gives three tabs. Closing a tab on a file keeps it in **File > Reopen Closed Tab**.

{: .warning }
An in-memory database exists only while its connection is open. Its tables are lost when you disconnect or quit.

## A file that has moved

Pharos never makes an empty database in place of a file that is no longer where it was. When a file was moved, renamed or deleted, or its disk is not connected, **Connect** shows "“sales.duckdb” can’t be found" with three choices:

- **Locate…** — choose where the file is now. Pharos stores the new place in the same connection, so its tabs, Sessions and history still belong to it.
- **Create Empty Database** — make a new, empty database at the old place.
- **Cancel** — change nothing.

When Pharos itself connected the file (**Connect when Pharos starts**, or a Shortcut), no alert opens: the tab says **File not found**, and its **Locate…** button does the same as above.

## The Connections Manager

Set **Engine** to **DuckDB**. The form then shows a **Database File** section instead of the Server, Authentication and SSH Tunnel sections:

- **File** — the database file. **Choose…** picks an existing file; **New…** picks where a new one goes.
- **In-memory database** — no file at all.
- **Read-only** (Session) — DuckDB refuses writes, and other apps that also open the file read-only can read it at the same time.
- **Test Connection** never creates or changes the file: it opens an existing file read-only. For a new file whose folder exists it says that **Save** creates the file.
- **Save** creates a new file. **Connect** never creates one.

## A file another app has open

DuckDB lets one app write a database file at a time, or several apps read it when every one of them opened it read-only. When another app (for example the `duckdb` command-line tool) holds the file, Pharos names the app or command that holds it, for example "duckdb (process 4512)", and offers **Open Read-Only**:

- If the other app only reads the file, the read-only open succeeds.
- If the other app is writing, no other app can open the file, even read-only. Close the file in that app, then connect again.

Read-only applies to that connect only.

A file written by a newer DuckDB than the one in Pharos does not open; the message says so.

## What differs from PostgreSQL

| | PostgreSQL | DuckDB |
|---|---|---|
| Default schema | `public` | `main` |
| Other attached databases | — | Shown as `database.schema` in the schema browser |
| Cancel and the query timeout | Server cancel | DuckDB's interrupt |
| Exports (Export Data…, Export as Parquet…, Shortcuts) | No time limit | No time limit |
| A card that fails inside a transaction | Undone alone (savepoint) | Can fail the transaction; roll it back from the transaction chip |
| Idle-transaction timeout | Set by the server | None |
| Editing result cells | Yes | No |
| Explain | PostgreSQL's plan | DuckDB's plan, with row counts and timings but no costs |
| Partitions, automatic ANALYZE | Yes | No (DuckDB keeps row counts itself) |
| Export | CSV, TSV, JSON, JSON Lines, SQL, Markdown, XLSX | The same, and **Export as Parquet…** in the schema browser |

Cells show DuckDB's own text for every type, including lists (`[1, 2]`), structs (`{'a': 1}`) and maps.

## Extensions

These DuckDB extensions are built into Pharos. You do not install or load them; DuckDB loads each one the first time a query needs it.

| Extension | What it gives you |
|---|---|
| `core_functions` | DuckDB's standard functions and aggregates |
| `parquet` | `read_parquet`, `COPY … TO 'x.parquet'` |
| `json` | The `JSON` type, `read_json`, JSON functions |
| `icu` | Time zones (`SET TimeZone`, `TIMESTAMPTZ`), collations, locale-aware dates |
| `inet` | The `INET` type (IPv4 and IPv6 addresses and networks), `host()`, `<<=` and `>>=` |
| `fts` | Full-text search: `PRAGMA create_fts_index`, `match_bm25` |
| `excel` | `read_xlsx`, `COPY … TO 'x.xlsx'`, Excel number formats |
| `sqlite_scanner` | `ATTACH 'file.sqlite' (TYPE sqlite)`, `sqlite_scan` |
| `httpfs` | `read_csv`, `read_parquet` and `read_json` over `https://`, `s3://`, `gcs://` and `r2://` |
| `postgres_scanner` | `ATTACH` a PostgreSQL database, `postgres_query` (see **Attach a PostgreSQL connection**) |
| `autocomplete` | `sql_auto_complete` |

`SELECT * FROM duckdb_extensions()` shows these with the install path `(BUILT-IN)`.

{: .note }
Pharos does not download extensions. macOS lets the app load only the libraries it shipped with, so an extension that is not in the list above (for example `spatial`) is not available.

**Settings > Connections > DuckDB** sets the worker threads and the memory limit. These settings apply the next time a database opens.

## Temporary tables

A `CREATE TEMP TABLE` belongs to the tab that ran it: each tab has its own connection, and other tabs cannot see it. The Database Navigator does not list temporary tables. To list a tab's temporary tables, run `SHOW ALL TABLES` in a card of that tab.

## Attach a PostgreSQL connection

You can query and join the tables of a saved PostgreSQL connection from a DuckDB tab.

1. Open a DuckDB tab and connect it.
2. Choose **Query > Attach PostgreSQL Connection…**, or right-click a schema in the Database Navigator and choose **Attach PostgreSQL Connection…**.
3. Choose the connection. If it is not connected, Pharos connects it first (Touch ID and the password prompt work as usual).
4. Optional: type a name for the attached database. The default comes from the connection's name, for example `live_analysis`.
5. Keep **Read-only** on unless you want DuckDB to write to the PostgreSQL database. A read-only connection always attaches read-only.
6. Click **Attach**.

The Database Navigator then shows the PostgreSQL schemas as `name.schema`. Query them as `name.schema.table`, for example `SELECT * FROM live_analysis.public.events e JOIN read_csv('events.csv') c USING (id)`.

- Pharos gives DuckDB the password in a temporary secret. The password is not in any SQL text, in query history or on disk.
- A connection that uses an SSH tunnel attaches through that tunnel.
- The attach lasts while the PostgreSQL connection stays connected. When you disconnect it, Pharos detaches it from DuckDB. To detach it sooner, right-click one of its schemas and choose **Detach**.
- `verify-ca` and `verify-full` use the connection's SSL root certificate, or the certificates that macOS ships (`/etc/ssl/cert.pem`) when the connection has none. Certificates you added to the Keychain are not used.

## Secrets

DuckDB secrets (for example S3 keys for `httpfs`) live in memory only: use `CREATE SECRET`, not `CREATE PERSISTENT SECRET`. DuckDB writes a persistent secret to disk in plain text, so Pharos refuses it. Pharos also does not load secrets that other DuckDB tools saved in `~/.duckdb/stored_secrets`. Query history replaces passwords and keys in SQL text with `'********'`.
