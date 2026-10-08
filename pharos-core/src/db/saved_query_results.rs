//! The results a saved Session keeps beside its cards.
//!
//! A saved query is a saved Session: one tab of cards and the result each
//! card held when it was saved, rows and all (every page the grid had loaded,
//! not the first page `query_history` caches). These rows are the Session's
//! own copy. History retention, Clear History and the workspace budget never
//! touch this table; only deleting the Session (`ON DELETE CASCADE`) or saving
//! it again removes them.
//!
//! A save is two-phase, so a save that fails part-way leaves the snapshot
//! already stored as it was:
//! 1. `stage` inserts each result under a NEW `snapshot_id`, invisible to
//!    readers, which only see the snapshot `saved_queries.results_snapshot_id`
//!    names.
//! 2. `commit` (one transaction) carries over the stored results the caller
//!    keeps, drops the old snapshot, applies the budget and points the
//!    Session at the new one. `abort` removes a failed save's staged rows.
//!
//! The callers compress before they take the database lock; nothing here
//! compresses or parses rows.

use rusqlite::{Connection, OptionalExtension, Result as SqliteResult};

use super::sqlite::{get_saved_query, results_to_demote};
use crate::models::{
    CommitSavedQuerySnapshot, CommittedSavedQuerySnapshot, SavedQueryResultMeta, StageSavedQueryResult,
    StagedSavedQueryResult,
};

/// Compressed bytes of results one Session may keep.
pub const SAVED_SESSION_BUDGET_BYTES: i64 = 100 * 1024 * 1024;

/// One result's gzipped JSON. All None for an "affected" result.
#[derive(Debug, Default)]
pub struct CompressedResult {
    pub columns: Option<Vec<u8>>,
    pub rows: Option<Vec<u8>>,
    pub row_identity: Option<Vec<u8>>,
}

impl CompressedResult {
    pub fn byte_count(&self) -> i64 {
        [&self.columns, &self.rows, &self.row_identity]
            .iter()
            .map(|b| b.as_ref().map_or(0, |v| v.len() as i64))
            .sum()
    }

    fn has_rows(&self) -> bool {
        self.columns.is_some() && self.rows.is_some()
    }
}

/// The table, its index, and the clean-up of rows a crashed save left staged.
pub fn create_schema(conn: &Connection) -> SqliteResult<()> {
    conn.execute_batch(
        r#"
        CREATE TABLE IF NOT EXISTS saved_query_results (
            id TEXT PRIMARY KEY,
            saved_query_id TEXT NOT NULL REFERENCES saved_queries(id) ON DELETE CASCADE,
            snapshot_id TEXT NOT NULL,
            run_id TEXT NOT NULL,
            card_id TEXT NOT NULL,
            priority INTEGER NOT NULL,
            kind TEXT NOT NULL,
            sql TEXT NOT NULL,
            raw_sql TEXT,
            schema_name TEXT,
            executed_at TEXT NOT NULL,
            execution_time_ms INTEGER NOT NULL,
            rows_affected INTEGER,
            row_count INTEGER,
            has_more INTEGER NOT NULL DEFAULT 0,
            chart_view_state_json TEXT,
            result_columns BLOB,
            result_rows BLOB,
            result_row_identity BLOB,
            compressed_bytes INTEGER NOT NULL DEFAULT 0,
            rows_dropped INTEGER NOT NULL DEFAULT 0,
            UNIQUE (snapshot_id, run_id)
        );
        CREATE INDEX IF NOT EXISTS idx_saved_query_results_owner
            ON saved_query_results(saved_query_id, snapshot_id);
        "#,
    )?;
    remove_orphans(conn)
}

/// Rows of a snapshot that never became the Session's own: a save that
/// crashed between stage and commit.
fn remove_orphans(conn: &Connection) -> SqliteResult<()> {
    conn.execute(
        "DELETE FROM saved_query_results
         WHERE snapshot_id IS NOT (SELECT results_snapshot_id FROM saved_queries s
                                   WHERE s.id = saved_query_results.saved_query_id)",
        [],
    )?;
    Ok(())
}

