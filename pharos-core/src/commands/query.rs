use futures::StreamExt;
use serde::{Deserialize, Serialize};
use sqlx::{Column, Row, ValueRef};
use std::sync::atomic::Ordering;
use std::time::Instant;

use crate::db::sqlite;
use crate::db::postgres;
use crate::models::QueryHistoryEntry;
use crate::state::AppState;

#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct ColumnDef {
    pub name: String,
    pub data_type: String,
}

#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct QueryResult {
    pub columns: Vec<ColumnDef>,
    pub rows: Vec<serde_json::Value>,
    pub row_count: usize,
    pub execution_time_ms: u64,
    pub has_more: bool,
    pub history_entry_id: Option<String>,
}

/// Execute a SQL query and return results
pub async fn execute_query(
    connection_id: String,
    sql: String,
    query_id: Option<String>,
    limit: Option<u32>,
    schema: Option<String>,
    state: &AppState,
) -> Result<QueryResult, String> {
    let pool = state
        .get_pool(&connection_id)
        .ok_or_else(|| format!("Not connected to: {}", connection_id))?;

    let limit = limit.unwrap_or(1000);
    let start = Instant::now();
    let query_id = query_id.unwrap_or_else(|| uuid::Uuid::new_v4().to_string());

    // Acquire a dedicated connection from the pool so that SET search_path
    // and the query run on the same connection
    let mut conn = pool.acquire().await.map_err(|e| e.to_string())?;

    // Get the backend PID for this connection so we can cancel it later
    let backend_pid: i32 = sqlx::query_scalar("SELECT pg_backend_pid()")
        .fetch_one(&mut *conn)
        .await
        .map_err(|e| e.to_string())?;

    // Register this query for potential cancellation
    let cancelled = state.register_query(query_id.clone(), backend_pid);

    // Set search_path if schema is specified
    if let Some(ref schema_name) = schema {
        // Strict validation: allow alphanumeric, underscores, and hyphens
        // PostgreSQL allows these in quoted identifiers
        if !schema_name.chars().all(|c| c.is_ascii_alphanumeric() || c == '_' || c == '-') {
            return Err("Invalid schema name: only letters, numbers, underscores, and hyphens allowed".to_string());
        }
        if schema_name.is_empty() || schema_name.len() > 63 {
            return Err("Invalid schema name: must be 1-63 characters".to_string());
        }
        // Use double-quote escaping for the identifier (escape any " as "")
        let escaped_schema = schema_name.replace('"', "\"\"");
        let set_schema_sql = format!("SET search_path TO \"{}\", public", escaped_schema);
        sqlx::query(&set_schema_sql)
            .execute(&mut *conn)
            .await
            .map_err(|e| format!("Failed to set schema: {}", e))?;
    }

    // Use simple query protocol (text format) — PostgreSQL formats all values as text,
    // so we get arrays as {1,2,3}, timestamps as 2024-01-15 12:34:56, etc.
    let mut stream = sqlx::raw_sql(&sql).fetch(&mut *conn);
    let mut rows: Vec<sqlx::postgres::PgRow> = Vec::with_capacity((limit + 1) as usize);
    let mut fetch_error: Option<String> = None;

    while let Some(row_result) = stream.next().await {
        // Check for cancellation
        if cancelled.load(Ordering::SeqCst) {
            drop(stream);
            state.unregister_query(&query_id);
            return Err("Query was cancelled".to_string());
        }

        match row_result {
            Ok(row) => {
                rows.push(row);
                if rows.len() > limit as usize {
                    break;
                }
            }
            Err(e) => {
                fetch_error = Some(e.to_string());
                break;
            }
        }
    }

    drop(stream);
    state.unregister_query(&query_id);

    if let Some(err) = fetch_error {
        return Err(err);
    }

    let execution_time_ms = start.elapsed().as_millis() as u64;

    if rows.is_empty() {
        return Ok(QueryResult {
            columns: vec![],
            rows: vec![],
            row_count: 0,
            execution_time_ms,
            has_more: false,
            history_entry_id: None,
        });
    }

    // Extract column information from the first row
    let first_row = &rows[0];
    let columns: Vec<ColumnDef> = first_row
        .columns()
        .iter()
        .map(|col| ColumnDef {
            name: col.name().to_string(),
            data_type: col.type_info().to_string(),
        })
        .collect();

    // Determine if there are more rows
    let has_more = rows.len() > limit as usize;
    let row_limit = std::cmp::min(rows.len(), limit as usize);

    // Convert rows to JSON
    let json_rows: Vec<serde_json::Value> = rows
        .into_iter()
        .take(row_limit)
        .map(|row| {
            let mut map = serde_json::Map::new();
            for (i, col) in columns.iter().enumerate() {
                let value = extract_value(&row, i, &col.data_type);
                map.insert(col.name.clone(), value);
            }
            serde_json::Value::Object(map)
        })
        .collect();

    // Auto-save to query history with cached results (fire-and-forget)
    let history_id = uuid::Uuid::new_v4().to_string();
    {
        let connection_name = state
            .get_config(&connection_id)
            .map(|c| c.name)
            .unwrap_or_else(|| connection_id.clone());
        let table_names = extract_table_names_for_history(&sql);
        let entry = QueryHistoryEntry {
            id: history_id.clone(),
            connection_id: connection_id.clone(),
            connection_name,
            sql: sql.clone(),
            row_count: Some(row_limit as i64),
            execution_time_ms: execution_time_ms as i64,
            executed_at: chrono::Utc::now().to_rfc3339(),
            has_results: false, // Set by DB on load
            schema: schema.clone(),
            column_count: Some(columns.len() as i64),
            table_names,
        };

        // Serialize results for caching (skip if too large)
        let result_data = if !json_rows.is_empty() {
            let columns_json = serde_json::to_string(&columns).unwrap_or_default();
            let rows_json = serde_json::to_string(&json_rows).unwrap_or_default();
            if columns_json.len() + rows_json.len() < 5_000_000 {
                Some((columns_json, rows_json))
            } else {
                None
            }
        } else {
            None
        };

        if let Ok(db) = state.metadata_db.lock() {
            if let Err(e) = sqlite::save_query_history(
                &db,
                &entry,
                result_data.as_ref().map(|(c, _)| c.as_str()),
                result_data.as_ref().map(|(_, r)| r.as_str()),
            ) {
                log::warn!("Failed to save query history: {}", e);
            }
        }
    }

    Ok(QueryResult {
        columns,
        rows: json_rows,
        row_count: row_limit,
        execution_time_ms,
        has_more,
        history_entry_id: Some(history_id),
    })
}

