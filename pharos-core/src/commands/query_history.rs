use serde::Serialize;

use crate::db::sqlite;
use crate::models::{FailedQueryRecord, HistoryStatusScope, QueryHistoryEntry};
use crate::state::AppState;

/// Cached query result data returned when loading a specific history entry's results
#[derive(Debug, Serialize)]
#[serde(rename_all = "camelCase")]
pub struct QueryHistoryResultData {
    /// The stored JSON text, passed through verbatim. `RawValue` checks that
    /// the text is well-formed JSON and serializes it as-is, so a reopen does
    /// not build a value tree of every cached cell only to write it out again.
    /// Swift is the only reader of these bytes.
    pub columns: Box<serde_json::value::RawValue>,
    pub rows: Box<serde_json::value::RawValue>,
    /// The saved row identity block, so a reopened workspace restores its tags.
    /// None for an entry saved before that column existed.
    ///
    /// `rename_all` above renames THIS struct's fields only, so the outer key is
    /// `rowIdentity`. It does not reach inside this `Value`, so the block keeps
    /// the snake_case keys `execute_query` wrote (`table_key`, `key_columns`,
    /// ...). That mixture is deliberate: Swift's `RowIdentity` carries
    /// snake_case CodingKeys while the tag models carry none. Do not unify it.
    pub row_identity: Option<Box<serde_json::value::RawValue>>,
}

/// Load query history entries with optional filtering
pub async fn load_query_history(
    connection_id: Option<String>,
    search: Option<String>,
    limit: Option<i64>,
    offset: Option<i64>,
    only_legacy: bool,
    status_scope: HistoryStatusScope,
    state: &AppState,
) -> Result<Vec<QueryHistoryEntry>, String> {
    let db = state.metadata_db.lock().map_err(|e| e.to_string())?;
    let limit = limit.unwrap_or(100);
    let offset = offset.unwrap_or(0);

    // Try FTS5 search first; fall back to no search on FTS errors (e.g., corrupted index).
    // The status scope survives that fallback: it is the user's choice of WHICH
    // rows, not a search, and dropping it would answer a "Failed" scope with
    // successes.
    let entries = match sqlite::load_query_history(&db, connection_id.as_deref(), search.as_deref(), limit, offset, only_legacy, status_scope) {
        Ok(entries) => entries,
        Err(e) if search.is_some() => {
            log::warn!("FTS5 search failed, falling back to unfiltered: {}", e);
            sqlite::load_query_history(&db, connection_id.as_deref(), None, limit, offset, only_legacy, status_scope)
                .map_err(|e| format!("Failed to load query history: {}", e))?
        }
        Err(e) => return Err(format!("Failed to load query history: {}", e)),
    };

    Ok(entries)
}

/// Record a query that FAILED, and return the new entry's id.
///
/// The core knows a query failed inside `commands::query`, but not the
/// workspace the editor tab belongs to nor the editor lines the statement came
/// from. Both live in the Swift session, so the save is driven from there.
///
/// Whether a failure is worth recording at all is decided in Swift too, by
/// `HistoryFailureFilter` and by Settings ▸ Library & History ▸ Record failed
/// queries. This function records what it is given.
pub async fn record_failed_query(
    record: FailedQueryRecord,
    state: &AppState,
) -> Result<String, String> {
    let id = uuid::Uuid::new_v4().to_string();
    let connection_name = state
        .get_config(&record.connection_id)
        .map(|c| c.name)
        .unwrap_or_else(|| record.connection_id.clone());

    let entry = QueryHistoryEntry {
        id: id.clone(),
        connection_id: record.connection_id.clone(),
        connection_name,
        sql: record.sql.clone(),
        // Not 0: a failed run produced no rows and no columns, which is a
        // different thing from producing none. The row's own `status` says
        // why, and the navigator's row shows "Failed" rather than "0 Rows".
        row_count: None,
        execution_time_ms: record.execution_time_ms,
        executed_at: chrono::Utc::now().to_rfc3339(),
        has_results: false,
        schema: record.schema.clone(),
        column_count: None,
        table_names: record.table_names.clone(),
        source: None,
        status: record.status.clone(),
        error_message: Some(record.message.clone()),
    };

    let db = state.metadata_db.lock().map_err(|e| e.to_string())?;
    sqlite::save_query_history_with_policy(
        &db, &entry, None, None, None,
        crate::commands::query::history_prune_policy(state),
    )
    .map_err(|e| format!("Failed to record failed query: {}", e))?;

    // The workspace association is a second statement, exactly as it is for a
    // successful run: `save_query_history_with_policy` writes the run, and
    // `associate_result_to_workspace` writes what the SESSION knows about it.
    //
    // `result_order` is -1 and `color_index` 0 because a failure takes no
    // result-tab slot — the rebuild skips it. -1 sorts it ahead of every real
    // result, and leaves the `MAX(result_order) + 1` seed that the rebuild
    // uses for the next result untouched.
    if let Some(workspace_id) = record.workspace_id.as_deref() {
        if let Err(e) = sqlite::associate_result_to_workspace(&db, &crate::models::ResultAssociation {
            history_id: id.clone(),
            workspace_id: workspace_id.to_string(),
            result_order: -1,
            color_index: 0,
            raw_sql: record.raw_sql.clone(),
            line_start: record.line_start,
            line_end: record.line_end,
            custom_label: None,
        }) {
            // Non-fatal: the failure IS recorded, it is simply not tied to the
            // workspace. Losing the whole row over a lost association would be
            // the larger failure.
            log::warn!("Failed query recorded but not associated with its workspace: {}", e);
        }
    }

    Ok(id)
}

