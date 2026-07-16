# Workspace History — Design Spec

**Date:** 2026-07-16
**Status:** Approved (design), pending implementation plan
**Component:** Query History (Rust `pharos-core` + Swift `QueryHistoryVC` and query-execution path)

## Problem

Pharos logs every executed query as its own item in the Results History sidebar.
Users tend to work a single analysis or research topic in one editor tab over time,
running many related queries. The flat, one-row-per-query list makes it hard to find
a specific result set — you scroll through hundreds of near-identical rows with no
sense of which analysis they belonged to.

## Goal

Log an entire **workspace** — one editor tab's working session, including its editor
text, its variables, and every result tab it produced — as a single history item.
Users scan a compact list of workspaces, drill into one to find a specific result,
and reopen a whole analysis (editor + variables + all results) to continue or review.

## Definitions

- **Workspace** — the persisted record of one editor tab's working session. Holds the
  tab's current editor text, its `QueryVariable` set, and an ordered list of result
  tabs (one per executed query segment).
- **Result** (child) — one executed query within a workspace: its SQL, cached result
  columns/rows (when within budget), row count, timing, table names, schema, and the
  display metadata of its result tab (order, color index, custom label).
- **Legacy entry** — an existing `query_history` row created before this feature, with
  no workspace association. Surfaced under a collapsed "Earlier history" section.

## Design Decisions (locked)

1. **Capture model — live per-tab rolling record.** Each editor tab owns one workspace
   record. The record is created lazily on the *first query execution* in that tab
   (empty tabs never create records). As queries run, each result is appended to the
   same record and the editor-text + variables snapshot is refreshed in place. The
   record finalizes when the tab closes or the app quits.

2. **Auto-naming.** If the user has not manually named the tab, the workspace name is
   the name of the **first database queried**. If queries in the same workspace ran
   against more than one database, the name is `"<first db> +N"` where N is the count
   of *additional* distinct databases. A manual rename sets `name_is_custom = true` and
   permanently overrides auto-naming. **"Database" is sourced from the connection's
   `connection_name`** (what history already stores); this is the pragmatic choice and
   may later be swapped for the literal database name from the connection config.

3. **Result-data persistence.** Persist all result data (gzip, as today). Per-result
   cap raised from **5 MB → 10 MB** (measured on serialized `columns_json + rows_json`,
   matching the existing check). Add a **100 MB per-workspace budget**. When adding a
   result would exceed the budget, the oldest results in that workspace demote to
   **"SQL only"** — their blob is dropped but the row (SQL + metadata) is kept and still
   listed. Demoted results re-run on demand against the live connection.

4. **Reopen — resume the same record.** Reopening binds the workspace to a live editor
   tab and *continues the same record*: new queries append to it; it stays one evolving
   analysis across sessions. Viewing/scrolling changes nothing — only executing a query
   appends. A separate **Duplicate workspace** action forks a full copy (new id) for
   safe branching.

5. **Legacy coexistence — "Earlier history" section.** New workspaces appear at the top
   of the sidebar. Existing per-query rows (`workspace_id IS NULL`) appear in a
   clearly-labeled, collapsed "Earlier history" section (the current flat list, still
   searchable). They age out naturally at 90 days. No fabricated grouping.

6. **Sidebar layout — flat list + preview pane (Layout B).** The history tab is a
   compact flat workspace list plus a preview pane pinned at the bottom that reveals the
   selected workspace's result tabs. Single-click selects a workspace and populates the
   preview pane.

7. **Open behavior — double-click restores the full workspace.** Double-click a
   workspace row → restore editor text + variables + all result tabs into a live editor
   tab, focused on the last-active result. Double-click a result in the preview pane →
   same restore, focused on that result. If the workspace is already open, just focus
   its existing tab.

## Data Model / Storage (Rust + SQLite)

Reuse the existing `query_history` table as the **per-result child store** — each
executed query remains one row, preserving today's result-blob caching, timing,
`table_names` extraction, FTS indexing, and delete paths.

### New table: `workspaces`