/// Insert one result under the save's snapshot. When its rows would take
/// the staged snapshot over `budget`, only its metadata goes in.
pub fn stage(
    conn: &Connection,
    id: &str,
    row: &StageSavedQueryResult,
    blobs: CompressedResult,
    budget: i64,
) -> SqliteResult<StagedSavedQueryResult> {
    let staged: i64 = conn.query_row(
        "SELECT COALESCE(SUM(compressed_bytes), 0) FROM saved_query_results
         WHERE saved_query_id = ?1 AND snapshot_id = ?2",
        (&row.saved_query_id, &row.snapshot_id),
        |r| r.get(0),
    )?;
    let had_rows = blobs.has_rows();
    let fits = staged + blobs.byte_count() <= budget;
    let blobs = if fits { blobs } else { CompressedResult::default() };
    let bytes = blobs.byte_count();
    conn.execute(
        r#"
        INSERT INTO saved_query_results (
            id, saved_query_id, snapshot_id, run_id, card_id, priority, kind, sql, raw_sql,
            schema_name, executed_at, execution_time_ms, rows_affected, row_count, has_more,
            chart_view_state_json, result_columns, result_rows, result_row_identity,
            compressed_bytes, rows_dropped)
        VALUES (?1, ?2, ?3, ?4, ?5, ?6, ?7, ?8, ?9, ?10, ?11, ?12, ?13, ?14, ?15, ?16, ?17, ?18, ?19, ?20, ?21)
        "#,
        rusqlite::params![
            id,
            row.saved_query_id,
            row.snapshot_id,
            row.run_id,
            row.card_id,
            row.priority,
            row.kind,
            row.sql,
            row.raw_sql,
            row.schema_name,
            row.executed_at,
            row.execution_time_ms,
            row.rows_affected,
            row.row_count,
            row.has_more,
            row.chart_view_state_json,
            blobs.columns,
            blobs.rows,
            blobs.row_identity,
            bytes,
            had_rows && !fits,
        ],
    )?;
    Ok(StagedSavedQueryResult { id: id.to_string(), stored: !had_rows || fits, compressed_bytes: bytes })
}