/// Extract a value from a row at the given index.
/// With simple query protocol (raw_sql), all values arrive in PostgreSQL text format.
/// We just read the text representation directly — no per-type decoding needed.
fn extract_value(row: &sqlx::postgres::PgRow, index: usize, _type_name: &str) -> serde_json::Value {
    match row.try_get_raw(index) {
        Ok(raw) => {
            if raw.is_null() {
                serde_json::Value::Null
            } else if let Ok(s) = raw.as_str() {
                serde_json::Value::String(s.to_string())
            } else {
                serde_json::Value::Null
            }
        }
        Err(_) => serde_json::Value::Null,
    }
}

/// Fetch more rows from an already-executed query using LIMIT/OFFSET
pub async fn fetch_more_rows(
    connection_id: String,
    sql: String,
    limit: i64,
    offset: i64,
    schema: Option<String>,
    state: &AppState,
) -> Result<QueryResult, String> {
    let pool = state
        .get_pool(&connection_id)
        .ok_or_else(|| format!("Not connected to: {}", connection_id))?;

    let start = Instant::now();

    let mut conn = pool.acquire().await.map_err(|e| e.to_string())?;

    // Set search_path if schema is specified
    if let Some(ref schema_name) = schema {
        if !schema_name.chars().all(|c| c.is_ascii_alphanumeric() || c == '_' || c == '-') {
            return Err("Invalid schema name".to_string());
        }
        if schema_name.is_empty() || schema_name.len() > 63 {
            return Err("Invalid schema name: must be 1-63 characters".to_string());
        }
        let escaped_schema = schema_name.replace('"', "\"\"");
        let set_schema_sql = format!("SET search_path TO \"{}\", public", escaped_schema);
        sqlx::query(&set_schema_sql)
            .execute(&mut *conn)
            .await
            .map_err(|e| format!("Failed to set schema: {}", e))?;
    }

    // Wrap the original SQL with LIMIT/OFFSET
    let wrapped_sql = format!(
        "SELECT * FROM ({}) AS _pharos_paginated LIMIT {} OFFSET {}",
        sql.trim().trim_end_matches(';'),
        limit + 1,
        offset
    );

    let mut stream = sqlx::raw_sql(&wrapped_sql).fetch(&mut *conn);
    let mut rows: Vec<sqlx::postgres::PgRow> = Vec::with_capacity((limit + 1) as usize);

    while let Some(row_result) = stream.next().await {
        match row_result {
            Ok(row) => {
                rows.push(row);
                if rows.len() > limit as usize {
                    break;
                }
            }
            Err(e) => {
                drop(stream);
                return Err(e.to_string());
            }
        }
    }
    drop(stream);

    let execution_time_ms = start.elapsed().as_millis() as u64;

    if rows.is_empty() {
        return Ok(QueryResult {
            columns: vec![],
            rows: vec![],
            row_count: 0,
            execution_time_ms,
            has_more: false,
            history_entry_id: None,
        });
    }

    let first_row = &rows[0];
    let columns: Vec<ColumnDef> = first_row
        .columns()
        .iter()
        .map(|col| ColumnDef {
            name: col.name().to_string(),
            data_type: col.type_info().to_string(),
        })
        .collect();

    let has_more = rows.len() > limit as usize;
    let row_limit = std::cmp::min(rows.len(), limit as usize);

    let json_rows: Vec<serde_json::Value> = rows
        .into_iter()
        .take(row_limit)
        .map(|row| {
            let mut map = serde_json::Map::new();
            for (i, col) in columns.iter().enumerate() {
                let value = extract_value(&row, i, &col.data_type);
                map.insert(col.name.clone(), value);
            }
            serde_json::Value::Object(map)
        })
        .collect();

    Ok(QueryResult {
        columns,
        rows: json_rows,
        row_count: row_limit,
        execution_time_ms,
        has_more,
        history_entry_id: None,
    })
}