| column | type | notes |
| --- | --- | --- |
| `id` | TEXT PK | UUID |
| `name` | TEXT NULL | NULL ⇒ render from auto-name rule |
| `name_is_custom` | INTEGER (bool) | manual rename latch |
| `connection_id` | TEXT | first queried connection |
| `connection_name` | TEXT | first queried db name (auto-name source) |
| `queried_connection_count` | INTEGER | distinct connections queried (for `+N`) |
| `editor_text` | TEXT | latest editor buffer snapshot |
| `variables_json` | TEXT | serialized `[QueryVariable]` |
| `cursor_position` | INTEGER NULL | restore caret |
| `created_at` | TEXT | ISO 8601 |
| `last_activity_at` | TEXT | ISO 8601; drives retention + sort |

Index: `idx_workspaces_last_activity` on `last_activity_at`.

### New columns on `query_history`

| column | type | notes |
| --- | --- | --- |
| `workspace_id` | TEXT NULL | FK → `workspaces.id`; **NULL = legacy** |
| `result_order` | INTEGER NULL | ordering of result tabs within a workspace |
| `color_index` | INTEGER NULL | result-tab color palette index |
| `custom_label` | TEXT NULL | user-renamed result-tab label |

Index: `idx_query_history_workspace` on `workspace_id`.

### Budget enforcement

- Per-result cap: 10 MB on serialized `columns_json + rows_json` (else save row with
  no blob, `has_results = false`).
- Per-workspace budget: 100 MB of stored (compressed) blob across the workspace's
  children. On insert, if the new total would exceed 100 MB, drop blobs from the
  oldest children (by `result_order` / `executed_at`) until under budget; those rows
  remain as "SQL only."

### FTS

Extend search to index workspace `name` + `editor_text` in addition to the existing
per-query `sql` (+ `connection_name`). A workspace matches a query if its name, its
editor buffer, or any child query's SQL matches. Preserve existing FTS behavior for
legacy rows and the current FTS-failure fallback path.

### Retention

90-day prune keyed on workspace `last_activity_at` (cascades to child rows). Legacy
rows (`workspace_id IS NULL`) prune on their own `executed_at` as today. Keep the
"prune roughly every 100 inserts" cadence.

### Migration (non-destructive)

Add `workspaces` table + indices; add the four columns to `query_history` (all
nullable). Existing rows keep `workspace_id = NULL` and render under "Earlier history."
No data is moved or dropped.

## Capture & Lifecycle

- **Swift owns workspace identity.** On the first execute in a tab, Swift calls
  `upsert_workspace` to create the record and stores the returned id on `QueryTab`
  (new field, e.g. `workspaceId`).
- Each execute passes `workspace_id` + result-tab metadata (`result_order`,
  `color_index`) into the execute command so the child row is stamped and ordered, and
  refreshes the workspace snapshot (`editor_text`, `variables_json`,
  `queried_connection_count`, `last_activity_at`). The live editor buffer is available
  at execute time.
- Tab close / app quit flushes a final `editor_text` (+ variables + cursor) snapshot
  via `upsert_workspace`.
- Result-tab display changes made after execution (rename a result tab, recolor) call
  `update_result_meta` to persist `custom_label` / `color_index`.

## Sidebar UI (`QueryHistoryVC`, Layout B)

Structure top→bottom:

1. **Search field** — placeholder "Search name, SQL, editor text…"; filters via FTS.
2. **Workspace list** (`NSTableView`, scrollable). Each row (two-line cell):
   - Line 1: `📊 <name>` (auto or custom).
   - Line 2: `"<N> queries · <relative time> · <db>"` where db is `connection_name`
     or `"<db> +N"`.
   - Multi-select enabled (for delete), like today.
3. **"Earlier history" section** — collapsed disclosure row (`▸ Earlier history (count)`)
   that expands to the legacy flat list (current two-line cells). Still searchable.
4. **Preview pane** (bottom, draggable divider, remembers height). Shows the selected
   workspace's result tabs:
   - Header: `<WORKSPACE NAME> — <N> RESULTS` + budget hint.
   - Rows: color dot + SQL snippet (or custom label) + row count, or a "SQL only" badge
     for demoted results.

### Interactions

- Single-click workspace → select + populate preview pane.
- Double-click workspace → restore full workspace (see Reopen).
- Double-click preview result → restore full workspace, focus that result.
- Workspace context menu: **Rename**, **Duplicate**, **Delete** (cascades). Multi-select
  → "Delete N Workspaces" with confirmation (mirrors current batch-delete UX).