/// Make the staged snapshot the Session's own, in one transaction. Returns
/// the Session as stored and the runs whose rows did not fit.
pub fn commit(
    conn: &Connection,
    commit: &CommitSavedQuerySnapshot,
    budget: i64,
) -> SqliteResult<CommittedSavedQuerySnapshot> {
    let tx = conn.unchecked_transaction()?;
    let current: Option<String> = tx.query_row(
        "SELECT results_snapshot_id FROM saved_queries WHERE id = ?1",
        [&commit.saved_query_id],
        |r| r.get(0),
    )?;

    // Stored results the caller keeps move to the new snapshot.
    if let Some(current) = &current {
        for keep in &commit.keep {
            tx.execute(
                "UPDATE saved_query_results SET snapshot_id = ?1, priority = ?2
                 WHERE saved_query_id = ?3 AND snapshot_id = ?4 AND run_id = ?5",
                (&commit.snapshot_id, keep.priority, &commit.saved_query_id, current, &keep.run_id),
            )?;
        }
    }
    tx.execute(
        "DELETE FROM saved_query_results WHERE saved_query_id = ?1 AND snapshot_id <> ?2",
        (&commit.saved_query_id, &commit.snapshot_id),
    )?;

    // Over the budget, the lowest priority loses its rows first.
    let sizes: Vec<(String, i64)> = tx
        .prepare(
            "SELECT id, compressed_bytes FROM saved_query_results
             WHERE saved_query_id = ?1 AND snapshot_id = ?2 AND compressed_bytes > 0
             ORDER BY priority DESC",
        )?
        .query_map((&commit.saved_query_id, &commit.snapshot_id), |r| Ok((r.get(0)?, r.get(1)?)))?
        .collect::<SqliteResult<_>>()?;
    for id in results_to_demote(&sizes, budget) {
        tx.execute(
            "UPDATE saved_query_results SET result_columns = NULL, result_rows = NULL,
                 result_row_identity = NULL, compressed_bytes = 0, rows_dropped = 1
             WHERE id = ?1",
            [&id],
        )?;
    }
    let dropped_run_ids: Vec<String> = tx
        .prepare(
            "SELECT run_id FROM saved_query_results
             WHERE saved_query_id = ?1 AND snapshot_id = ?2 AND rows_dropped = 1 ORDER BY priority",
        )?
        .query_map((&commit.saved_query_id, &commit.snapshot_id), |r| r.get(0))?
        .collect::<SqliteResult<_>>()?;
    let (bytes, count): (i64, i64) = tx.query_row(
        "SELECT COALESCE(SUM(compressed_bytes), 0), COUNT(*) FROM saved_query_results
         WHERE saved_query_id = ?1 AND snapshot_id = ?2",
        (&commit.saved_query_id, &commit.snapshot_id),
        |r| Ok((r.get(0)?, r.get(1)?)),
    )?;

    // The connection may have been deleted since the tab picked it: the
    // foreign key would refuse it, so a stale id is stored as NULL.
    let now = chrono::Utc::now().to_rfc3339();
    tx.execute(
        "UPDATE saved_queries SET sql = ?1, cards_json = ?2,
             connection_id = (SELECT id FROM connections WHERE id = ?3), schema_name = ?4,
             results_snapshot_id = ?5, results_saved_at = ?6, results_bytes = ?7, result_count = ?8,
             updated_at = ?6
         WHERE id = ?9",
        rusqlite::params![
            commit.sql,
            commit.cards_json,
            commit.connection_id,
            commit.schema_name,
            commit.snapshot_id,
            now,
            bytes,
            count,
            commit.saved_query_id,
        ],
    )?;
    tx.commit()?;

    let saved_query = get_saved_query(conn, &commit.saved_query_id)?.ok_or(rusqlite::Error::QueryReturnedNoRows)?;
    Ok(CommittedSavedQuerySnapshot { saved_query, dropped_run_ids })
}

/// Remove the rows a failed save staged. Never the Session's own snapshot.
pub fn abort(conn: &Connection, saved_query_id: &str, snapshot_id: &str) -> SqliteResult<usize> {
    conn.execute(
        "DELETE FROM saved_query_results
         WHERE saved_query_id = ?1 AND snapshot_id = ?2
           AND snapshot_id IS NOT (SELECT results_snapshot_id FROM saved_queries WHERE id = ?1)",
        (saved_query_id, snapshot_id),
    )
}

/// The Session's stored results, without rows, highest priority first.
pub fn load_metas(conn: &Connection, saved_query_id: &str) -> SqliteResult<Vec<SavedQueryResultMeta>> {
    let mut stmt = conn.prepare(
        r#"
        SELECT r.id, r.run_id, r.card_id, r.kind, r.sql, r.raw_sql, r.schema_name, r.executed_at,
               r.execution_time_ms, r.rows_affected, r.row_count, r.has_more, r.chart_view_state_json,
               r.result_columns IS NOT NULL AND r.result_rows IS NOT NULL, r.compressed_bytes
        FROM saved_query_results r
        JOIN saved_queries s ON s.id = r.saved_query_id AND s.results_snapshot_id = r.snapshot_id
        WHERE r.saved_query_id = ?1
        ORDER BY r.priority
        "#,
    )?;
    let metas = stmt.query_map([saved_query_id], |r| {
        Ok(SavedQueryResultMeta {
            id: r.get(0)?,
            run_id: r.get(1)?,
            card_id: r.get(2)?,
            kind: r.get(3)?,
            sql: r.get(4)?,
            raw_sql: r.get(5)?,
            schema_name: r.get(6)?,
            executed_at: r.get(7)?,
            execution_time_ms: r.get(8)?,
            rows_affected: r.get(9)?,
            row_count: r.get(10)?,
            has_more: r.get(11)?,
            chart_view_state_json: r.get(12)?,
            has_rows: r.get(13)?,
            compressed_bytes: r.get(14)?,
        })
    })?;
    metas.collect()
}