/// Execute a statement that doesn't return rows (INSERT, UPDATE, DELETE, etc.)
pub async fn execute_statement(
    connection_id: String,
    sql: String,
    schema: Option<String>,
    state: &AppState,
) -> Result<ExecuteResult, String> {
    let pool = state
        .get_pool(&connection_id)
        .ok_or_else(|| format!("Not connected to: {}", connection_id))?;

    let start = Instant::now();

    // Acquire a dedicated connection so SET search_path and the statement
    // run on the same connection
    let mut conn = pool.acquire().await.map_err(|e| e.to_string())?;

    // Set search_path if schema is specified
    if let Some(ref schema_name) = schema {
        if !schema_name.chars().all(|c| c.is_ascii_alphanumeric() || c == '_' || c == '-') {
            return Err("Invalid schema name: only letters, numbers, underscores, and hyphens allowed".to_string());
        }
        if schema_name.is_empty() || schema_name.len() > 63 {
            return Err("Invalid schema name: must be 1-63 characters".to_string());
        }
        let escaped_schema = schema_name.replace('"', "\"\"");
        let set_schema_sql = format!("SET search_path TO \"{}\", public", escaped_schema);
        sqlx::query(&set_schema_sql)
            .execute(&mut *conn)
            .await
            .map_err(|e| format!("Failed to set schema: {}", e))?;
    }

    let result = sqlx::query(&sql)
        .execute(&mut *conn)
        .await
        .map_err(|e| e.to_string())?;

    let execution_time_ms = start.elapsed().as_millis() as u64;

    let rows_affected = result.rows_affected();

    // Auto-save to query history (fire-and-forget, no results for statements)
    {
        let connection_name = state
            .get_config(&connection_id)
            .map(|c| c.name)
            .unwrap_or_else(|| connection_id.clone());
        let table_names = extract_table_names_for_history(&sql);
        let entry = QueryHistoryEntry {
            id: uuid::Uuid::new_v4().to_string(),
            connection_id: connection_id.clone(),
            connection_name,
            sql: sql.clone(),
            row_count: Some(rows_affected as i64),
            execution_time_ms: execution_time_ms as i64,
            executed_at: chrono::Utc::now().to_rfc3339(),
            has_results: false,
            schema: schema.clone(),
            column_count: None,
            table_names,
        };
        if let Ok(db) = state.metadata_db.lock() {
            if let Err(e) = sqlite::save_query_history(&db, &entry, None, None) {
                log::warn!("Failed to save query history: {}", e);
            }
        }
    }

    Ok(ExecuteResult {
        rows_affected,
        execution_time_ms,
    })
}

