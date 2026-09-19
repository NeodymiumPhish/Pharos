use std::os::raw::c_char;

use super::*;

// ---------------------------------------------------------------------------
// Query history
// ---------------------------------------------------------------------------

/// The filter `pharos_load_query_history` reads, as Swift's
/// `QueryHistoryFilter` writes it.
///
/// At module scope rather than inside the function so a test can decode the
/// exact bytes the Swift encoder produces. `JSONEncoder.pharos` applies no key
/// strategy, so every name here must be the Swift property's own spelling.
#[derive(serde::Deserialize)]
#[serde(rename_all = "camelCase")]
struct HistoryFilter {
    connection_id: Option<String>,
    search: Option<String>,
    limit: Option<i64>,
    offset: Option<i64>,
    only_legacy: Option<bool>,
    /// "all" (the default), "succeeded" or "failed".
    status: Option<crate::models::HistoryStatusScope>,
}

impl Default for HistoryFilter {
    fn default() -> Self {
        HistoryFilter {
            connection_id: None,
            search: None,
            limit: Some(100),
            offset: Some(0),
            only_legacy: None,
            status: None,
        }
    }
}

/// Load query history. `json` is JSON with optional filters: {connectionId?, search?, limit?, offset?}.
/// Returns JSON array. Caller must free.
#[no_mangle]
pub extern "C" fn pharos_load_query_history(json: *const c_char) -> *mut c_char {
    ffi_sync!({
        let state = app_state();
        let rt = runtime();
        let json_str = unsafe { c_str_to_string(json) };

        // A payload this side cannot read used to fall back SILENTLY, which
        // is how a filter field becomes a permanent no-op: the navigator asks
        // for failures, the fallback answers with everything, and nothing
        // anywhere says so. It still falls back — an unreadable filter must
        // not lose the user their history — but it says so first.
        let filter: HistoryFilter = match serde_json::from_str(&json_str) {
            Ok(filter) => filter,
            Err(e) => {
                log::warn!("Unreadable history filter, loading unfiltered: {} ({})", e, json_str);
                HistoryFilter::default()
            }
        };

        match rt.block_on(crate::commands::load_query_history(
            filter.connection_id,
            filter.search,
            filter.limit,
            filter.offset,
            filter.only_legacy.unwrap_or(false),
            filter.status.unwrap_or_default(),
            state,
        )) {
            Ok(entries) => to_json_c_string(&entries),
            Err(e) => to_c_string(&serde_json::json!({"error": e.to_string()}).to_string()),
        }
    })
}

/// Record a query that FAILED. `json` is a `FailedQueryRecord`:
/// `{connectionId, sql, rawSql?, message, status?, schema?, tableNames?,
///   workspaceId?, lineStart?, lineEnd?, executionTimeMs?}`.
///
/// Returns the new entry's id as a bare string, or `{"error": "..."}`.
/// Caller must free.
///
/// Swift drives this rather than the failure site in `commands::query`,
/// because the workspace id and the editor line range live in the Swift
/// session. Whether a failure is recorded at all is decided there too — see
/// `HistoryFailureFilter` and Settings ▸ Library & History ▸ Record failed
/// queries.
#[no_mangle]
pub extern "C" fn pharos_record_failed_query(json: *const c_char) -> *mut c_char {
    ffi_sync!({
        let state = app_state();
        let rt = runtime();
        let json_str = unsafe { c_str_to_string(json) };

        let record: crate::models::FailedQueryRecord = match serde_json::from_str(&json_str) {
            Ok(r) => r,
            Err(e) => return to_c_string(&serde_json::json!({"error": e.to_string()}).to_string()),
        };

        match rt.block_on(crate::commands::record_failed_query(record, state)) {
            Ok(id) => to_c_string(&id),
            Err(e) => to_c_string(&serde_json::json!({"error": e}).to_string()),
        }
    })
}

/// Delete a query history entry. Returns "true"/"false".
#[no_mangle]
pub extern "C" fn pharos_delete_query_history_entry(entry_id: *const c_char) -> *mut c_char {
    ffi_sync!({
        let state = app_state();
        let rt = runtime();
        let id = unsafe { c_str_to_string(entry_id) };
        match rt.block_on(crate::commands::delete_query_history_entry(id, state)) {
            Ok(deleted) => to_c_string(if deleted { "true" } else { "false" }),
            Err(e) => to_c_string(&serde_json::json!({"error": e.to_string()}).to_string()),
        }
    })
}

/// Get cached result data for a history entry. Returns JSON or NULL.
#[no_mangle]
pub extern "C" fn pharos_get_query_history_result(entry_id: *const c_char) -> *mut c_char {
    ffi_sync!({
        let state = app_state();
        let rt = runtime();
        let id = unsafe { c_str_to_string(entry_id) };
        match rt.block_on(crate::commands::get_query_history_result(id, state)) {
            Ok(Some(data)) => to_json_c_string(&data),
            Ok(None) => std::ptr::null_mut(),
            Err(e) => to_c_string(&serde_json::json!({"error": e.to_string()}).to_string()),
        }
    })
}

