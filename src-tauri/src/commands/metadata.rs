use tauri::State;

use crate::db::postgres;
use crate::models::{AnalyzeResult, ColumnInfo, ConstraintInfo, FunctionInfo, IndexInfo, SchemaInfo, TableInfo};
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

/// Analyze unanalyzed tables in a schema to populate row count estimates.
/// Returns which tables were attempted and which had permission errors.
/// Skips tables already known to be permission-denied for this session.
#[tauri::command]
pub async fn analyze_schema(
    connection_id: String,
    schema_name: String,
    state: State<'_, AppState>,
) -> Result<AnalyzeResult, String> {
    let pool = state
        .get_pool(&connection_id)
        .ok_or_else(|| format!("Not connected to: {}", connection_id))?;

    let cached_denied = state.get_analyze_denied(&connection_id, &schema_name);

    let result = postgres::analyze_schema(&pool, &schema_name, &cached_denied)
        .await
        .map_err(|e| e.to_string())?;

    // Cache any newly discovered permission-denied tables
    state.add_analyze_denied(&connection_id, &schema_name, &result.permission_denied_tables);

    Ok(result)
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

/// Get indexes for a table
#[tauri::command]
pub async fn get_table_indexes(
    connection_id: String,
    schema_name: String,
    table_name: String,
    state: State<'_, AppState>,
) -> Result<Vec<IndexInfo>, String> {
    let pool = state
        .get_pool(&connection_id)
        .ok_or_else(|| format!("Not connected to: {}", connection_id))?;

    postgres::get_table_indexes(&pool, &schema_name, &table_name)
        .await
        .map_err(|e| e.to_string())
}

/// Get constraints for a table
#[tauri::command]
pub async fn get_table_constraints(
    connection_id: String,
    schema_name: String,
    table_name: String,
    state: State<'_, AppState>,
) -> Result<Vec<ConstraintInfo>, String> {
    let pool = state
        .get_pool(&connection_id)
        .ok_or_else(|| format!("Not connected to: {}", connection_id))?;

    postgres::get_table_constraints(&pool, &schema_name, &table_name)
        .await
        .map_err(|e| e.to_string())
}

/// Get functions and procedures in a schema
#[tauri::command]
pub async fn get_schema_functions(
    connection_id: String,
    schema_name: String,
    state: State<'_, AppState>,
) -> Result<Vec<FunctionInfo>, String> {
    let pool = state
        .get_pool(&connection_id)
        .ok_or_else(|| format!("Not connected to: {}", connection_id))?;

    postgres::get_schema_functions(&pool, &schema_name)
        .await
        .map_err(|e| e.to_string())
}
