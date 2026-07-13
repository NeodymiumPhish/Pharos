# Partition-Aware Database Navigator Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Render PostgreSQL declaratively partitioned tables parent-first in the Database Navigator — the logical parent leads with a strategy badge and aggregate size, and its partitions live in a collapsible, bound-ordered "Partitions" group instead of flooding the flat table list.

**Architecture:** Backend-driven. `pharos-core` reports the partition graph: `get_tables` includes partitioned parents (`relkind='p'`) and *excludes* leaf partitions from the flat list, while a new lazy `get_partitions(parent)` call fetches a parent's direct children (with bounds/size). A lightweight `get_partition_map(schema)` fetches parent→child names once per schema so the filter can match partition names without eagerly loading full detail. Swift builds the grouped tree, sorts partitions via pure testable helpers, and renders the Rich cell layout.

**Tech Stack:** Rust (`sqlx`, `serde`, cbindgen FFI), Swift/AppKit (`NSOutlineView`), standalone `swiftc` test harness (no Xcode test target), Rust `cargo test` for pure helpers.

---

## File Structure

**Rust (`pharos-core/`)**
- `src/models/schema.rs` — MODIFY: `TableType::PartitionedTable`, new `PartitionStrategy` enum, new `TableInfo` fields, new `PartitionRef` struct.
- `src/db/postgres.rs` — MODIFY: `get_tables` SQL; ADD `get_partitions`, `get_partition_map`.
- `src/commands/metadata.rs` — ADD command wrappers `get_partitions`, `get_partition_map`.
- `src/ffi/schema.rs` — ADD FFI `pharos_get_partitions`, `pharos_get_partition_map`.

**Swift (`Pharos/`)**
- `Models/Schema.swift` — MODIFY: `TableType.partitionedTable`, `PartitionStrategy`, `TableInfo` fields, `PartitionRef`.
- `Models/PartitionOrdering.swift` — CREATE: pure sort logic (bound/name/size). Testable.
- `Models/PartitionDisplay.swift` — CREATE: pure display formatting (key columns, bound summary, badge text). Testable.
- `Models/SchemaTreeNode.swift` — MODIFY: `.partitionGroup` / `.partition` kinds; icon/subtitle/badge/isExpandable.
- `Core/PharosCore+Schema.swift` — MODIFY: `getPartitions`, `getPartitionMap` wrappers.
- `ViewControllers/SchemaBrowserVC.swift` (+ `SchemaBrowser/`) — MODIFY: grouped tree build, lazy partition load, sort toggle state, filter.
- `Views/SchemaTreeCellView.swift` — MODIFY: strategy badge, bound subtitle, DEFAULT muted styling.
- `ViewControllers/InspectorViewController.swift` — MODIFY: partition/parent detail.

**Tests**
- `pharos-core/src/models/schema.rs` — inline `#[cfg(test)]` for `PartitionStrategy::from_pg_char`.
- `PharosTests/PartitionOrderingTests.swift` + `scripts/test-partition-ordering.sh` — CREATE.
- `PharosTests/PartitionDisplayTests.swift` + `scripts/test-partition-display.sh` — CREATE.

**Note on TDD scope:** Pure logic (Rust strategy mapping, Swift ordering + display) is developed test-first. SQL and AppKit-coupled code (tree building, cell, inspector, sort UI, filter wiring) has no unit harness in this project — those tasks end with a build check and a manual `/verify` against a live partitioned database, per `pharos-swift-test-harness`.

---

## Phase A — Backend (Rust)

### Task 1: Partition model types + strategy mapping (TDD)

**Files:**
- Modify: `pharos-core/src/models/schema.rs`

- [ ] **Step 1: Write the failing test**

Add at the end of `pharos-core/src/models/schema.rs`:

```rust
#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn strategy_from_pg_char() {
        assert_eq!(PartitionStrategy::from_pg_char('r'), Some(PartitionStrategy::Range));
        assert_eq!(PartitionStrategy::from_pg_char('l'), Some(PartitionStrategy::List));
        assert_eq!(PartitionStrategy::from_pg_char('h'), Some(PartitionStrategy::Hash));
        assert_eq!(PartitionStrategy::from_pg_char('x'), None);
    }
}
```

- [ ] **Step 2: Run test to verify it fails**

Run: `cd pharos-core && cargo test strategy_from_pg_char`
Expected: FAIL — `cannot find type PartitionStrategy` / does not compile.

- [ ] **Step 3: Add the model types**

In `pharos-core/src/models/schema.rs`, add the `PartitionedTable` variant to `TableType`:

```rust
#[derive(Debug, Clone, Serialize, Deserialize)]
#[serde(rename_all = "lowercase")]
pub enum TableType {
    Table,
    View,
    #[serde(rename = "foreign-table")]
    ForeignTable,
    #[serde(rename = "partitioned-table")]
    PartitionedTable,
}
```

Add the strategy enum (place after `TableType`):

```rust
#[derive(Debug, Clone, Copy, PartialEq, Eq, Serialize, Deserialize)]
#[serde(rename_all = "lowercase")]
pub enum PartitionStrategy {
    Range,
    List,
    Hash,
}

impl PartitionStrategy {
    /// Map `pg_partitioned_table.partstrat` ('r' | 'l' | 'h') to a strategy.
    pub fn from_pg_char(c: char) -> Option<PartitionStrategy> {
        match c {
            'r' => Some(PartitionStrategy::Range),
            'l' => Some(PartitionStrategy::List),
            'h' => Some(PartitionStrategy::Hash),
            _ => None,
        }
    }
}
```

Extend `TableInfo` with the new optional fields (keep existing fields):

```rust
#[derive(Debug, Clone, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct TableInfo {
    pub name: String,
    pub schema_name: String,
    pub table_type: TableType,
    pub row_count_estimate: Option<i64>,
    pub total_size_bytes: Option<i64>,
    /// True when this relation is a partitioned parent (relkind='p').
    #[serde(default)]
    pub is_partitioned: bool,
    /// True when this relation is itself a partition of some parent.
    #[serde(default)]
    pub is_partition: bool,
    /// Present when `is_partitioned`.
    #[serde(default)]
    pub partition_strategy: Option<PartitionStrategy>,
    /// Raw `pg_get_partkeydef` output, e.g. "RANGE (created_at)". Present when `is_partitioned`.
    #[serde(default)]
    pub partition_key: Option<String>,
    /// This partition's bound text from `pg_get_expr(relpartbound)`, or "DEFAULT". Present when `is_partition`.
    #[serde(default)]
    pub partition_bound: Option<String>,
    /// Number of direct child partitions. Present when `is_partitioned`.
    #[serde(default)]
    pub partition_count: Option<i64>,
}
```

Add a lightweight ref type used by the partition-name map (place after `TableInfo`):

```rust
/// Minimal parent→child pairing used to populate the sidebar filter index
/// without eagerly fetching full partition detail.
#[derive(Debug, Clone, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct PartitionRef {
    pub parent_name: String,
    pub name: String,
}
```

- [ ] **Step 4: Run test to verify it passes**

Run: `cd pharos-core && cargo test strategy_from_pg_char`
Expected: PASS (1 passed).

- [ ] **Step 5: Fix existing construction sites**

`TableInfo` is constructed in `src/db/postgres.rs` (`get_tables` pg-catalog and fallback branches). Add the new fields defaulted so the crate still compiles; Task 2 sets them properly. In BOTH `TableInfo { ... }` literals in `get_tables` add:

```rust
                    is_partitioned: false,
                    is_partition: false,
                    partition_strategy: None,
                    partition_key: None,
                    partition_bound: None,
                    partition_count: None,
```

Run: `cd pharos-core && cargo build`
Expected: builds (no "missing field" errors).

- [ ] **Step 6: Commit**

```bash
git add pharos-core/src/models/schema.rs pharos-core/src/db/postgres.rs
git commit -m "feat(core): partition model types + strategy mapping"
```

---

### Task 2: `get_tables` — include parents, exclude leaves, aggregate size

**Files:**
- Modify: `pharos-core/src/db/postgres.rs:217-305` (`get_tables`)

- [ ] **Step 1: Replace the pg_catalog SQL**

In `get_tables`, replace the `pg_catalog_sql` string (currently `postgres.rs:221-251`) with:

