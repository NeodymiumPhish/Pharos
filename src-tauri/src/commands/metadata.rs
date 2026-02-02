use tauri::State;

use crate::db::postgres;
use crate::models::{ColumnInfo, SchemaInfo, TableInfo};
use crate::state::AppState;

/// Get all schemas for a connection
#[tauri::command]
pub async fn get_schemas(
    connection_id: String,
    state: State<'_, AppState>,
) -> Result<Vec<SchemaInfo>, String> {
    let pool = state
        .get_pool(&connection_id)
        .ok_or_else(|| format!("Not connected to: {}", connection_id))?;

    postgres::get_schemas(&pool)
        .await
        .map_err(|e| e.to_string())
}

/// Get all tables for a schema
#[tauri::command]
pub async fn get_tables(
    connection_id: String,
    schema_name: String,
    state: State<'_, AppState>,
) -> Result<Vec<TableInfo>, String> {
    let pool = state
        .get_pool(&connection_id)
        .ok_or_else(|| format!("Not connected to: {}", connection_id))?;

    postgres::get_tables(&pool, &schema_name)
        .await
        .map_err(|e| e.to_string())
}

/// Get all columns for a table
#[tauri::command]
pub async fn get_columns(
    connection_id: String,
    schema_name: String,
    table_name: String,
    state: State<'_, AppState>,
) -> Result<Vec<ColumnInfo>, String> {
    let pool = state
        .get_pool(&connection_id)
        .ok_or_else(|| format!("Not connected to: {}", connection_id))?;

    postgres::get_columns(&pool, &schema_name, &table_name)
        .await
        .map_err(|e| e.to_string())
}
