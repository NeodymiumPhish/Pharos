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
| Open a file again | **File > Open Recent**. It lists DuckDB databases and the data files you opened (CSV, JSON, Parquet, Excel). A file moves to the top of the list each time a tab uses it or it connects. Two files with the same name show their folder, for example "data.duckdb — Reports". The Dock's recent list shows the same files, so the Dock menu lists only PostgreSQL connections and in-memory databases. |
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

**File > New DuckDB Database…** never replaces a file that is in use: when you choose the name of a file that Pharos has open, or that another app holds (for example the `duckdb` command-line tool), the panel says so and stays open. When it does replace a file, the old file and its `.wal` go to the Trash together.

## A file another app has open

DuckDB lets one app write a database file at a time, or several apps read it when every one of them opened it read-only. When another app (for example the `duckdb` command-line tool) holds the file, Pharos names the app or command that holds it, for example "duckdb (process 4512)", and offers **Open Read-Only**:

- If the other app only reads the file, the read-only open succeeds.
- If the other app is writing, no other app can open the file, even read-only. Close the file in that app, then connect again.

Read-only applies to that connect only.

While a connection is open read-only, the tab's context row shows **Read-only** with a lock. Its help says why: the connection's Read-only setting, or another app that holds the file. The Database Navigator then leaves out Import Data…, Truncate and Drop. Two connections on the same file must have the same Read-only setting: when one is open, the other does not connect and says so.

A file written by a newer DuckDB than the one in Pharos does not open. The tab's context row says "Needs a newer DuckDB", with no Try Again, because a retry cannot succeed.

When Pharos connects on its own (at launch, or from a Shortcut), it shows no alert. The tab's context row says "In use by another app" with an **Open Read-Only** button, or "File not found" with a **Locate…** button.

## Remove a file from Pharos

In the Connections Manager, select the DuckDB connection and click **−**. The alert says **Remove “sales” from Pharos?**: Pharos forgets the connection, and the file stays where it is. Saved Sessions on it lose their connection. For an open in-memory database, its tables are lost.

**Test Connection** on a DuckDB file shows the file size, when it was last changed and its storage format, for example "DuckDB file · 12.4 MB · modified today · storage version 64, written by DuckDB v1.5.6". The size is the database file only, without a `.wal` file beside it.

## When Pharos closes a file

Pharos closes a DuckDB file a few seconds after the last tab that uses it closes, or changes to another connection. The DuckDB lock then goes, so the `duckdb` command-line tool, Python and other apps can open the file. Closing the file also detaches its attached databases and drops its temporary secrets. Pharos keeps a file open when:

- the connection is in-memory (closing it would lose its tables), or
- the connection has **Connect when Pharos starts** on.

**File > Disconnect** closes the file at once.

## In-memory databases

**File > New In-Memory DuckDB Database** makes a database that lives in memory only, in a new tab: "In-memory DuckDB", then "In-memory DuckDB 2", and so on. It is useful for a quick look at some files.

Its tables are lost when it disconnects or Pharos quits. When it holds tables or views, **File > Disconnect**, **Quit** and **−** in the Connections Manager first ask: **Do you want to save the in-memory database?** with **Save…**, **Don't Save** and **Cancel**. Pharos always asks, whatever **Warn before closing unsaved tabs** says, because the tables have no other copy.

**File > Save In-Memory Database…** copies the database to a new `.duckdb` file at any time, then offers to open the file in a new tab. The tabs on the in-memory database stay as they are. The copy has the tables and views with their data. It leaves out temporary tables, attached PostgreSQL databases and work that other tabs have not committed.

## Query files in place

DuckDB reads CSV, TSV, JSON, newline-delimited JSON, Parquet and Excel files where they are, with no import. On a DuckDB tab:

| To do this | Do this |
|---|---|
| Query a file | Drag the file from Finder onto an empty card. The card gets `SELECT * FROM read_csv('/Users/you/Data/sales.csv')` (or `read_json`, `read_parquet`, `read_xlsx`). |
| Use a file in a query you are writing | Drag the file onto a card with text. Pharos inserts the quoted path at the drop point, for example `'/Users/you/Data/sales.csv'`. A quoted path is a valid `FROM` target: `SELECT region, sum(total) FROM '/Users/you/Data/sales.csv' GROUP BY ALL`. |
| Query several files together | Drag them together onto an empty card: `read_csv(['/Users/you/a.csv', '/Users/you/b.csv'], union_by_name = true)`. |
| Choose the files in a panel | **Query > Insert File Reference…** |
| Open a file from Finder, the Dock or **File > Open…** | With a DuckDB tab in front, each file gets its own card after the current one, `SELECT * FROM read_parquet('…')`, and the card runs when the tab is connected. With no DuckDB tab in front, Pharos makes a new in-memory database in a new tab, with one card per file, and runs the cards. Pharos is listed in Finder's **Open With** for CSV, TSV, JSON, Excel and Parquet files, but it never becomes their default app. |

