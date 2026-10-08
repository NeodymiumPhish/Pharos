
use crate::commands::QueryHistoryResultData;
use crate::db::saved_query_results::{self, CompressedResult, SAVED_SESSION_BUDGET_BYTES};
use crate::db::sqlite;
use crate::models::{
    CommitSavedQuerySnapshot, CommittedSavedQuerySnapshot, CreateSavedQuery, SavedQuery, SavedQueryResultMeta,
    StageSavedQueryResult, StagedSavedQueryResult, UpdateSavedQuery,
};
use crate::state::AppState;

pub async fn create_saved_query(
    state: &AppState,
    query: CreateSavedQuery,
) -> Result<SavedQuery, String> {
    let id = uuid::Uuid::new_v4().to_string();
    let db = state.metadata_db.lock().map_err(|e| e.to_string())?;

    sqlite::create_saved_query(&db, &id, &query).map_err(|e| format!("Failed to create saved query: {}", e))
}

pub async fn load_saved_queries(state: &AppState) -> Result<Vec<SavedQuery>, String> {
    let db = state.metadata_db.lock().map_err(|e| e.to_string())?;

    sqlite::load_saved_queries(&db).map_err(|e| format!("Failed to load saved queries: {}", e))
}

pub async fn get_saved_query(
    state: &AppState,
    query_id: String,
) -> Result<Option<SavedQuery>, String> {
    let db = state.metadata_db.lock().map_err(|e| e.to_string())?;

    sqlite::get_saved_query(&db, &query_id).map_err(|e| format!("Failed to get saved query: {}", e))
}

pub async fn update_saved_query(
    state: &AppState,
    update: UpdateSavedQuery,
) -> Result<Option<SavedQuery>, String> {
    let db = state.metadata_db.lock().map_err(|e| e.to_string())?;

    sqlite::update_saved_query(&db, &update).map_err(|e| format!("Failed to update saved query: {}", e))
}

pub async fn delete_saved_query(
    state: &AppState,
    query_id: String,
) -> Result<bool, String> {
    let db = state.metadata_db.lock().map_err(|e| e.to_string())?;

    sqlite::delete_saved_query(&db, &query_id).map_err(|e| format!("Failed to delete saved query: {}", e))
}

pub async fn batch_delete_saved_queries(
    state: &AppState,
    ids: Vec<String>,
) -> Result<usize, String> {
    let db = state.metadata_db.lock().map_err(|e| e.to_string())?;

    sqlite::batch_delete_saved_queries(&db, &ids).map_err(|e| format!("Failed to batch delete saved queries: {}", e))
}

// ==================== Session results ====================
//
// Compression happens before the database lock is taken and decompression
// after it is released: a Session can hold 100 MB of results, and every other
// database call waits on that lock.

/// Stage one result of a Session save (see `db::saved_query_results`).
pub async fn stage_saved_query_result(
    state: &AppState,
    row: StageSavedQueryResult,
) -> Result<StagedSavedQueryResult, String> {
    let compress = |raw: &Option<Box<serde_json::value::RawValue>>| {
        raw.as_ref().map(|v| sqlite::compress_data(v.get())).transpose()
    };
    let blobs = CompressedResult {
        columns: compress(&row.columns)?,
        rows: compress(&row.rows)?,
        row_identity: compress(&row.row_identity)?,
    };
    let id = uuid::Uuid::new_v4().to_string();
    let db = state.metadata_db.lock().map_err(|e| e.to_string())?;
    saved_query_results::stage(&db, &id, &row, blobs, SAVED_SESSION_BUDGET_BYTES)
        .map_err(|e| format!("Failed to save a Session result: {}", e))
}

pub async fn commit_saved_query_snapshot(
    state: &AppState,
    commit: CommitSavedQuerySnapshot,
) -> Result<CommittedSavedQuerySnapshot, String> {
    let db = state.metadata_db.lock().map_err(|e| e.to_string())?;
    saved_query_results::commit(&db, &commit, SAVED_SESSION_BUDGET_BYTES)
        .map_err(|e| format!("Failed to save the Session: {}", e))
}

pub async fn abort_saved_query_snapshot(
    state: &AppState,
    saved_query_id: String,
    snapshot_id: String,
) -> Result<usize, String> {
    let db = state.metadata_db.lock().map_err(|e| e.to_string())?;
    saved_query_results::abort(&db, &saved_query_id, &snapshot_id)
        .map_err(|e| format!("Failed to discard a Session save: {}", e))
}

