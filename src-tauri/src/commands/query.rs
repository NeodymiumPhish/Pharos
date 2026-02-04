use serde::{Deserialize, Serialize};
use sqlx::{Column, Row, ValueRef};
use std::time::Instant;
use std::sync::atomic::Ordering;
use tauri::State;

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
}

/// Execute a SQL query and return results
#[tauri::command]
pub async fn execute_query(
    connection_id: String,
    sql: String,
    query_id: Option<String>,
    limit: Option<u32>,
    schema: Option<String>,
    state: State<'_, AppState>,
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

    // Execute the query on the same connection
    let result = sqlx::query(&sql)
        .fetch_all(&mut *conn)
        .await;

    // Unregister the query now that it's done
    state.unregister_query(&query_id);

    // Check if cancelled
    if cancelled.load(Ordering::SeqCst) {
        return Err("Query was cancelled".to_string());
    }

    let rows = result.map_err(|e| e.to_string())?;

    let execution_time_ms = start.elapsed().as_millis() as u64;

    if rows.is_empty() {
        return Ok(QueryResult {
            columns: vec![],
            rows: vec![],
            row_count: 0,
            execution_time_ms,
            has_more: false,
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

    // Convert rows to JSON
    let total_rows = rows.len();
    let has_more = total_rows > limit as usize;
    let row_limit = std::cmp::min(total_rows, limit as usize);

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
        row_count: total_rows,
        execution_time_ms,
        has_more,
    })
}

/// Extract a value from a row at the given index
fn extract_value(row: &sqlx::postgres::PgRow, index: usize, type_name: &str) -> serde_json::Value {
    let upper_type = type_name.to_uppercase();
    let type_str = upper_type.as_str();

    // Check for array types first (they start with underscore in PostgreSQL internal names or end with [])
    if type_str.starts_with('_') || type_str.ends_with("[]") {
        return extract_array_value(row, index, type_str);
    }

    // Try to extract based on type
    match type_str {
        // Integer types
        "INT2" | "SMALLINT" => {
            if let Ok(v) = row.try_get::<Option<i16>, _>(index) {
                return match v {
                    Some(n) => serde_json::Value::Number(n.into()),
                    None => serde_json::Value::Null,
                };
            }
        }
        "INT4" | "INTEGER" | "SERIAL" => {
            if let Ok(v) = row.try_get::<Option<i32>, _>(index) {
                return match v {
                    Some(n) => serde_json::Value::Number(n.into()),
                    None => serde_json::Value::Null,
                };
            }
        }
        "INT8" | "BIGINT" | "BIGSERIAL" => {
            if let Ok(v) = row.try_get::<Option<i64>, _>(index) {
                return match v {
                    Some(n) => serde_json::Value::Number(n.into()),
                    None => serde_json::Value::Null,
                };
            }
        }
        // Floating point types
        "FLOAT4" | "REAL" => {
            if let Ok(v) = row.try_get::<Option<f32>, _>(index) {
                return match v {
                    Some(n) => serde_json::Number::from_f64(n as f64)
                        .map(serde_json::Value::Number)
                        .unwrap_or(serde_json::Value::String(n.to_string())),
                    None => serde_json::Value::Null,
                };
            }
        }
        "FLOAT8" | "DOUBLE PRECISION" => {
            if let Ok(v) = row.try_get::<Option<f64>, _>(index) {
                return match v {
                    Some(n) => serde_json::Number::from_f64(n)
                        .map(serde_json::Value::Number)
                        .unwrap_or(serde_json::Value::String(n.to_string())),
                    None => serde_json::Value::Null,
                };
            }
        }
        // Numeric/Decimal - try as f64 first, then fallback to string
        "NUMERIC" | "DECIMAL" => {
            // Try f64 first (works for most numeric values)
            if let Ok(v) = row.try_get::<Option<f64>, _>(index) {
                return match v {
                    Some(n) => serde_json::Number::from_f64(n)
                        .map(serde_json::Value::Number)
                        .unwrap_or(serde_json::Value::String(n.to_string())),
                    None => serde_json::Value::Null,
                };
            }
            // Fallback to string for high precision numbers
            if let Ok(v) = row.try_get::<Option<String>, _>(index) {
                return match v {
                    Some(s) => serde_json::Value::String(s),
                    None => serde_json::Value::Null,
                };
            }
        }
        // Boolean
        "BOOL" | "BOOLEAN" => {
            if let Ok(v) = row.try_get::<Option<bool>, _>(index) {
                return match v {
                    Some(b) => serde_json::Value::Bool(b),
                    None => serde_json::Value::Null,
                };
            }
        }
        // JSON types
        "JSON" | "JSONB" => {
            if let Ok(v) = row.try_get::<Option<serde_json::Value>, _>(index) {
                return v.unwrap_or(serde_json::Value::Null);
            }
        }
        // UUID
        "UUID" => {
            if let Ok(v) = row.try_get::<Option<uuid::Uuid>, _>(index) {
                return match v {
                    Some(u) => serde_json::Value::String(u.to_string()),
                    None => serde_json::Value::Null,
                };
            }
        }
        // Timestamp types
        "TIMESTAMP" | "TIMESTAMP WITHOUT TIME ZONE" => {
            if let Ok(v) = row.try_get::<Option<chrono::NaiveDateTime>, _>(index) {
                return match v {
                    Some(dt) => serde_json::Value::String(dt.format("%Y-%m-%d %H:%M:%S%.f").to_string()),
                    None => serde_json::Value::Null,
                };
            }
        }
        "TIMESTAMPTZ" | "TIMESTAMP WITH TIME ZONE" => {
            if let Ok(v) = row.try_get::<Option<chrono::DateTime<chrono::Utc>>, _>(index) {
                return match v {
                    Some(dt) => serde_json::Value::String(dt.to_rfc3339()),
                    None => serde_json::Value::Null,
                };
            }
        }
        // Date
        "DATE" => {
            if let Ok(v) = row.try_get::<Option<chrono::NaiveDate>, _>(index) {
                return match v {
                    Some(d) => serde_json::Value::String(d.to_string()),
                    None => serde_json::Value::Null,
                };
            }
        }
        // Time types
        "TIME" | "TIME WITHOUT TIME ZONE" => {
            if let Ok(v) = row.try_get::<Option<chrono::NaiveTime>, _>(index) {
                return match v {
                    Some(t) => serde_json::Value::String(t.format("%H:%M:%S%.f").to_string()),
                    None => serde_json::Value::Null,
                };
            }
        }
        "TIMETZ" | "TIME WITH TIME ZONE" => {
            // TimeTz isn't directly supported, fall through to string
        }
        // Network types
        "INET" => {
            if let Ok(v) = row.try_get::<Option<ipnetwork::IpNetwork>, _>(index) {
                return match v {
                    Some(ip) => {
                        // For single host addresses, don't show CIDR notation
                        let is_single_host = match ip {
                            ipnetwork::IpNetwork::V4(net) => net.prefix() == 32,
                            ipnetwork::IpNetwork::V6(net) => net.prefix() == 128,
                        };
                        if is_single_host {
                            serde_json::Value::String(ip.ip().to_string())
                        } else {
                            serde_json::Value::String(ip.to_string())
                        }
                    }
                    None => serde_json::Value::Null,
                };
            }
        }
        "CIDR" => {
            if let Ok(v) = row.try_get::<Option<ipnetwork::IpNetwork>, _>(index) {
                return match v {
                    Some(ip) => serde_json::Value::String(ip.to_string()),
                    None => serde_json::Value::Null,
                };
            }
        }
        "MACADDR" | "MACADDR8" => {
            if let Ok(v) = row.try_get::<Option<mac_address::MacAddress>, _>(index) {
                return match v {
                    Some(mac) => serde_json::Value::String(mac.to_string()),
                    None => serde_json::Value::Null,
                };
            }
        }
        // Binary data
        "BYTEA" => {
            if let Ok(v) = row.try_get::<Option<Vec<u8>>, _>(index) {
                return match v {
                    Some(bytes) => serde_json::Value::String(format!("\\x{}", hex::encode(bytes))),
                    None => serde_json::Value::Null,
                };
            }
        }
        // Bit strings - fall through to string fallback
        "BIT" | "VARBIT" | "BIT VARYING" => {}
        // Interval
        "INTERVAL" => {
            if let Ok(v) = row.try_get::<Option<sqlx::postgres::types::PgInterval>, _>(index) {
                return match v {
                    Some(interval) => {
                        // Format interval as human-readable string
                        let mut parts = Vec::new();
                        if interval.months != 0 {
                            let years = interval.months / 12;
                            let months = interval.months % 12;
                            if years != 0 {
                                parts.push(format!("{} year{}", years, if years.abs() != 1 { "s" } else { "" }));
                            }
                            if months != 0 {
                                parts.push(format!("{} mon{}", months, if months.abs() != 1 { "s" } else { "" }));
                            }
                        }
                        if interval.days != 0 {
                            parts.push(format!("{} day{}", interval.days, if interval.days.abs() != 1 { "s" } else { "" }));
                        }
                        if interval.microseconds != 0 {
                            let total_secs = interval.microseconds / 1_000_000;
                            let hours = total_secs / 3600;
                            let mins = (total_secs % 3600) / 60;
                            let secs = total_secs % 60;
                            let micros = interval.microseconds % 1_000_000;

                            if hours != 0 || mins != 0 || secs != 0 || micros != 0 {
                                if micros != 0 {
                                    parts.push(format!("{:02}:{:02}:{:02}.{:06}", hours, mins, secs, micros.abs()));
                                } else {
                                    parts.push(format!("{:02}:{:02}:{:02}", hours, mins, secs));
                                }
                            }
                        }
                        if parts.is_empty() {
                            serde_json::Value::String("00:00:00".to_string())
                        } else {
                            serde_json::Value::String(parts.join(" "))
                        }
                    }
                    None => serde_json::Value::Null,
                };
            }
        }
        // Geometric types - fall through to string
        "POINT" | "LINE" | "LSEG" | "BOX" | "PATH" | "POLYGON" | "CIRCLE" => {}
        // Range types - fall through to string
        "INT4RANGE" | "INT8RANGE" | "NUMRANGE" | "TSRANGE" | "TSTZRANGE" | "DATERANGE" => {}
        // Text search types
        "TSVECTOR" | "TSQUERY" => {}
        // OID types - PostgreSQL OIDs are returned as i32 in sqlx
        "OID" | "REGCLASS" | "REGPROC" | "REGTYPE" => {
            if let Ok(v) = row.try_get::<Option<i32>, _>(index) {
                return match v {
                    Some(n) => serde_json::Value::Number(n.into()),
                    None => serde_json::Value::Null,
                };
            }
        }
        // Character types - handled in fallback
        "CHAR" | "VARCHAR" | "TEXT" | "BPCHAR" | "NAME" => {}
        // XML
        "XML" => {}
        // Money - stored as bigint internally, but returned as string with formatting
        "MONEY" => {}
        _ => {}
    }

    // Fallback: try to get as string (handles TEXT, VARCHAR, CHAR, and many other types)
    if let Ok(v) = row.try_get::<Option<String>, _>(index) {
        return match v {
            Some(s) => serde_json::Value::String(s),
            None => serde_json::Value::Null,
        };
    }

    // Final fallback for truly unknown types
    serde_json::Value::Null
}

/// Parse PostgreSQL array string format into JSON values
/// Handles format like: elem1,elem2,NULL,"quoted value"
fn parse_pg_array_string(s: &str) -> Vec<serde_json::Value> {
    let mut elements = Vec::new();
    let mut current = String::new();
    let mut in_quotes = false;

    for c in s.chars() {
        match c {
            '"' if !in_quotes => in_quotes = true,
            '"' if in_quotes => in_quotes = false,
            ',' if !in_quotes => {
                elements.push(pg_element_to_json(&current));
                current.clear();
            }
            _ => current.push(c),
        }
    }

    if !current.is_empty() || !s.is_empty() {
        elements.push(pg_element_to_json(&current));
    }

    elements
}

/// Convert a single PostgreSQL array element to JSON value
fn pg_element_to_json(s: &str) -> serde_json::Value {
    let trimmed = s.trim();
    if trimmed.eq_ignore_ascii_case("null") {
        serde_json::Value::Null
    } else if let Ok(n) = trimmed.parse::<i64>() {
        serde_json::Value::Number(n.into())
    } else if let Ok(n) = trimmed.parse::<f64>() {
        serde_json::Number::from_f64(n)
            .map(serde_json::Value::Number)
            .unwrap_or_else(|| serde_json::Value::String(trimmed.to_string()))
    } else if trimmed == "t" || trimmed == "true" {
        serde_json::Value::Bool(true)
    } else if trimmed == "f" || trimmed == "false" {
        serde_json::Value::Bool(false)
    } else {
        serde_json::Value::String(trimmed.to_string())
    }
}

/// Extract array values from PostgreSQL array types
fn extract_array_value(row: &sqlx::postgres::PgRow, index: usize, type_name: &str) -> serde_json::Value {
    // Determine the base type (remove leading underscore or trailing [])
    let base_type = type_name
        .trim_start_matches('_')
        .trim_end_matches("[]")
        .to_uppercase();

    match base_type.as_str() {
        // Integer arrays
        "INT2" | "SMALLINT" => {
            if let Ok(v) = row.try_get::<Option<Vec<i16>>, _>(index) {
                return match v {
                    Some(arr) => serde_json::Value::Array(arr.into_iter().map(|n| serde_json::Value::Number(n.into())).collect()),
                    None => serde_json::Value::Null,
                };
            }
        }
        "INT4" | "INTEGER" => {
            if let Ok(v) = row.try_get::<Option<Vec<i32>>, _>(index) {
                return match v {
                    Some(arr) => serde_json::Value::Array(arr.into_iter().map(|n| serde_json::Value::Number(n.into())).collect()),
                    None => serde_json::Value::Null,
                };
            }
        }
        "INT8" | "BIGINT" => {
            if let Ok(v) = row.try_get::<Option<Vec<i64>>, _>(index) {
                return match v {
                    Some(arr) => serde_json::Value::Array(arr.into_iter().map(|n| serde_json::Value::Number(n.into())).collect()),
                    None => serde_json::Value::Null,
                };
            }
        }
        // Float arrays
        "FLOAT4" | "REAL" => {
            if let Ok(v) = row.try_get::<Option<Vec<f32>>, _>(index) {
                return match v {
                    Some(arr) => serde_json::Value::Array(arr.into_iter().map(|n| {
                        serde_json::Number::from_f64(n as f64)
                            .map(serde_json::Value::Number)
                            .unwrap_or(serde_json::Value::String(n.to_string()))
                    }).collect()),
                    None => serde_json::Value::Null,
                };
            }
        }
        "FLOAT8" | "DOUBLE PRECISION" => {
            if let Ok(v) = row.try_get::<Option<Vec<f64>>, _>(index) {
                return match v {
                    Some(arr) => serde_json::Value::Array(arr.into_iter().map(|n| {
                        serde_json::Number::from_f64(n)
                            .map(serde_json::Value::Number)
                            .unwrap_or(serde_json::Value::String(n.to_string()))
                    }).collect()),
                    None => serde_json::Value::Null,
                };
            }
        }
        // Boolean arrays
        "BOOL" | "BOOLEAN" => {
            if let Ok(v) = row.try_get::<Option<Vec<bool>>, _>(index) {
                return match v {
                    Some(arr) => serde_json::Value::Array(arr.into_iter().map(serde_json::Value::Bool).collect()),
                    None => serde_json::Value::Null,
                };
            }
        }
        // UUID arrays
        "UUID" => {
            if let Ok(v) = row.try_get::<Option<Vec<uuid::Uuid>>, _>(index) {
                return match v {
                    Some(arr) => serde_json::Value::Array(arr.into_iter().map(|u| serde_json::Value::String(u.to_string())).collect()),
                    None => serde_json::Value::Null,
                };
            }
        }
        // Text/String arrays
        "TEXT" | "VARCHAR" | "CHAR" | "BPCHAR" | "NAME" => {
            if let Ok(v) = row.try_get::<Option<Vec<String>>, _>(index) {
                return match v {
                    Some(arr) => serde_json::Value::Array(arr.into_iter().map(serde_json::Value::String).collect()),
                    None => serde_json::Value::Null,
                };
            }
        }
        // Inet arrays
        "INET" | "CIDR" => {
            if let Ok(v) = row.try_get::<Option<Vec<ipnetwork::IpNetwork>>, _>(index) {
                return match v {
                    Some(arr) => serde_json::Value::Array(arr.into_iter().map(|ip| serde_json::Value::String(ip.to_string())).collect()),
                    None => serde_json::Value::Null,
                };
            }
        }
        // JSON arrays
        "JSON" | "JSONB" => {
            if let Ok(v) = row.try_get::<Option<Vec<serde_json::Value>>, _>(index) {
                return match v {
                    Some(arr) => serde_json::Value::Array(arr),
                    None => serde_json::Value::Null,
                };
            }
        }
        _ => {}
    }

    // Fallback: try to get as string array
    if let Ok(v) = row.try_get::<Option<Vec<String>>, _>(index) {
        return match v {
            Some(arr) => serde_json::Value::Array(arr.into_iter().map(serde_json::Value::String).collect()),
            None => serde_json::Value::Null,
        };
    }

    // Last resort: get raw PostgreSQL text representation and parse it
    if let Ok(value_ref) = row.try_get_raw(index) {
        if value_ref.is_null() {
            return serde_json::Value::Null;
        }
        if let Ok(s) = value_ref.as_str() {
            // Parse PostgreSQL array format: {elem1,elem2,NULL,...}
            if s.starts_with('{') && s.ends_with('}') {
                let inner = &s[1..s.len()-1];
                if inner.is_empty() {
                    return serde_json::Value::Array(vec![]);
                }
                let elements = parse_pg_array_string(inner);
                return serde_json::Value::Array(elements);
            }
            // Not an array format, return as string
            return serde_json::Value::String(s.to_string());
        }
    }

    serde_json::Value::Null
}

/// Execute a statement that doesn't return rows (INSERT, UPDATE, DELETE, etc.)
#[tauri::command]
pub async fn execute_statement(
    connection_id: String,
    sql: String,
    state: State<'_, AppState>,
) -> Result<ExecuteResult, String> {
    let pool = state
        .get_pool(&connection_id)
        .ok_or_else(|| format!("Not connected to: {}", connection_id))?;

    let start = Instant::now();

    let result = sqlx::query(&sql)
        .execute(&pool)
        .await
        .map_err(|e| e.to_string())?;

    let execution_time_ms = start.elapsed().as_millis() as u64;

    Ok(ExecuteResult {
        rows_affected: result.rows_affected(),
        execution_time_ms,
    })
}

#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct ExecuteResult {
    pub rows_affected: u64,
    pub execution_time_ms: u64,
}

/// Cancel a running query
#[tauri::command]
pub async fn cancel_query(
    connection_id: String,
    query_id: String,
    state: State<'_, AppState>,
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
#[tauri::command]
pub async fn validate_sql(
    connection_id: String,
    sql: String,
    schema: Option<String>,
    state: State<'_, AppState>,
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
