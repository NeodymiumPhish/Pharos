use crate::db::sqlite;
use crate::models::{WorkspaceDetail, WorkspaceSummary, WorkspaceUpsert};
use crate::state::AppState;

pub async fn upsert_workspace(w: WorkspaceUpsert, state: &AppState) -> Result<(), String> {
    let db = state.metadata_db.lock().map_err(|e| e.to_string())?;
    sqlite::upsert_workspace(&db, &w).map_err(|e| format!("Failed to upsert workspace: {}", e))
}

pub async fn associate_result(
    history_id: String, workspace_id: String, result_order: i64, color_index: i64,
    raw_sql: Option<String>, state: &AppState,
) -> Result<(), String> {
    let db = state.metadata_db.lock().map_err(|e| e.to_string())?;
    sqlite::associate_result_to_workspace(
        &db, &history_id, &workspace_id, result_order, color_index, raw_sql.as_deref(),
    )
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

pub async fn update_result_chart_state(
    result_id: String, json: String, state: &AppState,
) -> Result<bool, String> {
    let db = state.metadata_db.lock().map_err(|e| e.to_string())?;
    sqlite::update_result_chart_state(&db, &result_id, &json)
        .map_err(|e| format!("Failed to update chart state: {}", e))
}