pub async fn load_saved_query_results(
    state: &AppState,
    saved_query_id: String,
) -> Result<Vec<SavedQueryResultMeta>, String> {
    let db = state.metadata_db.lock().map_err(|e| e.to_string())?;
    saved_query_results::load_metas(&db, &saved_query_id)
        .map_err(|e| format!("Failed to load the Session's results: {}", e))
}

/// One stored result in the shape a history result has, so Swift decodes
/// both with `QueryHistoryResultData`. None when its rows are not stored.
pub async fn get_saved_query_result(
    state: &AppState,
    result_id: String,
) -> Result<Option<QueryHistoryResultData>, String> {
    let blobs = {
        let db = state.metadata_db.lock().map_err(|e| e.to_string())?;
        saved_query_results::get_blobs(&db, &result_id)
            .map_err(|e| format!("Failed to load a Session result: {}", e))?
    };
    let Some((columns, rows, identity)) = blobs else { return Ok(None) };
    let raw = |bytes: Vec<u8>| {
        sqlite::decompress_or_passthrough(bytes)
            .and_then(|s| serde_json::value::RawValue::from_string(s).map_err(|e| e.to_string()))
    };
    Ok(Some(QueryHistoryResultData {
        columns: raw(columns)?,
        rows: raw(rows)?,
        // As in history: an identity block that will not parse is not worth
        // failing the open over.
        row_identity: identity.and_then(|b| raw(b).ok()),
    }))
}

#[cfg(test)]
mod tests {
    use super::*;
    use rusqlite::Connection;

    fn state_with_session() -> AppState {
        let conn = Connection::open_in_memory().unwrap();
        sqlite::create_schema(&conn).unwrap();
        let state = AppState::new(conn);
        let q = CreateSavedQuery {
            name: "S".into(), folder: None, sql: "SELECT 1".into(), connection_id: None,
            variables: None, cards_json: None, schema_name: None,
        };
        sqlite::create_saved_query(&state.metadata_db.lock().unwrap(), "s", &q).unwrap();
        state
    }

    /// The rows text comes back byte for byte: Rust never parses it.
    #[test]
    fn rows_round_trip_verbatim() {
        let state = state_with_session();
        let rt = tokio::runtime::Runtime::new().unwrap();
        let json = r#"{"savedQueryId":"s","snapshotId":"snap","runId":"run","cardId":"c","priority":0,
            "kind":"rows","sql":"SELECT 1","executedAt":"2026-10-08T00:00:00Z","executionTimeMs":3,
            "rowCount":2,"hasMore":true,
            "columns":[{"name":"a","data_type":"text"}],"rows":[["x"],[null]],
            "rowIdentity":{"table_key":"t"}}"#;
        let row: StageSavedQueryResult = serde_json::from_str(json).unwrap();
        let staged = rt.block_on(stage_saved_query_result(&state, row)).unwrap();
        assert!(staged.stored);
        let commit: CommitSavedQuerySnapshot = serde_json::from_str(
            r#"{"savedQueryId":"s","snapshotId":"snap","sql":"SELECT 1","cardsJson":"{}"}"#,
        )
        .unwrap();
        rt.block_on(commit_saved_query_snapshot(&state, commit)).unwrap();

        let metas = rt.block_on(load_saved_query_results(&state, "s".into())).unwrap();
        assert_eq!(metas.len(), 1);
        let data = rt.block_on(get_saved_query_result(&state, metas[0].id.clone())).unwrap().unwrap();
        assert_eq!(data.rows.get(), r#"[["x"],[null]]"#);
        assert_eq!(data.columns.get(), r#"[{"name":"a","data_type":"text"}]"#);
        assert_eq!(data.row_identity.unwrap().get(), r#"{"table_key":"t"}"#);
    }

    /// A JSON null for the rows (an "affected" result) stages no blobs.
    #[test]
    fn null_rows_stage_as_none() {
        let row: StageSavedQueryResult = serde_json::from_str(
            r#"{"savedQueryId":"s","snapshotId":"snap","runId":"run","cardId":"c","priority":0,
                "kind":"affected","sql":"DELETE","executedAt":"t","executionTimeMs":1,"rowsAffected":4,
                "columns":null,"rows":null}"#,
        )
        .unwrap();
        assert!(row.columns.is_none() && row.rows.is_none() && row.row_identity.is_none());
    }
}