#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct ExecuteResult {
    pub rows_affected: u64,
    pub execution_time_ms: u64,
}

/// Cancel a running query
pub async fn cancel_query(
    connection_id: String,
    query_id: String,
    state: &AppState,
) -> Result<bool, String> {
    // Get the pool to send the cancel command
    let pool = state
        .get_pool(&connection_id)
        .ok_or_else(|| format!("Not connected to: {}", connection_id))?;

    // Get the backend PID for the query we want to cancel
    let backend_pid = state
        .get_query_backend_pid(&query_id)
        .ok_or_else(|| format!("Query not found: {}", query_id))?;

    // Mark the query as cancelled
    state.mark_query_cancelled(&query_id);

    // Send cancel signal to PostgreSQL
    let cancelled: bool = sqlx::query_scalar("SELECT pg_cancel_backend($1)")
        .bind(backend_pid)
        .fetch_one(&pool)
        .await
        .map_err(|e| e.to_string())?;

    Ok(cancelled)
}

/// Result of SQL validation
#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct ValidationResult {
    pub valid: bool,
    pub error: Option<ValidationError>,
}

#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct ValidationError {
    pub message: String,
    pub position: Option<usize>,
    pub line: Option<usize>,
    pub column: Option<usize>,
}

/// Validate SQL syntax without executing it
/// Uses PostgreSQL's PREPARE statement to check syntax
pub async fn validate_sql(
    connection_id: String,
    sql: String,
    schema: Option<String>,
    state: &AppState,
) -> Result<ValidationResult, String> {
    let pool = state
        .get_pool(&connection_id)
        .ok_or_else(|| format!("Not connected to: {}", connection_id))?;

    // Skip validation for empty queries
    let sql_trimmed = sql.trim();
    if sql_trimmed.is_empty() {
        return Ok(ValidationResult {
            valid: true,
            error: None,
        });
    }

    // Calculate the offset of trimmed content from the start of the original SQL
    // This is how many characters of leading whitespace were removed
    let leading_whitespace_len = sql.len() - sql.trim_start().len();

    // Acquire a dedicated connection
    let mut conn = pool.acquire().await.map_err(|e| e.to_string())?;

    // Set search_path if schema is specified
    if let Some(ref schema_name) = schema {
        if !schema_name.chars().all(|c| c.is_alphanumeric() || c == '_' || c == '-') {
            return Err("Invalid schema name".to_string());
        }
        let set_schema_sql = format!("SET search_path TO \"{}\", public", schema_name);
        sqlx::query(&set_schema_sql)
            .execute(&mut *conn)
            .await
            .map_err(|e| e.to_string())?;
    }

    // Generate a unique prepared statement name
    let stmt_name = format!("validate_{}", uuid::Uuid::new_v4().to_string().replace('-', "_"));

    // Build the PREPARE statement prefix - we need to know its length to adjust error positions
    let prepare_prefix = format!("PREPARE {} AS ", stmt_name);
    let prefix_len = prepare_prefix.len();

    // Try to prepare the statement - this validates the SQL without executing it
    let prepare_sql = format!("{}{}", prepare_prefix, sql_trimmed);

    match sqlx::query(&prepare_sql).execute(&mut *conn).await {
        Ok(_) => {
            // Clean up the prepared statement
            let deallocate_sql = format!("DEALLOCATE {}", stmt_name);
            let _ = sqlx::query(&deallocate_sql).execute(&mut *conn).await;

            Ok(ValidationResult {
                valid: true,
                error: None,
            })
        }
        Err(e) => {
            let error_msg = e.to_string();

            // Try to extract position information from PostgreSQL error
            // PostgreSQL errors often include "at character N" or similar
            // We need to subtract the PREPARE prefix length to get the position in the original SQL
            // and add back the leading whitespace offset for correct Monaco editor positioning
            let (position, line, column) = parse_error_position(&error_msg, &sql, prefix_len, leading_whitespace_len);

            Ok(ValidationResult {
                valid: false,
                error: Some(ValidationError {
                    message: clean_error_message(&error_msg),
                    position,
                    line,
                    column,
                }),
            })
        }
    }
}