**Edit > Undo** removes the inserted text in one step. On a PostgreSQL tab, a dropped CSV or SQL file opens as a tab of its own, and a dropped `.duckdb` file opens the database on any tab.

### Relative paths

A relative path in a read starts in the database file's folder. So with `~/Data/sales.duckdb` open, `read_csv('events.csv')` reads `~/Data/events.csv`.

| Statement | A relative path starts in |
|---|---|
| `read_csv`, `read_json`, `read_parquet`, `read_xlsx`, `FROM 'file'`, `COPY … FROM`, `glob()` | The database file's folder |
| `COPY … TO`, `ATTACH` | The root folder, which is read-only: use a full path |
| Any statement on an in-memory database | The root folder: use full paths |

A folder whose name has a comma gets no relative reads, because DuckDB splits the setting at commas.

Load More and Load All read the file again for each page. For a large file you query often, make a table from it first.

## Make a table from a file

**Query > New Table from File…** copies a CSV, JSON, Parquet or Excel file into a new table. You can also choose **New Table from File…** on a schema row, or on empty space, in the Database Navigator, or drop the file on the Database Navigator.

1. Choose the file (a dropped file needs no panel).
2. Type the table's name. The default comes from the file name, for example `sales_2024_q1`.
3. Pharos adds two cards and runs them:
   - `CREATE TABLE "main"."sales_2024_q1" AS FROM read_csv('/Users/you/Data/Sales 2024-Q1.csv')`
   - `SELECT * FROM "main"."sales_2024_q1" LIMIT 100`

For a CSV file, the NULL text and the encoding in **Settings > Export & Import** apply. The first card is ordinary SQL: edit it to set reader options such as `delim` or `header`, or to make a view instead. Pharos never replaces a table: when the name is in use, DuckDB says so. A CSV dropped on an existing table still opens **Import Data…** for that table.

## Keep a result

On a DuckDB tab, the result's **Export** popover has three more items below the formats:

| Item | What it does |
|---|---|
| **Export All Rows as Parquet…** | Adds a card `COPY (<query>) TO '<file>' (FORMAT parquet, COMPRESSION zstd)` after the result's card and runs it. |
| **Export All Rows as Excel…** | The same, with `(FORMAT xlsx, HEADER true)`. |
| **Save Result as Table…** | Adds a card `CREATE TABLE "main"."<name>" AS <query>`. Edit the name, then run it. |

These run the query again on the tab's own connection, so its temporary tables apply, and they write every row, not only the loaded rows. Grid filters, sort and tags do not apply. The formats above them (CSV, JSON and the others) write the rows the grid has loaded.

## What differs from PostgreSQL

| | PostgreSQL | DuckDB |
|---|---|---|
| Default schema | `public` | `main` |
| Other attached databases | — | Shown as `database.schema` in the schema browser |
| Cancel and the query timeout | Server cancel | DuckDB's interrupt. A statement the interrupt cannot reach (for example an ATTACH whose PostgreSQL server never answers) is left running in the background after 2 s; the card ends, and the tab gets a new connection, so its temporary tables and settings are gone. |
| Exports (Export Data…, Export as Parquet…, Shortcuts) | No time limit | No time limit |
| A card that fails inside a transaction | Undone alone (savepoint) | DuckDB has no savepoints: an error while a statement runs, or Cancel, fails the whole transaction (a syntax error does not). Roll it back from the transaction chip, whose help says so. |
| Editor-tab connections per connection | Limited by **Settings > Connections** | No limit: each tab always has its own connection |
| Idle-transaction timeout | Set by the server | None |
| Editing result cells | Yes | No |
| Explain | PostgreSQL's plan | DuckDB's plan, with row counts and timings but no costs |
| Partitions, automatic ANALYZE | Yes | No (DuckDB keeps row counts itself) |
| Export | CSV, TSV, JSON, JSON Lines, SQL, Markdown, XLSX | The same, and Parquet: **Export as Parquet…** in the schema browser, or **Parquet** in the **Export Data…** sheet with the columns you choose |

Cells show DuckDB's own text for every type, including lists (`[1, 2]`), structs (`{'a': 1}`) and maps.

## Extensions

These DuckDB extensions are built into Pharos. You do not install or load them; DuckDB loads each one the first time a query needs it.

