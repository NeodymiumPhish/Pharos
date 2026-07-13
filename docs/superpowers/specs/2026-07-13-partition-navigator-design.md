# Partition-Aware Database Navigator — Design

**Date:** 2026-07-13
**Status:** Approved for planning
**Area:** Schema browser (sidebar navigator), `pharos-core` metadata, tree rendering, inspector

## Problem

PostgreSQL declaratively partitioned tables render poorly in the Database Navigator:

- The `get_tables` SQL filters `relkind IN ('r','v','m','f')`, which **excludes partitioned parents** (`relkind='p'`). The logical parent table (e.g. `events`) never appears.
- Every **leaf partition** (`relkind='r'`) appears as an ordinary flat, alphabetical sibling. A table split into 60 monthly partitions floods the list with `events_2024_01 … events_2029_12`, and alphabetical order mis-sorts them (`events_2024_1` vs `events_2024_10`).
- Users must lean on the filter input just to see the distinct logical tables in a schema.

There is currently **zero** partition awareness anywhere in the codebase.

## Goal

Present partitioned tables parent-first. The logical parent leads; individual partitions are tucked into a collapsible group, discoverable but out of the main flow. Users rarely work with individual partitions, so the parent is the star.

## Non-Goals

- Partition management actions (create/detach/attach/drop partitions). Partitions remain real tables and keep existing table actions (query, view data, export); no new maintenance verbs.
- Changing how non-partitioned tables/views render.

## Design Decisions (resolved during brainstorming)

1. **Layout:** Parent table node → expands into a single **"Partitions (N)"** group plus the normal **Columns**. Collapsed by default. (Chosen over "hide partitions entirely" and "nest leaves directly among columns".)
2. **Partition ordering:** Default to **bound order**, with a **sort toggle** (bound / name / size) on the Partitions group.
3. **Node detail:** **Rich** density — bounds shown inline on leaves, strategy + key on the parent.
4. **Parent aggregate:** Parent row shows aggregate **rows and size** summed across its partitions.
5. **Filter:** Searches parent + partition names, but keeps the Partitions group **collapsed**, showing a **hit-count badge** on the parent.
6. **Sub-partitioning:** **Recursive nesting** — a partition that is itself partitioned expands into its own Partitions group.
7. **Inspector:** **In scope** — partition/partitioned-table detail surfaces in the inspector panel.

## Approach