/// Parse error position from PostgreSQL error message
/// The prefix_len is the length of the PREPARE statement prefix that needs to be subtracted
/// The leading_whitespace_len is the number of leading whitespace chars that were trimmed
fn parse_error_position(error_msg: &str, original_sql: &str, prefix_len: usize, leading_whitespace_len: usize) -> (Option<usize>, Option<usize>, Option<usize>) {
    // PostgreSQL often includes "at character N" in error messages
    // Also look for "POSITION: N" in the detailed error
    let raw_position = if let Some(pos_start) = error_msg.find("at character ") {
        let start = pos_start + "at character ".len();
        let end = error_msg[start..]
            .find(|c: char| !c.is_ascii_digit())
            .map(|i| start + i)
            .unwrap_or(error_msg.len());
        error_msg[start..end].parse::<usize>().ok()
    } else {
        None
    };

    // Adjust position:
    // 1. Subtract the PREPARE prefix length to get position in trimmed SQL
    // 2. Add leading whitespace length to get position in original SQL
    let position = raw_position.map(|p| {
        if p > prefix_len {
            // Position in trimmed SQL
            let trimmed_pos = p - prefix_len;
            // Add back leading whitespace to get position in original SQL
            trimmed_pos + leading_whitespace_len
        } else {
            1 // Default to position 1 if somehow the position is within the prefix
        }
    });

    // Convert character position to line and column using original SQL
    if let Some(pos) = position {
        let (line, column) = char_position_to_line_col(original_sql, pos);
        (Some(pos), Some(line), Some(column))
    } else {
        (None, None, None)
    }
}

/// Convert a character position to line and column numbers
fn char_position_to_line_col(sql: &str, position: usize) -> (usize, usize) {
    let mut line = 1;
    let mut col = 1;

    for (i, c) in sql.chars().enumerate() {
        if i + 1 >= position {
            break;
        }
        if c == '\n' {
            line += 1;
            col = 1;
        } else {
            col += 1;
        }
    }

    (line, col)
}

/// Clean up PostgreSQL error message for display
fn clean_error_message(error_msg: &str) -> String {
    // Remove the "error returned from database:" prefix that sqlx adds
    let msg = error_msg
        .strip_prefix("error returned from database: ")
        .unwrap_or(error_msg);

    // Remove the "at character N" suffix since we're providing position separately
    if let Some(pos) = msg.rfind(" at character ") {
        msg[..pos].to_string()
    } else {
        msg.to_string()
    }
}

// ============================================================================
// Inline Data Editing Commands
// ============================================================================

#[derive(Debug, Clone, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct EditableInfo {
    pub is_editable: bool,
    pub reason: Option<String>,
    pub schema_name: String,
    pub table_name: String,
    pub primary_keys: Vec<String>,
}

