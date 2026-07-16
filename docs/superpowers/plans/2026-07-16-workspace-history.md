# Workspace History Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Log an entire editor-tab working session (editor text, variables, and all its result tabs) as one "workspace" item in the Results History sidebar, instead of one row per query.

**Architecture:** Reuse the existing `query_history` table as the per-result child store; add a new `workspaces` parent table + nullable child columns (`workspace_id`, `result_order`, `color_index`, `custom_label`). Query execution is UNCHANGED — Swift associates each produced result (it already receives `history_entry_id`) to a workspace via new post-hoc FFI commands, and upserts the workspace's editor/variables snapshot on execute and on tab close. The history sidebar becomes a flat workspace list + a bottom preview pane; double-clicking restores the full workspace into a live editor tab.

**Tech Stack:** Rust (`rusqlite`, `serde`, `flate2` gzip, FTS5), C FFI via cbindgen, Swift/AppKit (`NSTableView`, `NSSplitView`), XcodeGen.

**Design spec:** `docs/superpowers/specs/2026-07-16-workspace-history-design.md`

**Conventions for every Rust task below:** after editing Rust, build with
`cd pharos-core && cargo build --release` (regenerates the C header via cbindgen).
Run Rust unit tests with `cd pharos-core && cargo test`. Swift is verified by an
Xcode build (`xcodebuild -scheme Pharos -configuration Debug build`) — there is no
Swift unit-test target; UI-logic tests use standalone `swiftc` harness scripts as
noted. New Swift files must be added to `project.yml`'s sources (they already glob
`Pharos/**`, so a re-run of `xcodegen generate` picks them up — run it after creating
any new file).

---

## Phase 0 — Rust storage schema & pure logic

### Task 0.1: Add `workspaces` table + `query_history` workspace columns

**Files:**
- Modify: `pharos-core/src/db/sqlite.rs:269` (end of the main `execute_batch` schema block) and `:299` (after the schema/column_count migration)

- [ ] **Step 1: Add the `workspaces` table + indices to the schema batch.**
  In the big `r#"..."#` schema string, immediately before the closing `"#,` at
  `sqlite.rs:269`, append:

```sql
        -- Workspaces: one per editor-tab working session
        CREATE TABLE IF NOT EXISTS workspaces (
            id TEXT PRIMARY KEY,
            name TEXT,
            name_is_custom INTEGER NOT NULL DEFAULT 0,
            connection_id TEXT NOT NULL,
            connection_name TEXT NOT NULL,
            editor_text TEXT NOT NULL DEFAULT '',
            variables_json TEXT NOT NULL DEFAULT '[]',
            cursor_position INTEGER,
            created_at TEXT NOT NULL,
            last_activity_at TEXT NOT NULL
        );

        CREATE INDEX IF NOT EXISTS idx_workspaces_last_activity
            ON workspaces(last_activity_at DESC);
```

- [ ] **Step 2: Add the nullable child columns to `query_history` via migration.**
  After the schema/column_count migration block (after `sqlite.rs:299`, i.e. after the
  `has_schema_column` `if` block closes), add a new migration guarded on `workspace_id`:

```rust
    // Migration: Add workspace association columns to query_history
    let has_workspace_col: bool = conn
        .prepare("SELECT COUNT(*) FROM pragma_table_info('query_history') WHERE name = 'workspace_id'")?
        .query_row([], |row| row.get::<_, i64>(0))
        .map(|count| count > 0)
        .unwrap_or(false);

    if !has_workspace_col {
        conn.execute_batch(
            "ALTER TABLE query_history ADD COLUMN workspace_id TEXT;
             ALTER TABLE query_history ADD COLUMN result_order INTEGER;
             ALTER TABLE query_history ADD COLUMN color_index INTEGER;
             ALTER TABLE query_history ADD COLUMN custom_label TEXT;
             CREATE INDEX IF NOT EXISTS idx_query_history_workspace
                 ON query_history(workspace_id, result_order);"
        )?;
    }
```

