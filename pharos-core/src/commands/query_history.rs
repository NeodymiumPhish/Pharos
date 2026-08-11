use serde::Serialize;

use crate::db::sqlite;
use crate::models::QueryHistoryEntry;
use crate::state::AppState;

/// Cached query result data returned when loading a specific history entry's results
#[derive(Debug, Serialize)]
#[serde(rename_all = "camelCase")]
pub struct QueryHistoryResultData {
    pub columns: serde_json::Value,
    pub rows: serde_json::Value,
    /// The saved row identity block, so a reopened workspace restores its tags.
    /// None for an entry saved before that column existed.
    ///
    /// `rename_all` above renames THIS struct's fields only, so the outer key is
    /// `rowIdentity`. It does not reach inside this `Value`, so the block keeps
    /// the snake_case keys `execute_query` wrote (`table_key`, `key_columns`,
    /// ...). That mixture is deliberate: Swift's `RowIdentity` carries
    /// snake_case CodingKeys while the tag models carry none. Do not unify it.
    pub row_identity: Option<serde_json::Value>,
}

/// Load query history entries with optional filtering
pub async fn load_query_history(
    connection_id: Option<String>,
    search: Option<String>,
    limit: Option<i64>,
    offset: Option<i64>,
    only_legacy: bool,
    state: &AppState,
) -> Result<Vec<QueryHistoryEntry>, String> {
    let db = state.metadata_db.lock().map_err(|e| e.to_string())?;
    let limit = limit.unwrap_or(100);
    let offset = offset.unwrap_or(0);

    // Try FTS5 search first; fall back to no search on FTS errors (e.g., corrupted index)
    let entries = match sqlite::load_query_history(&db, connection_id.as_deref(), search.as_deref(), limit, offset, only_legacy) {
        Ok(entries) => entries,
        Err(e) if search.is_some() => {
            log::warn!("FTS5 search failed, falling back to unfiltered: {}", e);
            sqlite::load_query_history(&db, connection_id.as_deref(), None, limit, offset, only_legacy)
                .map_err(|e| format!("Failed to load query history: {}", e))?
        }
        Err(e) => return Err(format!("Failed to load query history: {}", e)),
    };

    Ok(entries)
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
            let columns: serde_json::Value = serde_json::from_str(&columns_json)
                .map_err(|e| format!("Failed to parse cached columns: {}", e))?;
            let rows: serde_json::Value = serde_json::from_str(&rows_json)
                .map_err(|e| format!("Failed to parse cached rows: {}", e))?;
            // A stored block that will not parse is not worth failing a reopen
            // over: the result then falls to the fingerprint tier.
            let row_identity = identity_json
                .and_then(|s| serde_json::from_str::<serde_json::Value>(&s).ok());
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

        let payload = QueryHistoryResultData {
            columns: serde_json::json!([{"name": "id", "data_type": "int4"}]),
            rows: serde_json::json!([["42"]]),
            row_identity: Some(serde_json::to_value(&identity).unwrap()),
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
        let payload = QueryHistoryResultData {
            columns: serde_json::json!([]),
            rows: serde_json::json!([]),
            row_identity: None,
        };
        let json = serde_json::to_string(&payload).unwrap();
        assert!(json.contains("\"rowIdentity\":null"), "got {}", json);

        // The lenient parse the command performs on a corrupt block.
        let salvaged = Some("{not json".to_string())
            .and_then(|s| serde_json::from_str::<serde_json::Value>(&s).ok());
        assert!(salvaged.is_none());
    }
}