#[derive(Debug, Clone, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct RowEdit {
    #[serde(rename = "type")]
    pub edit_type: String, // "update" | "delete"
    pub row_index: usize,
    pub changes: serde_json::Value,    // { column: newValue }
    pub original_row: serde_json::Value, // { column: oldValue }
}

#[derive(Debug, Clone, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct CommitEditsOptions {
    pub schema_name: String,
    pub table_name: String,
    pub primary_keys: Vec<String>,
    pub edits: Vec<RowEdit>,
}

#[derive(Debug, Clone, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct CommitEditsResult {
    pub success: bool,
    pub rows_affected: u64,
    pub errors: Vec<String>,
}

/// Extract schema and table name from a normalized SQL query.
/// Handles: FROM table, FROM "table", FROM schema.table, FROM "schema"."table"
fn extract_table_from_sql(upper: &str, normalized: &str, default_schema: &Option<String>) -> Option<(String, String)> {
    // Find FROM keyword position
    let from_pos = upper.find(" FROM ")?;
    let after_from = &normalized[from_pos + 6..]; // skip " FROM "
    let after_from = after_from.trim_start();

    // Parse the table reference (possibly schema-qualified)
    let (first_ident, rest) = parse_identifier(after_from)?;

    // Check if there's a dot (schema.table)
    let rest = rest.trim_start();
    if rest.starts_with('.') {
        let after_dot = rest[1..].trim_start();
        let (second_ident, _) = parse_identifier(after_dot)?;
        Some((first_ident, second_ident))
    } else {
        let schema = default_schema.clone().unwrap_or_else(|| "public".to_string());
        Some((schema, first_ident))
    }
}

/// Extract table names from SQL for history display.
/// Scans for FROM and JOIN keywords, returns comma-separated table names.
fn extract_table_names_for_history(sql: &str) -> Option<String> {
    // Strip single-line comments and normalize whitespace
    let normalized: String = sql
        .lines()
        .map(|l| {
            if let Some(pos) = l.find("--") { &l[..pos] } else { l }
        })
        .collect::<Vec<_>>()
        .join(" ");
    let normalized: String = normalized.split_whitespace().collect::<Vec<_>>().join(" ");
    let upper = normalized.to_uppercase();

    let mut tables = Vec::new();
    let keywords = [" FROM ", " JOIN "];

    for keyword in &keywords {
        let mut search_from = 0;
        while let Some(pos) = upper[search_from..].find(keyword) {
            let abs_pos = search_from + pos + keyword.len();
            if abs_pos >= normalized.len() {
                break;
            }
            let after = normalized[abs_pos..].trim_start();
            // Skip subqueries
            if after.starts_with('(') {
                search_from = abs_pos;
                continue;
            }
            if let Some((ident, rest)) = parse_identifier(after) {
                let rest = rest.trim_start();
                let table_name = if rest.starts_with('.') {
                    // schema.table — take the table part
                    parse_identifier(rest[1..].trim_start())
                        .map(|(t, _)| t)
                        .unwrap_or(ident)
                } else {
                    ident
                };
                if !tables.contains(&table_name) {
                    tables.push(table_name);
                }
            }
            search_from = abs_pos;
        }
    }

    if tables.is_empty() { None } else { Some(tables.join(", ")) }
}

/// Parse a SQL identifier (quoted or unquoted) from the start of a string.
/// Returns (identifier, rest_of_string).
fn parse_identifier(s: &str) -> Option<(String, &str)> {
    if s.starts_with('"') {
        // Quoted identifier
        let end = s[1..].find('"')?;
        let ident = &s[1..end + 1];
        Some((ident.to_string(), &s[end + 2..]))
    } else {
        // Unquoted identifier
        let end = s.find(|c: char| !c.is_ascii_alphanumeric() && c != '_').unwrap_or(s.len());
        if end == 0 {
            return None;
        }
        Some((s[..end].to_string(), &s[end..]))
    }
}

