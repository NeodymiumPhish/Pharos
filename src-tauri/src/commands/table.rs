use serde::{Deserialize, Serialize};
use sqlx::{Column, Row};
use std::fs::File;
use std::io::BufWriter;
use tauri::State;

use crate::db::postgres;
use crate::state::AppState;

// ============================================================================
// Clone Table
// ============================================================================

#[derive(Debug, Clone, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct CloneTableOptions {
    pub source_schema: String,
    pub source_table: String,
    pub target_schema: String,
    pub target_table: String,
    pub include_data: bool,
}

#[derive(Debug, Clone, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct CloneTableResult {
    pub success: bool,
    pub rows_copied: Option<u64>,
}

/// Clone a table structure with optional data
#[tauri::command]
pub async fn clone_table(
    connection_id: String,
    options: CloneTableOptions,
    state: State<'_, AppState>,
) -> Result<CloneTableResult, String> {
    let pool = state
        .get_pool(&connection_id)
        .ok_or_else(|| format!("Not connected to: {}", connection_id))?;

    // Validate identifiers to prevent SQL injection
    validate_identifier(&options.source_schema)?;
    validate_identifier(&options.source_table)?;
    validate_identifier(&options.target_schema)?;
    validate_identifier(&options.target_table)?;

    // Create the table structure using LIKE INCLUDING ALL
    // This copies columns, constraints, indexes, defaults, etc.
    let create_sql = format!(
        r#"CREATE TABLE "{}"."{}" (LIKE "{}"."{}" INCLUDING ALL)"#,
        options.target_schema,
        options.target_table,
        options.source_schema,
        options.source_table
    );

    sqlx::query(&create_sql)
        .execute(&pool)
        .await
        .map_err(|e| format!("Failed to create table: {}", e))?;

    let mut rows_copied: Option<u64> = None;

    // Copy data if requested
    if options.include_data {
        let insert_sql = format!(
            "INSERT INTO \"{}\".\"{}\" SELECT * FROM \"{}\".\"{}\"",
            options.target_schema,
            options.target_table,
            options.source_schema,
            options.source_table
        );

        let result = sqlx::query(&insert_sql)
            .execute(&pool)
            .await
            .map_err(|e| format!("Failed to copy data: {}", e))?;

        rows_copied = Some(result.rows_affected());
    }

    Ok(CloneTableResult {
        success: true,
        rows_copied,
    })
}

// ============================================================================
// CSV Validation
// ============================================================================

#[derive(Debug, Clone, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct CsvValidationResult {
    pub valid: bool,
    pub row_count: usize,
    pub column_count: usize,
    pub csv_headers: Option<Vec<String>>,
    pub table_columns: Vec<String>,
    pub error: Option<String>,
}

/// Validate a CSV file for import into a table
#[tauri::command]
pub async fn validate_csv_for_import(
    connection_id: String,
    schema_name: String,
    table_name: String,
    file_path: String,
    has_headers: bool,
    state: State<'_, AppState>,
) -> Result<CsvValidationResult, String> {
    let pool = state
        .get_pool(&connection_id)
        .ok_or_else(|| format!("Not connected to: {}", connection_id))?;

    // Validate identifiers
    validate_identifier(&schema_name)?;
    validate_identifier(&table_name)?;

    // Get table columns
    let columns = postgres::get_columns(&pool, &schema_name, &table_name)
        .await
        .map_err(|e| format!("Failed to get table columns: {}", e))?;

    let table_columns: Vec<String> = columns.iter().map(|c| c.name.clone()).collect();

    // Open and read the CSV file
    let file = File::open(&file_path)
        .map_err(|e| format!("Failed to open file: {}", e))?;

    let mut reader = csv::ReaderBuilder::new()
        .has_headers(has_headers)
        .from_reader(file);

    let csv_headers: Option<Vec<String>> = if has_headers {
        let headers = reader.headers()
            .map_err(|e| format!("Failed to read CSV headers: {}", e))?;
        Some(headers.iter().map(|h| h.to_string()).collect())
    } else {
        None
    };

    // Count rows and check column count
    let mut row_count = 0;
    let mut csv_column_count = 0;

    for result in reader.records() {
        let record = result.map_err(|e| format!("Failed to read CSV row {}: {}", row_count + 1, e))?;

        if row_count == 0 {
            csv_column_count = record.len();
        } else if record.len() != csv_column_count {
            return Ok(CsvValidationResult {
                valid: false,
                row_count,
                column_count: csv_column_count,
                csv_headers,
                table_columns,
                error: Some(format!(
                    "Inconsistent column count: row {} has {} columns, expected {}",
                    row_count + 1,
                    record.len(),
                    csv_column_count
                )),
            });
        }

        row_count += 1;
    }

    // Check if column count matches table
    let table_column_count = table_columns.len();
    if csv_column_count != table_column_count {
        return Ok(CsvValidationResult {
            valid: false,
            row_count,
            column_count: csv_column_count,
            csv_headers,
            table_columns,
            error: Some(format!(
                "Column count mismatch: CSV has {} columns, table has {}",
                csv_column_count,
                table_column_count
            )),
        });
    }

    Ok(CsvValidationResult {
        valid: true,
        row_count,
        column_count: csv_column_count,
        csv_headers,
        table_columns,
        error: None,
    })
}

