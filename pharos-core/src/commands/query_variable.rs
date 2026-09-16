use crate::db::sqlite;
use crate::models::QueryVariable;
use crate::state::AppState;

/// Every stored variable, in the user's order.
pub async fn load_query_variables(state: &AppState) -> Result<Vec<QueryVariable>, String> {
    let db = state.metadata_db.lock().map_err(|e| e.to_string())?;

    sqlite::load_query_variables(&db).map_err(|e| format!("Failed to load query variables: {}", e))
}

/// Replace the whole stored list with `variables`, in that order.
pub async fn save_query_variables(state: &AppState, variables: Vec<QueryVariable>) -> Result<(), String> {
    let mut db = state.metadata_db.lock().map_err(|e| e.to_string())?;

    sqlite::save_query_variables(&mut db, &variables)
        .map_err(|e| format!("Failed to save query variables: {}", e))
}