/// Check if a SQL query produces editable results (simple single-table SELECT with PK)
pub async fn check_query_editable(
    connection_id: String,
    sql: String,
    schema: Option<String>,
    state: &AppState,
) -> Result<EditableInfo, String> {
    let pool = state
        .get_pool(&connection_id)
        .ok_or_else(|| format!("Not connected to: {}", connection_id))?;

    let not_editable = |reason: &str| -> Result<EditableInfo, String> {
        Ok(EditableInfo {
            is_editable: false,
            reason: Some(reason.to_string()),
            schema_name: String::new(),
            table_name: String::new(),
            primary_keys: vec![],
        })
    };

    // Normalize SQL: strip comments, collapse whitespace
    let normalized = sql
        .lines()
        .map(|l| {
            if let Some(pos) = l.find("--") {
                &l[..pos]
            } else {
                l
            }
        })
        .collect::<Vec<_>>()
        .join(" ");
    let normalized = normalized.split_whitespace().collect::<Vec<_>>().join(" ");
    let upper = normalized.to_uppercase();

    // Disqualify complex queries
    if upper.contains(" JOIN ") {
        return not_editable("Cannot edit: query contains JOIN");
    }
    if upper.contains(" UNION ") {
        return not_editable("Cannot edit: query contains UNION");
    }
    if upper.contains(" GROUP BY ") {
        return not_editable("Cannot edit: query contains GROUP BY");
    }
    if upper.contains(" DISTINCT ") || upper.starts_with("SELECT DISTINCT") {
        return not_editable("Cannot edit: query contains DISTINCT");
    }
    if upper.contains("(SELECT ") {
        return not_editable("Cannot edit: query contains subquery");
    }
    if upper.starts_with("WITH ") {
        return not_editable("Cannot edit: query contains CTE");
    }

    // Extract table name from simple SELECT ... FROM [schema.]table
    let (schema_name, table_name) = match extract_table_from_sql(&upper, &normalized, &schema) {
        Some(result) => result,
        None => return not_editable("Cannot edit: unable to parse table name"),
    };

    // Look up primary key columns
    let columns = postgres::get_columns(&pool, &schema_name, &table_name)
        .await
        .map_err(|e| e.to_string())?;

    let primary_keys: Vec<String> = columns
        .iter()
        .filter(|c| c.is_primary_key)
        .map(|c| c.name.clone())
        .collect();

    if primary_keys.is_empty() {
        return not_editable("Cannot edit: table has no primary key");
    }

    Ok(EditableInfo {
        is_editable: true,
        reason: None,
        schema_name,
        table_name,
        primary_keys,
    })
}

/// Commit data edits (UPDATE/DELETE) to the database within a transaction
pub async fn commit_data_edits(
    connection_id: String,
    options: CommitEditsOptions,
    state: &AppState,
) -> Result<CommitEditsResult, String> {
    let pool = state
        .get_pool(&connection_id)
        .ok_or_else(|| format!("Not connected to: {}", connection_id))?;

    let mut conn = pool.acquire().await.map_err(|e| e.to_string())?;
    let mut total_affected: u64 = 0;
    let mut errors: Vec<String> = vec![];

    // Start transaction
    sqlx::query("BEGIN").execute(&mut *conn).await.map_err(|e| e.to_string())?;

    for edit in &options.edits {
        let result = match edit.edit_type.as_str() {
            "update" => {
                execute_update(
                    &mut conn,
                    &options.schema_name,
                    &options.table_name,
                    &options.primary_keys,
                    edit,
                ).await
            }
            "delete" => {
                execute_delete(
                    &mut conn,
                    &options.schema_name,
                    &options.table_name,
                    &options.primary_keys,
                    edit,
                ).await
            }
            other => Err(format!("Unknown edit type: {}", other)),
        };

        match result {
            Ok(affected) => total_affected += affected,
            Err(e) => {
                errors.push(e.clone());
                // Rollback on first error
                let _ = sqlx::query("ROLLBACK").execute(&mut *conn).await;
                return Ok(CommitEditsResult {
                    success: false,
                    rows_affected: 0,
                    errors,
                });
            }
        }
    }

    // Commit
    sqlx::query("COMMIT").execute(&mut *conn).await.map_err(|e| e.to_string())?;

    Ok(CommitEditsResult {
        success: true,
        rows_affected: total_affected,
        errors,
    })
}