- Preview-result context menu: **Delete this result**, **Copy SQL**.
- Auto-reload on `.queryHistoryDidChange` (and a new `.workspaceHistoryDidChange` if a
  distinct signal is cleaner); off-main-thread load with the existing generation-counter
  staleness guard.

## Reopen / Restore

`handleOpenWorkspace(id, focusResultId?)` in `ContentViewController`:

1. If a live editor tab is already bound to `workspace_id`, focus it and (if
   `focusResultId`) select that result tab. Done.
2. Else call `load_workspace(id)` → editor text, variables, cursor, ordered result-tab
   metadata.
3. Create a new editor tab in the focused pane, set `sql`/`variables`/`cursorPosition`,
   set `QueryTab.workspaceId = id` (so subsequent executes resume the same record).
4. Rebuild the `ResultTab` array from the metadata; each result lazily fetches its blob
   via `get_query_history_result` (existing) when first shown. Cached results carry
   their original `historyTimestamp` and a stale marker; "SQL only" results show a
   re-run affordance.
5. Focus `focusResultId` if given, else the most recent result (highest `result_order`).

Reuses the existing per-editor-tab result-tab archive in `ContentViewController`
(`resultTabsByEditorTab`), now seeded from persisted metadata.

## FFI Surface (new)

New commands in `pharos-core/src/commands/` (likely a new `workspace.rs` or extending
`query_history.rs`) + FFI wrappers + Swift wrappers (`PharosCore+Workspaces.swift`):

- `upsert_workspace(workspace_json) -> workspace_id` — create/update name, editor_text,
  variables, connection, counts, last_activity.
- `load_workspaces(filter) -> [WorkspaceSummary]` — id, name(resolved), query count,
  last_activity, connection label, budget usage; honors search + limit/offset.
- `load_workspace(id) -> Workspace` — editor_text, variables, cursor, ordered
  `[ResultMeta]` (result id, sql, order, color_index, custom_label, row_count,
  has_results/demoted, timestamp).
- `rename_workspace(id, name)`, `duplicate_workspace(id) -> new_id` (copies workspace +
  children + blobs), `delete_workspace(id)` (cascade), `delete_workspace_result(result_id)`.
- `update_result_meta(result_id, custom_label?, color_index?)`.
- Execute commands (`execute_query`, `execute_statement`) gain optional
  `workspace_id`, `result_order`, `color_index` params; when present the child row is
  stamped and budget enforcement runs.

Follow the repo's add-command workflow: command → FFI → `cargo build --release`
(regenerates the C header via cbindgen) → Swift wrapper → Swift models.

## Swift Models

- `QueryTab`: add `workspaceId: String?`.
- New `Workspace` / `WorkspaceSummary` / `WorkspaceResultMeta` Codable models in
  `Pharos/Models/`.
- Reuse `QueryVariable`, `ResultTab`, `QueryResult`, `ColumnDef`, `AnyCodable`.

## Testing & Verification

- **Rust unit tests:** budget enforcement (demotion order), auto-name resolution
  (single vs multi-db `+N`), cascade delete, duplicate.
- **SQL→struct decode seam (mandatory live-Postgres pass):** per repo lesson, pure
  composer tests miss decode bugs. Assert that workspace + result rows round-trip from a
  real query result — new nullable columns, bool `name_is_custom`, JSON `variables_json`
  — not from hand-built structs.
- **Swift harness:** standalone `swiftc` scripts for `QueryHistoryVC` list + preview
  pane rendering, restore mapping (metadata → `ResultTab[]`), and auto-name display.
- **End-to-end (`/verify`):** run several queries in one tab → confirm a single
  workspace with ordered results; rename; close + reopen → editor text, variables, and
  all result tabs restore; exceed budget → oldest demote to "SQL only" and re-run;
  legacy rows appear under "Earlier history"; search matches name/editor-text/child-SQL.

## Out of Scope (YAGNI)

- Cross-device sync / export of workspaces.
- Manual drag-reordering or merging of workspaces.
- Diffing result sets across re-runs.
- Restoring multi-pane layout (restore lands in a single editor tab in the focused pane).