| Extension | What it gives you |
|---|---|
| `core_functions` | DuckDB's standard functions and aggregates |
| `parquet` | `read_parquet`, `COPY … TO '/Users/you/x.parquet'` |
| `json` | The `JSON` type, `read_json`, JSON functions |
| `icu` | Time zones (`SET TimeZone`, `TIMESTAMPTZ`), collations, locale-aware dates |
| `inet` | The `INET` type (IPv4 and IPv6 addresses and networks), `host()`, `<<=` and `>>=` |
| `fts` | Full-text search: `PRAGMA create_fts_index`, `match_bm25` |
| `excel` | `read_xlsx`, `COPY … TO '/Users/you/x.xlsx'`, Excel number formats |
| `sqlite_scanner` | `ATTACH '/Users/you/file.sqlite' (TYPE sqlite)`, `sqlite_scan` |
| `httpfs` | `read_csv`, `read_parquet` and `read_json` over `https://`, `s3://`, `gcs://` and `r2://` |
| `postgres_scanner` | `ATTACH` a PostgreSQL database, `postgres_query` (see **Attach a PostgreSQL connection**) |
| `autocomplete` | `sql_auto_complete` |

`SELECT * FROM duckdb_extensions()` shows these with the install path `(BUILT-IN)`.

{: .note }
Pharos does not download extensions. macOS lets the app load only the libraries it shipped with, so an extension that is not in the list above (for example `spatial`) is not available.

**Settings > Connections > DuckDB** sets the worker threads and the memory limit. A database reads these settings when it opens. To change an open database, run `SET memory_limit = '4GB'` or `SET threads = 4` in a card. Each open database has its own limit, so several open databases can use more memory in all.

Work larger than the memory limit spills to disk: for a database file into `<file>.tmp` beside it, and for an in-memory database into its own folder in the system's temporary folder. DuckDB removes the folder when the database closes.

## Summarize a table

On a DuckDB table row in the Database Navigator, choose **Summarize**. A card runs `SUMMARIZE "main"."sales"`: one row per column, with its type, smallest and largest value, the number of distinct values, the share of NULLs and the quartiles.

On a table of an attached PostgreSQL database, **Copy to main…** asks for a name, then runs `CREATE TABLE "main"."<name>" AS SELECT * FROM <the table>` as a card, so the copy has the card's Cancel and progress.

## View definitions

On a DuckDB view row in the Database Navigator, choose **View Definition…** (or double-click the row when **Settings > Navigator > Double-click** is set to Describe). The sheet shows the `CREATE VIEW` statement with **Copy DDL**. **Copy into Table…** makes a table with the view's rows.

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

The Database Navigator then shows the PostgreSQL schemas as `name.schema`, after the DuckDB file's own schemas. As on a PostgreSQL connection, it hides `pg_toast` and the temporary schemas unless system schemas are shown. The tables of an attached PostgreSQL database show no row count, because DuckDB does not get a count from PostgreSQL. When the tab shows one schema only, the attached schemas follow its tables. Query them as `name.schema.table`, for example `SELECT * FROM live_analysis.public.events e JOIN read_csv('events.csv') c USING (id)`.

- Pharos gives DuckDB the password in a temporary secret. The password is not in any SQL text, in query history or on disk.
- A connection that uses an SSH tunnel attaches through that tunnel.
- The attach lasts while the PostgreSQL connection stays connected. When you disconnect it, Pharos detaches it from DuckDB. To detach it sooner, right-click one of its schemas and choose **Detach**.
- `verify-ca` and `verify-full` use the connection's SSL root certificate, or the certificates that macOS ships (`/etc/ssl/cert.pem`) when the connection has none. Certificates you added to the Keychain are not used.

## Cloud storage (S3, R2, GCS)

To read `s3://`, `r2://` or `gcs://` paths, add a credential in **Settings > Connections > DuckDB > Cloud storage credentials**:

1. Click **+**.
2. Type a name, choose the provider, and type the key ID and the secret key.
3. For S3, type the region. For S3-compatible storage such as MinIO, also type the endpoint. For Cloudflare R2, type the account ID.
4. Optional: type a scope, for example `s3://my-bucket`, so the credential applies to that bucket only. With no scope, it applies to every path of the provider.
5. Click **Save**.

Pharos keeps the secret key in the Keychain. Each DuckDB database gets every credential as a temporary secret when it opens, and a database that is open gets a changed credential at once. Then `SELECT * FROM read_parquet('s3://my-bucket/sales/*.parquet')` works with no `CREATE SECRET` card.

A public file, or a presigned `https://` link, needs no credential.

## Secrets

DuckDB secrets (for example S3 keys for `httpfs`) live in memory only: use `CREATE SECRET`, not `CREATE PERSISTENT SECRET`. DuckDB writes a persistent secret to disk in plain text, so Pharos refuses it. Pharos also does not load secrets that other DuckDB tools saved in `~/.duckdb/stored_secrets`.

Query history replaces passwords and keys in SQL text with `'********'`, for `CREATE SECRET` and for the older `SET s3_secret_access_key = '…'` form. But a card's own text is kept as you typed it: relaunch restore and saved Sessions keep a `CREATE SECRET` card in plain text. Use **Cloud storage credentials** in Settings instead, or delete the card after it runs.