```rust
    let pg_catalog_sql = format!(
        "SELECT \
            c.relname as table_name, \
            CASE c.relkind \
                WHEN 'r' THEN 'BASE TABLE' \
                WHEN 'v' THEN 'VIEW' \
                WHEN 'm' THEN 'VIEW' \
                WHEN 'f' THEN 'FOREIGN TABLE' \
                WHEN 'p' THEN 'PARTITIONED TABLE' \
                ELSE 'BASE TABLE' \
            END as table_type, \
            CASE \
                WHEN c.relkind = 'p' THEN ( \
                    SELECT COALESCE(SUM(lc.reltuples), 0)::bigint \
                    FROM pg_partition_tree(c.oid) pt \
                    JOIN pg_class lc ON lc.oid = pt.relid \
                    WHERE pt.isleaf) \
                WHEN c.reltuples >= 0 THEN c.reltuples::bigint \
                WHEN s.n_live_tup IS NOT NULL THEN s.n_live_tup \
                ELSE NULL \
            END as row_estimate, \
            CASE \
                WHEN c.relkind = 'p' THEN ( \
                    SELECT COALESCE(SUM(pg_total_relation_size(pt.relid)), 0)::bigint \
                    FROM pg_partition_tree(c.oid) pt WHERE pt.isleaf) \
                WHEN c.relkind IN ('r', 'm') THEN pg_total_relation_size(c.oid) \
                ELSE NULL \
            END as total_size_bytes, \
            (c.relkind = 'p') as is_partitioned, \
            CASE WHEN c.relkind = 'p' THEN pt2.partstrat::text ELSE NULL END as part_strat, \
            CASE WHEN c.relkind = 'p' THEN pg_get_partkeydef(c.oid) ELSE NULL END as part_key, \
            CASE WHEN c.relkind = 'p' THEN ( \
                SELECT count(*) FROM pg_inherits WHERE inhparent = c.oid)::bigint \
                ELSE NULL END as part_count \
         FROM pg_catalog.pg_class c \
         JOIN pg_catalog.pg_namespace n ON n.oid = c.relnamespace \
         LEFT JOIN pg_catalog.pg_stat_all_tables s ON s.relid = c.oid \
         LEFT JOIN pg_catalog.pg_partitioned_table pt2 ON pt2.partrelid = c.oid \
         WHERE n.nspname = '{}' \
           AND c.relkind IN ('r', 'v', 'm', 'f', 'p') \
           AND c.relispartition = false \
         ORDER BY \
            CASE c.relkind \
                WHEN 'r' THEN 1 \
                WHEN 'p' THEN 1 \
                WHEN 'f' THEN 2 \
                WHEN 'v' THEN 3 \
                WHEN 'm' THEN 4 \
            END, \
            c.relname",
        escaped
    );
```

Key changes: `'p'` added to the `relkind` filter; **`c.relispartition = false`** excludes every leaf/child partition from the flat list (the core fix); partitioned parents aggregate rows/size across leaf descendants via `pg_partition_tree` (PostgreSQL ≥ 12); partition metadata columns added; parents rank alongside regular tables (rank 1).

- [ ] **Step 2: Map the new columns into TableInfo**

Replace the pg-catalog `.map(|row| { ... })` block (currently `postgres.rs:256-269`) with:

```rust
            .map(|row| {
                let table_type_str: String = row.get("table_type");
                let is_partitioned: bool = row.try_get("is_partitioned").unwrap_or(false);
                let part_strat: Option<String> = row.try_get("part_strat").ok().flatten();
                let partition_strategy = part_strat
                    .as_deref()
                    .and_then(|s| s.chars().next())
                    .and_then(PartitionStrategy::from_pg_char);
                TableInfo {
                    name: row.get("table_name"),
                    schema_name: schema_name.to_string(),
                    table_type: match table_type_str.as_str() {
                        "VIEW" => TableType::View,
                        "FOREIGN TABLE" => TableType::ForeignTable,
                        "PARTITIONED TABLE" => TableType::PartitionedTable,
                        _ => TableType::Table,
                    },
                    row_count_estimate: row.try_get("row_estimate").ok(),
                    total_size_bytes: row.try_get("total_size_bytes").ok().flatten(),
                    is_partitioned,
                    is_partition: false,
                    partition_strategy,
                    partition_key: row.try_get("part_key").ok().flatten(),
                    partition_bound: None,
                    partition_count: row.try_get("part_count").ok().flatten(),
                }
            })
```

Add the import for `PartitionStrategy` at the top of `postgres.rs` if `TableType`/`TableInfo` are imported there — extend the existing `use crate::models::{...}` line to include `PartitionStrategy`.

- [ ] **Step 3: Leave the information_schema fallback as-is**

The fallback branch (`postgres.rs:286-302`) already defaults the new fields to `false`/`None` from Task 1 Step 5. Non-PG servers degrade to flat behavior — no change needed. Confirm it still compiles.

- [ ] **Step 4: Build**

Run: `cd pharos-core && cargo build`
Expected: builds clean.

- [ ] **Step 5: Commit**

```bash
git add pharos-core/src/db/postgres.rs
git commit -m "feat(core): get_tables includes partitioned parents, excludes leaf partitions, aggregates size"
```

---

### Task 3: `get_partitions` + `get_partition_map` (db + command + FFI)

**Files:**
- Modify: `pharos-core/src/db/postgres.rs` (add two functions after `get_tables`)
- Modify: `pharos-core/src/commands/metadata.rs`
- Modify: `pharos-core/src/ffi/schema.rs`

- [ ] **Step 1: Add `get_partitions` to postgres.rs**

Add after `get_tables` (after `postgres.rs:305`):

```rust
/// Get the direct child partitions of a partitioned parent table.
pub async fn get_partitions(
    pool: &PgPool,
    schema_name: &str,
    parent_table: &str,
) -> Result<Vec<TableInfo>, sqlx::Error> {
    let escaped_schema = escape_sql_literal(schema_name);
    let escaped_parent = escape_sql_literal(parent_table);

    let sql = format!(
        "SELECT \
            c.relname as table_name, \
            c.relkind as relkind, \
            CASE \
                WHEN c.relkind = 'p' THEN ( \
                    SELECT COALESCE(SUM(lc.reltuples), 0)::bigint \
                    FROM pg_partition_tree(c.oid) pt \
                    JOIN pg_class lc ON lc.oid = pt.relid WHERE pt.isleaf) \
                WHEN c.reltuples >= 0 THEN c.reltuples::bigint \
                ELSE NULL \
            END as row_estimate, \
            CASE \
                WHEN c.relkind = 'p' THEN ( \
                    SELECT COALESCE(SUM(pg_total_relation_size(pt.relid)), 0)::bigint \
                    FROM pg_partition_tree(c.oid) pt WHERE pt.isleaf) \
                ELSE pg_total_relation_size(c.oid) \
            END as total_size_bytes, \
            pg_get_expr(c.relpartbound, c.oid) as part_bound, \
            (c.relkind = 'p') as is_partitioned, \
            CASE WHEN c.relkind = 'p' THEN pt2.partstrat::text ELSE NULL END as part_strat, \
            CASE WHEN c.relkind = 'p' THEN pg_get_partkeydef(c.oid) ELSE NULL END as part_key, \
            CASE WHEN c.relkind = 'p' THEN ( \
                SELECT count(*) FROM pg_inherits WHERE inhparent = c.oid)::bigint \
                ELSE NULL END as part_count \
         FROM pg_catalog.pg_inherits i \
         JOIN pg_catalog.pg_class parent ON parent.oid = i.inhparent \
         JOIN pg_catalog.pg_namespace pn ON pn.oid = parent.relnamespace \
         JOIN pg_catalog.pg_class c ON c.oid = i.inhrelid \
         LEFT JOIN pg_catalog.pg_partitioned_table pt2 ON pt2.partrelid = c.oid \
         WHERE pn.nspname = '{}' AND parent.relname = '{}' \
         ORDER BY c.relname",
        escaped_schema, escaped_parent
    );

    let rows = sqlx::raw_sql(&sql).fetch_all(pool).await?;
    let partitions = rows
        .into_iter()
        .map(|row| {
            let relkind: String = row.get("relkind");
            let is_partitioned: bool = row.try_get("is_partitioned").unwrap_or(false);
            let part_strat: Option<String> = row.try_get("part_strat").ok().flatten();
            let partition_strategy = part_strat
                .as_deref()
                .and_then(|s| s.chars().next())
                .and_then(PartitionStrategy::from_pg_char);
            let table_type = match relkind.as_str() {
                "p" => TableType::PartitionedTable,
                "f" => TableType::ForeignTable,
                _ => TableType::Table,
            };
            TableInfo {
                name: row.get("table_name"),
                schema_name: schema_name.to_string(),
                table_type,
                row_count_estimate: row.try_get("row_estimate").ok().flatten(),
                total_size_bytes: row.try_get("total_size_bytes").ok().flatten(),
                is_partitioned,
                is_partition: true,
                partition_strategy,
                partition_key: row.try_get("part_key").ok().flatten(),
                partition_bound: row.try_get("part_bound").ok().flatten(),
                partition_count: row.try_get("part_count").ok().flatten(),
            }
        })
        .collect();

    Ok(partitions)
}

/// Get a flat parent→child name map for all partitioned parents in a schema.
/// Used to populate the sidebar filter index without loading full partition detail.
pub async fn get_partition_map(
    pool: &PgPool,
    schema_name: &str,
) -> Result<Vec<PartitionRef>, sqlx::Error> {
    let escaped = escape_sql_literal(schema_name);
    let sql = format!(
        "SELECT parent.relname as parent_name, c.relname as name \
         FROM pg_catalog.pg_inherits i \
         JOIN pg_catalog.pg_class parent ON parent.oid = i.inhparent \
         JOIN pg_catalog.pg_namespace pn ON pn.oid = parent.relnamespace \
         JOIN pg_catalog.pg_class c ON c.oid = i.inhrelid \
         WHERE pn.nspname = '{}' AND parent.relkind = 'p'",
        escaped
    );
    let rows = sqlx::raw_sql(&sql).fetch_all(pool).await?;
    let refs = rows
        .into_iter()
        .map(|row| PartitionRef {
            parent_name: row.get("parent_name"),
            name: row.get("name"),
        })
        .collect();
    Ok(refs)
}
```