// ============================================================================
// CSV Import
// ============================================================================

#[derive(Debug, Clone, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct ImportCsvOptions {
    pub schema_name: String,
    pub table_name: String,
    pub file_path: String,
    pub has_headers: bool,
}

#[derive(Debug, Clone, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct ImportCsvResult {
    pub success: bool,
    pub rows_imported: u64,
}

/// Import CSV data into a table
#[tauri::command]
pub async fn import_csv(
    connection_id: String,
    options: ImportCsvOptions,
    state: State<'_, AppState>,
) -> Result<ImportCsvResult, String> {
    let pool = state
        .get_pool(&connection_id)
        .ok_or_else(|| format!("Not connected to: {}", connection_id))?;

    // Validate identifiers
    validate_identifier(&options.schema_name)?;
    validate_identifier(&options.table_name)?;

    // Get table columns for ordering
    let columns = postgres::get_columns(&pool, &options.schema_name, &options.table_name)
        .await
        .map_err(|e| format!("Failed to get table columns: {}", e))?;

    let column_names: Vec<String> = columns.iter().map(|c| format!("\"{}\"", c.name)).collect();
    let column_list = column_names.join(", ");

    // Open and read the CSV file
    let file = File::open(&options.file_path)
        .map_err(|e| format!("Failed to open file: {}", e))?;

    let mut reader = csv::ReaderBuilder::new()
        .has_headers(options.has_headers)
        .from_reader(file);

    // Begin a transaction
    let mut tx = pool.begin().await.map_err(|e| format!("Failed to begin transaction: {}", e))?;

    let mut rows_imported: u64 = 0;
    let batch_size = 100;
    let mut batch_values: Vec<String> = Vec::with_capacity(batch_size);

    for result in reader.records() {
        let record = result.map_err(|e| format!("Failed to read CSV row: {}", e))?;

        // Build value string for this row
        let values: Vec<String> = record
            .iter()
            .map(|v| {
                if v.is_empty() {
                    "NULL".to_string()
                } else {
                    // Escape single quotes for SQL
                    format!("'{}'", v.replace('\'', "''"))
                }
            })
            .collect();

        batch_values.push(format!("({})", values.join(", ")));

        // Execute batch when full
        if batch_values.len() >= batch_size {
            let insert_sql = format!(
                r#"INSERT INTO "{}"."{}" ({}) VALUES {}"#,
                options.schema_name,
                options.table_name,
                column_list,
                batch_values.join(", ")
            );

            let result = sqlx::query(&insert_sql)
                .execute(&mut *tx)
                .await
                .map_err(|e| format!("Failed to insert batch: {}", e))?;

            rows_imported += result.rows_affected();
            batch_values.clear();
        }
    }

    // Insert remaining rows
    if !batch_values.is_empty() {
        let insert_sql = format!(
            r#"INSERT INTO "{}"."{}" ({}) VALUES {}"#,
            options.schema_name,
            options.table_name,
            column_list,
            batch_values.join(", ")
        );

        let result = sqlx::query(&insert_sql)
            .execute(&mut *tx)
            .await
            .map_err(|e| format!("Failed to insert final batch: {}", e))?;

        rows_imported += result.rows_affected();
    }

    // Commit transaction
    tx.commit().await.map_err(|e| format!("Failed to commit transaction: {}", e))?;

    Ok(ImportCsvResult {
        success: true,
        rows_imported,
    })
}