async fn execute_update(
    conn: &mut sqlx::pool::PoolConnection<sqlx::Postgres>,
    schema_name: &str,
    table_name: &str,
    primary_keys: &[String],
    edit: &RowEdit,
) -> Result<u64, String> {
    let changes = edit.changes.as_object()
        .ok_or("Invalid changes format")?;
    let original = edit.original_row.as_object()
        .ok_or("Invalid original_row format")?;

    if changes.is_empty() {
        return Ok(0);
    }

    // Build SET clause
    let mut set_parts: Vec<String> = vec![];
    let mut param_index = 1u32;
    let mut params: Vec<String> = vec![];

    for (col, val) in changes {
        if val.is_null() {
            set_parts.push(format!("\"{}\" = NULL", col));
        } else {
            set_parts.push(format!("\"{}\" = ${}", col, param_index));
            params.push(json_value_to_sql_param(val));
            param_index += 1;
        }
    }

    // Build WHERE clause from primary keys
    let mut where_parts: Vec<String> = vec![];
    for pk in primary_keys {
        let pk_val = original.get(pk)
            .ok_or_else(|| format!("Primary key '{}' not found in original row", pk))?;
        if pk_val.is_null() {
            where_parts.push(format!("\"{}\" IS NULL", pk));
        } else {
            where_parts.push(format!("\"{}\" = ${}", pk, param_index));
            params.push(json_value_to_sql_param(pk_val));
            param_index += 1;
        }
    }

    let sql = format!(
        "UPDATE \"{}\".\"{}\" SET {} WHERE {}",
        schema_name, table_name,
        set_parts.join(", "),
        where_parts.join(" AND ")
    );

    // Build dynamic query with text parameters and let PostgreSQL cast
    let mut query = sqlx::query(&sql);
    for p in &params {
        query = query.bind(p.clone());
    }

    let result = query.execute(&mut **conn).await.map_err(|e| e.to_string())?;
    Ok(result.rows_affected())
}

async fn execute_delete(
    conn: &mut sqlx::pool::PoolConnection<sqlx::Postgres>,
    schema_name: &str,
    table_name: &str,
    primary_keys: &[String],
    edit: &RowEdit,
) -> Result<u64, String> {
    let original = edit.original_row.as_object()
        .ok_or("Invalid original_row format")?;

    let mut where_parts: Vec<String> = vec![];
    let mut params: Vec<String> = vec![];
    let mut param_index = 1u32;

    for pk in primary_keys {
        let pk_val = original.get(pk)
            .ok_or_else(|| format!("Primary key '{}' not found in original row", pk))?;
        if pk_val.is_null() {
            where_parts.push(format!("\"{}\" IS NULL", pk));
        } else {
            where_parts.push(format!("\"{}\" = ${}", pk, param_index));
            params.push(json_value_to_sql_param(pk_val));
            param_index += 1;
        }
    }

    let sql = format!(
        "DELETE FROM \"{}\".\"{}\" WHERE {}",
        schema_name, table_name,
        where_parts.join(" AND ")
    );

    let mut query = sqlx::query(&sql);
    for p in &params {
        query = query.bind(p.clone());
    }

    let result = query.execute(&mut **conn).await.map_err(|e| e.to_string())?;
    Ok(result.rows_affected())
}

fn json_value_to_sql_param(val: &serde_json::Value) -> String {
    match val {
        serde_json::Value::Null => "".to_string(), // Will be bound as text; use IS NULL in WHERE for null checks
        serde_json::Value::Bool(b) => b.to_string(),
        serde_json::Value::Number(n) => n.to_string(),
        serde_json::Value::String(s) => s.clone(),
        other => other.to_string(),
    }
}