/// Batch delete query history entries. `json` is a JSON array of ID strings.
/// Returns the count of deleted entries as a string, or error JSON.
#[no_mangle]
pub extern "C" fn pharos_batch_delete_query_history(json: *const c_char) -> *mut c_char {
    ffi_sync!({
        let state = app_state();
        let rt = runtime();
        let json_str = unsafe { c_str_to_string(json) };
        let ids: Vec<String> = match serde_json::from_str(&json_str) {
            Ok(ids) => ids,
            Err(e) => return to_c_string(&serde_json::json!({"error": e.to_string()}).to_string()),
        };
        match rt.block_on(crate::commands::batch_delete_query_history_entries(ids, state)) {
            Ok(count) => to_c_string(&format!("{}", count)),
            Err(e) => to_c_string(&serde_json::json!({"error": e.to_string()}).to_string()),
        }
    })
}

/// Clear Query History. `json` is `{"olderThanDays": n, "preview": bool}`;
/// `olderThanDays` of 0 (or absent) means everything, and `preview` counts
/// without deleting. Returns `{"deleted": n}` or `{"error": "..."}`.
/// Caller must free.
#[no_mangle]
pub extern "C" fn pharos_clear_query_history(json: *const c_char) -> *mut c_char {
    ffi_sync!({
        let state = app_state();
        let rt = runtime();
        let json_str = unsafe { c_str_to_string(json) };

        #[derive(serde::Deserialize)]
        #[serde(rename_all = "camelCase")]
        struct ClearRequest {
            #[serde(default)]
            older_than_days: u32,
            #[serde(default)]
            preview: bool,
        }

        let request: ClearRequest = serde_json::from_str(&json_str)
            .unwrap_or(ClearRequest { older_than_days: 0, preview: false });

        match rt.block_on(crate::commands::clear_query_history(
            state,
            request.older_than_days,
            request.preview,
        )) {
            Ok(deleted) => to_json_c_string(&serde_json::json!({ "deleted": deleted })),
            Err(e) => to_c_string(&serde_json::json!({ "error": e }).to_string()),
        }
    })
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::models::HistoryStatusScope;

    /// The exact bytes `JSONEncoder.pharos` produced for a
    /// `QueryHistoryFilter` with the Failed scope, measured rather than
    /// guessed. A key this side spells differently decodes as absent, the
    /// scope silently becomes All, and the navigator's Failed segment lists
    /// successes — a no-op that looks like a feature.
    #[test]
    fn the_filter_swift_sends_carries_its_scope() {
        let json = r#"{"connectionId":"c1","limit":200,"onlyLegacy":false,"search":"users","status":"failed"}"#;
        let filter: HistoryFilter = serde_json::from_str(json).expect("decode the real payload");
        assert_eq!(filter.status, Some(HistoryStatusScope::Failed));
        assert_eq!(filter.connection_id.as_deref(), Some("c1"));
        assert_eq!(filter.limit, Some(200));
        assert_eq!(filter.only_legacy, Some(false));
        assert_eq!(filter.search.as_deref(), Some("users"));
    }

    /// Every scope, and the absent case that means All.
    #[test]
    fn every_scope_the_control_can_send_decodes() {
        for (text, expected) in [
            ("\"all\"", HistoryStatusScope::All),
            ("\"succeeded\"", HistoryStatusScope::Succeeded),
            ("\"failed\"", HistoryStatusScope::Failed),
        ] {
            let json = format!(r#"{{"onlyLegacy":true,"status":{}}}"#, text);
            let filter: HistoryFilter = serde_json::from_str(&json).expect("decode");
            assert_eq!(filter.status, Some(expected), "for {}", text);
        }
        let old: HistoryFilter = serde_json::from_str(r#"{"onlyLegacy":true}"#).expect("decode");
        assert_eq!(old.status, None, "a caller that sends no scope gets All");
        assert_eq!(old.status.unwrap_or_default(), HistoryStatusScope::All);
    }

    /// The exact bytes `JSONEncoder.pharos` produced for a
    /// `PharosCore.FailedQueryRecord`, likewise measured. The two fields the
    /// core cannot work out for itself — the workspace and the line range —
    /// are the ones a casing slip would drop in silence.
    #[test]
    fn the_record_swift_sends_carries_the_workspace_and_the_line_range() {
        let json = r#"{"connectionId":"c1","executionTimeMs":0,"lineEnd":6,"lineStart":4,"message":"syntax error","rawSql":"SELCT {{n}}","schema":"public","sql":"SELCT 1","status":"error","workspaceId":"ws1"}"#;
        let record: crate::models::FailedQueryRecord =
            serde_json::from_str(json).expect("decode the real payload");
        assert_eq!(record.connection_id, "c1");
        assert_eq!(record.sql, "SELCT 1");
        assert_eq!(record.raw_sql.as_deref(), Some("SELCT {{n}}"));
        assert_eq!(record.message, "syntax error");
        assert_eq!(record.status, crate::models::HISTORY_STATUS_ERROR);
        assert_eq!(record.schema.as_deref(), Some("public"));
        assert_eq!(record.workspace_id.as_deref(), Some("ws1"));
        assert_eq!(record.line_start, Some(4));
        assert_eq!(record.line_end, Some(6));
    }
}