// ============================================================================
// CSV Export
// ============================================================================

#[derive(Debug, Clone, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct ExportCsvOptions {
    pub schema_name: String,
    pub table_name: String,
    pub columns: Vec<String>,
    pub include_headers: bool,
    pub null_as_empty: bool,
    pub file_path: String,
}

#[derive(Debug, Clone, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct ExportCsvResult {
    pub success: bool,
    pub rows_exported: u64,
}

/// Export table data to CSV
#[tauri::command]
pub async fn export_csv(
    connection_id: String,
    options: ExportCsvOptions,
    state: State<'_, AppState>,
) -> Result<ExportCsvResult, String> {
    let pool = state
        .get_pool(&connection_id)
        .ok_or_else(|| format!("Not connected to: {}", connection_id))?;

    // Validate identifiers
    validate_identifier(&options.schema_name)?;
    validate_identifier(&options.table_name)?;
    for col in &options.columns {
        validate_identifier(col)?;
    }

    // Build column list for SELECT
    let column_list = if options.columns.is_empty() {
        "*".to_string()
    } else {
        options.columns.iter()
            .map(|c| format!("\"{}\"", c))
            .collect::<Vec<_>>()
            .join(", ")
    };

    let select_sql = format!(
        "SELECT {} FROM \"{}\".\"{}\"",
        column_list,
        options.schema_name,
        options.table_name
    );

    // Execute query
    let rows = sqlx::query(&select_sql)
        .fetch_all(&pool)
        .await
        .map_err(|e| format!("Failed to query table: {}", e))?;

    // Create output file
    let file = File::create(&options.file_path)
        .map_err(|e| format!("Failed to create file: {}", e))?;

    let mut writer = csv::Writer::from_writer(BufWriter::new(file));

    // Write headers if requested
    if options.include_headers && !rows.is_empty() {
        let first_row = &rows[0];
        let headers: Vec<&str> = first_row.columns()
            .iter()
            .map(|col| col.name())
            .collect();
        writer.write_record(&headers)
            .map_err(|e| format!("Failed to write headers: {}", e))?;
    }

    // Write data rows
    let mut rows_exported: u64 = 0;
    for row in &rows {
        let mut record: Vec<String> = Vec::with_capacity(row.columns().len());

        for (i, col) in row.columns().iter().enumerate() {
            let type_name = col.type_info().to_string();
            let value = extract_csv_value(row, i, &type_name, options.null_as_empty);
            record.push(value);
        }

        writer.write_record(&record)
            .map_err(|e| format!("Failed to write row: {}", e))?;
        rows_exported += 1;
    }

    writer.flush()
        .map_err(|e| format!("Failed to flush writer: {}", e))?;

    Ok(ExportCsvResult {
        success: true,
        rows_exported,
    })
}

// ============================================================================
// Helper Functions
// ============================================================================

/// Validate an identifier (schema, table, or column name) to prevent SQL injection
fn validate_identifier(name: &str) -> Result<(), String> {
    if name.is_empty() {
        return Err("Identifier cannot be empty".to_string());
    }

    // Allow alphanumeric, underscores, hyphens, and spaces
    // PostgreSQL allows more, but this is a reasonable subset
    if !name.chars().all(|c| c.is_alphanumeric() || c == '_' || c == '-' || c == ' ') {
        return Err(format!("Invalid identifier: {}", name));
    }

    // Check for common SQL injection patterns
    let lower = name.to_lowercase();
    let dangerous = ["--", ";", "drop", "delete", "insert", "update", "truncate", "alter", "create"];
    for pattern in dangerous {
        if lower.contains(pattern) {
            return Err(format!("Invalid identifier contains dangerous pattern: {}", name));
        }
    }

    Ok(())
}