/// Delete a single query history entry
pub async fn delete_query_history_entry(
    entry_id: String,
    state: &AppState,
) -> Result<bool, String> {
    let db = state.metadata_db.lock().map_err(|e| e.to_string())?;
    sqlite::delete_query_history_entry(&db, &entry_id)
        .map_err(|e| format!("Failed to delete history entry: {}", e))
}

/// Batch delete query history entries
pub async fn batch_delete_query_history_entries(
    ids: Vec<String>,
    state: &AppState,
) -> Result<usize, String> {
    let db = state.metadata_db.lock().map_err(|e| e.to_string())?;
    sqlite::batch_delete_query_history_entries(&db, &ids)
        .map_err(|e| format!("Failed to batch delete history entries: {}", e))
}

/// Load cached result data for a specific history entry
pub async fn get_query_history_result(
    entry_id: String,
    state: &AppState,
) -> Result<Option<QueryHistoryResultData>, String> {
    let db = state.metadata_db.lock().map_err(|e| e.to_string())?;
    let result = sqlite::get_query_history_result(&db, &entry_id)
        .map_err(|e| format!("Failed to load history result: {}", e))?;

    match result {
        Some((columns_json, rows_json, identity_json)) => {
            let columns = serde_json::value::RawValue::from_string(columns_json)
                .map_err(|e| format!("Failed to parse cached columns: {}", e))?;
            let rows = serde_json::value::RawValue::from_string(rows_json)
                .map_err(|e| format!("Failed to parse cached rows: {}", e))?;
            // A stored block that will not parse is not worth failing a reopen
            // over: the result then falls to the fingerprint tier.
            let row_identity = identity_json
                .and_then(|s| serde_json::value::RawValue::from_string(s).ok());
            Ok(Some(QueryHistoryResultData { columns, rows, row_identity }))
        }
        None => Ok(None),
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::commands::row_identity::{KeySet, RowIdentity};

    /// The reopen payload is the ONE place the two casing conventions meet:
    /// `QueryHistoryResultData` renames its own fields to camelCase, while the
    /// nested identity block must keep the snake_case keys `execute_query`
    /// wrote. A mistake either way compiles and only fails inside Swift's
    /// decoder at run time, so assert both halves here.
    ///
    /// The block is built by serializing a real `RowIdentity`, not from a hand
    /// written literal. A literal would still pass if someone added
    /// `rename_all = "camelCase"` to `RowIdentity` itself, which is exactly the
    /// well-meaning tidy-up this test exists to stop.
    #[test]
    fn reopen_payload_is_camel_case_outside_and_snake_case_inside() {
        let identity = RowIdentity {
            table_key: "oid:16543".into(),
            table_display: "public.users".into(),
            table_keys: vec!["oid:16543".into()],
            candidates: vec![KeySet {
                kind: "pk".into(),
                key_columns: vec!["id".into()],
                keys: vec!["V2:42".into()],
            }],
        };

        let raw = |s: &str| serde_json::value::RawValue::from_string(s.to_string()).unwrap();
        let payload = QueryHistoryResultData {
            columns: raw(r#"[{"name": "id", "data_type": "int4"}]"#),
            rows: raw(r#"[["42"]]"#),
            row_identity: Some(raw(&serde_json::to_string(&identity).unwrap())),
        };
        let json = serde_json::to_string(&payload).unwrap();

        // Outer: the struct's own field is renamed.
        assert!(json.contains("\"rowIdentity\""), "outer key not camelCase: {}", json);
        assert!(!json.contains("\"row_identity\""), "outer key still snake_case: {}", json);

        // Inner: `rename_all` does not reach into the nested Value.
        assert!(json.contains("\"table_key\""), "inner key not snake_case: {}", json);
        assert!(!json.contains("\"tableKey\""), "inner key was camelCased: {}", json);
        assert!(json.contains("\"key_columns\""), "inner key not snake_case: {}", json);
        assert!(!json.contains("\"keyColumns\""), "inner key was camelCased: {}", json);
        assert!(json.contains("\"table_display\""), "inner key not snake_case: {}", json);
        assert!(json.contains("\"table_keys\""), "inner key not snake_case: {}", json);
    }

    /// An entry saved before the column existed, and one whose stored block is
    /// corrupt, must both reopen. The command turns either into None rather
    /// than an error, so the result falls to the fingerprint tier.
    #[test]
    fn absent_identity_serializes_as_null() {
        let raw = |s: &str| serde_json::value::RawValue::from_string(s.to_string()).unwrap();
        let payload = QueryHistoryResultData {
            columns: raw("[]"),
            rows: raw("[]"),
            row_identity: None,
        };
        let json = serde_json::to_string(&payload).unwrap();
        assert!(json.contains("\"rowIdentity\":null"), "got {}", json);

        // The lenient parse the command performs on a corrupt block.
        let salvaged = Some("{not json".to_string())
            .and_then(|s| serde_json::value::RawValue::from_string(s).ok());
        assert!(salvaged.is_none());
    }
}

/// Clear Query History, and say how many entries went.
///
/// `older_than_days` of 0 (or absent) means everything. `preview` counts
/// without deleting, so the confirmation dialog can name the number before
/// the user agrees to it.
pub async fn clear_query_history(
    state: &AppState,
    older_than_days: u32,
    preview: bool,
) -> Result<usize, String> {
    let scope = if older_than_days == 0 {
        sqlite::ClearHistoryScope::All
    } else {
        sqlite::ClearHistoryScope::OlderThanDays(older_than_days)
    };
    let db = state.metadata_db.lock().map_err(|e| e.to_string())?;
    if preview {
        sqlite::count_query_history(&db, scope).map_err(|e| format!("Failed to count history: {}", e))
    } else {
        sqlite::clear_query_history(&db, scope).map_err(|e| format!("Failed to clear history: {}", e))
    }
}