/// One result's compressed columns, rows and row identity, or None when its
/// rows are not stored.
pub fn get_blobs(conn: &Connection, result_id: &str) -> SqliteResult<Option<(Vec<u8>, Vec<u8>, Option<Vec<u8>>)>> {
    conn.query_row(
        "SELECT result_columns, result_rows, result_row_identity FROM saved_query_results
         WHERE id = ?1 AND result_columns IS NOT NULL AND result_rows IS NOT NULL",
        [result_id],
        |r| Ok((r.get(0)?, r.get(1)?, r.get(2)?)),
    )
    .optional()
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::db::sqlite::{
        batch_delete_saved_queries, clear_query_history, create_saved_query, create_schema as create_all,
        delete_saved_query, load_saved_queries, prune_query_history_now, ClearHistoryScope, HistoryPrunePolicy,
    };
    use crate::models::{CreateSavedQuery, KeepSavedQueryResult};

    fn db() -> Connection {
        let conn = Connection::open_in_memory().unwrap();
        create_all(&conn).unwrap();
        conn
    }

    fn session(conn: &Connection, id: &str) {
        let q = CreateSavedQuery {
            name: id.into(),
            folder: None,
            sql: "SELECT 1".into(),
            connection_id: None,
            variables: None,
            cards_json: None,
            schema_name: None,
        };
        create_saved_query(conn, id, &q).unwrap();
    }

    fn row(session: &str, snapshot: &str, run: &str, priority: i64) -> StageSavedQueryResult {
        StageSavedQueryResult {
            saved_query_id: session.into(),
            snapshot_id: snapshot.into(),
            run_id: run.into(),
            card_id: format!("card-{run}"),
            priority,
            kind: "rows".into(),
            sql: "SELECT 1".into(),
            raw_sql: None,
            schema_name: Some("public".into()),
            executed_at: "2026-10-08T00:00:00Z".into(),
            execution_time_ms: 5,
            rows_affected: None,
            row_count: Some(2),
            has_more: true,
            chart_view_state_json: Some("{\"viewMode\":\"grid\"}".into()),
            columns: None,
            rows: None,
            row_identity: None,
        }
    }

    fn blobs(n: usize) -> CompressedResult {
        CompressedResult { columns: Some(vec![1; n]), rows: Some(vec![2; n]), row_identity: None }
    }

    fn commit_of(session: &str, snapshot: &str, keep: Vec<KeepSavedQueryResult>) -> CommitSavedQuerySnapshot {
        CommitSavedQuerySnapshot {
            saved_query_id: session.into(),
            snapshot_id: snapshot.into(),
            sql: "SELECT 1;\nSELECT 2".into(),
            cards_json: Some("{}".into()),
            connection_id: None,
            schema_name: Some("public".into()),
            keep,
        }
    }

    fn table_rows(conn: &Connection) -> i64 {
        conn.query_row("SELECT COUNT(*) FROM saved_query_results", [], |r| r.get(0)).unwrap()
    }

    #[test]
    fn schema_is_idempotent() {
        let conn = db();
        create_all(&conn).unwrap();
        for column in ["schema_name", "results_snapshot_id", "results_saved_at", "results_bytes", "result_count"] {
            let n: i64 = conn
                .query_row(
                    "SELECT COUNT(*) FROM pragma_table_info('saved_queries') WHERE name = ?1",
                    [column],
                    |r| r.get(0),
                )
                .unwrap();
            assert_eq!(n, 1, "saved_queries.{column}");
        }
    }

    #[test]
    fn stage_and_commit_round_trip() {
        let conn = db();
        session(&conn, "s");
        let staged = stage(&conn, "r1", &row("s", "snap1", "run1", 0), blobs(10), 1000).unwrap();
        assert_eq!(staged, StagedSavedQueryResult { id: "r1".into(), stored: true, compressed_bytes: 20 });
        assert!(load_metas(&conn, "s").unwrap().is_empty(), "staged rows are invisible before the commit");

        let done = commit(&conn, &commit_of("s", "snap1", vec![]), 1000).unwrap();
        assert!(done.dropped_run_ids.is_empty());
        assert_eq!(done.saved_query.results_snapshot_id.as_deref(), Some("snap1"));
        assert_eq!(done.saved_query.results_bytes, Some(20));
        assert_eq!(done.saved_query.result_count, Some(1));
        assert_eq!(done.saved_query.sql, "SELECT 1;\nSELECT 2");
        assert_eq!(done.saved_query.schema_name.as_deref(), Some("public"));

        let metas = load_metas(&conn, "s").unwrap();
        assert_eq!(metas.len(), 1);
        let m = &metas[0];
        assert!(m.has_rows && m.has_more && m.run_id == "run1" && m.row_count == Some(2));
        assert_eq!(m.chart_view_state_json.as_deref(), Some("{\"viewMode\":\"grid\"}"));
        let (columns, rows, identity) = get_blobs(&conn, "r1").unwrap().unwrap();
        assert_eq!((columns.len(), rows.len(), identity), (10, 10, None));
    }

    #[test]
    fn a_second_save_replaces_the_first_and_keeps_what_it_is_told_to() {
        let conn = db();
        session(&conn, "s");
        stage(&conn, "a", &row("s", "snap1", "runA", 0), blobs(5), 1000).unwrap();
        stage(&conn, "b", &row("s", "snap1", "runB", 1), blobs(5), 1000).unwrap();
        commit(&conn, &commit_of("s", "snap1", vec![]), 1000).unwrap();

        // runA is still stored but not in memory: keep it. runB is gone. runC is new.
        stage(&conn, "c", &row("s", "snap2", "runC", 0), blobs(5), 1000).unwrap();
        let keep = vec![KeepSavedQueryResult { run_id: "runA".into(), priority: 1 }];
        commit(&conn, &commit_of("s", "snap2", keep), 1000).unwrap();

        let runs: Vec<String> = load_metas(&conn, "s").unwrap().into_iter().map(|m| m.run_id).collect();
        assert_eq!(runs, vec!["runC", "runA"], "new snapshot, priority order");
        assert_eq!(table_rows(&conn), 2, "the old snapshot's other rows are gone");
    }

    #[test]
    fn abort_leaves_the_stored_snapshot() {
        let conn = db();
        session(&conn, "s");
        stage(&conn, "a", &row("s", "snap1", "runA", 0), blobs(5), 1000).unwrap();
        commit(&conn, &commit_of("s", "snap1", vec![]), 1000).unwrap();
        stage(&conn, "b", &row("s", "snap2", "runB", 0), blobs(5), 1000).unwrap();

        assert_eq!(abort(&conn, "s", "snap2").unwrap(), 1);
        assert_eq!(abort(&conn, "s", "snap1").unwrap(), 0, "never the Session's own snapshot");
        let runs: Vec<String> = load_metas(&conn, "s").unwrap().into_iter().map(|m| m.run_id).collect();
        assert_eq!(runs, vec!["runA"]);
    }

    #[test]
    fn staging_over_the_budget_keeps_metadata_only() {
        let conn = db();
        session(&conn, "s");
        assert!(stage(&conn, "a", &row("s", "snap", "runA", 0), blobs(30), 100).unwrap().stored);
        let over = stage(&conn, "b", &row("s", "snap", "runB", 1), blobs(30), 100).unwrap();
        assert!(!over.stored && over.compressed_bytes == 0);
        let done = commit(&conn, &commit_of("s", "snap", vec![]), 100).unwrap();
        assert_eq!(done.dropped_run_ids, vec!["runB"]);
        let metas = load_metas(&conn, "s").unwrap();
        assert!(metas[0].has_rows && !metas[1].has_rows);
        assert!(get_blobs(&conn, "b").unwrap().is_none());
    }

    #[test]
    fn commit_drops_the_lowest_priority_first() {
        let conn = db();
        session(&conn, "s");
        stage(&conn, "a", &row("s", "snap1", "runA", 0), blobs(20), 1000).unwrap();
        stage(&conn, "b", &row("s", "snap1", "runB", 1), blobs(20), 1000).unwrap();
        commit(&conn, &commit_of("s", "snap1", vec![]), 1000).unwrap();

        // A new result with a smaller budget: the kept runB (lowest priority) goes.
        stage(&conn, "c", &row("s", "snap2", "runC", 0), blobs(20), 100).unwrap();
        let keep = vec![
            KeepSavedQueryResult { run_id: "runA".into(), priority: 1 },
            KeepSavedQueryResult { run_id: "runB".into(), priority: 2 },
        ];
        let done = commit(&conn, &commit_of("s", "snap2", keep), 100).unwrap();
        assert_eq!(done.dropped_run_ids, vec!["runB"]);
        assert_eq!(done.saved_query.results_bytes, Some(80));
        assert_eq!(done.saved_query.result_count, Some(3));
    }

    #[test]
    fn affected_results_have_no_rows_and_are_never_dropped() {
        let conn = db();
        session(&conn, "s");
        let mut r = row("s", "snap", "runA", 0);
        r.kind = "affected".into();
        r.rows_affected = Some(4);
        let staged = stage(&conn, "a", &r, CompressedResult::default(), 0).unwrap();
        assert!(staged.stored);
        let done = commit(&conn, &commit_of("s", "snap", vec![]), 0).unwrap();
        assert!(done.dropped_run_ids.is_empty());
        assert_eq!(load_metas(&conn, "s").unwrap()[0].rows_affected, Some(4));
    }

    #[test]
    fn deleting_a_session_deletes_its_results() {
        let conn = db();
        for id in ["s1", "s2", "s3"] {
            session(&conn, id);
            stage(&conn, &format!("r-{id}"), &row(id, &format!("snap-{id}"), "run", 0), blobs(5), 1000).unwrap();
            commit(&conn, &commit_of(id, &format!("snap-{id}"), vec![]), 1000).unwrap();
        }
        delete_saved_query(&conn, "s1").unwrap();
        assert_eq!(table_rows(&conn), 2);
        batch_delete_saved_queries(&conn, &["s2".into(), "s3".into()]).unwrap();
        assert_eq!(table_rows(&conn), 0);
    }

    #[test]
    fn history_clean_up_leaves_session_results_alone() {
        let conn = db();
        session(&conn, "s");
        stage(&conn, "a", &row("s", "snap", "runA", 0), blobs(5), 1000).unwrap();
        commit(&conn, &commit_of("s", "snap", vec![]), 1000).unwrap();

        clear_query_history(&conn, ClearHistoryScope::All).unwrap();
        prune_query_history_now(&conn, HistoryPrunePolicy { retention_days: 1, max_entries: 1 }).unwrap();
        assert_eq!(load_metas(&conn, "s").unwrap().len(), 1);
        assert!(get_blobs(&conn, "a").unwrap().is_some());
    }

    #[test]
    fn a_deleted_connection_is_stored_as_null() {
        let conn = db();
        session(&conn, "s");
        let mut c = commit_of("s", "snap", vec![]);
        c.connection_id = Some("gone".into());
        let done = commit(&conn, &c, 1000).unwrap();
        assert_eq!(done.saved_query.connection_id, None);
    }

    #[test]
    fn committing_for_a_missing_session_fails() {
        let conn = db();
        assert!(commit(&conn, &commit_of("missing", "snap", vec![]), 1000).is_err());
        assert!(stage(&conn, "a", &row("missing", "snap", "run", 0), blobs(1), 1000).is_err(), "the foreign key");
    }

    #[test]
    fn startup_removes_rows_a_crashed_save_left() {
        let conn = db();
        session(&conn, "s");
        stage(&conn, "a", &row("s", "snap1", "runA", 0), blobs(5), 1000).unwrap();
        commit(&conn, &commit_of("s", "snap1", vec![]), 1000).unwrap();
        stage(&conn, "b", &row("s", "snap2", "runB", 0), blobs(5), 1000).unwrap();
        create_all(&conn).unwrap();
        assert_eq!(table_rows(&conn), 1);
        assert_eq!(load_saved_queries(&conn).unwrap()[0].results_snapshot_id.as_deref(), Some("snap1"));
    }
}
