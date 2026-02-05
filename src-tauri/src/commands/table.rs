use serde::{Deserialize, Serialize};
use sqlx::{Column, Row};
use std::fs::File;
use std::io::BufWriter;
use std::path::Path;
use tauri::State;

use crate::db::postgres;
use crate::state::AppState;

/// Validate that a file path is safe (not attempting path traversal)
fn validate_file_path(path: &str) -> Result<(), String> {
    let path = Path::new(path);

    // Must be absolute path
    if !path.is_absolute() {
        return Err("File path must be absolute".to_string());
    }

    // Check for path traversal attempts
    let canonical = path.canonicalize()
        .map_err(|_| "Invalid file path")?;

    // Ensure the canonical path doesn't contain suspicious patterns
    let path_str = canonical.to_string_lossy();
    if path_str.contains("..") {
        return Err("Invalid file path: contains traversal".to_string());
    }

    // On macOS/Linux, allow common user-accessible directories
    #[cfg(target_os = "macos")]
    {
        let home = std::env::var("HOME").unwrap_or_default();
        let allowed_prefixes = [
            format!("{}/", home),
            "/tmp/".to_string(),
            "/var/folders/".to_string(), // macOS temp directories
        ];

        let is_allowed = allowed_prefixes.iter().any(|prefix| path_str.starts_with(prefix));
        if !is_allowed {
            return Err("File path not in allowed directory".to_string());
        }
    }

    Ok(())
}

/// Map a PostgreSQL data type to a type suitable for casting from text.
/// This allows CSV text values to be properly converted to the target column type.
fn map_data_type_for_cast(data_type: &str) -> &str {
    let dt = data_type.to_lowercase();

    // Handle array types - they need special handling
    if dt.starts_with('_') || dt.ends_with("[]") {
        return data_type;
    }

    // Map common types - most can be cast directly from text
    match dt.as_str() {
        // Numeric types
        "smallint" | "int2" => "smallint",
        "integer" | "int" | "int4" => "integer",
        "bigint" | "int8" => "bigint",
        "real" | "float4" => "real",
        "double precision" | "float8" => "double precision",
        "numeric" | "decimal" => "numeric",
        "smallserial" | "serial2" => "smallint",
        "serial" | "serial4" => "integer",
        "bigserial" | "serial8" => "bigint",

        // Monetary
        "money" => "money",

        // Character types
        "character varying" | "varchar" => "text",
        "character" | "char" => "text",
        "text" => "text",
        "citext" => "citext",

        // Binary
        "bytea" => "bytea",

        // Date/time types
        "timestamp" | "timestamp without time zone" => "timestamp",
        "timestamp with time zone" | "timestamptz" => "timestamptz",
        "date" => "date",
        "time" | "time without time zone" => "time",
        "time with time zone" | "timetz" => "timetz",
        "interval" => "interval",

        // Boolean
        "boolean" | "bool" => "boolean",

        // Geometric types
        "point" => "point",
        "line" => "line",
        "lseg" => "lseg",
        "box" => "box",
        "path" => "path",
        "polygon" => "polygon",
        "circle" => "circle",

        // Network types
        "cidr" => "cidr",
        "inet" => "inet",
        "macaddr" => "macaddr",
        "macaddr8" => "macaddr8",

        // Bit string types
        "bit" => "bit",
        "bit varying" | "varbit" => "varbit",

        // UUID
        "uuid" => "uuid",

        // JSON types
        "json" => "json",
        "jsonb" => "jsonb",

        // XML
        "xml" => "xml",

        // Range types
        "int4range" => "int4range",
        "int8range" => "int8range",
        "numrange" => "numrange",
        "tsrange" => "tsrange",
        "tstzrange" => "tstzrange",
        "daterange" => "daterange",

        // For unknown types, use the original type and let PostgreSQL handle it
        _ => data_type,
    }
}

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

    // Validate file path for security
    validate_file_path(&file_path)?;

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

