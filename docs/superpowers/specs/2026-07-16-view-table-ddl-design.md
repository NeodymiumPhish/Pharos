# View Table DDL — Design

**Date:** 2026-07-16
**Status:** Approved (design), pending implementation plan

## Summary

Replace the Database Navigator's `"Clone Table DDL…"` table context-menu item with
`"View Table DDL…"`, which opens a modal (modeled on the results pane's "View SQL
Query" modal) showing the target table's reconstructed `CREATE TABLE` DDL. The modal
lets the user:

- Switch the **level of detail** shown via a left sidebar (columns → + constraints →
  + indexes), updating the read-only text box live.
- **Copy** the currently-shown DDL to the clipboard.
- **Clone the table** via an inline disclosure (new name + "Include table rows"),
  using the existing `LIKE … INCLUDING ALL` clone path unchanged.

This subsumes the old clone menu item: cloning is now reachable from inside the DDL
modal rather than as its own menu entry / sheet.

## Motivation

Today the only table-structure affordance is `"Clone Table DDL…"`, which opens
`CloneTableSheet` and clones via `CREATE TABLE … (LIKE … INCLUDING ALL)` — Postgres
does the copy internally and the app never materializes a readable DDL string. There
is **no way to view a table's actual `CREATE TABLE` DDL** in the app. This feature
adds that (the common "show me the schema" need) while keeping clone one click away.

## Non-Goals

- No editing of the displayed DDL (it is read-only). Clone does **not** run the
  displayed text; it uses the existing structured `LIKE … INCLUDING ALL` path. This
  deliberately avoids the constraint/index name-collision problem that running
  reconstructed DDL verbatim into the same schema would cause.
- No ownership, grants/privileges, table/column comments, storage parameters,
  tablespace, partitioning DDL, or triggers in the reconstructed output (v1 scope).
- No schema retargeting on clone (unchanged from today — clone stays in the source
  schema; only the table name is user-configurable).
- No new menu item for partitions beyond what they get today; existing partition
  exclusions in `SchemaContextMenu` are preserved.

## User Experience

Right-click a table in the Database Navigator → **View Table DDL…**. A sheet opens:

```
┌ Table DDL — public.orders ───────────────────────┐
│ ┌───────────────┐ ┌────────────────────────────┐ │
│ │ Columns       │ │ CREATE TABLE "public"....   │ │
│ │ + Constraints │ │   id  bigint ...            │ │  ← read-only,
│ │ Full (+Index) │ │   ...                       │ │    monospaced
│ └───────────────┘ └────────────────────────────┘ │
│  [Copy DDL]                         [Clone Table] │
│  ── (clone section, hidden until clicked) ──      │
│  New table name: [orders_copy]  ☐ Include rows    │
│                               [Cancel] [Clone]    │
│                                          [Done]   │
└───────────────────────────────────────────────────┘
```

- **Left sidebar** — single-select list of cumulative detail levels. Selecting one
  swaps the text-box content instantly (no DB round-trip):
  1. **Columns** — `CREATE TABLE` with column definitions only (type via
     `format_type`, `DEFAULT`, `NOT NULL`, identity/generated).
  2. **+ Constraints** — adds `PRIMARY KEY`, `UNIQUE`, `CHECK`, and `FOREIGN KEY`
     (via `pg_get_constraintdef`), rendered inline in the `CREATE TABLE` body.
  3. **Full (+ Indexes)** — everything above plus `CREATE INDEX` statements for
     non-constraint indexes (via `pg_get_indexdef`).
- **Text box** — read-only, monospaced, scrollable (same treatment as
  `QueryDetailSheet`'s SQL view).
- **Copy DDL** — copies the currently-shown level's text to the general pasteboard;
  briefly flashes the button title to "Copied!" (mirrors
  `QueryDetailSheet.copyQuery`).
- **Clone Table** — a disclosure button. When clicked, reveals an inline section
  (growing the sheet):
  - **New table name** field, defaulting to `<table>_copy`.
  - **Include table rows** checkbox, default **off**.
  - **Clone** button (and Cancel to collapse the section).
  - On Clone: calls the existing `PharosCore.cloneTable` (structured
    `LIKE … INCLUDING ALL`, plus `INSERT … SELECT` when rows are included). On
    success: dismiss the sheet, show the existing success alert, and reload the
    navigator (`contextMenuDidRequestReload`). On failure: existing error alert.
- **Done** — dismisses the sheet.

Default selected level on open: **Full (+ Indexes)** (the most complete view).

## Architecture

### Menu (`Pharos/ViewControllers/SchemaBrowser/SchemaContextMenu.swift`)

- Replace the `"Clone Table DDL…"` `NSMenuItem` (currently at ~line 391, action
  `contextCloneTable`) with `"View Table DDL…"` → new action `contextViewTableDDL`,
  in the same "Data operations" group / position.
- Remove `contextCloneTable` (and its use of `CloneTableSheet`). Clone is now driven
  from inside the new modal.
- `contextViewTableDDL` resolves the clicked node's connection id / schema / table
  (same guards as the existing handlers), fetches the DDL via
  `PharosCore.generateTableDDL`, constructs `TableDDLSheet`, and presents it via
  `delegate?.contextMenuPresentSheet`.

### Modal (`Pharos/Sheets/TableDDLSheet.swift`, new)

- `NSViewController` modeled on `QueryDetailSheet`.
- Inputs: `schema`, `table`, the fetched `TableDDL` (three variants), a
  connection id, and callbacks for clone (success/failure/reload) — wired the same
  way the current `contextCloneTable` wires its clone callback.
- Left sidebar: a small single-select `NSTableView` (or equivalent source list) with
  the three level rows; selection swaps the text view's `string` to the matching
  variant. No re-query — all three variants come from the single fetch.
- Read-only `NSTextView` in a scroll view (reuse `QueryDetailSheet`'s configuration).
- Clone disclosure section built with the same controls/logic as today's
  `CloneTableSheet` (name field default `<table>_copy`, checkbox default off),
  relabeled "Include table rows", shown/hidden on demand.

### DDL generation (Rust)

- `pharos-core/src/commands/table.rs`: new `generate_table_ddl(connection_id: String,
  schema: String, table: String, state: &AppState) -> Result<TableDdl, String>`.
  - Validate identifiers (reuse `validate_identifier`).
  - Query columns, constraints, and indexes from `pg_catalog`, reusing the query
    patterns already present in `pharos-core/src/db/postgres.rs` (`format_type`,
    `pg_get_constraintdef`, `pg_get_indexdef`; the internal `"char"` columns must be
    cast `::text` per the known sqlx decode gotcha).
  - Compose the **three ready-to-display variants** so the Swift side never has to
    assemble SQL and sidebar clicks need no round-trip:
    - `columns_only` — `CREATE TABLE` with column defs only.
    - `with_constraints` — columns + inline constraints.
    - `full` — `with_constraints` + `CREATE INDEX` statements (indexes that back a
      constraint, e.g. the PK/unique index, are excluded to avoid duplication).
  - Return struct `TableDdl { columns_only, with_constraints, full }`
    (`#[serde(rename_all = "camelCase")]`).
- `pharos-core/src/ffi/table_ops.rs` (or `table_metadata.rs`, matching where the
  read-vs-mutate split lives): new `#[no_mangle] pub extern "C" fn
  pharos_generate_table_ddl(...)` following the established `ffi_spawn!` +
  `callback_ok`/`callback_err` pattern; takes connection id / schema / table as C
  strings (read-op style, like the metadata FFIs).
- `cargo build --release` regenerates the C header via cbindgen.

### Swift FFI wrapper & model

- `Pharos/Core/PharosCore+TableMetadata.swift` (read op): new
  `static func generateTableDDL(connectionId:schema:table:) async throws -> TableDDL`
  following the `getTableIndexes` / `getTableConstraints` wrapper pattern.
- `Pharos/Models/`: new `TableDDL` model (`columnsOnly`, `withConstraints`, `full`),
  `Codable`, matching the Rust camelCase JSON.

## Data Flow

1. User right-clicks table → **View Table DDL…**.
2. `contextViewTableDDL` → `await PharosCore.generateTableDDL(...)` → one FFI call →
   Rust `generate_table_ddl` → returns `{ columnsOnly, withConstraints, full }`.
3. `TableDDLSheet` presented; default level **Full** shown.
4. Sidebar selection swaps the text view content (in-memory, no FFI).
5. Copy DDL → pasteboard.
6. Clone Table disclosure → name + include-rows → `PharosCore.cloneTable` (existing
   path) → success alert + navigator reload.

## Error Handling

- DDL fetch failure: show the existing error-alert pattern and do **not** open the
  sheet.
- Clone failure: existing `showErrorAlert(title: "Clone Failed", …)`.
- Clone success: existing success alert + `contextMenuDidRequestReload`.
- Tables with no indexes/constraints: the corresponding variant simply omits those
  sections; "Columns" is always present.

## Testing

- **Rust:** unit tests for `generate_table_ddl` against a table exercising: an
  identity/serial column, a composite `PRIMARY KEY`, a `FOREIGN KEY`, a `CHECK`
  constraint, a `NOT NULL` + `DEFAULT` column, and a secondary (non-constraint)
  index. Assert each of the three variants contains exactly the expected sections
  (e.g. `columns_only` has no `CONSTRAINT`/`CREATE INDEX`; `with_constraints` has
  constraints but no `CREATE INDEX`; `full` has both, and does not duplicate the
  PK/unique index as a separate `CREATE INDEX`).
- **Swift:** standalone `swiftc` harness (project has no Xcode test target) covering
  `TableDDL` decoding and the sidebar-selection → text-swap logic. Watch the
  `main.swift` shim gotcha and register any new files with `xcodegen`.

## Open Questions

None. (Scope, edit-ability, clone behavior, and the sidebar interaction are all
settled per the brainstorming session.)