Extend the `use crate::models::{...}` import in `postgres.rs` to include `PartitionRef`.

- [ ] **Step 2: Add command wrappers to metadata.rs**

In `pharos-core/src/commands/metadata.rs`, extend the top import to include `PartitionRef`, then add after `get_tables` (`metadata.rs:33`):

```rust
/// Get direct child partitions of a partitioned parent.
pub async fn get_partitions(
    connection_id: String,
    schema_name: String,
    parent_table: String,
    state: &AppState,
) -> Result<Vec<TableInfo>, String> {
    let pool = state
        .get_pool(&connection_id)
        .ok_or_else(|| format!("Not connected to: {}", connection_id))?;
    postgres::get_partitions(&pool, &schema_name, &parent_table)
        .await
        .map_err(|e| e.to_string())
}

/// Get parent→child partition name map for a schema (filter index).
pub async fn get_partition_map(
    connection_id: String,
    schema_name: String,
    state: &AppState,
) -> Result<Vec<PartitionRef>, String> {
    let pool = state
        .get_pool(&connection_id)
        .ok_or_else(|| format!("Not connected to: {}", connection_id))?;
    postgres::get_partition_map(&pool, &schema_name)
        .await
        .map_err(|e| e.to_string())
}
```

Confirm `commands/mod.rs` re-exports these (it uses `pub use metadata::*;` or names each — match the existing pattern; if functions are named individually, add `get_partitions, get_partition_map`).

- [ ] **Step 3: Add FFI wrappers to ffi/schema.rs**

In `pharos-core/src/ffi/schema.rs`, add after `pharos_get_tables` (`schema.rs:53`):

```rust
/// Get direct child partitions of a partitioned parent. Returns JSON array via callback.
#[no_mangle]
pub extern "C" fn pharos_get_partitions(
    connection_id: *const c_char,
    schema_name: *const c_char,
    parent_table: *const c_char,
    callback: AsyncCallback,
    context: *mut std::ffi::c_void,
) {
    let state = app_state();
    let conn_id = unsafe { c_str_to_string(connection_id) };
    let schema = unsafe { c_str_to_string(schema_name) };
    let parent = unsafe { c_str_to_string(parent_table) };
    let ctx = context as usize;

    ffi_spawn!(callback, context, async move {
        match crate::commands::get_partitions(conn_id, schema, parent, state).await {
            Ok(parts) => {
                let json = serde_json::to_string(&parts).unwrap_or_default();
                callback_ok(callback, ctx, &json);
            }
            Err(e) => callback_err(callback, ctx, &e),
        }
    });
}

/// Get parent→child partition name map for a schema. Returns JSON array via callback.
#[no_mangle]
pub extern "C" fn pharos_get_partition_map(
    connection_id: *const c_char,
    schema_name: *const c_char,
    callback: AsyncCallback,
    context: *mut std::ffi::c_void,
) {
    let state = app_state();
    let conn_id = unsafe { c_str_to_string(connection_id) };
    let schema = unsafe { c_str_to_string(schema_name) };
    let ctx = context as usize;

    ffi_spawn!(callback, context, async move {
        match crate::commands::get_partition_map(conn_id, schema, state).await {
            Ok(refs) => {
                let json = serde_json::to_string(&refs).unwrap_or_default();
                callback_ok(callback, ctx, &json);
            }
            Err(e) => callback_err(callback, ctx, &e),
        }
    });
}
```

- [ ] **Step 4: Build + regenerate C header**

Run: `cd pharos-core && cargo build --release`
Expected: builds clean; cbindgen regenerates the header with `pharos_get_partitions` and `pharos_get_partition_map`. Verify:

Run: `grep -c "pharos_get_partitions\|pharos_get_partition_map" $(find . -name '*.h' | head -1)`
Expected: `2` (both symbols present in the generated header).

- [ ] **Step 5: Commit**

```bash
git add pharos-core/src/db/postgres.rs pharos-core/src/commands/metadata.rs pharos-core/src/ffi/schema.rs
git commit -m "feat(core): add get_partitions and get_partition_map (db + command + FFI)"
```

---

## Phase B — Swift model + pure logic

### Task 4: Extend Swift models

**Files:**
- Modify: `Pharos/Models/Schema.swift:8-21`

- [ ] **Step 1: Update TableType and add PartitionStrategy**

Replace `TableType` (`Schema.swift:8-12`) with:

```swift
enum TableType: String, Codable {
    case table
    case view
    case foreignTable = "foreign-table"
    case partitionedTable = "partitioned-table"
}

enum PartitionStrategy: String, Codable {
    case range
    case list
    case hash

    /// Short uppercase badge label: RANGE / LIST / HASH.
    var badgeLabel: String { rawValue.uppercased() }
}
```

- [ ] **Step 2: Extend TableInfo and add PartitionRef**

Replace `TableInfo` (`Schema.swift:14-21`) with:

```swift
struct TableInfo: Codable {
    let name: String
    let schemaName: String
    let tableType: TableType
    let rowCountEstimate: Int64?
    let totalSizeBytes: Int64?
    // Partition metadata (all optional; absent/false on non-PG servers).
    var isPartitioned: Bool = false
    var isPartition: Bool = false
    var partitionStrategy: PartitionStrategy?
    var partitionKey: String?       // raw pg_get_partkeydef, e.g. "RANGE (created_at)"
    var partitionBound: String?     // pg_get_expr(relpartbound) or "DEFAULT"
    var partitionCount: Int64?
    // Rust uses #[serde(rename_all = "camelCase")] — Swift property names match directly

    enum CodingKeys: String, CodingKey {
        case name, schemaName, tableType, rowCountEstimate, totalSizeBytes
        case isPartitioned, isPartition, partitionStrategy, partitionKey, partitionBound, partitionCount
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        name = try c.decode(String.self, forKey: .name)
        schemaName = try c.decode(String.self, forKey: .schemaName)
        tableType = try c.decode(TableType.self, forKey: .tableType)
        rowCountEstimate = try c.decodeIfPresent(Int64.self, forKey: .rowCountEstimate)
        totalSizeBytes = try c.decodeIfPresent(Int64.self, forKey: .totalSizeBytes)
        isPartitioned = try c.decodeIfPresent(Bool.self, forKey: .isPartitioned) ?? false
        isPartition = try c.decodeIfPresent(Bool.self, forKey: .isPartition) ?? false
        partitionStrategy = try c.decodeIfPresent(PartitionStrategy.self, forKey: .partitionStrategy)
        partitionKey = try c.decodeIfPresent(String.self, forKey: .partitionKey)
        partitionBound = try c.decodeIfPresent(String.self, forKey: .partitionBound)
        partitionCount = try c.decodeIfPresent(Int64.self, forKey: .partitionCount)
    }

    /// Memberwise init for tests / in-code construction.
    init(name: String, schemaName: String, tableType: TableType,
         rowCountEstimate: Int64?, totalSizeBytes: Int64?,
         isPartitioned: Bool = false, isPartition: Bool = false,
         partitionStrategy: PartitionStrategy? = nil, partitionKey: String? = nil,
         partitionBound: String? = nil, partitionCount: Int64? = nil) {
        self.name = name; self.schemaName = schemaName; self.tableType = tableType
        self.rowCountEstimate = rowCountEstimate; self.totalSizeBytes = totalSizeBytes
        self.isPartitioned = isPartitioned; self.isPartition = isPartition
        self.partitionStrategy = partitionStrategy; self.partitionKey = partitionKey
        self.partitionBound = partitionBound; self.partitionCount = partitionCount
    }
}

struct PartitionRef: Codable {
    let parentName: String
    let name: String
}
```

(The explicit initializers are required because adding a custom `init(from:)` otherwise removes the synthesized memberwise init that tests and node-building code rely on.)

- [ ] **Step 3: Build the app to confirm the model compiles**

Run: `xcodebuild -project Pharos.xcodeproj -scheme Pharos build 2>&1 | tail -5`
Expected: `** BUILD SUCCEEDED **` (existing `TableInfo` construction sites still compile — the memberwise init preserves the old call shape with new params defaulted).

- [ ] **Step 4: Commit**

```bash
git add Pharos/Models/Schema.swift
git commit -m "feat: Swift partition model types (TableType.partitionedTable, PartitionStrategy, PartitionRef)"
```

---

### Task 5: `PartitionOrdering` pure sort logic (TDD)

**Files:**
- Create: `Pharos/Models/PartitionOrdering.swift`
- Create: `PharosTests/PartitionOrderingTests.swift`
- Create: `scripts/test-partition-ordering.sh`