- [ ] **Step 3: Add a `workspaces_fts` FTS5 table + sync triggers** so workspace
  name/editor_text are searchable. Add to the migration (inside the same `if
  !has_workspace_col` block is fine, or a separate guarded block keyed on the FTS
  table's existence). Append after the ALTER block above, still inside the `if`:

```rust
        conn.execute_batch(
            "CREATE VIRTUAL TABLE IF NOT EXISTS workspaces_fts USING fts5(
                 name, editor_text, content='workspaces', content_rowid='rowid'
             );
             CREATE TRIGGER IF NOT EXISTS workspaces_ai AFTER INSERT ON workspaces BEGIN
                 INSERT INTO workspaces_fts(rowid, name, editor_text)
                 VALUES (new.rowid, COALESCE(new.name,''), new.editor_text);
             END;
             CREATE TRIGGER IF NOT EXISTS workspaces_ad AFTER DELETE ON workspaces BEGIN
                 INSERT INTO workspaces_fts(workspaces_fts, rowid, name, editor_text)
                 VALUES ('delete', old.rowid, COALESCE(old.name,''), old.editor_text);
             END;
             CREATE TRIGGER IF NOT EXISTS workspaces_au AFTER UPDATE ON workspaces BEGIN
                 INSERT INTO workspaces_fts(workspaces_fts, rowid, name, editor_text)
                 VALUES ('delete', old.rowid, COALESCE(old.name,''), old.editor_text);
                 INSERT INTO workspaces_fts(rowid, name, editor_text)
                 VALUES (new.rowid, COALESCE(new.name,''), new.editor_text);
             END;"
        )?;
```

- [ ] **Step 4: Build.** Run: `cd pharos-core && cargo build --release`
  Expected: compiles. (Schema runs on next `pharos_init`; existing DBs migrate in place.)

- [ ] **Step 5: Commit.**

```bash
git add pharos-core/src/db/sqlite.rs
git commit -m "feat(core): workspaces table + query_history workspace columns + FTS"
```

---

### Task 0.2: `resolve_workspace_name` pure function + tests

The auto-name rule (Decision 2): custom name wins; else first-queried `connection_name`;
else `"<db> +N"` where N = additional distinct databases.

**Files:**
- Modify: `pharos-core/src/db/sqlite.rs` (add near the FTS helpers, ~`:45`)

- [ ] **Step 1: Write the failing test.** Add at the bottom of `sqlite.rs`:

```rust
#[cfg(test)]
mod workspace_name_tests {
    use super::resolve_workspace_name;

    #[test]
    fn custom_name_wins() {
        assert_eq!(resolve_workspace_name(Some("My Analysis"), true, "prod-db", 3), "My Analysis");
    }
    #[test]
    fn single_db_uses_connection_name() {
        assert_eq!(resolve_workspace_name(None, false, "prod-db", 1), "prod-db");
    }
    #[test]
    fn multi_db_appends_plus_n() {
        assert_eq!(resolve_workspace_name(None, false, "prod-db", 3), "prod-db +2");
    }
    #[test]
    fn zero_dbs_falls_back_to_connection_name() {
        assert_eq!(resolve_workspace_name(None, false, "prod-db", 0), "prod-db");
    }
    #[test]
    fn empty_connection_name_is_untitled() {
        assert_eq!(resolve_workspace_name(None, false, "", 1), "Untitled");
    }
    #[test]
    fn custom_but_empty_falls_back() {
        assert_eq!(resolve_workspace_name(Some(""), true, "prod-db", 1), "prod-db");
    }
}
```

- [ ] **Step 2: Run test to verify it fails.**
  Run: `cd pharos-core && cargo test workspace_name_tests`
  Expected: FAIL — `cannot find function resolve_workspace_name`.

- [ ] **Step 3: Implement.** Add near the FTS helpers (after `escape_fts5_query`, ~`:45`):

```rust
/// Resolve a workspace's display name. Custom names win; otherwise use the
/// first-queried connection name, suffixed with " +N" when N additional
/// distinct databases were queried in the same workspace.
pub fn resolve_workspace_name(
    name: Option<&str>,
    name_is_custom: bool,
    connection_name: &str,
    distinct_db_count: i64,
) -> String {
    if name_is_custom {
        if let Some(n) = name {
            if !n.is_empty() {
                return n.to_string();
            }
        }
    }
    let base = if connection_name.is_empty() { "Untitled" } else { connection_name };
    if distinct_db_count > 1 {
        format!("{} +{}", base, distinct_db_count - 1)
    } else {
        base.to_string()
    }
}
```

- [ ] **Step 4: Run tests to verify they pass.**
  Run: `cd pharos-core && cargo test workspace_name_tests`
  Expected: 6 passed.

- [ ] **Step 5: Commit.**

```bash
git add pharos-core/src/db/sqlite.rs
git commit -m "feat(core): resolve_workspace_name auto-naming with +N multi-db rule"
```

---

### Task 0.3: `results_to_demote` budget pure function + tests

Per-workspace budget (Decision 3): 100 MB across the workspace's cached blobs; when
over budget, drop blobs from the OLDEST results first (they stay listed as "SQL only").

**Files:**
- Modify: `pharos-core/src/db/sqlite.rs`

- [ ] **Step 1: Write the failing test.** Add another test module at the bottom:

```rust
#[cfg(test)]
mod budget_tests {
    use super::results_to_demote;

    fn ids(v: &[&str]) -> Vec<String> { v.iter().map(|s| s.to_string()).collect() }

    #[test]
    fn under_budget_demotes_nothing() {
        let sizes = vec![("a".into(), 10i64), ("b".into(), 20)];
        assert_eq!(results_to_demote(&sizes, 100), Vec::<String>::new());
    }
    #[test]
    fn demotes_oldest_first_until_under_budget() {
        // oldest-first: a(50), b(40), c(30) = 120; budget 100 -> drop a -> 70
        let sizes = vec![("a".into(), 50i64), ("b".into(), 40), ("c".into(), 30)];
        assert_eq!(results_to_demote(&sizes, 100), ids(&["a"]));
    }
    #[test]
    fn demotes_multiple_when_needed() {
        let sizes = vec![("a".into(), 60i64), ("b".into(), 60), ("c".into(), 60)];
        // total 180, budget 100 -> drop a(120) -> drop b(60) -> under
        assert_eq!(results_to_demote(&sizes, 100), ids(&["a", "b"]));
    }
    #[test]
    fn exactly_at_budget_demotes_nothing() {
        let sizes = vec![("a".into(), 100i64)];
        assert_eq!(results_to_demote(&sizes, 100), Vec::<String>::new());
    }
}
```

- [ ] **Step 2: Run test to verify it fails.**
  Run: `cd pharos-core && cargo test budget_tests`
  Expected: FAIL — `cannot find function results_to_demote`.

- [ ] **Step 3: Implement.** Add near `resolve_workspace_name`:

```rust
/// Given a workspace's cached results as (id, blob_bytes) ordered OLDEST-FIRST,
/// return the ids whose blobs must be dropped so the total is <= budget_bytes.
pub fn results_to_demote(sizes_oldest_first: &[(String, i64)], budget_bytes: i64) -> Vec<String> {
    let mut total: i64 = sizes_oldest_first.iter().map(|(_, sz)| *sz).sum();
    let mut demote = Vec::new();
    for (id, sz) in sizes_oldest_first {
        if total <= budget_bytes {
            break;
        }
        demote.push(id.clone());
        total -= *sz;
    }
    demote
}
```

- [ ] **Step 4: Run tests to verify they pass.**
  Run: `cd pharos-core && cargo test budget_tests`
  Expected: 4 passed.

- [ ] **Step 5: Commit.**

```bash
git add pharos-core/src/db/sqlite.rs
git commit -m "feat(core): results_to_demote workspace blob budget logic"
```

---

## Phase 1 — Rust models, sqlite functions, commands

### Task 1.1: Workspace model structs

**Files:**
- Create: `pharos-core/src/models/workspace.rs`
- Modify: `pharos-core/src/models/mod.rs`

- [ ] **Step 1: Create the models file.**

```rust
use serde::{Deserialize, Serialize};

/// Full workspace record + payload used for upsert from Swift.
#[derive(Debug, Clone, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct WorkspaceUpsert {
    pub id: String,
    #[serde(default)]
    pub name: Option<String>,
    #[serde(default)]
    pub name_is_custom: bool,
    pub connection_id: String,
    pub connection_name: String,
    #[serde(default)]
    pub editor_text: String,
    /// JSON-encoded array of QueryVariable, stored verbatim.
    #[serde(default = "default_variables_json")]
    pub variables_json: String,
    #[serde(default)]
    pub cursor_position: Option<i64>,
}

fn default_variables_json() -> String { "[]".to_string() }

/// Row shown in the workspace list (Layout B).
#[derive(Debug, Clone, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct WorkspaceSummary {
    pub id: String,
    /// Already resolved via resolve_workspace_name.
    pub name: String,
    pub connection_name: String,
    pub distinct_db_count: i64,
    pub query_count: i64,
    pub last_activity_at: String,
}

/// One child result's metadata, for the preview pane and restore.
#[derive(Debug, Clone, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct WorkspaceResultMeta {
    pub id: String, // == query_history.id
    pub sql: String,
    pub result_order: Option<i64>,
    pub color_index: Option<i64>,
    pub custom_label: Option<String>,
    pub row_count: Option<i64>,
    pub column_count: Option<i64>,
    pub schema: Option<String>,
    pub table_names: Option<String>,
    pub has_results: bool,
    pub execution_time_ms: i64,
    pub executed_at: String,
}

/// Full workspace payload returned on reopen.
#[derive(Debug, Clone, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct WorkspaceDetail {
    pub id: String,
    pub name: String,
    pub connection_id: String,
    pub connection_name: String,
    pub editor_text: String,
    pub variables_json: String,
    pub cursor_position: Option<i64>,
    pub results: Vec<WorkspaceResultMeta>,
}
```

- [ ] **Step 2: Export from `models/mod.rs`.** Add:

```rust
pub mod workspace;
pub use workspace::{WorkspaceDetail, WorkspaceResultMeta, WorkspaceSummary, WorkspaceUpsert};
```

(Match the existing `pub mod ...; pub use ...;` style already in `models/mod.rs`.)

- [ ] **Step 3: Build.** Run: `cd pharos-core && cargo build --release`
  Expected: compiles (structs unused warnings are fine until wired).

- [ ] **Step 4: Commit.**

```bash
git add pharos-core/src/models/workspace.rs pharos-core/src/models/mod.rs
git commit -m "feat(core): workspace model structs"
```

---

### Task 1.2: sqlite — `upsert_workspace`

Create-or-update. On CREATE, set `connection_id`/`connection_name`/`created_at` (these
are "first queried" and never overwritten). On UPDATE, refresh `editor_text`,
`variables_json`, `cursor_position`, `last_activity_at`, and `name`/`name_is_custom`
(only when a custom rename is being applied — see Task 1.6 for rename; the execute-path
upsert passes `name_is_custom=false` and must NOT clobber a prior custom name).

**Files:**
- Modify: `pharos-core/src/db/sqlite.rs` (Query History section, after `save_query_history`)

- [ ] **Step 1: Implement.**

```rust
/// Create or update a workspace. Connection identity + created_at are set only
/// on first insert. Editor snapshot fields are always refreshed. A non-custom
/// upsert never overwrites an existing custom name.
pub fn upsert_workspace(conn: &Connection, w: &crate::models::WorkspaceUpsert) -> SqliteResult<()> {
    let now = chrono::Utc::now().to_rfc3339();
    conn.execute(
        r#"
        INSERT INTO workspaces
            (id, name, name_is_custom, connection_id, connection_name,
             editor_text, variables_json, cursor_position, created_at, last_activity_at)
        VALUES (?1, ?2, ?3, ?4, ?5, ?6, ?7, ?8, ?9, ?9)
        ON CONFLICT(id) DO UPDATE SET
            editor_text = excluded.editor_text,
            variables_json = excluded.variables_json,
            cursor_position = excluded.cursor_position,
            last_activity_at = excluded.last_activity_at,
            name = CASE WHEN excluded.name_is_custom = 1 THEN excluded.name ELSE workspaces.name END,
            name_is_custom = CASE WHEN excluded.name_is_custom = 1 THEN 1 ELSE workspaces.name_is_custom END
        "#,
        (
            &w.id,
            &w.name,
            &(w.name_is_custom as i64),
            &w.connection_id,
            &w.connection_name,
            &w.editor_text,
            &w.variables_json,
            &w.cursor_position,
            &now,
        ),
    )?;
    Ok(())
}
```

- [ ] **Step 2: Build.** `cd pharos-core && cargo build --release` → compiles.
- [ ] **Step 3: Commit.** `git commit -am "feat(core): upsert_workspace"`

---

### Task 1.3: sqlite — `associate_result_to_workspace` + budget enforcement

**Files:**
- Modify: `pharos-core/src/db/sqlite.rs`

- [ ] **Step 1: Implement.** Add after `upsert_workspace`:

```rust
const WORKSPACE_BUDGET_BYTES: i64 = 100 * 1024 * 1024; // 100 MB compressed

/// Stamp a query_history row with its workspace association + result-tab display
/// metadata, then enforce the per-workspace blob budget by demoting oldest cached
/// results to "SQL only".
pub fn associate_result_to_workspace(
    conn: &Connection,
    history_id: &str,
    workspace_id: &str,
    result_order: i64,
    color_index: i64,
) -> SqliteResult<()> {
    conn.execute(
        "UPDATE query_history SET workspace_id = ?1, result_order = ?2, color_index = ?3 WHERE id = ?4",
        (workspace_id, result_order, color_index, history_id),
    )?;
    enforce_workspace_budget(conn, workspace_id)?;
    Ok(())
}

/// Drop cached blobs from the oldest results in a workspace until the total
/// compressed blob size is within WORKSPACE_BUDGET_BYTES. Rows are kept (SQL only).
pub fn enforce_workspace_budget(conn: &Connection, workspace_id: &str) -> SqliteResult<()> {
    let mut stmt = conn.prepare(
        "SELECT id, COALESCE(LENGTH(result_columns),0) + COALESCE(LENGTH(result_rows),0) AS sz
         FROM query_history
         WHERE workspace_id = ?1 AND result_columns IS NOT NULL
         ORDER BY result_order ASC, executed_at ASC",
    )?;
    let sizes: Vec<(String, i64)> = stmt
        .query_map([workspace_id], |row| Ok((row.get::<_, String>(0)?, row.get::<_, i64>(1)?)))?
        .collect::<SqliteResult<Vec<_>>>()?;

    for id in results_to_demote(&sizes, WORKSPACE_BUDGET_BYTES) {
        conn.execute(
            "UPDATE query_history SET result_columns = NULL, result_rows = NULL WHERE id = ?1",
            [&id],
        )?;
    }
    Ok(())
}
```

- [ ] **Step 2: Build.** `cd pharos-core && cargo build --release` → compiles.
- [ ] **Step 3: Commit.** `git commit -am "feat(core): associate_result_to_workspace + budget enforcement"`

---

### Task 1.4: sqlite — `load_workspaces` (list summaries, searchable)

**Files:**
- Modify: `pharos-core/src/db/sqlite.rs`

- [ ] **Step 1: Implement.**

```rust
/// Load workspace summaries, newest activity first. When `search` is set, a
/// workspace matches if its name/editor_text match OR any child query SQL matches.
pub fn load_workspaces(
    conn: &Connection,
    search: Option<&str>,
    limit: i64,
    offset: i64,
) -> SqliteResult<Vec<crate::models::WorkspaceSummary>> {
    let mut sql = String::from(
        "SELECT w.id, w.name, w.name_is_custom, w.connection_name, w.last_activity_at,
                (SELECT COUNT(*) FROM query_history qh WHERE qh.workspace_id = w.id) AS query_count,
                (SELECT COUNT(DISTINCT qh.connection_id) FROM query_history qh WHERE qh.workspace_id = w.id) AS distinct_db_count
         FROM workspaces w WHERE 1=1",
    );
    let mut params: Vec<Box<dyn rusqlite::ToSql>> = Vec::new();
    let mut idx = 1;

    if let Some(q) = search {
        if !q.is_empty() {
            let escaped = escape_fts5_query(q);
            sql.push_str(&format!(
                " AND (w.rowid IN (SELECT rowid FROM workspaces_fts WHERE workspaces_fts MATCH ?{i})
                       OR w.id IN (SELECT qh.workspace_id FROM query_history qh
                                   WHERE qh.workspace_id IS NOT NULL
                                     AND qh.rowid IN (SELECT rowid FROM query_history_fts WHERE query_history_fts MATCH ?{i})))",
                i = idx
            ));
            params.push(Box::new(escaped));
            idx += 1;
        }
    }

    sql.push_str(&format!(" ORDER BY w.last_activity_at DESC LIMIT ?{} OFFSET ?{}", idx, idx + 1));
    params.push(Box::new(limit));
    params.push(Box::new(offset));

    let params_refs: Vec<&dyn rusqlite::ToSql> = params.iter().map(|p| p.as_ref()).collect();
    let mut stmt = conn.prepare(&sql)?;
    let rows = stmt.query_map(params_refs.as_slice(), |row| {
        let name: Option<String> = row.get(1)?;
        let name_is_custom: i64 = row.get(2)?;
        let connection_name: String = row.get(3)?;
        let distinct_db_count: i64 = row.get(6)?;
        Ok(crate::models::WorkspaceSummary {
            id: row.get(0)?,
            name: resolve_workspace_name(name.as_deref(), name_is_custom != 0, &connection_name, distinct_db_count),
            connection_name,
            distinct_db_count,
            query_count: row.get(5)?,
            last_activity_at: row.get(4)?,
        })
    })?;
    rows.collect()
}
```

- [ ] **Step 2: Build.** `cd pharos-core && cargo build --release` → compiles.
- [ ] **Step 3: Commit.** `git commit -am "feat(core): load_workspaces summaries with FTS search"`

---

### Task 1.5: sqlite — `load_workspace` (full detail for reopen)

**Files:**
- Modify: `pharos-core/src/db/sqlite.rs`

- [ ] **Step 1: Implement.**

```rust
/// Load a workspace with its ordered child results (metadata only; blobs are
/// fetched per-result via get_query_history_result).
pub fn load_workspace(conn: &Connection, id: &str) -> SqliteResult<Option<crate::models::WorkspaceDetail>> {
    let head = conn.query_row(
        "SELECT id, name, name_is_custom, connection_id, connection_name, editor_text, variables_json, cursor_position
         FROM workspaces WHERE id = ?1",
        [id],
        |row| {
            let name: Option<String> = row.get(1)?;
            let name_is_custom: i64 = row.get(2)?;
            let connection_name: String = row.get(4)?;
            Ok((
                row.get::<_, String>(0)?,
                resolve_workspace_name(name.as_deref(), name_is_custom != 0, &connection_name, 1),
                row.get::<_, String>(3)?,
                connection_name,
                row.get::<_, String>(5)?,
                row.get::<_, String>(6)?,
                row.get::<_, Option<i64>>(7)?,
            ))
        },
    );

    let (wid, resolved_name, connection_id, connection_name, editor_text, variables_json, cursor_position) =
        match head {
            Ok(v) => v,
            Err(rusqlite::Error::QueryReturnedNoRows) => return Ok(None),
            Err(e) => return Err(e),
        };

    let mut stmt = conn.prepare(
        "SELECT id, sql, result_order, color_index, custom_label, row_count, column_count,
                schema, table_names, (result_columns IS NOT NULL) AS has_results,
                execution_time_ms, executed_at
         FROM query_history WHERE workspace_id = ?1
         ORDER BY result_order ASC, executed_at ASC",
    )?;
    let results = stmt
        .query_map([id], |row| {
            Ok(crate::models::WorkspaceResultMeta {
                id: row.get(0)?,
                sql: row.get(1)?,
                result_order: row.get(2)?,
                color_index: row.get(3)?,
                custom_label: row.get(4)?,
                row_count: row.get(5)?,
                column_count: row.get(6)?,
                schema: row.get(7)?,
                table_names: row.get(8)?,
                has_results: row.get(9)?,
                execution_time_ms: row.get(10)?,
                executed_at: row.get(11)?,
            })
        })?
        .collect::<SqliteResult<Vec<_>>>()?;

    Ok(Some(crate::models::WorkspaceDetail {
        id: wid,
        name: resolved_name,
        connection_id,
        connection_name,
        editor_text,
        variables_json,
        cursor_position,
        results,
    }))
}
```

- [ ] **Step 2: Build + Commit.** `cd pharos-core && cargo build --release`; `git commit -am "feat(core): load_workspace detail with ordered results"`

---

### Task 1.6: sqlite — rename / duplicate / delete / delete-result / update-result-meta

**Files:**
- Modify: `pharos-core/src/db/sqlite.rs`

- [ ] **Step 1: Implement all five.**

```rust
/// Rename a workspace (sets it custom so auto-naming stops overriding it).
pub fn rename_workspace(conn: &Connection, id: &str, name: &str) -> SqliteResult<bool> {
    let n = conn.execute(
        "UPDATE workspaces SET name = ?1, name_is_custom = 1 WHERE id = ?2",
        (name, id),
    )?;
    Ok(n > 0)
}

/// Delete a workspace and cascade-delete its child results.
pub fn delete_workspace(conn: &Connection, id: &str) -> SqliteResult<bool> {
    conn.execute("DELETE FROM query_history WHERE workspace_id = ?1", [id])?;
    let n = conn.execute("DELETE FROM workspaces WHERE id = ?1", [id])?;
    Ok(n > 0)
}

/// Delete a single child result from a workspace.
pub fn delete_workspace_result(conn: &Connection, result_id: &str) -> SqliteResult<bool> {
    let n = conn.execute(
        "DELETE FROM query_history WHERE id = ?1 AND workspace_id IS NOT NULL",
        [result_id],
    )?;
    Ok(n > 0)
}

/// Update a child result's display metadata (custom label and/or color index).
pub fn update_result_meta(
    conn: &Connection,
    result_id: &str,
    custom_label: Option<&str>,
    color_index: Option<i64>,
) -> SqliteResult<bool> {
    let n = conn.execute(
        "UPDATE query_history
         SET custom_label = COALESCE(?2, custom_label),
             color_index  = COALESCE(?3, color_index)
         WHERE id = ?1",
        (result_id, custom_label, color_index),
    )?;
    Ok(n > 0)
}

/// Duplicate a workspace (new id) including its children and cached blobs.
/// Returns the new workspace id.
pub fn duplicate_workspace(conn: &Connection, id: &str) -> SqliteResult<Option<String>> {
    let exists: bool = conn
        .query_row("SELECT COUNT(*) FROM workspaces WHERE id = ?1", [id], |r| r.get::<_, i64>(0))
        .map(|c| c > 0)
        .unwrap_or(false);
    if !exists {
        return Ok(None);
    }
    let new_id = uuid::Uuid::new_v4().to_string();
    let now = chrono::Utc::now().to_rfc3339();
    conn.execute(
        "INSERT INTO workspaces
            (id, name, name_is_custom, connection_id, connection_name, editor_text, variables_json, cursor_position, created_at, last_activity_at)
         SELECT ?1,
                CASE WHEN name IS NULL THEN NULL ELSE name || ' (copy)' END,
                name_is_custom, connection_id, connection_name, editor_text, variables_json, cursor_position, ?2, ?2
         FROM workspaces WHERE id = ?3",
        (&new_id, &now, id),
    )?;
    // Copy children with fresh ids, preserving order/blobs/metadata.
    let mut stmt = conn.prepare(
        "SELECT connection_id, connection_name, sql, row_count, execution_time_ms, executed_at,
                result_columns, result_rows, schema, column_count, table_names,
                result_order, color_index, custom_label
         FROM query_history WHERE workspace_id = ?1 ORDER BY result_order ASC, executed_at ASC",
    )?;
    let rows: Vec<_> = stmt
        .query_map([id], |r| {
            Ok((
                r.get::<_, String>(0)?, r.get::<_, String>(1)?, r.get::<_, String>(2)?,
                r.get::<_, Option<i64>>(3)?, r.get::<_, i64>(4)?, r.get::<_, String>(5)?,
                r.get::<_, Option<Vec<u8>>>(6)?, r.get::<_, Option<Vec<u8>>>(7)?,
                r.get::<_, Option<String>>(8)?, r.get::<_, Option<i64>>(9)?, r.get::<_, Option<String>>(10)?,
                r.get::<_, Option<i64>>(11)?, r.get::<_, Option<i64>>(12)?, r.get::<_, Option<String>>(13)?,
            ))
        })?
        .collect::<SqliteResult<Vec<_>>>()?;
    for row in rows {
        let child_id = uuid::Uuid::new_v4().to_string();
        conn.execute(
            "INSERT INTO query_history
                (id, connection_id, connection_name, sql, row_count, execution_time_ms, executed_at,
                 result_columns, result_rows, schema, column_count, table_names,
                 workspace_id, result_order, color_index, custom_label)
             VALUES (?1,?2,?3,?4,?5,?6,?7,?8,?9,?10,?11,?12,?13,?14,?15,?16)",
            (
                &child_id, &row.0, &row.1, &row.2, &row.3, &row.4, &row.5,
                &row.6, &row.7, &row.8, &row.9, &row.10,
                &new_id, &row.11, &row.12, &row.13,
            ),
        )?;
    }
    Ok(Some(new_id))
}
```

- [ ] **Step 2: Build + Commit.** `cd pharos-core && cargo build --release`;
  `git commit -am "feat(core): workspace rename/duplicate/delete/result ops"`

---

### Task 1.7: Retention keyed on workspace `last_activity_at`

**Files:**
- Modify: `pharos-core/src/db/sqlite.rs:650-660` (the prune block inside `save_query_history`)

- [ ] **Step 1: Extend the prune to also drop stale workspaces (cascading children).**
  Replace the prune `if` body (currently only deletes old `query_history` rows) with:

```rust
    if PRUNE_COUNTER.fetch_add(1, Ordering::Relaxed) % 100 == 0 {
        let cutoff = format!("-{} days", HISTORY_RETENTION_DAYS);
        // Drop stale workspaces (by last activity) and their children.
        conn.execute(
            "DELETE FROM query_history WHERE workspace_id IN
                (SELECT id FROM workspaces WHERE datetime(last_activity_at) < datetime('now', ?1))",
            [&cutoff],
        )?;
        conn.execute(
            "DELETE FROM workspaces WHERE datetime(last_activity_at) < datetime('now', ?1)",
            [&cutoff],
        )?;
        // Drop stale legacy (workspace_id IS NULL) rows by their own executed_at.
        conn.execute(
            "DELETE FROM query_history WHERE workspace_id IS NULL AND datetime(executed_at) < datetime('now', ?1)",
            [&cutoff],
        )?;
    }
```

- [ ] **Step 2: Build + Commit.** `cd pharos-core && cargo build --release`;
  `git commit -am "feat(core): retention prunes stale workspaces by last activity"`

---

### Task 1.8: Command layer (`commands/workspace.rs`)

**Files:**
- Create: `pharos-core/src/commands/workspace.rs`
- Modify: `pharos-core/src/commands/mod.rs` (add `pub mod workspace; pub use workspace::*;` in the existing style)

- [ ] **Step 1: Implement the async command wrappers** (mirror
  `commands/query_history.rs` — all take `&AppState`, lock `state.metadata_db`, map
  errors to `String`):

```rust
use crate::db::sqlite;
use crate::models::{WorkspaceDetail, WorkspaceSummary, WorkspaceUpsert};
use crate::state::AppState;

pub async fn upsert_workspace(w: WorkspaceUpsert, state: &AppState) -> Result<(), String> {
    let db = state.metadata_db.lock().map_err(|e| e.to_string())?;
    sqlite::upsert_workspace(&db, &w).map_err(|e| format!("Failed to upsert workspace: {}", e))
}

pub async fn associate_result(
    history_id: String, workspace_id: String, result_order: i64, color_index: i64, state: &AppState,
) -> Result<(), String> {
    let db = state.metadata_db.lock().map_err(|e| e.to_string())?;
    sqlite::associate_result_to_workspace(&db, &history_id, &workspace_id, result_order, color_index)
        .map_err(|e| format!("Failed to associate result: {}", e))
}

pub async fn load_workspaces(
    search: Option<String>, limit: Option<i64>, offset: Option<i64>, state: &AppState,
) -> Result<Vec<WorkspaceSummary>, String> {
    let db = state.metadata_db.lock().map_err(|e| e.to_string())?;
    match sqlite::load_workspaces(&db, search.as_deref(), limit.unwrap_or(200), offset.unwrap_or(0)) {
        Ok(v) => Ok(v),
        Err(e) if search.is_some() => sqlite::load_workspaces(&db, None, limit.unwrap_or(200), offset.unwrap_or(0))
            .map_err(|e2| format!("Failed to load workspaces: {} (fallback: {})", e, e2)),
        Err(e) => Err(format!("Failed to load workspaces: {}", e)),
    }
}

pub async fn load_workspace(id: String, state: &AppState) -> Result<Option<WorkspaceDetail>, String> {
    let db = state.metadata_db.lock().map_err(|e| e.to_string())?;
    sqlite::load_workspace(&db, &id).map_err(|e| format!("Failed to load workspace: {}", e))
}

pub async fn rename_workspace(id: String, name: String, state: &AppState) -> Result<bool, String> {
    let db = state.metadata_db.lock().map_err(|e| e.to_string())?;
    sqlite::rename_workspace(&db, &id, &name).map_err(|e| format!("Failed to rename workspace: {}", e))
}

pub async fn duplicate_workspace(id: String, state: &AppState) -> Result<Option<String>, String> {
    let db = state.metadata_db.lock().map_err(|e| e.to_string())?;
    sqlite::duplicate_workspace(&db, &id).map_err(|e| format!("Failed to duplicate workspace: {}", e))
}

pub async fn delete_workspace(id: String, state: &AppState) -> Result<bool, String> {
    let db = state.metadata_db.lock().map_err(|e| e.to_string())?;
    sqlite::delete_workspace(&db, &id).map_err(|e| format!("Failed to delete workspace: {}", e))
}

pub async fn delete_workspace_result(result_id: String, state: &AppState) -> Result<bool, String> {
    let db = state.metadata_db.lock().map_err(|e| e.to_string())?;
    sqlite::delete_workspace_result(&db, &result_id).map_err(|e| format!("Failed to delete result: {}", e))
}

pub async fn update_result_meta(
    result_id: String, custom_label: Option<String>, color_index: Option<i64>, state: &AppState,
) -> Result<bool, String> {
    let db = state.metadata_db.lock().map_err(|e| e.to_string())?;
    sqlite::update_result_meta(&db, &result_id, custom_label.as_deref(), color_index)
        .map_err(|e| format!("Failed to update result meta: {}", e))
}
```

- [ ] **Step 2: Build + Commit.** `cd pharos-core && cargo build --release`;
  `git commit -am "feat(core): workspace command layer"`

---

## Phase 2 — FFI + build

### Task 2.1: `ExecuteResult` returns `history_entry_id`

So statement results (INSERT/UPDATE/DELETE) can be associated with a workspace.

**Files:**
- Modify: `pharos-core/src/commands/query.rs:415-446` and the `ExecuteResult` struct (`:448`)

- [ ] **Step 1: Add the field to `ExecuteResult`.** In the struct at `query.rs:448`:

```rust
#[derive(Debug, Clone, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct ExecuteResult {
    pub rows_affected: u64,
    pub execution_time_ms: u64,
    #[serde(skip_serializing_if = "Option::is_none")]
    pub history_entry_id: Option<String>,
}
```

- [ ] **Step 2: Populate it in `execute_statement`.** In the history block at
  `query.rs:415-440`, hoist the id: change `id: uuid::Uuid::new_v4().to_string(),` to
  use a `let statement_history_id = uuid::Uuid::new_v4().to_string();` declared just
  above `let entry = ...`, set `id: statement_history_id.clone(),`, then update the
  return at `:442`:

```rust
    Ok(ExecuteResult {
        rows_affected,
        execution_time_ms,
        history_entry_id: Some(statement_history_id),
    })
```

- [ ] **Step 3: Raise the per-result cache cap to 10 MB.** In `execute_query` at
  `query.rs:232`, replace `< 5_000_000` with `< 10_000_000`. (Add a
  `// per-result cache cap: 10 MB uncompressed serialized JSON` comment.)

- [ ] **Step 4: Build.** `cd pharos-core && cargo build --release` → compiles.
  Fix any other construction sites of `ExecuteResult` the compiler flags (add
  `history_entry_id: None`).

- [ ] **Step 5: Commit.** `git commit -am "feat(core): ExecuteResult carries history_entry_id; 10MB result cap"`

---

### Task 2.2: FFI wrappers (`ffi/workspace.rs`)

**Files:**
- Create: `pharos-core/src/ffi/workspace.rs`
- Modify: `pharos-core/src/ffi/mod.rs` (add `pub mod workspace;` next to the other `pub mod`s)

- [ ] **Step 1: Implement the FFI functions**, mirroring `ffi/query_history.rs`
  (`ffi_sync!`, `app_state()`, `runtime()`, `c_str_to_string`, `to_json_c_string`,
  `to_c_string`). Write all nine:

```rust
use std::os::raw::c_char;
use super::*;

/// Upsert a workspace. `json` = WorkspaceUpsert. Returns "true" or error JSON.
#[no_mangle]
pub extern "C" fn pharos_upsert_workspace(json: *const c_char) -> *mut c_char {
    ffi_sync!({
        let state = app_state();
        let rt = runtime();
        let s = unsafe { c_str_to_string(json) };
        let w: crate::models::WorkspaceUpsert = match serde_json::from_str(&s) {
            Ok(w) => w,
            Err(e) => return to_c_string(&serde_json::json!({"error": e.to_string()}).to_string()),
        };
        match rt.block_on(crate::commands::upsert_workspace(w, state)) {
            Ok(()) => to_c_string("true"),
            Err(e) => to_c_string(&serde_json::json!({"error": e}).to_string()),
        }
    })
}

/// Associate a result. `json` = {historyId, workspaceId, resultOrder, colorIndex}.
#[no_mangle]
pub extern "C" fn pharos_associate_result(json: *const c_char) -> *mut c_char {
    ffi_sync!({
        let state = app_state();
        let rt = runtime();
        let s = unsafe { c_str_to_string(json) };
        #[derive(serde::Deserialize)]
        #[serde(rename_all = "camelCase")]
        struct Assoc { history_id: String, workspace_id: String, result_order: i64, color_index: i64 }
        let a: Assoc = match serde_json::from_str(&s) {
            Ok(a) => a,
            Err(e) => return to_c_string(&serde_json::json!({"error": e.to_string()}).to_string()),
        };
        match rt.block_on(crate::commands::associate_result(a.history_id, a.workspace_id, a.result_order, a.color_index, state)) {
            Ok(()) => to_c_string("true"),
            Err(e) => to_c_string(&serde_json::json!({"error": e}).to_string()),
        }
    })
}

/// Load workspace summaries. `json` = {search?, limit?, offset?}. Returns JSON array.
#[no_mangle]
pub extern "C" fn pharos_load_workspaces(json: *const c_char) -> *mut c_char {
    ffi_sync!({
        let state = app_state();
        let rt = runtime();
        let s = unsafe { c_str_to_string(json) };
        #[derive(serde::Deserialize, Default)]
        #[serde(rename_all = "camelCase")]
        struct F { search: Option<String>, limit: Option<i64>, offset: Option<i64> }
        let f: F = serde_json::from_str(&s).unwrap_or_default();
        match rt.block_on(crate::commands::load_workspaces(f.search, f.limit, f.offset, state)) {
            Ok(v) => to_json_c_string(&v),
            Err(e) => to_c_string(&serde_json::json!({"error": e}).to_string()),
        }
    })
}

/// Load a full workspace by id. Returns JSON object, or NULL if not found.
#[no_mangle]
pub extern "C" fn pharos_load_workspace(id: *const c_char) -> *mut c_char {
    ffi_sync!({
        let state = app_state();
        let rt = runtime();
        let id = unsafe { c_str_to_string(id) };
        match rt.block_on(crate::commands::load_workspace(id, state)) {
            Ok(Some(d)) => to_json_c_string(&d),
            Ok(None) => std::ptr::null_mut(),
            Err(e) => to_c_string(&serde_json::json!({"error": e}).to_string()),
        }
    })
}

/// Rename a workspace. `json` = {id, name}. Returns "true"/"false".
#[no_mangle]
pub extern "C" fn pharos_rename_workspace(json: *const c_char) -> *mut c_char {
    ffi_sync!({
        let state = app_state();
        let rt = runtime();
        let s = unsafe { c_str_to_string(json) };
        #[derive(serde::Deserialize)] struct R { id: String, name: String }
        let r: R = match serde_json::from_str(&s) { Ok(r) => r, Err(e) => return to_c_string(&serde_json::json!({"error": e.to_string()}).to_string()) };
        match rt.block_on(crate::commands::rename_workspace(r.id, r.name, state)) {
            Ok(ok) => to_c_string(if ok { "true" } else { "false" }),
            Err(e) => to_c_string(&serde_json::json!({"error": e}).to_string()),
        }
    })
}

/// Duplicate a workspace. Arg = id string. Returns the new id string, or error JSON.
#[no_mangle]
pub extern "C" fn pharos_duplicate_workspace(id: *const c_char) -> *mut c_char {
    ffi_sync!({
        let state = app_state();
        let rt = runtime();
        let id = unsafe { c_str_to_string(id) };
        match rt.block_on(crate::commands::duplicate_workspace(id, state)) {
            Ok(Some(new_id)) => to_c_string(&new_id),
            Ok(None) => std::ptr::null_mut(),
            Err(e) => to_c_string(&serde_json::json!({"error": e}).to_string()),
        }
    })
}

/// Delete a workspace (cascades). Arg = id string. Returns "true"/"false".
#[no_mangle]
pub extern "C" fn pharos_delete_workspace(id: *const c_char) -> *mut c_char {
    ffi_sync!({
        let state = app_state();
        let rt = runtime();
        let id = unsafe { c_str_to_string(id) };
        match rt.block_on(crate::commands::delete_workspace(id, state)) {
            Ok(ok) => to_c_string(if ok { "true" } else { "false" }),
            Err(e) => to_c_string(&serde_json::json!({"error": e}).to_string()),
        }
    })
}

/// Delete one child result. Arg = result id string. Returns "true"/"false".
#[no_mangle]
pub extern "C" fn pharos_delete_workspace_result(id: *const c_char) -> *mut c_char {
    ffi_sync!({
        let state = app_state();
        let rt = runtime();
        let id = unsafe { c_str_to_string(id) };
        match rt.block_on(crate::commands::delete_workspace_result(id, state)) {
            Ok(ok) => to_c_string(if ok { "true" } else { "false" }),
            Err(e) => to_c_string(&serde_json::json!({"error": e}).to_string()),
        }
    })
}

/// Update a result's display metadata. `json` = {resultId, customLabel?, colorIndex?}.
#[no_mangle]
pub extern "C" fn pharos_update_result_meta(json: *const c_char) -> *mut c_char {
    ffi_sync!({
        let state = app_state();
        let rt = runtime();
        let s = unsafe { c_str_to_string(json) };
        #[derive(serde::Deserialize)]
        #[serde(rename_all = "camelCase")]
        struct U { result_id: String, custom_label: Option<String>, color_index: Option<i64> }
        let u: U = match serde_json::from_str(&s) { Ok(u) => u, Err(e) => return to_c_string(&serde_json::json!({"error": e.to_string()}).to_string()) };
        match rt.block_on(crate::commands::update_result_meta(u.result_id, u.custom_label, u.color_index, state)) {
            Ok(ok) => to_c_string(if ok { "true" } else { "false" }),
            Err(e) => to_c_string(&serde_json::json!({"error": e}).to_string()),
        }
    })
}
```

- [ ] **Step 2: Build (regenerates the C header via cbindgen).**
  Run: `cd pharos-core && cargo build --release`
  Expected: compiles; the generated header (referenced by the `CPharosCore` module)
  now declares the nine `pharos_*` functions. Confirm with:
  `grep -c pharos_upsert_workspace target/*/build/*/out/*.h 2>/dev/null || true` (path
  varies; the Xcode build wires the header — Step verified in Task 3.x build).

- [ ] **Step 3: Commit.** `git commit -am "feat(core): workspace FFI wrappers"`

---

## Phase 3 — Swift bridge

### Task 3.1: Swift models

**Files:**
- Create: `Pharos/Models/Workspace.swift`
- Then run `xcodegen generate`.

- [ ] **Step 1: Create the models** (Codable; match Rust camelCase JSON):

```swift
import Foundation

/// Payload sent to Rust to create/refresh a workspace snapshot.
struct WorkspaceUpsert: Codable {
    var id: String
    var name: String?
    var nameIsCustom: Bool
    var connectionId: String
    var connectionName: String
    var editorText: String
    var variablesJson: String
    var cursorPosition: Int?
}

/// A row in the workspace list.
struct WorkspaceSummary: Codable {
    let id: String
    let name: String
    let connectionName: String
    let distinctDbCount: Int
    let queryCount: Int
    let lastActivityAt: String
}

/// One child result's metadata.
struct WorkspaceResultMeta: Codable {
    let id: String
    let sql: String
    let resultOrder: Int?
    let colorIndex: Int?
    let customLabel: String?
    let rowCount: Int?
    let columnCount: Int?
    let schema: String?
    let tableNames: String?
    let hasResults: Bool
    let executionTimeMs: Int
    let executedAt: String
}

/// Full workspace payload for reopen.
struct WorkspaceDetail: Codable {
    let id: String
    let name: String
    let connectionId: String
    let connectionName: String
    let editorText: String
    let variablesJson: String
    let cursorPosition: Int?
    let results: [WorkspaceResultMeta]
}
```

- [ ] **Step 2: Regenerate project + build.**
  Run: `cd /Users/nfinn/Projects/aSideProjects/Pharos && xcodegen generate`
  Run: `xcodebuild -scheme Pharos -configuration Debug build` → BUILD SUCCEEDED.

- [ ] **Step 3: Commit.** `git add -A && git commit -m "feat: workspace Swift models"`

---

### Task 3.2: Swift FFI wrappers (`PharosCore+Workspaces.swift`) + `QueryTab.workspaceId`

**Files:**
- Create: `Pharos/Core/PharosCore+Workspaces.swift`
- Modify: `Pharos/Models/QueryTab.swift`

- [ ] **Step 1: Add `workspaceId` to `QueryTab`.** After `var variablesPanelVisible: Bool = false` (`QueryTab.swift:55`):

```swift
    /// The persisted workspace history record this tab is bound to. nil until
    /// the first query executes (or until reopened from history). When set,
    /// executed results associate to this workspace and appear as one history item.
    var workspaceId: String?
```

- [ ] **Step 2: Create the wrappers**, mirroring `PharosCore+QueryHistory.swift`
  (`callSync(input:)` for JSON-in/JSON-out; the manual `withCString` + `pharos_free_string`
  + error-dict pattern for string returns):

```swift
import Foundation
import CPharosCore

extension PharosCore {
    static func upsertWorkspace(_ w: WorkspaceUpsert) throws {
        _ = try callBoolResult(input: w) { pharos_upsert_workspace($0) }
    }

    struct ResultAssociation: Codable {
        let historyId: String
        let workspaceId: String
        let resultOrder: Int
        let colorIndex: Int
    }
    static func associateResult(_ a: ResultAssociation) throws {
        _ = try callBoolResult(input: a) { pharos_associate_result($0) }
    }

    struct WorkspaceFilter: Codable {
        var search: String? = nil
        var limit: Int? = 200
        var offset: Int? = 0
    }
    static func loadWorkspaces(filter: WorkspaceFilter = WorkspaceFilter()) throws -> [WorkspaceSummary] {
        try callSync(input: filter) { pharos_load_workspaces($0) }
    }

    static func loadWorkspace(id: String) throws -> WorkspaceDetail? {
        guard let ptr = id.withCString({ pharos_load_workspace($0) }) else { return nil }
        defer { pharos_free_string(ptr) }
        let json = String(cString: ptr)
        try throwIfError(json)
        return try JSONDecoder.pharos.decode(WorkspaceDetail.self, from: Data(json.utf8))
    }

    struct RenamePayload: Codable { let id: String; let name: String }
    @discardableResult
    static func renameWorkspace(id: String, name: String) throws -> Bool {
        try callBoolResult(input: RenamePayload(id: id, name: name)) { pharos_rename_workspace($0) }
    }

    static func duplicateWorkspace(id: String) throws -> String? {
        guard let ptr = id.withCString({ pharos_duplicate_workspace($0) }) else { return nil }
        defer { pharos_free_string(ptr) }
        let s = String(cString: ptr)
        try throwIfError(s)
        return s
    }

    @discardableResult
    static func deleteWorkspace(id: String) throws -> Bool {
        try callBoolString(arg: id) { pharos_delete_workspace($0) }
    }

    @discardableResult
    static func deleteWorkspaceResult(id: String) throws -> Bool {
        try callBoolString(arg: id) { pharos_delete_workspace_result($0) }
    }

    struct UpdateResultMetaPayload: Codable { let resultId: String; let customLabel: String?; let colorIndex: Int? }
    @discardableResult
    static func updateResultMeta(resultId: String, customLabel: String? = nil, colorIndex: Int? = nil) throws -> Bool {
        try callBoolResult(input: UpdateResultMetaPayload(resultId: resultId, customLabel: customLabel, colorIndex: colorIndex)) {
            pharos_update_result_meta($0)
        }
    }
}
```

- [ ] **Step 3: Add the small helpers** used above. If `PharosCore` lacks
  `throwIfError`, `callBoolResult`, `callBoolString`, add them to
  `PharosCore+Workspaces.swift` (private extension) mirroring the existing error/decoding
  handling in `PharosCore+QueryHistory.swift:29-40`:

```swift
private extension PharosCore {
    static func throwIfError(_ json: String) throws {
        if let data = json.data(using: .utf8),
           let dict = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
           let msg = dict["error"] as? String {
            throw PharosCoreError.rustError(msg)
        }
    }

    /// JSON-in, expects "true"/"false" or error JSON out.
    static func callBoolResult<T: Encodable>(input: T, _ call: (UnsafePointer<CChar>) -> UnsafeMutablePointer<CChar>?) throws -> Bool {
        let jsonStr = String(decoding: try JSONEncoder.pharos.encode(input), as: UTF8.self)
        guard let ptr = jsonStr.withCString({ call($0) }) else { throw PharosCoreError.nullResult }
        defer { pharos_free_string(ptr) }
        let s = String(cString: ptr)
        try throwIfError(s)
        return s == "true"
    }

    /// String-arg in, expects "true"/"false" or error JSON out.
    static func callBoolString(arg: String, _ call: (UnsafePointer<CChar>) -> UnsafeMutablePointer<CChar>?) throws -> Bool {
        guard let ptr = arg.withCString({ call($0) }) else { throw PharosCoreError.nullResult }
        defer { pharos_free_string(ptr) }
        let s = String(cString: ptr)
        try throwIfError(s)
        return s == "true"
    }
}
```

  > NOTE for executor: verify the exact signature of the existing `callSync(input:)`
  > helper in `PharosCore.swift` and match its generic constraints; reuse it rather than
  > duplicating if it already covers the JSON-in/typed-out case.

- [ ] **Step 4: Regenerate + build.** `xcodegen generate` then
  `xcodebuild -scheme Pharos -configuration Debug build` → BUILD SUCCEEDED.

- [ ] **Step 5: Commit.** `git add -A && git commit -m "feat: workspace Swift FFI wrappers + QueryTab.workspaceId"`

---

## Phase 4 — Capture wiring

### Task 4.1: Ensure-workspace + associate-result on execution

The single place result tabs are created from an executed query is
`ContentViewController`. Read the result-handling path (search for `addResultTab(` and
the `history_entry_id`/`historyEntryId` usage) to find where a `QueryResult`/
`ExecuteResult` becomes a `ResultTab`. Wire capture there.

**Files:**
- Modify: `Pharos/ViewControllers/ContentViewController.swift` (result-creation path;
  `resultTabs`/`resultTabsByEditorTab` at `:37-40`), `Pharos/Models/QueryResult.swift`
  (confirm `historyEntryId`), `Pharos/Models/ResultTab.swift`

- [ ] **Step 1: Add a `colorIndex` to `ResultTab`** so restore is deterministic.
  In `ResultTab.swift` after `let color: NSColor` (`:10`):

```swift
    /// Index into `ResultTab.palette` for this tab's color (persisted for restore).
    var colorIndex: Int = 0
```

  And update `nextColor()`/creation so `colorIndex` is captured. Simplest: at each
  result-tab creation site, set `rt.colorIndex = ResultTab.palette.firstIndex(of: rt.color) ?? 0`.

- [ ] **Step 2: Add a capture helper** to `ContentViewController` (near the result-tab
  management region). It ensures the active editor tab has a workspace and associates a
  freshly-produced result:

```swift
    /// Ensure the given editor tab has a persisted workspace, refreshing its
    /// editor/variables snapshot, and return the workspace id.
    @discardableResult
    private func ensureWorkspace(for tab: QueryTab) -> String? {
        let wsId = tab.workspaceId ?? UUID().uuidString
        guard let connId = tab.connectionId else { return tab.workspaceId }
        let connName = stateManager.connectionName(for: connId) ?? connId
        let varsJson = (try? String(decoding: JSONEncoder.pharos.encode(tab.variables), as: UTF8.self)) ?? "[]"
        let payload = WorkspaceUpsert(
            id: wsId,
            name: nil,
            nameIsCustom: false,
            connectionId: connId,
            connectionName: connName,
            editorText: tab.sql,
            variablesJson: varsJson,
            cursorPosition: tab.cursorPosition
        )
        do {
            try PharosCore.upsertWorkspace(payload)
            if tab.workspaceId == nil {
                stateManager.updateTab(id: tab.id) { $0.workspaceId = wsId }
            }
            return wsId
        } catch {
            NSLog("upsertWorkspace failed: \(error)")
            return tab.workspaceId
        }
    }

    /// Associate a produced result (identified by its history id) with the
    /// active editor tab's workspace, at the given order + color.
    private func associateResultToWorkspace(historyId: String, order: Int, colorIndex: Int) {
        guard let tab = stateManager.activeTab, let wsId = ensureWorkspace(for: tab) else { return }
        do {
            try PharosCore.associateResult(.init(historyId: historyId, workspaceId: wsId, resultOrder: order, colorIndex: colorIndex))
            NotificationCenter.default.post(name: .workspaceHistoryDidChange, object: nil)
        } catch {
            NSLog("associateResult failed: \(error)")
        }
    }
```

  > If `stateManager.connectionName(for:)` and `stateManager.activeTab` don't exist,
  > add thin accessors to `AppStateManager` (there is already `activeTabId` and a `tabs`
  > array to derive them). Confirm names during execution.

- [ ] **Step 3: Add the `.workspaceHistoryDidChange` notification name.** In
  `QueryHistoryVC.swift:3-6` extension:

```swift
    static let workspaceHistoryDidChange = Notification.Name("PharosWorkspaceHistoryDidChange")
```

- [ ] **Step 4: Call `associateResultToWorkspace` when a result tab is created.**
  At the result-creation site(s), after the `ResultTab` is built and its
  `queryResult.historyEntryId` (row queries) or `executeResult.historyEntryId`
  (statements) is known, call:

```swift
    if let hid = rt.queryResult?.historyEntryId ?? rt.executeResult?.historyEntryId {
        associateResultToWorkspace(historyId: hid, order: newResultOrder, colorIndex: rt.colorIndex)
    }
```

  where `newResultOrder` is the count of result tabs already in this editor tab (0-based
  append index). Use the same index basis you'll restore with in Task 5/6.

  > REQUIRES: `QueryResult` exposes `historyEntryId` (it does — `QueryResult.swift`) and
  > `ExecuteResult` now exposes `historyEntryId` (Task 2.1). Confirm the Swift
  > `ExecuteResult` model has the new optional field; add `var historyEntryId: String?`
  > to it if the Swift struct is hand-maintained.

- [ ] **Step 5: Build + verify wiring.** `xcodebuild -scheme Pharos -configuration Debug build` → BUILD SUCCEEDED.

- [ ] **Step 6: Commit.** `git add -A && git commit -m "feat: associate executed results to a workspace snapshot"`

---

### Task 4.2: Snapshot editor text on tab close / app quit

**Files:**
- Modify: `Pharos/ViewControllers/ContentViewController.swift` (tab-close path) and the
  app-termination path (`AppDelegate.swift` `applicationWillTerminate` or an
  `AppStateManager` teardown).

- [ ] **Step 1: On tab close**, before discarding a tab that has a `workspaceId`, call
  `ensureWorkspace(for:)` with its final `sql`/`variables`/`cursorPosition` so the last
  edits are captured. Find the close handler (search `closeTab` / `removeTab`) and add:

```swift
    if closingTab.workspaceId != nil { _ = ensureWorkspace(for: closingTab) }
```

- [ ] **Step 2: On app quit**, iterate `stateManager.tabs` and `ensureWorkspace(for:)`
  each tab whose `workspaceId != nil`. Add to `applicationWillTerminate` (route through
  a method on the content VC or AppStateManager that has access to `upsertWorkspace`).

- [ ] **Step 3: Build + Commit.** `xcodebuild ... build` → SUCCEEDED;
  `git commit -am "feat: flush workspace editor snapshot on tab close and quit"`

---

## Phase 5 — Sidebar UI (Layout B)

### Task 5.1: Row model + dual load (workspaces + legacy) + rendering

Rework `QueryHistoryVC` to show a heterogeneous list: workspace rows, then an "Earlier
history (N)" disclosure row, then (when expanded) legacy entries.

**Files:**
- Modify: `Pharos/ViewControllers/QueryHistoryVC.swift`

- [ ] **Step 1: Introduce the row enum + state.** Replace the `entries` field (`:53`)
  region with:

```swift
    private enum HistoryRow {
        case workspace(WorkspaceSummary)
        case earlierHeader(count: Int, expanded: Bool)
        case legacy(QueryHistoryEntry)
    }

    private var rows: [HistoryRow] = []
    private var workspaces: [WorkspaceSummary] = []
    private var legacyEntries: [QueryHistoryEntry] = []
    private var earlierExpanded = false
```

- [ ] **Step 2: Load both sources in `requery()`.** Replace the body of `requery()`
  (`:159-192`) so the detached task loads workspaces AND legacy (workspace_id IS NULL)
  entries. Legacy loading needs a Rust-side filter for NULL workspace — add a
  `only_legacy: bool` option to `load_query_history` (extend the FTS SQL with
  `AND workspace_id IS NULL` when set; thread through command + FFI `HistoryFilter` +
  Swift `QueryHistoryFilter`). Then:

```swift
    private func requery() {
        requeryGeneration &+= 1
        let generation = requeryGeneration
        let search = (filterText?.isEmpty ?? true) ? nil : filterText
        Task.detached(priority: .userInitiated) { [weak self] in
            let ws: [WorkspaceSummary]
            let legacy: [QueryHistoryEntry]
            do {
                ws = try PharosCore.loadWorkspaces(filter: .init(search: search, limit: 200, offset: 0))
                legacy = try PharosCore.loadQueryHistory(filter: QueryHistoryFilter(connectionId: nil, search: search, limit: 200, onlyLegacy: true))
            } catch {
                NSLog("Failed to load workspace history: \(error)")
                return
            }
            await MainActor.run {
                guard let self, generation == self.requeryGeneration else { return }
                self.workspaces = ws
                self.legacyEntries = legacy
                self.rebuildRows()
                self.tableView.reloadData()
            }
        }
    }

    private func rebuildRows() {
        var out: [HistoryRow] = workspaces.map { .workspace($0) }
        if !legacyEntries.isEmpty {
            out.append(.earlierHeader(count: legacyEntries.count, expanded: earlierExpanded))
            if earlierExpanded { out.append(contentsOf: legacyEntries.map { .legacy($0) }) }
        }
        rows = out
    }
```

  > The `QueryHistoryFilter` Swift struct (`Pharos/Models/QueryHistory.swift:32-37`) and
  > the Rust `load_query_history`/FFI `HistoryFilter` all gain an `onlyLegacy: bool`
  > (default false). Small change; include it in this task.

- [ ] **Step 3: Update `numberOfRows` + `viewFor`** to switch on `rows[row]`:
  - `.workspace(w)`: line1 `📊 <w.name>`; line2 `"<w.queryCount> quer{y|ies} · <relative(w.lastActivityAt)> · <w.connectionName>"`. Reuse `formatDate`.
  - `.earlierHeader(count, expanded)`: single line `"\(expanded ? "▾" : "▸") Earlier history (\(count))"`, secondary label empty, tinted `.secondaryLabelColor`.
  - `.legacy(e)`: exactly the current two-line rendering (`:259-294`) — keep that code, moved into this branch.

- [ ] **Step 4: Build + Commit.** `xcodebuild ... build` → SUCCEEDED;
  `git commit -am "feat: workspace list + Earlier history rows in QueryHistoryVC"`

---

### Task 5.2: Earlier-history expand/collapse + preview pane split

**Files:**
- Modify: `Pharos/ViewControllers/QueryHistoryVC.swift`

- [ ] **Step 1: Wrap the table in a vertical `NSSplitView`** with the workspace/legacy
  table on top and a preview table on the bottom. In `loadView()` replace the single
  `scrollView` install (`:80-92`) with a split view:

```swift
    private let previewTable = NSTableView()
    private let previewScroll = NSScrollView()
    private let splitView = NSSplitView()
    private var previewResults: [WorkspaceResultMeta] = []
```

  Configure `splitView.isVertical = false` (stacks top/bottom), `dividerStyle = .thin`,
  add the main `scrollView` and `previewScroll` as arranged subviews, set an autosave
  name (`"PharosHistoryPreviewSplit"`) so the divider height is remembered, and pin the
  split view to the container edges. Give `previewTable` one column, `rowHeight = 34`,
  headerless, and a `previewDoubleAction`.

- [ ] **Step 2: Toggle Earlier on single-click of the header row.** In
  `tableViewSelectionDidChange` (or a click handler), if the selected row is
  `.earlierHeader`, flip `earlierExpanded`, `rebuildRows()`, `reloadData()`. Otherwise
  update the preview pane (Step 3).

- [ ] **Step 3: Populate preview on workspace selection.** When the selected row is
  `.workspace(w)`, load its results into `previewResults` and reload `previewTable`:

```swift
    private func showPreview(for workspaceId: String) {
        Task.detached(priority: .userInitiated) { [weak self] in
            let detail = try? PharosCore.loadWorkspace(id: workspaceId)
            await MainActor.run {
                guard let self else { return }
                self.previewResults = detail?.results ?? []
                self.previewTable.reloadData()
            }
        }
    }
```

  Preview cell: a small colored dot (from `ResultTab.palette[colorIndex % count]`),
  the SQL snippet or `customLabel`, and either `"\(formatRowCount(rowCount)) rows"` or a
  dim `"SQL only"` badge when `!hasResults`. (Make `previewTable` its own
  `NSTableViewDataSource`/`Delegate` — either a nested type or `if tableView ==
  previewTable` branches in the shared delegate methods.)

- [ ] **Step 4: Build + Commit.** `xcodebuild ... build` → SUCCEEDED;
  `git commit -am "feat: preview pane + Earlier history expand/collapse"`

---

## Phase 6 — Reopen, actions, restore

### Task 6.1: Open notification + restore in ContentViewController

**Files:**
- Modify: `Pharos/ViewControllers/QueryHistoryVC.swift`, `Pharos/ViewControllers/ContentViewController.swift`

- [ ] **Step 1: Post open notifications.** Add names in the extension:

```swift
    static let openWorkspace = Notification.Name("PharosOpenWorkspace")
```

  Double-click behavior in `QueryHistoryVC` (`doubleClickedRow` + a `previewDoubleClicked`):
  - Main table double-click on `.workspace(w)` → post `.openWorkspace` with
    `userInfo: ["workspaceId": w.id]`.
  - Main table double-click on `.legacy(e)` → keep posting the existing `.openHistoryEntry`.
  - Preview double-click → post `.openWorkspace` with
    `["workspaceId": selectedWorkspaceId, "focusResultId": previewResults[row].id]`.

- [ ] **Step 2: Handle `.openWorkspace` in `ContentViewController`.** Register the
  observer next to the existing `.openHistoryEntry` one (`:320-324`) and implement:

```swift
    @objc private func handleOpenWorkspace(_ notification: Notification) {
        guard let wsId = notification.userInfo?["workspaceId"] as? String else { return }
        let focusResultId = notification.userInfo?["focusResultId"] as? String

        // Already open? Just focus it.
        if let existing = stateManager.tabs.first(where: { $0.workspaceId == wsId }) {
            stateManager.selectTab(id: existing.id)
            if let fid = focusResultId { focusResultTab(historyId: fid) }
            return
        }

        guard let detail = try? PharosCore.loadWorkspace(id: wsId), let detail else { return }

        let vars = (try? JSONDecoder.pharos.decode([QueryVariable].self, from: Data(detail.variablesJson.utf8))) ?? []
        let tab = stateManager.createTab(sql: detail.editorText, name: detail.name)
        stateManager.updateTab(id: tab.id) {
            $0.workspaceId = detail.id
            $0.connectionId = detail.connectionId
            $0.variables = vars
            $0.cursorPosition = detail.cursorPosition ?? 0
        }

        // Rebuild result tabs from metadata; fetch cached blobs eagerly for
        // results that have them, leave "SQL only" ones as re-runnable stubs.
        var restored: [ResultTab] = []
        for meta in detail.results {
            let color = ResultTab.palette[(meta.colorIndex ?? 0) % ResultTab.palette.count]
            var rt = ResultTab(
                id: UUID().uuidString,
                segmentIndex: -1,
                sql: meta.sql,
                lineRange: 0...0,
                color: color,
                timestamp: Date()
            )
            rt.colorIndex = meta.colorIndex ?? 0
            rt.customLabel = meta.customLabel ?? meta.tableNames
            rt.executionTimeMs = UInt64(meta.executionTimeMs)
            rt.historySchema = meta.schema
            rt.historyTimestamp = meta.executedAt
            rt.isStale = true
            if meta.hasResults, let data = try? PharosCore.getQueryHistoryResult(id: meta.id) {
                rt.queryResult = QueryResult(
                    columns: data.columns, rows: data.rows,
                    rowCount: data.rows.count, executionTimeMs: UInt64(meta.executionTimeMs),
                    hasMore: false, historyEntryId: meta.id
                )
            }
            restored.append(rt)
        }
        // Seed the per-editor-tab dictionaries directly (same reasoning as the
        // legacy handleOpenHistoryEntry path — activeTabChanged fires later on
        // RunLoop.main and will read these).
        resultTabsByEditorTab[tab.id] = restored
        let focus = focusResultId.flatMap { fid in restored.first(where: { $0.queryResult?.historyEntryId == fid }) } ?? restored.last
        activeResultTabIdByEditorTab[tab.id] = focus?.id
    }

    private func focusResultTab(historyId: String) {
        guard let idx = resultTabs.firstIndex(where: { $0.queryResult?.historyEntryId == historyId }) else { return }
        selectResultTab(id: resultTabs[idx].id)  // use the existing result-tab selection API
    }
```

  > Confirm the exact existing result-tab selection method name (search
  > `activeResultTabId =` / `func select...ResultTab`) and use it in `focusResultTab`.

- [ ] **Step 3: Build + Commit.** `xcodebuild ... build` → SUCCEEDED;
  `git commit -am "feat: reopen a workspace, restoring editor + variables + result tabs"`

---

### Task 6.2: Context menus — rename / duplicate / delete workspace; delete result

**Files:**
- Modify: `Pharos/ViewControllers/QueryHistoryVC.swift`

- [ ] **Step 1: Rebuild `menuNeedsUpdate`** to branch on the clicked row type:
  - `.workspace`: items **Rename…**, **Duplicate**, separator, **Delete**. Multi-select
    of workspaces → "Delete N Workspaces" (mirror existing multi-delete flow).
  - `.legacy`: keep the current Copy SQL / Delete items (existing behavior).
  - `.earlierHeader`: no menu.
  - Preview table menu: **Delete this result**, **Copy SQL**.

- [ ] **Step 2: Implement the actions.**

```swift
    @objc private func contextRenameWorkspace(_: Any?) {
        let row = tableView.clickedRow
        guard case .workspace(let w)? = rowAt(row) else { return }
        let alert = NSAlert()
        alert.messageText = "Rename Workspace"
        let field = NSTextField(string: w.name)
        field.frame = NSRect(x: 0, y: 0, width: 240, height: 24)
        alert.accessoryView = field
        alert.addButton(withTitle: "Rename"); alert.addButton(withTitle: "Cancel")
        guard let win = view.window else { return }
        alert.beginSheetModal(for: win) { [weak self] resp in
            guard resp == .alertFirstButtonReturn else { return }
            try? PharosCore.renameWorkspace(id: w.id, name: field.stringValue)
            self?.requery()
        }
    }

    @objc private func contextDuplicateWorkspace(_: Any?) {
        let row = tableView.clickedRow
        guard case .workspace(let w)? = rowAt(row) else { return }
        _ = try? PharosCore.duplicateWorkspace(id: w.id)
        requery()
    }

    @objc private func contextDeleteWorkspace(_: Any?) {
        let row = tableView.clickedRow
        guard case .workspace(let w)? = rowAt(row) else { return }
        _ = try? PharosCore.deleteWorkspace(id: w.id)
        requery()
    }

    @objc private func contextDeletePreviewResult(_: Any?) {
        let row = previewTable.clickedRow
        guard row >= 0, row < previewResults.count else { return }
        _ = try? PharosCore.deleteWorkspaceResult(id: previewResults[row].id)
        requery()
        if let wsId = selectedWorkspaceId { showPreview(for: wsId) }
    }

    private func rowAt(_ index: Int) -> HistoryRow? {
        guard index >= 0, index < rows.count else { return nil }
        return rows[index]
    }
```

  (Add a `selectedWorkspaceId` stored property, set in Step 5.2's selection handler.)

- [ ] **Step 3: Build + Commit.** `xcodebuild ... build` → SUCCEEDED;
  `git commit -am "feat: workspace + result context-menu actions"`

---

### Task 6.3: Persist result-tab rename/recolor via `update_result_meta`

**Files:**
- Modify: `Pharos/ViewControllers/ContentViewController.swift` (wherever a result tab's
  `customLabel`/color is edited — search `customLabel =` in the result-tab-bar handling)

- [ ] **Step 1:** When a user renames or recolors a *restored/associated* result tab
  (one whose `queryResult?.historyEntryId` is set), after updating the in-memory
  `ResultTab`, call:

```swift
    if let hid = rt.queryResult?.historyEntryId ?? rt.executeResult?.historyEntryId {
        try? PharosCore.updateResultMeta(resultId: hid, customLabel: rt.customLabel, colorIndex: rt.colorIndex)
    }
```

- [ ] **Step 2: Build + Commit.** `xcodebuild ... build` → SUCCEEDED;
  `git commit -am "feat: persist result-tab label/color to workspace history"`

---

## Phase 7 — Verification

### Task 7.1: Rust decode-seam integration check (live Postgres)

Per the lessons file: pure composer/unit tests miss the SQL→struct decode seam. Prove
the new columns/tables round-trip from real writes.

**Files:**
- Create: `pharos-core/tests/workspace_roundtrip.rs`

- [ ] **Step 1: Write an `#[ignore]` integration test** that opens a temp SQLite DB via
  `sqlite::init_database`, upserts a workspace, inserts a `query_history` row + associates
  it, then asserts `load_workspaces` and `load_workspace` decode every field correctly
  (name resolution, `has_results`, `variables_json` verbatim, ordered results). This
  exercises the real rusqlite row→struct mapping, not hand-built structs.

```rust
// Run with: cargo test --test workspace_roundtrip -- --ignored
#[test]
#[ignore]
fn workspace_roundtrips_through_sqlite() {
    // (Executor: use a tempdir; call pharos_core::db::sqlite functions directly.
    //  Assert resolve, counts, has_results, ordering. See design spec §Testing.)
}
```

  > If any `sqlite` fn is not `pub` at crate root, expose via `pub use` or make the test
  > a `#[cfg(test)] mod` inside `sqlite.rs` instead. Postgres itself isn't required for
  > this seam (the metadata store is SQLite); the *end-to-end* PG exercise is Task 7.2.

- [ ] **Step 2: Run.** `cd pharos-core && cargo test --test workspace_roundtrip -- --ignored`
  Expected: PASS.

- [ ] **Step 3: Commit.** `git add -A && git commit -m "test(core): workspace sqlite round-trip decode seam"`

### Task 7.2: End-to-end verification (`/verify`)

- [ ] **Step 1: Run the app** (`xcodegen generate`, open in Xcode, Cmd+R) against a real
  Postgres connection and walk the design's acceptance list:
  1. Run 3+ queries in ONE editor tab → History shows ONE workspace, auto-named after the
     DB, with the correct query count; preview lists all results with color dots + row counts.
  2. Query a second connection in the same tab → name becomes `"<db> +1"`.
  3. Rename the workspace → name sticks; running another query does NOT revert it.
  4. Close the tab, reopen the workspace (double-click) → editor text, variables, and all
     result tabs restore; grid shows cached rows with the history banner.
  5. Double-click a specific preview result → same restore, that result focused.
  6. Reopen an already-open workspace → focuses the existing tab (no duplicate).
  7. Duplicate → a separate `"… (copy)"` workspace appears; editing it doesn't touch the original.
  8. Exceed 100 MB (many/large results) → oldest demote to "SQL only"; re-running refreshes.
  9. Legacy rows appear under a collapsed "Earlier history"; expanding + double-clicking one
     still opens via the old single-result path.
  10. Search matches on workspace name, editor text, and a child query's SQL.

- [ ] **Step 2: Record results** in `tasks/todo.md` review section; capture any lesson in
  `tasks/lessons.md`.

---

## Notes for the executor

- **Confirm-before-coding accessors:** several steps reference `AppStateManager` /
  `ContentViewController` methods by likely name (`activeTab`, `connectionName(for:)`,
  `selectResultTab(id:)`, `closeTab`). Grep and use the real names; add thin accessors
  only if genuinely absent.
- **JSON casing:** Rust structs use `#[serde(rename_all = "camelCase")]`; Swift models are
  plain camelCase Codable. Keep them in lockstep — a rename on one side must match the other.
- **Don't touch the query execution hot path** beyond Task 2.1 (add a returned id + raise a
  constant). All workspace logic is post-hoc association, by design (lower risk, preserves
  cancellation/PID handling).
- **`callSync` reuse:** verify the existing `PharosCore.callSync(input:)` generic signature
  and prefer it over the local helpers in Task 3.2 where it already fits.