/// Import CSV data into a table using parameterized queries
#[tauri::command]
pub async fn import_csv(
    connection_id: String,
    options: ImportCsvOptions,
    state: State<'_, AppState>,
) -> Result<ImportCsvResult, String> {
    let pool = state
        .get_pool(&connection_id)
        .ok_or_else(|| format!("Not connected to: {}", connection_id))?;

    // Validate file path for security
    validate_file_path(&options.file_path)?;

    // Validate identifiers
    validate_identifier(&options.schema_name)?;
    validate_identifier(&options.table_name)?;

    // Get table columns for ordering
    let columns = postgres::get_columns(&pool, &options.schema_name, &options.table_name)
        .await
        .map_err(|e| format!("Failed to get table columns: {}", e))?;

    let num_columns = columns.len();
    let column_names: Vec<String> = columns.iter().map(|c| format!("\"{}\"", escape_identifier(&c.name))).collect();
    let column_list = column_names.join(", ");

    // Build parameterized placeholders with type casts ($1::type, $2::type, ...)
    // This allows PostgreSQL to convert text values from CSV to the appropriate column types
    let placeholders: Vec<String> = columns.iter().enumerate().map(|(i, col)| {
        let pg_type = map_data_type_for_cast(&col.data_type);
        format!("${}::{}", i + 1, pg_type)
    }).collect();
    let placeholder_list = placeholders.join(", ");

    // Build the INSERT statement with parameters
    let insert_sql = format!(
        "INSERT INTO \"{}\".\"{}\" ({}) VALUES ({})",
        escape_identifier(&options.schema_name),
        escape_identifier(&options.table_name),
        column_list,
        placeholder_list
    );

    // Open and read the CSV file
    let file = File::open(&options.file_path)
        .map_err(|e| format!("Failed to open file: {}", e))?;

    let mut reader = csv::ReaderBuilder::new()
        .has_headers(options.has_headers)
        .from_reader(file);

    // Begin a transaction
    let mut tx = pool.begin().await.map_err(|e| format!("Failed to begin transaction: {}", e))?;

    let mut rows_imported: u64 = 0;

    for result in reader.records() {
        let record = result.map_err(|e| format!("Failed to read CSV row: {}", e))?;

        // Verify column count matches
        if record.len() != num_columns {
            tx.rollback().await.ok();
            return Err(format!(
                "CSV row has {} columns but table has {} columns",
                record.len(),
                num_columns
            ));
        }

        // Build query with bound parameters
        let mut query = sqlx::query(&insert_sql);

        for value in record.iter() {
            if value.is_empty() {
                query = query.bind(None::<String>);
            } else {
                query = query.bind(value);
            }
        }

        query.execute(&mut *tx)
            .await
            .map_err(|e| {
                format!("Failed to insert row {}: {}", rows_imported + 1, e)
            })?;

        rows_imported += 1;
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

    // Validate file path for security
    validate_file_path(&options.file_path)?;

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
            .map(|c| format!("\"{}\"", escape_identifier(c)))
            .collect::<Vec<_>>()
            .join(", ")
    };

    let select_sql = format!(
        "SELECT {} FROM \"{}\".\"{}\"",
        column_list,
        escape_identifier(&options.schema_name),
        escape_identifier(&options.table_name)
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
/// Uses strict whitelist approach: only ASCII alphanumeric, underscores, and hyphens allowed
/// PostgreSQL allows these characters in quoted identifiers
fn validate_identifier(name: &str) -> Result<(), String> {
    if name.is_empty() {
        return Err("Identifier cannot be empty".to_string());
    }

    if name.len() > 63 {
        return Err("Identifier too long (max 63 characters)".to_string());
    }

    // Strict whitelist: ASCII alphanumeric, underscores, and hyphens
    // First character must be a letter, underscore, or hyphen (PostgreSQL allows this in quoted identifiers)
    let first_char = name.chars().next().unwrap();
    if !first_char.is_ascii_alphabetic() && first_char != '_' && first_char != '-' {
        return Err(format!("Invalid identifier '{}': must start with a letter, underscore, or hyphen", name));
    }

    // Remaining characters must be alphanumeric, underscore, or hyphen
    if !name.chars().all(|c| c.is_ascii_alphanumeric() || c == '_' || c == '-') {
        return Err(format!("Invalid identifier '{}': only letters, numbers, underscores, and hyphens allowed", name));
    }

    Ok(())
}

/// Escape a PostgreSQL identifier by doubling any double-quotes
fn escape_identifier(name: &str) -> String {
    name.replace('"', "\"\"")
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