- [ ] **Step 1: Write the failing test**

Create `PharosTests/PartitionOrderingTests.swift`:

```swift
// Standalone test runner for PartitionOrdering — no Xcode project involvement.
// Compiled with Pharos/Models/Schema.swift + PartitionOrdering.swift by
// scripts/test-partition-ordering.sh.
import Foundation

var failures = 0

func expectEqualNames(_ actual: [TableInfo], _ expected: [String], _ name: String) {
    let got = actual.map { $0.name }
    if got == expected { print("PASS \(name)") } else {
        failures += 1
        print("FAIL \(name)\n  expected: \(expected)\n  actual:   \(got)")
    }
}

private func part(_ name: String, bound: String?, size: Int64? = nil) -> TableInfo {
    TableInfo(name: name, schemaName: "public", tableType: .table,
              rowCountEstimate: nil, totalSizeBytes: size,
              isPartition: true, partitionBound: bound)
}

func runTests() {
    // Range partitions: bound order must beat the "2024_1 vs 2024_10" lexical bug.
    let ranges = [
        part("events_2024_10", bound: "FOR VALUES FROM ('2024-10-01') TO ('2024-11-01')"),
        part("events_2024_2",  bound: "FOR VALUES FROM ('2024-02-01') TO ('2024-03-01')"),
        part("events_2024_1",  bound: "FOR VALUES FROM ('2024-01-01') TO ('2024-02-01')"),
        part("events_default", bound: "DEFAULT"),
    ]
    expectEqualNames(PartitionOrdering.sorted(ranges, by: .bound),
        ["events_2024_1", "events_2024_2", "events_2024_10", "events_default"],
        "bound order sorts chronologically, DEFAULT last")

    // Integer range bounds must compare numerically, not lexically.
    let ints = [
        part("p_1000", bound: "FOR VALUES FROM (1000) TO (2000)"),
        part("p_20",   bound: "FOR VALUES FROM (20) TO (30)"),
        part("p_100",  bound: "FOR VALUES FROM (100) TO (200)"),
    ]
    expectEqualNames(PartitionOrdering.sorted(ints, by: .bound),
        ["p_20", "p_100", "p_1000"],
        "numeric range bounds compared numerically")

    // Name order = plain case-insensitive.
    expectEqualNames(PartitionOrdering.sorted(ranges, by: .name),
        ["events_2024_1", "events_2024_10", "events_2024_2", "events_default"],
        "name order is lexical")

    // Size order = largest first, nil sizes last.
    let sized = [
        part("small", bound: "DEFAULT", size: 10),
        part("big",   bound: "DEFAULT", size: 900),
        part("mid",   bound: "DEFAULT", size: 500),
    ]
    expectEqualNames(PartitionOrdering.sorted(sized, by: .size),
        ["big", "mid", "small"],
        "size order is descending")

    // HASH bounds have no natural order → fall back to name.
    let hash = [
        part("h_2", bound: "FOR VALUES WITH (modulus 4, remainder 2)"),
        part("h_0", bound: "FOR VALUES WITH (modulus 4, remainder 0)"),
    ]
    expectEqualNames(PartitionOrdering.sorted(hash, by: .bound),
        ["h_0", "h_2"],
        "hash bound order falls back to remainder/name")

    if failures == 0 { print("\nAll tests passed.") } else { print("\n\(failures) failure(s)."); exit(1) }
}
```

Create `PharosTests/PartitionOrderingMain.swift`? No — reuse the existing shim pattern. Create a dedicated shim is unnecessary; the script compiles a `main.swift`-named shim. Create `scripts/test-partition-ordering.sh`:

```bash
#!/bin/bash
# Standalone test runner for PartitionOrdering — no Xcode project involvement.
set -euo pipefail
cd "$(dirname "$0")/.."
TMPMAIN=$(mktemp -d)/main.swift
echo "runTests()" > "$TMPMAIN"
swiftc -o /tmp/partition-ordering-tests \
  Pharos/Models/Schema.swift \
  Pharos/Models/PartitionOrdering.swift \
  PharosTests/PartitionOrderingTests.swift \
  "$TMPMAIN"
/tmp/partition-ordering-tests
```

Make it executable: `chmod +x scripts/test-partition-ordering.sh`

(Note: the shim is generated in a temp dir because `swiftc` only accepts top-level statements in a file literally named `main.swift`, per `pharos-swift-test-harness`. Schema.swift imports only Foundation, so it compiles standalone.)

- [ ] **Step 2: Run test to verify it fails**