Backend-driven: PostgreSQL reports the partition graph via `pharos-core`; Swift builds the grouping from a richer model. (Rejected: Swift-side inference from name prefixes — unreliable, can't obtain bounds/strategy.)

---

## Component Design

### 1. Backend model & query (`pharos-core`)

**`pharos-core/src/models/schema.rs`**

- `TableType` gains a `PartitionedTable` variant (maps `relkind='p'`). Leaf partitions retain their underlying type (`Table`/`ForeignTable`) and are flagged via `is_partition`.
- `TableInfo` gains:
  - `is_partitioned: bool` — this relation is a partitioned parent (`relkind='p'`).
  - `is_partition: bool` — this relation is itself a partition of some parent (`relispartition`).
  - `partition_strategy: Option<PartitionStrategy>` — `Range | List | Hash` (from `pg_partitioned_table.partstrat`), present when `is_partitioned`.
  - `partition_key: Option<String>` — human-readable key expression, e.g. `created_at` (from `pg_get_partkeydef`).
  - `parent_table: Option<String>` — parent relation name when `is_partition` (from `pg_inherits.inhparent`).
  - `partition_bound: Option<String>` — this partition's bound text from `pg_get_expr(relpartbound, oid)`, or the literal `"DEFAULT"` for a default partition.
  - `partition_count: Option<i64>` — number of direct child partitions when `is_partitioned`.

New enum `PartitionStrategy { Range, List, Hash }` (serde-serialized to match Swift model).

**`pharos-core/src/db/postgres.rs` — `get_tables`**

- Add `'p'` to the `relkind` filter so partitioned parents appear.
- LEFT JOIN `pg_partitioned_table` for `partstrat` and `pg_get_partkeydef(c.oid)` for the key expression.
- Determine `relispartition` and, when true, resolve the parent name via `pg_inherits` (`inhrelid = c.oid → inhparent`).
- Compute `partition_bound` via `pg_get_expr(c.relpartbound, c.oid)`.
- For partitioned parents, aggregate `reltuples` and `pg_total_relation_size` across descendant leaves (parents report ~0 on their own). Use `pg_partition_tree(parent)` where available (PG ≥ 12; the app targets modern PG) to sum leaf sizes/rows, or a recursive `pg_inherits` CTE as the portable path.
- Compute `partition_count` = number of direct children in `pg_inherits`.
- The `information_schema` fallback path (non-PG-compatible servers) leaves the new fields `None`/`false` — those servers degrade to today's flat behavior gracefully.

**Behavior change (the core fix):** Leaf partitions are **excluded from the flat top-level table list**. They are returned only when fetching the partitions of a given parent. Two shapes are acceptable and left to planning:
  - (a) `get_tables` returns only non-partition relations (regular tables, views, partitioned parents); a new `get_partitions(parent)` call lazily fetches a parent's direct children; **or**
  - (b) `get_tables` returns everything with the flags, and Swift filters/groups.
  Preference: **(a)** — keeps lazy loading server-side and scales to thousands of partitions. `get_partitions` returns direct children only (recursion happens one level per expand).

### 2. Tree model (`Pharos/Models/SchemaTreeNode.swift`)

- New `Kind` cases:
  - `.partitionGroup(parent: TableInfo, count: Int)` — the "Partitions (N)" folder.
  - `.partition(TableInfo)` — a leaf (or sub-parent) partition.
- A `.table`/`.partitionedTable` node where `is_partitioned` is expandable into **[Partitions group] + [Columns]** (group listed first).
- `isExpandable`:
  - partitioned parent → true (has Partitions group + columns).
  - `.partitionGroup` → true (has partition children).
  - `.partition` → true if it is itself partitioned (recursive), else expandable into its own columns like any table.
- **Lazy loading:** Partition group children load on group expand via `get_partitions(parent)`. The group is **never auto-expanded**, including under the existing `autoExpandTableThreshold = 500`. Recursion is one `get_partitions` call per expanded sub-parent.

### 3. Tree building, sort & filter (`SchemaBrowserVC.swift`, `SchemaBrowser/`)

- In `loadTablesForSchema` (currently `SchemaBrowserVC.swift:179-226`): the table/view split logic gains a partitioned-parent path. Partitioned parents sort among regular tables by name (existing alpha order for the top level is unchanged — the top level now contains only logical tables, which is the desired outcome).
- **Sort toggle:** The Partitions group owns an ordering mode (`bound` default / `name` / `size`), persisted per group (or per connection — planning detail). Applied when materializing the group's children:
  - `bound`: parse RANGE FROM value / LIST first value for comparison; fall back to name for HASH or when bounds tie/are absent.
  - `name`: `localizedCaseInsensitiveCompare`.
  - `size`: `total_size_bytes` descending.
- **Filter** (`filterNode`, `SchemaBrowserVC.swift:487-523`): extend matching to partition names. A parent whose partition matches stays visible with the group **collapsed** and a **hit-count badge** (e.g. "2 matches"). Regular table/view filtering is unchanged.

### 4. Rendering (`Pharos/Views/SchemaTreeCellView.swift` + `SchemaTreeNode` icon/subtitle)

Rich density, using the existing two-line cell (title 13pt + subtitle 10pt):

- **Partitioned parent:** distinct icon; strategy **badge** (`RANGE`/`LIST`/`HASH`) after the title; subtitle `by (<key>) · N partitions`; right-aligned aggregate `48.1M rows · 9.2 GB`.
- **Partitions group:** folder icon, title `Partitions`, muted count `(N)`; hosts the sort-toggle control (chips) and, under filter, the hit-count badge.
- **Partition leaf:** title = partition name; subtitle = bound expression (`[2024-01-01, 2024-02-01)`, `IN ('US','CA')`, `mod 4, rem 0`); right side `rows · size`. **DEFAULT** partition rendered muted and visually distinct.
- New badge styling is additive to the existing subtitle/glow infrastructure; the strategy badge reuses accent color conventions.

### 5. Inspector (`InspectorViewController.swift`)

- Selecting a **partitioned parent**: show strategy, partition key, partition count, aggregate rows/size, and a compact list of partitions with per-partition size.
- Selecting a **partition**: show parent, bound expression, strategy (inherited), rows/size, and whether it is a DEFAULT partition or itself sub-partitioned.
- Reuses existing inspector detail patterns; no new FFI beyond the enriched `TableInfo` (+ `get_partitions`).

---

## Data Flow

```
SchemaBrowserVC.loadTablesForSchema
  └─ PharosCore.getTables(schema)         → regular tables/views + partitioned parents (leaves excluded)
        parent node (is_partitioned) → build [Partitions group (lazy)] + [Columns (lazy)]
  User expands "Partitions (N)"
  └─ PharosCore.getPartitions(parent)     → direct child partitions (with bounds/size/rows)
        sorted by group's ordering mode (bound|name|size)
        a child that is_partitioned → itself gets a nested Partitions group (recursive)
  Selection → InspectorViewController renders partition/parent detail
```

## FFI / Wiring Checklist (per CLAUDE.md)

1. `pharos-core/src/commands/metadata.rs`: enrich `get_tables`; add `get_partitions(connection, schema, parent)`.
2. `pharos-core/src/db/postgres.rs`: updated SQL + aggregation + new partitions query.
3. `pharos-core/src/models/schema.rs`: `TableType::PartitionedTable`, `PartitionStrategy`, new `TableInfo` fields.
4. `pharos-core/src/ffi/schema.rs`: FFI wrapper for `get_partitions`.
5. `cargo build --release` to regenerate the C header (cbindgen).
6. `Pharos/Core/PharosCore+Schema.swift`: Swift wrapper for `getPartitions`; decode new `TableInfo` fields.
7. `Pharos/Models/`: extend `TableInfo`, add `PartitionStrategy`; extend `SchemaTreeNode.Kind`.
8. `Pharos/ViewControllers/SchemaBrowserVC.swift` (+ `SchemaBrowser/`): grouping, lazy partition load, sort toggle, filter.
9. `Pharos/Views/SchemaTreeCellView.swift`: badges, strategy/bound rendering, DEFAULT styling.
10. `Pharos/ViewControllers/InspectorViewController.swift`: partition detail.

## Edge Cases

- **HASH partitions:** no natural bound order → bound mode falls back to name; bound text shows `mod N, rem K`.
- **DEFAULT partition:** `partition_bound = "DEFAULT"`; rendered muted; sorts last in bound mode.
- **Sub-partitioning:** recursive one-level-per-expand; a sub-parent's aggregate rolls up its own descendants.
- **Huge partition counts (thousands):** group stays collapsed and lazy; only `partition_count` (a cheap COUNT) is needed for the parent badge until expanded.
- **Non-PG / information_schema fallback:** new fields empty; behaves like today (flat), no crash.
- **Foreign-table partitions:** a partition may be a foreign table; keep its foreign icon while tagging `is_partition`.

## Testing

Per the project's standalone `swiftc` harness (no Xcode test target):

- **Rust:** unit-test the partition query against a fixture PG with RANGE/LIST/HASH, a DEFAULT partition, and a two-level sub-partition; assert flags, bounds text, aggregate rows/size, and `partition_count`.
- **Swift model:** given a `TableInfo` set, assert tree assembly produces parent → [Partitions group + Columns], correct recursion, and that leaves are excluded from the top level.
- **Sort:** assert bound/name/size ordering, including the `2024_1` vs `2024_10` case and DEFAULT-sorts-last.
- **Filter:** assert a partition-name match keeps the parent visible, group collapsed, with a hit-count badge.
- **Manual (per /verify):** connect to a partitioned DB, confirm parent-first rendering, expand/recurse, toggle sort, filter, and inspector detail.

## Open Questions (none blocking)

All major decisions resolved during brainstorming. Persistence granularity of the sort toggle (per-group vs per-connection) is a planning-time detail.