/// Extract a value from a row as a CSV-friendly string
fn extract_csv_value(row: &sqlx::postgres::PgRow, index: usize, type_name: &str, null_as_empty: bool) -> String {
    let upper_type = type_name.to_uppercase();

    // Helper for NULL handling
    let null_string = || if null_as_empty { String::new() } else { "NULL".to_string() };

    // Try to extract based on type (simplified version of query.rs extract_value)
    match upper_type.as_str() {
        "INT2" | "SMALLINT" => {
            if let Ok(v) = row.try_get::<Option<i16>, _>(index) {
                return match v {
                    Some(n) => n.to_string(),
                    None => null_string(),
                };
            }
        }
        "INT4" | "INTEGER" | "SERIAL" => {
            if let Ok(v) = row.try_get::<Option<i32>, _>(index) {
                return match v {
                    Some(n) => n.to_string(),
                    None => null_string(),
                };
            }
        }
        "INT8" | "BIGINT" | "BIGSERIAL" => {
            if let Ok(v) = row.try_get::<Option<i64>, _>(index) {
                return match v {
                    Some(n) => n.to_string(),
                    None => null_string(),
                };
            }
        }
        "FLOAT4" | "REAL" => {
            if let Ok(v) = row.try_get::<Option<f32>, _>(index) {
                return match v {
                    Some(n) => n.to_string(),
                    None => null_string(),
                };
            }
        }
        "FLOAT8" | "DOUBLE PRECISION" => {
            if let Ok(v) = row.try_get::<Option<f64>, _>(index) {
                return match v {
                    Some(n) => n.to_string(),
                    None => null_string(),
                };
            }
        }
        "NUMERIC" | "DECIMAL" => {
            if let Ok(v) = row.try_get::<Option<f64>, _>(index) {
                return match v {
                    Some(n) => n.to_string(),
                    None => null_string(),
                };
            }
        }
        "BOOL" | "BOOLEAN" => {
            if let Ok(v) = row.try_get::<Option<bool>, _>(index) {
                return match v {
                    Some(b) => b.to_string(),
                    None => null_string(),
                };
            }
        }
        "UUID" => {
            if let Ok(v) = row.try_get::<Option<uuid::Uuid>, _>(index) {
                return match v {
                    Some(u) => u.to_string(),
                    None => null_string(),
                };
            }
        }
        "TIMESTAMP" | "TIMESTAMP WITHOUT TIME ZONE" => {
            if let Ok(v) = row.try_get::<Option<chrono::NaiveDateTime>, _>(index) {
                return match v {
                    Some(dt) => dt.format("%Y-%m-%d %H:%M:%S%.f").to_string(),
                    None => null_string(),
                };
            }
        }
        "TIMESTAMPTZ" | "TIMESTAMP WITH TIME ZONE" => {
            if let Ok(v) = row.try_get::<Option<chrono::DateTime<chrono::Utc>>, _>(index) {
                return match v {
                    Some(dt) => dt.to_rfc3339(),
                    None => null_string(),
                };
            }
        }
        "DATE" => {
            if let Ok(v) = row.try_get::<Option<chrono::NaiveDate>, _>(index) {
                return match v {
                    Some(d) => d.to_string(),
                    None => null_string(),
                };
            }
        }
        "JSON" | "JSONB" => {
            if let Ok(v) = row.try_get::<Option<serde_json::Value>, _>(index) {
                return match v {
                    Some(j) => j.to_string(),
                    None => null_string(),
                };
            }
        }
        _ => {}
    }

    // Fallback: try to get as string
    if let Ok(v) = row.try_get::<Option<String>, _>(index) {
        return match v {
            Some(s) => s,
            None => null_string(),
        };
    }

    null_string()
}