Run: `./scripts/test-partition-ordering.sh`
Expected: FAIL — `cannot find 'PartitionOrdering' in scope` (file doesn't exist yet).

- [ ] **Step 3: Implement PartitionOrdering**

Create `Pharos/Models/PartitionOrdering.swift`:

```swift
import Foundation

/// Ordering modes for the partitions group in the schema browser.
enum PartitionSortMode: String {
    case bound   // default — by partition boundary
    case name
    case size
}

/// Pure sorting logic for a partitioned table's child partitions.
/// Depends only on TableInfo (Foundation) so it is unit-testable standalone.
enum PartitionOrdering {

    static func sorted(_ partitions: [TableInfo], by mode: PartitionSortMode) -> [TableInfo] {
        switch mode {
        case .name:
            return partitions.sorted { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending }
        case .size:
            return partitions.sorted { ($0.totalSizeBytes ?? -1) > ($1.totalSizeBytes ?? -1) }
        case .bound:
            return partitions.sorted { boundLess($0, $1) }
        }
    }

    /// Strict weak ordering by bound. DEFAULT sorts last; ties break by name.
    private static func boundLess(_ a: TableInfo, _ b: TableInfo) -> Bool {
        let ka = boundKey(a.partitionBound)
        let kb = boundKey(b.partitionBound)
        switch (ka, kb) {
        case (nil, nil): return a.name.localizedCaseInsensitiveCompare(b.name) == .orderedAscending
        case (nil, _):   return false   // a is DEFAULT → after b
        case (_, nil):   return true    // b is DEFAULT → a before
        case let (.some(x), .some(y)):
            if let nx = Double(x), let ny = Double(y), nx != ny { return nx < ny }
            if x != y { return x.localizedStandardCompare(y) == .orderedAscending }
            return a.name.localizedCaseInsensitiveCompare(b.name) == .orderedAscending
        }
    }

    /// Extract a comparable key from a bound expression. Returns nil for DEFAULT
    /// (which sorts last). RANGE → first FROM value; LIST → first IN value;
    /// HASH → remainder number; unknown → nil.
    static func boundKey(_ bound: String?) -> String? {
        guard let bound = bound else { return nil }
        let b = bound.trimmingCharacters(in: .whitespaces)
        if b == "DEFAULT" { return nil }
        if let r = b.range(of: "FROM (") {
            return firstToken(after: r.upperBound, in: b, closing: ")")
        }
        if let r = b.range(of: "IN (") {
            return firstToken(after: r.upperBound, in: b, closing: ")")
        }
        if let r = b.range(of: "remainder ") {
            return firstToken(after: r.upperBound, in: b, closing: ")")
        }
        return nil
    }

    /// Read the first value up to a comma or the closing token, stripping quotes/spaces.
    private static func firstToken(after start: String.Index, in s: String, closing: Character) -> String {
        var token = ""
        var i = start
        while i < s.endIndex {
            let ch = s[i]
            if ch == "," || ch == closing { break }
            token.append(ch)
            i = s.index(after: i)
        }
        return token
            .trimmingCharacters(in: .whitespaces)
            .trimmingCharacters(in: CharacterSet(charactersIn: "'\""))
            .trimmingCharacters(in: .whitespaces)
    }
}
```

- [ ] **Step 4: Run test to verify it passes**

Run: `./scripts/test-partition-ordering.sh`
Expected: `All tests passed.`

- [ ] **Step 5: Commit**

```bash
git add Pharos/Models/PartitionOrdering.swift PharosTests/PartitionOrderingTests.swift scripts/test-partition-ordering.sh
git commit -m "feat: PartitionOrdering pure sort logic (bound/name/size) + tests"
```

---

### Task 6: `PartitionDisplay` pure formatting (TDD)

**Files:**
- Create: `Pharos/Models/PartitionDisplay.swift`
- Create: `PharosTests/PartitionDisplayTests.swift`
- Create: `scripts/test-partition-display.sh`

- [ ] **Step 1: Write the failing test**

Create `PharosTests/PartitionDisplayTests.swift`:

```swift
// Standalone test runner for PartitionDisplay.
import Foundation

var failures = 0

func expectEqualStr(_ actual: String?, _ expected: String?, _ name: String) {
    if actual == expected { print("PASS \(name)") } else {
        failures += 1
        print("FAIL \(name)\n  expected: \(expected ?? "nil")\n  actual:   \(actual ?? "nil")")
    }
}

func runTests() {
    // keyColumns extracts the parenthesized column list from pg_get_partkeydef.
    expectEqualStr(PartitionDisplay.keyColumns(fromPartKeyDef: "RANGE (created_at)"), "created_at",
        "range key columns")
    expectEqualStr(PartitionDisplay.keyColumns(fromPartKeyDef: "LIST (region, tier)"), "region, tier",
        "multi-column key")
    expectEqualStr(PartitionDisplay.keyColumns(fromPartKeyDef: nil), nil, "nil key def")

    // boundSummary compacts the common forms.
    expectEqualStr(PartitionDisplay.boundSummary("FOR VALUES FROM ('2024-01-01') TO ('2024-02-01')"),
        "[2024-01-01, 2024-02-01)", "range → bracket notation")
    expectEqualStr(PartitionDisplay.boundSummary("FOR VALUES IN ('US', 'CA')"),
        "IN (US, CA)", "list → IN summary")
    expectEqualStr(PartitionDisplay.boundSummary("FOR VALUES WITH (modulus 4, remainder 0)"),
        "mod 4, rem 0", "hash → mod/rem summary")
    expectEqualStr(PartitionDisplay.boundSummary("DEFAULT"), "DEFAULT", "default passthrough")
    expectEqualStr(PartitionDisplay.boundSummary(nil), nil, "nil bound")

    if failures == 0 { print("\nAll tests passed.") } else { print("\n\(failures) failure(s)."); exit(1) }
}
```

Create `scripts/test-partition-display.sh`:

```bash
#!/bin/bash
# Standalone test runner for PartitionDisplay.
set -euo pipefail
cd "$(dirname "$0")/.."
TMPMAIN=$(mktemp -d)/main.swift
echo "runTests()" > "$TMPMAIN"
swiftc -o /tmp/partition-display-tests \
  Pharos/Models/PartitionDisplay.swift \
  PharosTests/PartitionDisplayTests.swift \
  "$TMPMAIN"
/tmp/partition-display-tests
```

`chmod +x scripts/test-partition-display.sh`

- [ ] **Step 2: Run test to verify it fails**

Run: `./scripts/test-partition-display.sh`
Expected: FAIL — `cannot find 'PartitionDisplay' in scope`.

- [ ] **Step 3: Implement PartitionDisplay**

Create `Pharos/Models/PartitionDisplay.swift`:

```swift
import Foundation

/// Pure display-string formatting for partition metadata. Foundation-only,
/// so it is unit-testable standalone.
enum PartitionDisplay {

    /// Extract the parenthesized column list from a pg_get_partkeydef string.
    /// "RANGE (created_at)" -> "created_at"; "LIST (region, tier)" -> "region, tier".
    static func keyColumns(fromPartKeyDef def: String?) -> String? {
        guard let def = def,
              let open = def.firstIndex(of: "("),
              let close = def.lastIndex(of: ")"),
              open < close else { return nil }
        let inner = def[def.index(after: open)..<close]
        let trimmed = inner.trimmingCharacters(in: .whitespaces)
        return trimmed.isEmpty ? nil : trimmed
    }

    /// Compact one-line summary of a partition bound for the leaf subtitle.
    static func boundSummary(_ bound: String?) -> String? {
        guard let bound = bound else { return nil }
        let b = bound.trimmingCharacters(in: .whitespaces)
        if b == "DEFAULT" { return "DEFAULT" }

        if let fromR = b.range(of: "FROM ("), let toR = b.range(of: ") TO (") {
            let from = String(b[fromR.upperBound..<toR.lowerBound]).stripBoundValue()
            let after = b[toR.upperBound...]
            let to = String(after.prefix(while: { $0 != ")" })).stripBoundValue()
            return "[\(from), \(to))"
        }
        if let inR = b.range(of: "IN (") {
            let inner = String(b[inR.upperBound...].prefix(while: { $0 != ")" }))
            let values = inner.split(separator: ",")
                .map { $0.trimmingCharacters(in: .whitespaces).stripBoundValue() }
                .joined(separator: ", ")
            return "IN (\(values))"
        }
        if let modR = b.range(of: "modulus "), let remR = b.range(of: "remainder ") {
            let modulus = String(b[modR.upperBound...].prefix(while: { $0.isNumber }))
            let remainder = String(b[remR.upperBound...].prefix(while: { $0.isNumber }))
            return "mod \(modulus), rem \(remainder)"
        }
        return b   // unknown form: show raw
    }
}

private extension String {
    /// Strip surrounding quotes and whitespace from a bound literal token.
    func stripBoundValue() -> String {
        trimmingCharacters(in: .whitespaces)
            .trimmingCharacters(in: CharacterSet(charactersIn: "'\""))
            .trimmingCharacters(in: .whitespaces)
    }
}
```

- [ ] **Step 4: Run test to verify it passes**

Run: `./scripts/test-partition-display.sh`
Expected: `All tests passed.`

- [ ] **Step 5: Commit**

```bash
git add Pharos/Models/PartitionDisplay.swift PharosTests/PartitionDisplayTests.swift scripts/test-partition-display.sh
git commit -m "feat: PartitionDisplay pure formatting (key columns, bound summary) + tests"
```

---

### Task 7: Swift FFI wrappers for partitions

**Files:**
- Modify: `Pharos/Core/PharosCore+Schema.swift`

- [ ] **Step 1: Add the wrappers**

In `Pharos/Core/PharosCore+Schema.swift`, add after `getTables` (`+Schema.swift:26`):

```swift
    /// Get direct child partitions of a partitioned parent table.
    static func getPartitions(connectionId: String, schema: String, parent: String) async throws -> [TableInfo] {
        return try await withAsyncCallback { callback, context in
            connectionId.withCString { cConn in
                schema.withCString { cSchema in
                    parent.withCString { cParent in
                        pharos_get_partitions(cConn, cSchema, cParent, callback, context)
                    }
                }
            }
        }
    }

    /// Get the parent→child partition name map for a schema (filter index).
    static func getPartitionMap(connectionId: String, schema: String) async throws -> [PartitionRef] {
        return try await withAsyncCallback { callback, context in
            connectionId.withCString { cConn in
                schema.withCString { cSchema in
                    pharos_get_partition_map(cConn, cSchema, callback, context)
                }
            }
        }
    }
```

- [ ] **Step 2: Build**

Run: `xcodebuild -project Pharos.xcodeproj -scheme Pharos build 2>&1 | tail -5`
Expected: `** BUILD SUCCEEDED **` (the C symbols `pharos_get_partitions` / `pharos_get_partition_map` resolve from the header regenerated in Task 3).

- [ ] **Step 3: Commit**

```bash
git add Pharos/Core/PharosCore+Schema.swift
git commit -m "feat: Swift FFI wrappers getPartitions / getPartitionMap"
```

---

## Phase C — Swift tree & UI

### Task 8: SchemaTreeNode partition kinds & rendering data

**Files:**
- Modify: `Pharos/Models/SchemaTreeNode.swift`

- [ ] **Step 1: Add the new Kind cases**

In `SchemaTreeNode.swift`, extend the `Kind` enum (`:9-15`):

```swift
    enum Kind {
        case schema(SchemaInfo)
        case table(TableInfo)
        case view(TableInfo)
        case column(ColumnInfo)
        case partitionGroup(TableInfo)   // "Partitions" folder; associated value = parent table
        case partition(TableInfo)        // a leaf or sub-parent partition
        case loading
    }
```

- [ ] **Step 2: Add a partition-sort-mode slot and filter match count**

Add stored properties alongside the existing ones (`:17-23`):

```swift
    /// For a `.partitionGroup`, the current ordering mode of its children.
    var partitionSortMode: PartitionSortMode = .bound
    /// Child partition names known from the filter index (set on `.table`/`.partition`
    /// parents at schema load). Used by the filter to match without loading detail.
    var knownPartitionNames: [String] = []
    /// When a filter is active, the number of this node's partitions matching it.
    var partitionMatchCount: Int = 0
```

- [ ] **Step 3: Update title**

Extend `title` (`:41-49`):

```swift
    var title: String {
        switch kind {
        case .schema(let info): return info.name
        case .table(let info): return info.name
        case .view(let info): return info.name
        case .column(let info): return info.name
        case .partitionGroup: return "Partitions"
        case .partition(let info): return info.name
        case .loading: return "Loading\u{2026}"
        }
    }
```

- [ ] **Step 4: Update subtitle, icon, tintColor, isExpandable**

Replace `subtitle` default arm and add partition arms. In the `subtitle` computed property, before the final `default:` arm, add:

```swift
        case .partitionGroup(let parent):
            if let count = parent.partitionCount { return "\(count) partitions" }
            return "\(children.count) partitions"
        case .partition(let info):
            return PartitionDisplay.boundSummary(info.partitionBound) ?? " "
```

For the partitioned-parent subtitle (the `.table` arm): the parent should read like `by (created_at) · N partitions`. Update the `.table, .view` branch so that when the table is partitioned it composes the partition subtitle. Replace the `guard hasRowCount ...` return at `:65` region with a partitioned-aware version — insert at the top of the `.table, .view` case body:

```swift
        case .table, .view:
            if case .table(let info) = kind, info.isPartitioned {
                var parts: [String] = []
                if let key = PartitionDisplay.keyColumns(fromPartKeyDef: info.partitionKey) {
                    parts.append("by (\(key))")
                }
                if let count = info.partitionCount { parts.append("\(count) partitions") }
                return parts.isEmpty ? " " : parts.joined(separator: " \u{00B7} ")
            }
            // ... existing importing / row-count logic unchanged ...
```

Extend `icon` (`:94-105`) — partitioned parents get a distinct symbol, groups a folder, partitions a sublevel mark:

```swift
        case .table(let info): name = info.isPartitioned ? "square.split.2x2" : "tablecells"
        ...
        case .partitionGroup: name = "rectangle.split.3x1"
        case .partition(let info): name = info.isPartitioned ? "square.split.2x2" : "tablecells.badge.ellipsis"
```

Extend `tintColor` (`:107-113`) so a DEFAULT partition renders muted:

```swift
        case .partition(let info) where PartitionDisplay.boundSummary(info.partitionBound) == "DEFAULT":
            return .tertiaryLabelColor
```

Extend `isExpandable` (`:115-120`):

```swift
    var isExpandable: Bool {
        switch kind {
        case .schema, .table, .view, .partitionGroup: return true
        case .partition(let info): return true  // columns (and sub-partitions if info.isPartitioned)
        default: return false
        }
    }
```

- [ ] **Step 5: Update tableName navigation helper**

A `.partition` is a real, queryable table; a `.partitionGroup` is not. Update `tableName` (`:133-138`):

```swift
    var tableName: String? {
        switch kind {
        case .table(let info), .view(let info): return info.name
        case .partition(let info): return info.name
        case .partitionGroup: return parent?.tableName
        default: return parent?.tableName
        }
    }
```

- [ ] **Step 6: Add a strategy-badge helper for the cell**

Add a computed property after `subtitle`:

```swift
    /// Uppercase strategy badge (RANGE/LIST/HASH) for a partitioned parent, else nil.
    var partitionBadge: String? {
        if case .table(let info) = kind, info.isPartitioned {
            return info.partitionStrategy?.badgeLabel
        }
        return nil
    }
```

- [ ] **Step 7: Build**

Run: `xcodebuild -project Pharos.xcodeproj -scheme Pharos build 2>&1 | tail -20`
Expected: `** BUILD SUCCEEDED **`. If the compiler flags non-exhaustive `switch` in `SchemaDataSource.swift` or elsewhere over `Kind`, add the missing `.partitionGroup` / `.partition` arms there (mirror the `.table` behavior for expansion/selection). Fix each until the build is clean.

- [ ] **Step 8: Commit**

```bash
git add Pharos/Models/SchemaTreeNode.swift Pharos/ViewControllers/SchemaBrowser/
git commit -m "feat: SchemaTreeNode partition group/leaf kinds + rendering data"
```

---

### Task 9: Build partitioned-parent nodes + lazy partition loading

**Files:**
- Modify: `Pharos/ViewControllers/SchemaBrowserVC.swift` (`loadTablesForSchema` ~`:179-226`, lazy loading ~`:547-578`, data source delegate ~`:585-587`)

- [ ] **Step 1: Include partitioned parents in the table block**

In `loadTablesForSchema`, the `tableItems` filter (`:188-190`) currently keeps `.table`/`.foreignTable`. Include partitioned parents:

```swift
                let tableItems = tables
                    .filter { $0.tableType == .table || $0.tableType == .foreignTable || $0.tableType == .partitionedTable }
                    .sorted { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending }
```

In the `for t in tableItems` loop (`:195-203`), give partitioned parents a Partitions group child in addition to the lazy-columns placeholder:

```swift
                for t in tableItems {
                    let tableNode = SchemaTreeNode(.table(t), parent: schemaNode)
                    if t.isPartitioned {
                        // Partitions group first, then columns — both lazy.
                        let group = SchemaTreeNode(.partitionGroup(t), parent: tableNode)
                        group.addChild(SchemaTreeNode(.loading, parent: group))
                        tableNode.addChild(group)
                    }
                    tableNode.addChild(SchemaTreeNode(.loading, parent: tableNode))
                    if t.rowCountEstimate != nil { tableNode.hasRowCount = true }
                    schemaNode.addChild(tableNode)
                }
```

(Leaf partitions no longer appear here at all — the backend excludes them via `relispartition = false`.)

- [ ] **Step 2: Fetch the partition-name filter index per schema**

Still inside `loadTablesForSchema`, after the tables are fetched (after `:182`), fetch the partition map and attach names to parent nodes. Add before `await MainActor.run {`:

```swift
            let partitionMap = (try? await PharosCore.getPartitionMap(connectionId: connectionId, schema: schemaName)) ?? []
            var namesByParent: [String: [String]] = [:]
            for ref in partitionMap { namesByParent[ref.parentName, default: []].append(ref.name) }
```

Then inside the `for t in tableItems` loop, after creating `tableNode`, set:

```swift
                    tableNode.knownPartitionNames = namesByParent[t.name] ?? []
```

- [ ] **Step 3: Lazy-load partitions when the group (or a sub-parent) expands**

Extend `lazyLoadColumnsIfNeeded` (`:547-578`) to also handle `.partitionGroup` and `.partition`. Replace the guard `switch` (`:550-553`) and add a partition-loading branch:

```swift
    private func lazyLoadColumnsIfNeeded(for node: SchemaTreeNode) {
        guard !node.isLoaded else { return }

        switch node.kind {
        case .table, .view, .partition:
            loadColumns(for: node)
        case .partitionGroup(let parent):
            loadPartitions(for: node, parent: parent)
        default:
            return
        }
    }
```

Move the existing column-loading body into a new `loadColumns(for:)` method (same as the old `Task { ... }` block, renamed), and add:

```swift
    private func loadColumns(for node: SchemaTreeNode) {
        guard let connectionId, let schemaName = node.schemaName, let tableName = node.tableName else { return }
        node.isLoaded = true
        Task {
            do {
                let columns = try await PharosCore.getColumns(connectionId: connectionId, schema: schemaName, table: tableName)
                await MainActor.run {
                    node.removeAllChildren()
                    for col in columns { node.addChild(SchemaTreeNode(.column(col), parent: node)) }
                    self.outlineView.reloadItem(node, reloadChildren: true)
                }
            } catch {
                await MainActor.run {
                    node.removeAllChildren()
                    self.outlineView.reloadItem(node, reloadChildren: true)
                }
                NSLog("Failed to load columns for \(schemaName).\(tableName): \(error)")
            }
        }
    }

    private func loadPartitions(for group: SchemaTreeNode, parent: TableInfo) {
        guard let connectionId else { return }
        group.isLoaded = true
        Task {
            do {
                let partitions = try await PharosCore.getPartitions(
                    connectionId: connectionId, schema: parent.schemaName, parent: parent.name)
                await MainActor.run {
                    let sorted = PartitionOrdering.sorted(partitions, by: group.partitionSortMode)
                    group.removeAllChildren()
                    for p in sorted {
                        let node = SchemaTreeNode(.partition(p), parent: group)
                        node.hasRowCount = p.rowCountEstimate != nil
                        // Sub-partitioned partition → nested Partitions group (recursion).
                        if p.isPartitioned {
                            let sub = SchemaTreeNode(.partitionGroup(p), parent: node)
                            sub.addChild(SchemaTreeNode(.loading, parent: sub))
                            node.addChild(sub)
                        }
                        node.addChild(SchemaTreeNode(.loading, parent: node))
                        group.addChild(node)
                    }
                    self.outlineView.reloadItem(group, reloadChildren: true)
                }
            } catch {
                await MainActor.run {
                    group.removeAllChildren()
                    self.outlineView.reloadItem(group, reloadChildren: true)
                }
                NSLog("Failed to load partitions for \(parent.schemaName).\(parent.name): \(error)")
            }
        }
    }
```

- [ ] **Step 4: Ensure the Partitions group never auto-expands**

The `.table` lazy-column placeholder means expanding a partitioned parent shows `[Partitions group] + [columns placeholder]`; the group itself is collapsed until the user clicks it. No auto-expand path targets partition groups (the existing `autoExpandTableThreshold` logic only expands schema nodes and `public`). No change needed — confirm by inspection that `rebuildDisplayTree`'s expand logic never calls `expandItem` on a `.partitionGroup`.

- [ ] **Step 5: Build + manual verify**

Run: `xcodebuild -project Pharos.xcodeproj -scheme Pharos build 2>&1 | tail -5`
Expected: `** BUILD SUCCEEDED **`.

Manual (`/verify`): connect to a database with a range-partitioned table. Confirm: the parent appears once in the table list with a strategy badge and `by (key) · N partitions` subtitle and aggregate rows; expanding shows a collapsed *Partitions (N)* group plus columns; expanding the group lists partitions in bound order with bound summaries and sizes; a sub-partitioned partition itself expands into a nested group. Leaf partitions do NOT appear as top-level siblings.

- [ ] **Step 6: Commit**

```bash
git add Pharos/ViewControllers/SchemaBrowserVC.swift
git commit -m "feat: build partitioned-parent nodes + lazy partition loading with recursion"
```

---

### Task 10: Partition sort toggle

**Files:**
- Modify: `Pharos/ViewControllers/SchemaBrowser/SchemaDataSource.swift` (cell/view for the group row)
- Modify: `Pharos/Views/SchemaTreeCellView.swift` (host the sort chips on a group row)
- Modify: `Pharos/ViewControllers/SchemaBrowserVC.swift` (re-sort handler)

- [ ] **Step 1: Add a re-sort entry point on the VC**

In `SchemaBrowserVC.swift`, add:

```swift
    /// Change a partition group's ordering and re-sort its already-loaded children in place.
    func setPartitionSort(_ mode: PartitionSortMode, for group: SchemaTreeNode) {
        guard case .partitionGroup = group.kind, group.partitionSortMode != mode else { return }
        group.partitionSortMode = mode
        guard group.isLoaded else { return }   // not loaded yet → will sort on first load
        let infos: [TableInfo] = group.children.compactMap {
            if case .partition(let info) = $0.kind { return info } else { return nil }
        }
        let sorted = PartitionOrdering.sorted(infos, by: mode)
        // Reorder existing child nodes to match, preserving their loaded subtrees.
        var byName: [String: SchemaTreeNode] = [:]
        for child in group.children { byName[child.title] = child }
        group.removeAllChildren()
        for info in sorted { if let node = byName[info.name] { group.addChild(node) } }
        outlineView.reloadItem(group, reloadChildren: true)
    }
```

- [ ] **Step 2: Render the sort chips on the group row**

In `SchemaTreeCellView.swift`, add an optional trailing segmented control shown only for group rows. Add a stored `NSSegmentedControl` and a callback, wire it in `configure(node:)`:

```swift
    /// Invoked when the user picks a sort mode on a partition-group row.
    var onPartitionSortChange: ((PartitionSortMode) -> Void)?
    private let sortControl = NSSegmentedControl(labels: ["Bound", "Name", "Size"],
                                                 trackingMode: .selectOne, target: nil, action: nil)
```

In `configure(node:)`, after setting labels, show/hide and select the control:

```swift
        if case .partitionGroup = node.kind {
            if sortControl.superview == nil {
                sortControl.segmentStyle = .capsule
                sortControl.controlSize = .mini
                sortControl.translatesAutoresizingMaskIntoConstraints = false
                sortControl.target = self
                sortControl.action = #selector(sortChanged(_:))
                addSubview(sortControl)
                NSLayoutConstraint.activate([
                    sortControl.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -4),
                    sortControl.centerYAnchor.constraint(equalTo: centerYAnchor),
                ])
            }
            sortControl.isHidden = false
            switch node.partitionSortMode {
            case .bound: sortControl.selectedSegment = 0
            case .name:  sortControl.selectedSegment = 1
            case .size:  sortControl.selectedSegment = 2
            }
        } else {
            sortControl.isHidden = true
        }
```

Add the action + reset in `prepareForReuse`:

```swift
    @objc private func sortChanged(_ sender: NSSegmentedControl) {
        let mode: PartitionSortMode = [.bound, .name, .size][sender.selectedSegment]
        onPartitionSortChange?(mode)
    }
```

In `prepareForReuse()` add: `onPartitionSortChange = nil; sortControl.isHidden = true`.

- [ ] **Step 3: Wire the callback where cells are vended**

In `SchemaDataSource.swift` (the `viewFor` / cell-configuration path), after `cell.configure(node:)` for a partition-group node, set:

```swift
        if case .partitionGroup = node.kind {
            cell.onPartitionSortChange = { [weak delegate] mode in
                delegate?.schemaDataSourceSetPartitionSort(mode, for: node)
            }
        }
```

Add `func schemaDataSourceSetPartitionSort(_ mode: PartitionSortMode, for node: SchemaTreeNode)` to the `SchemaDataSourceDelegate` protocol, and implement it in the VC extension (`:584-588`) as `setPartitionSort(mode, for: node)`.

- [ ] **Step 4: Build + manual verify**

Run: `xcodebuild -project Pharos.xcodeproj -scheme Pharos build 2>&1 | tail -5`
Expected: `** BUILD SUCCEEDED **`.

Manual (`/verify`): expand a Partitions group; the Bound/Name/Size capsule appears on the group row; switching to Name reorders lexically, Size reorders largest-first, Bound restores chronological order. Selection persists while the group stays expanded.

- [ ] **Step 5: Commit**

```bash
git add Pharos/ViewControllers/SchemaBrowserVC.swift Pharos/ViewControllers/SchemaBrowser/SchemaDataSource.swift Pharos/Views/SchemaTreeCellView.swift
git commit -m "feat: partition sort toggle (bound/name/size) on the Partitions group"
```

---

### Task 11: Filter — match partitions, keep collapsed, hit-count badge

**Files:**
- Modify: `Pharos/ViewControllers/SchemaBrowserVC.swift` (`filterNode` ~`:487-523`)
- Modify: `Pharos/Models/SchemaTreeNode.swift` (badge accessor — already has `partitionMatchCount`)

- [ ] **Step 1: Match partition names in filterNode without expanding the group**

In `filterNode`, the `.table, .view` case (`:505-518`) currently includes children when the title matches. For a partitioned parent whose own title does NOT match, check the filter index (`knownPartitionNames`) and keep the parent visible with a collapsed group + match count. Replace the `.table, .view` case with:

```swift
        case .table, .view:
            let matchingChildren = node.children.compactMap { filterNode($0, text: text, expandList: &expandList) }
            // Partition-name matches from the lightweight index (group stays collapsed).
            let partitionMatches = node.knownPartitionNames.filter { $0.lowercased().contains(text) }.count
            if !titleMatches && matchingChildren.isEmpty && partitionMatches == 0 { return nil }
            let filtered = SchemaTreeNode(node.kind, parent: node.parent)
            filtered.isLoaded = node.isLoaded
            filtered.knownPartitionNames = node.knownPartitionNames
            filtered.partitionMatchCount = titleMatches ? 0 : partitionMatches
            if titleMatches {
                for child in node.children { filtered.addChild(child) }
            } else {
                for child in matchingChildren { filtered.addChild(child) }
            }
            // Do NOT append partition groups to expandList — keep them collapsed even on a partition match.
            if !filtered.children.isEmpty && !isPartitionOnlyMatch(filtered) {
                expandList.append(filtered)
            }
            return filtered
```

Add a small helper:

```swift
    /// True when a node is visible only because a partition name matched (so we
    /// keep it collapsed rather than auto-expanding into columns/groups).
    private func isPartitionOnlyMatch(_ node: SchemaTreeNode) -> Bool {
        node.partitionMatchCount > 0
    }
```

- [ ] **Step 2: Render the hit-count badge**

In `SchemaTreeNode.subtitle`, for a partitioned `.table` with `partitionMatchCount > 0`, append the match count. In the partitioned-parent subtitle branch added in Task 8 Step 4, before returning, add:

```swift
                if partitionMatchCount > 0 {
                    parts.append("\(partitionMatchCount) matching")
                }
```

- [ ] **Step 3: Add `.partition` / `.partitionGroup` arms to filterNode**

The recursive `filterNode` switches over `node.kind`; add arms so a filter walk over an already-expanded/loaded group behaves (match partition titles, keep group if any child matches):

```swift
        case .partitionGroup:
            let matchingChildren = node.children.compactMap { filterNode($0, text: text, expandList: &expandList) }
            if matchingChildren.isEmpty { return nil }
            let filtered = SchemaTreeNode(node.kind, parent: node.parent)
            filtered.isLoaded = node.isLoaded
            filtered.partitionSortMode = node.partitionSortMode
            for child in matchingChildren { filtered.addChild(child) }
            return filtered

        case .partition:
            return titleMatches ? node : nil
```

- [ ] **Step 4: Build + manual verify**

Run: `xcodebuild -project Pharos.xcodeproj -scheme Pharos build 2>&1 | tail -5`
Expected: `** BUILD SUCCEEDED **`.

Manual (`/verify`): with a partitioned table `events`, type a full partition name (e.g. `events_2024_03`) into the sidebar filter. Confirm the `events` parent stays visible, the Partitions group stays **collapsed**, and the parent subtitle shows `… · 1 matching`. Typing the parent name `events` shows it normally. Clearing the filter restores the full tree.

- [ ] **Step 5: Commit**

```bash
git add Pharos/ViewControllers/SchemaBrowserVC.swift Pharos/Models/SchemaTreeNode.swift
git commit -m "feat: filter matches partition names, keeps group collapsed with hit-count badge"
```

---

### Task 12: Cell — strategy badge + DEFAULT styling

**Files:**
- Modify: `Pharos/Views/SchemaTreeCellView.swift`

- [ ] **Step 1: Render the strategy badge after the primary label**

Add a badge label to the cell and populate it from `node.partitionBadge`. Add stored property:

```swift
    private let badgeLabel = NSTextField(labelWithString: "")
```

In the initializer, style it and add it to the label row (place it inline after the primary label — use a horizontal container or add as a subview trailing the primaryLabel). Minimal approach: insert `badgeLabel` into a horizontal stack wrapping `primaryLabel`:

```swift
        badgeLabel.font = .systemFont(ofSize: 9, weight: .semibold)
        badgeLabel.textColor = .controlAccentColor
        badgeLabel.wantsLayer = true
        badgeLabel.layer?.cornerRadius = 3
        badgeLabel.isHidden = true
```

Wrap the primary line: replace `labelStack.addArrangedSubview(primaryLabel)` with a horizontal sub-stack containing `primaryLabel` and `badgeLabel`:

```swift
        let primaryRow = NSStackView(views: [primaryLabel, badgeLabel])
        primaryRow.orientation = .horizontal
        primaryRow.spacing = 5
        primaryRow.alignment = .firstBaseline
        labelStack.addArrangedSubview(primaryRow)
```

In `configure(node:)`, after setting `primaryLabel.stringValue`:

```swift
        if let badge = node.partitionBadge {
            badgeLabel.stringValue = " \(badge) "
            badgeLabel.isHidden = false
        } else {
            badgeLabel.isHidden = true
        }
```

Reset in `prepareForReuse()`: `badgeLabel.isHidden = true`.

- [ ] **Step 2: DEFAULT partition muted styling**

`SchemaTreeNode.tintColor` (Task 8) already returns `.tertiaryLabelColor` for a DEFAULT partition, which tints the icon. Also mute the primary label: in `configure(node:)`, extend the loading/normal color branch (`:75-81`):

```swift
        if case .loading = node.kind {
            primaryLabel.textColor = .tertiaryLabelColor
            primaryLabel.font = .systemFont(ofSize: 12)
        } else if case .partition(let info) = node.kind,
                  PartitionDisplay.boundSummary(info.partitionBound) == "DEFAULT" {
            primaryLabel.textColor = .secondaryLabelColor
            primaryLabel.font = .systemFont(ofSize: 13)
        } else {
            primaryLabel.textColor = .labelColor
            primaryLabel.font = .systemFont(ofSize: 13)
        }
```

- [ ] **Step 3: Build + manual verify**

Run: `xcodebuild -project Pharos.xcodeproj -scheme Pharos build 2>&1 | tail -5`
Expected: `** BUILD SUCCEEDED **`.

Manual (`/verify`): partitioned parent shows a `RANGE`/`LIST`/`HASH` badge next to its name; the DEFAULT partition renders in a muted color distinct from regular partitions. Badge does not linger on non-partitioned rows after scrolling (reuse reset works).

- [ ] **Step 4: Commit**

```bash
git add Pharos/Views/SchemaTreeCellView.swift
git commit -m "feat: strategy badge + DEFAULT partition styling in schema cell"
```

---

### Task 13: Inspector — partition detail

**Files:**
- Modify: `Pharos/ViewControllers/InspectorViewController.swift`

- [ ] **Step 1: Read the inspector's current selection-handling API**

Run: `grep -n "func \|TableInfo\|SchemaTreeNode\|selectedNode\|update" Pharos/ViewControllers/InspectorViewController.swift | head -40`
Expected: reveals how the inspector is currently populated from a selected node/table (method name and the model it renders). Note the entry point used by the schema browser selection.

- [ ] **Step 2: Add a partition-detail rendering path**

Following the inspector's existing field/section rendering pattern (rows of label→value), add a branch that, for a selected node whose `TableInfo` has `isPartitioned` or `isPartition`, renders:

- Partitioned parent: `Strategy` = `partitionStrategy?.badgeLabel`, `Partition key` = `PartitionDisplay.keyColumns(fromPartKeyDef:)`, `Partitions` = `partitionCount`, `Rows` = formatted `rowCountEstimate`, `Size` = formatted `totalSizeBytes`.
- Partition leaf: `Parent` (walk the node's `parent?.tableName`), `Bound` = `PartitionDisplay.boundSummary(partitionBound)`, `Rows`, `Size`, and a `DEFAULT partition` flag when the bound is DEFAULT.

Reuse the existing size/row formatting helper if the inspector has one; otherwise format inline with the same thresholds as `SchemaTreeNode.formatCount`. Do not invent a new UI framework — mirror the current inspector layout exactly.

- [ ] **Step 3: Route partition/group selections to the inspector**

In the schema browser's selection handler (find via `grep -n "InspectorView\|outlineViewSelectionDidChange\|inspector" Pharos/ViewControllers/SchemaBrowserVC.swift Pharos/ViewControllers/SchemaBrowser/*.swift`), ensure a selected `.partition` (and `.table` partitioned parent) forwards its `TableInfo` to the inspector using the same call already used for regular `.table` selections. A `.partitionGroup` selection should forward its parent `TableInfo` (same as selecting the parent).

- [ ] **Step 4: Build + manual verify**

Run: `xcodebuild -project Pharos.xcodeproj -scheme Pharos build 2>&1 | tail -5`
Expected: `** BUILD SUCCEEDED **`.

Manual (`/verify`): open the inspector (it is collapsed by default — reveal it), select a partitioned parent → strategy/key/count/rows/size shown; select an individual partition → parent/bound/rows/size shown, DEFAULT flagged for the default partition.

- [ ] **Step 5: Commit**

```bash
git add Pharos/ViewControllers/InspectorViewController.swift Pharos/ViewControllers/SchemaBrowserVC.swift
git commit -m "feat: inspector shows partitioned-table and partition detail"
```

---

### Task 14: Project regen, full run, end-to-end verify

**Files:** none (integration)

- [ ] **Step 1: Regenerate the Xcode project (new Swift files added)**

New files `PartitionOrdering.swift`, `PartitionDisplay.swift` live under `Pharos/Models/` (in the app sources path) so they compile into the app. If `project.yml` globs the sources directory they are picked up automatically; regenerate to be safe:

Run: `xcodegen generate`
Expected: `Created project at Pharos.xcodeproj`.

- [ ] **Step 2: Run all pure-logic tests**

```bash
cd pharos-core && cargo test && cd ..
./scripts/test-partition-ordering.sh
./scripts/test-partition-display.sh
```
Expected: Rust tests pass; both Swift harnesses print `All tests passed.`

- [ ] **Step 3: Clean build**

Run: `xcodebuild -project Pharos.xcodeproj -scheme Pharos build 2>&1 | tail -5`
Expected: `** BUILD SUCCEEDED **`.

- [ ] **Step 4: End-to-end manual verification (`/verify`)**

Against a PostgreSQL database containing: a RANGE-partitioned table with a DEFAULT partition, a LIST-partitioned table, a HASH-partitioned table, and a two-level sub-partitioned table:

1. Each partitioned parent appears once in its schema's table list with the correct strategy badge and `by (key) · N partitions` subtitle and aggregate rows·size.
2. No leaf partitions appear as flat top-level siblings.
3. Expanding a parent shows a collapsed *Partitions (N)* group + columns.
4. Expanding the group lists partitions in bound order with compact bound summaries and per-partition size; DEFAULT is muted and last.
5. The sort toggle switches bound/name/size and reorders correctly (verify the `_2024_1` vs `_2024_10` case orders chronologically under Bound).
6. A sub-partitioned partition expands into its own nested Partitions group.
7. Filtering by a partition name keeps the parent visible, group collapsed, with `N matching` on the parent.
8. The inspector shows parent and partition detail.
9. A non-partitioned table/view is unchanged from before.
10. Connect to a non-PostgreSQL-compatible server (or the information_schema fallback path) and confirm no crash and flat behavior.

- [ ] **Step 5: Final commit**

```bash
git add -A
git commit -m "chore: regenerate project; partition-aware navigator end-to-end verified"
```

---

## Self-Review Notes

- **Spec coverage:** §1 backend model/query → Tasks 1–3; §2 tree model → Task 8; §3 build/sort/filter → Tasks 9–11; §4 rendering → Tasks 8 & 12; §5 inspector → Task 13. Behavior change "leaf partitions excluded from flat list" → Task 2 Step 1 (`relispartition = false`). Recursive sub-partitioning → Task 9 Step 3. Filter "match + collapsed + hit badge" → Task 11.
- **Deviation from spec (documented):** The spec listed partition-name filtering generically; this plan implements it via a dedicated lightweight `get_partition_map`/`getPartitionMap` index (Tasks 3, 9 Step 2) so filtering does not force eager loading of full partition detail. This is an addition consistent with the spec's lazy-loading and huge-count constraints.
- **Type consistency:** `PartitionStrategy`, `PartitionSortMode`, `PartitionRef`, `TableInfo` fields, and the FFI symbol names (`pharos_get_partitions`, `pharos_get_partition_map`) are used identically across Rust and Swift tasks.
- **Persistence:** Sort mode is per-group in-memory (`SchemaTreeNode.partitionSortMode`), reset when the tree is rebuilt — no disk persistence (YAGNI; matches the spec's "planning detail" note).
