use serde::{Deserialize, Serialize};
use sqlx::{Column, Row};
use std::fs::File;
use std::io::{BufWriter, Cursor, Read, Write};
use std::path::Path;

use crate::commands::query::set_search_path;
use crate::db::postgres;
use crate::models::{
    decode_csv_bytes, encode_csv_chunk, encoding_bom, CsvDialect, CsvEncoding, CsvQuoteStyle,
    ExportFormat, ImportErrorPolicy,
};
use crate::state::AppState;

/// Validate that a file path is safe (not attempting path traversal).
/// Canonicalizes the parent directory (which must exist) since the file itself
/// may not exist yet (e.g. when saving a new export).
fn validate_file_path(path: &str) -> Result<(), String> {
    let path = Path::new(path);

    if !path.is_absolute() {
        return Err("File path must be absolute".to_string());
    }

    let file_name = path.file_name()
        .ok_or_else(|| "Invalid file path: no file name".to_string())?;
    let parent = path.parent()
        .ok_or_else(|| "Invalid file path: no parent directory".to_string())?;
    let canonical_parent = parent.canonicalize()
        .map_err(|_| "Invalid file path: parent directory does not exist".to_string())?;
    let canonical = canonical_parent.join(file_name);
    let path_str = canonical.to_string_lossy();

    if path_str.contains("..") {
        return Err("Invalid file path: contains traversal".to_string());
    }

    #[cfg(target_os = "macos")]
    {
        let home = std::env::var("HOME").unwrap_or_default();
        let allowed_prefixes = [
            format!("{}/", home),
            "/tmp/".to_string(),
            "/var/folders/".to_string(),
        ];
        if !allowed_prefixes.iter().any(|prefix| path_str.starts_with(prefix)) {
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

/// Which rows a clone takes when the source has descendants.
///
/// The copy is always a standalone table, so on a parent these two are very
/// different amounts of data: `SELECT *` on an inheritance parent reads every
/// descendant, which on a 4,700-table archive is the whole archive. The
/// default is the small, obvious one; the other is offered by name.
#[derive(Debug, Clone, Copy, Default, PartialEq, Eq, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub enum CloneRowScope {
    /// `FROM ONLY` — the rows stored in this table itself.
    #[default]
    OwnRows,
    /// No `ONLY` — this table's rows and every descendant's, flattened into
    /// the copy.
    WholeTree,
}

#[derive(Debug, Clone, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct CloneTableOptions {
    pub source_schema: String,
    pub source_table: String,
    pub target_schema: String,
    pub target_table: String,
    pub include_data: bool,
    /// Ignored unless `include_data`. `#[serde(default)]` so the safe scope is
    /// what an older or partial caller gets.
    #[serde(default)]
    pub row_scope: CloneRowScope,
}

#[derive(Debug, Clone, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct CloneTableResult {
    pub success: bool,
    pub rows_copied: Option<u64>,
}

/// Build the CREATE statement for a clone.
///
/// `LIKE ... INCLUDING ALL` copies columns, constraints, indexes and defaults,
/// but it carries NEITHER `PARTITION BY` nor `INHERITS`, so a clone of a
/// parent came out flat. `partition_by` — `pg_get_partkeydef` text, as
/// `render_create_table` in `ddl.rs` also treats it — puts the partition
/// clause back. Measured on PostgreSQL 16.14: the result is `relkind = 'p'`
/// with the source's primary key and indexes carried across.
///
/// `INHERITS` is deliberately NOT put back. `LIKE` already copies every
/// column a parent contributed, so the copy is complete, and attaching a new
/// child to a live tree would change what every query on the source root
/// returns. A clone must not alter the thing it copies.
///
/// Identifiers are interpolated raw because `validate_identifier` has already
/// held each one to an ASCII whitelist that cannot contain a quote.
pub(crate) fn build_clone_create_sql(
    options: &CloneTableOptions,
    partition_by: Option<&str>,
) -> String {
    let partition = match partition_by {
        Some(key) => format!(" PARTITION BY {}", key),
        None => String::new(),
    };
    format!(
        r#"CREATE TABLE "{}"."{}" (LIKE "{}"."{}" INCLUDING ALL){}"#,
        options.target_schema,
        options.target_table,
        options.source_schema,
        options.source_table,
        partition
    )
}

/// Build the INSERT ... SELECT that fills a clone.
///
/// `ONLY` is the difference between a table's own rows and its whole tree:
/// measured on PostgreSQL 16.14, a three-level inheritance parent answered 1
/// row with it and 4 without. The copy is flat either way, so without `ONLY`
/// an archive's every descendant lands in one table — which is what the
/// caller has to ask for by name.
pub(crate) fn build_clone_insert_sql(options: &CloneTableOptions) -> String {
    let only = match options.row_scope {
        CloneRowScope::OwnRows => "ONLY ",
        CloneRowScope::WholeTree => "",
    };
    format!(
        r#"INSERT INTO "{}"."{}" SELECT * FROM {}"{}"."{}""#,
        options.target_schema,
        options.target_table,
        only,
        options.source_schema,
        options.source_table
    )
}

/// The message for the one clone that cannot be made to work.
///
/// A copy of a partitioned parent is created with no partitions of its own, so
/// PostgreSQL answers any row with `ERROR: no partition of relation ... found
/// for row`. Said here, before anything is created, rather than left as a
/// half-built table and a server error.
pub(crate) fn partitioned_rows_refusal(options: &CloneTableOptions, partition_by: &str) -> String {
    format!(
        "\"{}\".\"{}\" is partitioned by {}: its rows live in its partitions, \
         and the copy is created with no partitions of its own, so no row can go \
         into it. Clone the structure without rows, or clone one partition.",
        options.source_schema, options.source_table, partition_by
    )
}

/// Clone a table structure with optional data
pub async fn clone_table(
    connection_id: String,
    options: CloneTableOptions,
    state: &AppState,
) -> Result<CloneTableResult, String> {
    // A read-only connection cannot be the TARGET of a clone. Refused here,
    // before the DDL is built, rather than by the server after it.
    state.require_writable(&connection_id)?;
    let pool = state.require_pool(&connection_id)?;

    // Validate identifiers to prevent SQL injection
    validate_identifier(&options.source_schema)?;
    validate_identifier(&options.source_table)?;
    validate_identifier(&options.target_schema)?;
    validate_identifier(&options.target_table)?;

    // The source's shape decides what the copy can be. Read BEFORE anything is
    // created, so the one impossible combination is refused with nothing left
    // behind.
    let shape = postgres::get_table_shape_facts(&pool, &options.source_schema, &options.source_table)
        .await
        .map_err(|e| format!("Failed to read the table's shape: {}", e))?;

    if options.include_data {
        if let Some(key) = &shape.partition_by {
            return Err(partitioned_rows_refusal(&options, key));
        }
    }

    let create_sql = build_clone_create_sql(&options, shape.partition_by.as_deref());
    sqlx::query(&create_sql)
        .execute(&pool)
        .await
        .map_err(|e| format!("Failed to create table: {}", e))?;

    let mut rows_copied: Option<u64> = None;

    // Copy data if requested
    if options.include_data {
        let insert_sql = build_clone_insert_sql(&options);
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

/// Generate the reconstructed CREATE TABLE DDL (three detail variants) for a table.
pub async fn generate_table_ddl(
    connection_id: String,
    schema_name: String,
    table_name: String,
    state: &AppState,
) -> Result<crate::commands::ddl::TableDdl, String> {
    let pool = state.require_pool(&connection_id)?;

    // No identifier validation here: this is a read-only path, like the sibling
    // metadata reads (get_columns / get_table_constraints), which also skip it.
    // The catalog queries escape names as SQL string literals and the composer
    // quotes them for output, so any legal quoted identifier — e.g. a UUID- or
    // digit-named table/schema — must be accepted, not rejected.
    let parts = crate::db::postgres::get_table_ddl_parts(&pool, &schema_name, &table_name)
        .await
        .map_err(|e| e.to_string())?;

    Ok(crate::commands::ddl::compose_table_ddl(
        &schema_name,
        &table_name,
        &parts,
    ))
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
pub async fn validate_csv_for_import(
    connection_id: String,
    schema_name: String,
    table_name: String,
    file_path: String,
    has_headers: bool,
    state: &AppState,
) -> Result<CsvValidationResult, String> {
    let pool = state.require_pool(&connection_id)?;

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
    /// The CSV shape to read. Swift fills it from
    /// `AppSettings.dataImport.dialect`.
    #[serde(default)]
    pub csv: CsvDialect,
    /// What a failing row does to the rest of the file.
    #[serde(default)]
    pub on_error: ImportErrorPolicy,
    /// Rows per transaction. 0 is one transaction for the whole file, which
    /// is what the importer did before this existed.
    #[serde(default)]
    pub commit_every: u32,
}

#[derive(Debug, Clone, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct ImportCsvResult {
    pub success: bool,
    pub rows_imported: u64,
    /// Rows rolled back to their savepoint and passed over. Always 0 under
    /// `ImportErrorPolicy::Abort`, which has no way to reach the next row.
    #[serde(default)]
    pub rows_skipped: u64,
    /// The first `MAX_REPORTED_IMPORT_ERRORS` failures, one line each. A file
    /// where everything fails must not return a message per row.
    #[serde(default)]
    pub errors: Vec<String>,
    /// Transactions committed before the end of the file. 0 when
    /// `commit_every` is 0, because then the only commit is the last one.
    #[serde(default)]
    pub committed_batches: u64,
}

/// How many row failures `ImportCsvResult::errors` carries. The count in
/// `rows_skipped` is complete; the messages are a sample.
const MAX_REPORTED_IMPORT_ERRORS: usize = 20;

/// Import CSV data into a table using parameterized queries
pub async fn import_csv(
    connection_id: String,
    options: ImportCsvOptions,
    state: &AppState,
) -> Result<ImportCsvResult, String> {
    // Refused before the file is opened, so a read-only connection cannot
    // spend the user's time parsing a CSV it can never insert.
    state.require_writable(&connection_id)?;
    let pool = state.require_pool(&connection_id)?;

    // Validate file path for security
    validate_file_path(&options.file_path)?;

    // Validate identifiers
    validate_identifier(&options.schema_name)?;
    validate_identifier(&options.table_name)?;

    // Register live progress counter so the UI can poll row count.
    let progress_key = format!("{}|{}|{}", connection_id, options.schema_name, options.table_name);
    let progress = state.register_import_progress(progress_key.clone());
    // RAII guard: ensure counter is removed on every exit path.
    struct ProgressGuard<'a> {
        state: &'a AppState,
        key: String,
    }
    impl<'a> Drop for ProgressGuard<'a> {
        fn drop(&mut self) {
            self.state.unregister_import_progress(&self.key);
        }
    }
    let _guard = ProgressGuard { state, key: progress_key };

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

    // Open the CSV file, past its byte-order mark and in its encoding.
    let source = open_csv_source(&options.file_path, &options.csv)?;

    let mut reader = csv::ReaderBuilder::new()
        .has_headers(options.has_headers)
        .delimiter(options.csv.delimiter_byte())
        .quote(options.csv.quote_byte())
        .from_reader(source);

    let skipping = options.on_error == ImportErrorPolicy::SkipRow;
    let commit_every = options.commit_every;

    // Begin a transaction
    let mut tx = pool.begin().await.map_err(|e| format!("Failed to begin transaction: {}", e))?;

    let mut rows_imported: u64 = 0;
    let mut rows_skipped: u64 = 0;
    let mut committed_batches: u64 = 0;
    let mut rows_since_commit: u32 = 0;
    let mut errors: Vec<String> = Vec::new();
    let mut row_number: u64 = 0;

    /// Keeps `errors` a sample rather than a transcript.
    macro_rules! record_error {
        ($errors:expr, $message:expr) => {
            if $errors.len() < MAX_REPORTED_IMPORT_ERRORS {
                $errors.push($message);
            }
        };
    }

    for result in reader.records() {
        row_number += 1;

        let record = match result {
            Ok(record) => record,
            Err(e) => {
                let message = format!("Row {}: {}", row_number, e);
                if !skipping {
                    tx.rollback().await.ok();
                    return Err(format!("Failed to read CSV row: {}", e));
                }
                rows_skipped += 1;
                record_error!(errors, message);
                continue;
            }
        };

        // Verify column count matches
        if record.len() != num_columns {
            let message = format!(
                "Row {}: CSV row has {} columns but table has {} columns",
                row_number,
                record.len(),
                num_columns
            );
            if !skipping {
                tx.rollback().await.ok();
                return Err(format!(
                    "CSV row has {} columns but table has {} columns",
                    record.len(),
                    num_columns
                ));
            }
            rows_skipped += 1;
            record_error!(errors, message);
            continue;
        }

        // Under skipRow every row runs inside its own savepoint, so a failure
        // rolls back that row alone and leaves the transaction usable. Under
        // abort there is nothing to roll back to, and no savepoint is taken.
        if skipping {
            sqlx::query("SAVEPOINT pharos_import_row")
                .execute(&mut *tx)
                .await
                .map_err(|e| format!("Failed to set savepoint: {}", e))?;
        }

        // Build query with bound parameters
        let mut query = sqlx::query(&insert_sql);

        for value in record.iter() {
            if value == options.csv.null_literal {
                query = query.bind(None::<String>);
            } else {
                query = query.bind(value);
            }
        }

        match query.execute(&mut *tx).await {
            Ok(_) => {
                if skipping {
                    sqlx::query("RELEASE SAVEPOINT pharos_import_row")
                        .execute(&mut *tx)
                        .await
                        .map_err(|e| format!("Failed to release savepoint: {}", e))?;
                }
                rows_imported += 1;
                rows_since_commit += 1;
                progress.store(rows_imported, std::sync::atomic::Ordering::Relaxed);
            }
            Err(e) => {
                if !skipping {
                    return Err(format!("Failed to insert row {}: {}", rows_imported + 1, e));
                }
                sqlx::query("ROLLBACK TO SAVEPOINT pharos_import_row")
                    .execute(&mut *tx)
                    .await
                    .map_err(|e| format!("Failed to roll back to savepoint: {}", e))?;
                rows_skipped += 1;
                record_error!(errors, format!("Row {}: {}", row_number, e));
            }
        }

        // A batch ceiling means the rows before a later failure are already
        // on the server, which is the whole point of asking for one.
        if commit_every > 0 && rows_since_commit >= commit_every {
            tx.commit().await.map_err(|e| format!("Failed to commit transaction: {}", e))?;
            committed_batches += 1;
            rows_since_commit = 0;
            tx = pool.begin().await.map_err(|e| format!("Failed to begin transaction: {}", e))?;
        }
    }

    // Commit transaction
    tx.commit().await.map_err(|e| format!("Failed to commit transaction: {}", e))?;

    Ok(ImportCsvResult {
        success: true,
        rows_imported,
        rows_skipped,
        errors,
        committed_batches,
    })
}

/// The CSV file as a reader of UTF-8 bytes, past any byte-order mark.
///
/// A mark WINS over the setting, so a file exported as UTF-16LE imports back
/// without the user changing the setting a second time. UTF-8 (with or
/// without a mark) streams straight off the file; UTF-16LE and Latin-1 are
/// transcoded whole, because neither can be decoded a buffer at a time
/// without carrying a partial code unit across the boundary.
fn open_csv_source(path: &str, dialect: &CsvDialect) -> Result<Box<dyn Read + Send>, String> {
    let mut file = File::open(path).map_err(|e| format!("Failed to open file: {}", e))?;

    let mut head = [0u8; 3];
    let mut filled = 0;
    while filled < head.len() {
        match file.read(&mut head[filled..]) {
            Ok(0) => break,
            Ok(n) => filled += n,
            Err(e) => return Err(format!("Failed to read file: {}", e)),
        }
    }
    let head = &head[..filled];

    let utf16_mark = head.starts_with(&[0xFF, 0xFE]);
    let needs_transcode = utf16_mark
        || matches!(dialect.encoding, CsvEncoding::Utf16Le | CsvEncoding::Latin1);

    if needs_transcode {
        let mut all = head.to_vec();
        file.read_to_end(&mut all).map_err(|e| format!("Failed to read file: {}", e))?;
        let text = decode_csv_bytes(&all, dialect.encoding)?;
        return Ok(Box::new(Cursor::new(text.into_bytes())));
    }

    if head == [0xEF, 0xBB, 0xBF] {
        // The mark is consumed; the rest of the file is plain UTF-8.
        return Ok(Box::new(file));
    }

    Ok(Box::new(Cursor::new(head.to_vec()).chain(file)))
}

// ============================================================================
// Table Export (multi-format)
// ============================================================================


#[derive(Debug, Clone, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct ExportTableOptions {
    pub schema_name: String,
    pub table_name: String,
    pub columns: Vec<String>,
    pub include_headers: bool,
    pub null_as_empty: bool,
    pub file_path: String,
    pub format: ExportFormat,
    /// The CSV shape this export asks for. Swift fills it from
    /// `AppSettings.dataExport.dialect`; `#[serde(default)]` keeps an older
    /// client's JSON decoding, at today's behaviour.
    #[serde(default)]
    pub csv: CsvDialect,
}

#[derive(Debug, Clone, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct ExportTableResult {
    pub success: bool,
    pub rows_exported: u64,
    /// Characters the chosen encoding could not carry and wrote as `?`.
    /// Always 0 for UTF-8 and UTF-16LE, which can carry anything.
    #[serde(default)]
    pub characters_substituted: u64,
}

/// Export table data in the specified format (streams via pagination)
pub async fn export_table(
    connection_id: String,
    options: ExportTableOptions,
    state: &AppState,
) -> Result<ExportTableResult, String> {
    let pool = state.require_pool(&connection_id)?;

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

    // SQL INSERT target for this table export
    let sql_insert_target = format!(
        "\"{}\".\"{}\"",
        escape_identifier(&options.schema_name),
        escape_identifier(&options.table_name)
    );

    let mut conn = pool.acquire().await.map_err(|e| e.to_string())?;

    stream_export(
        &mut conn,
        &select_sql,
        &options.file_path,
        &options.format,
        &sql_insert_target,
        options.null_as_empty,
        options.include_headers,
        &options.csv,
        state.settings().data_export.batch_size as i64,
        None,
    )
    .await
}

// ============================================================================
// Query Results Export (for XLSX from in-memory data)
// ============================================================================

#[derive(Debug, Clone, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct ExportResultsColumn {
    pub name: String,
    pub data_type: String,
}

#[derive(Debug, Clone, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct ExportResultsOptions {
    pub columns: Vec<ExportResultsColumn>,
    pub rows: Vec<serde_json::Value>,
    pub file_path: String,
}

/// Write text content to a file (for client-side text export formats)
pub async fn write_text_export(
    file_path: String,
    content: String,
) -> Result<(), String> {
    validate_file_path(&file_path)?;

    let file = File::create(&file_path)
        .map_err(|e| format!("Failed to create file: {}", e))?;
    let mut writer = BufWriter::new(file);
    writer.write_all(content.as_bytes())
        .map_err(|e| format!("Failed to write file: {}", e))?;
    writer.flush()
        .map_err(|e| format!("Failed to flush file: {}", e))?;

    Ok(())
}

/// Export in-memory query results to XLSX
pub async fn export_results(
    options: ExportResultsOptions,
) -> Result<ExportTableResult, String> {
    validate_file_path(&options.file_path)?;

    let mut workbook = rust_xlsxwriter::Workbook::new();
    let worksheet = workbook.add_worksheet();

    // Write headers
    for (col_idx, col) in options.columns.iter().enumerate() {
        worksheet.write_string(0, col_idx as u16, &col.name)
            .map_err(|e| format!("Failed to write header: {}", e))?;
    }

    // Write data rows
    for (row_idx, row) in options.rows.iter().enumerate() {
        if let Some(obj) = row.as_object() {
            for (col_idx, col) in options.columns.iter().enumerate() {
                let cell_value = obj.get(&col.name);
                write_xlsx_json_cell(worksheet, (row_idx as u32) + 1, col_idx as u16, cell_value, &col.data_type)
                    .map_err(|e| format!("Failed to write cell: {}", e))?;
            }
        }
    }

    let rows_exported = options.rows.len() as u64;

    workbook.save(&options.file_path)
        .map_err(|e| format!("Failed to save XLSX: {}", e))?;

    Ok(ExportTableResult {
        success: true,
        rows_exported,
        characters_substituted: 0,
    })
}

// ============================================================================
// Full Query Export (all rows, paginated, streamed to file)
// ============================================================================

#[derive(Debug, Clone, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct ExportQueryOptions {
    pub sql: String,
    pub schema: Option<String>,
    pub file_path: String,
    pub format: ExportFormat,
    #[serde(default)]
    pub csv: CsvDialect,
}

#[derive(Debug, Clone, Serialize)]
#[serde(rename_all = "camelCase")]
pub struct ExportProgress {
    pub rows_exported: u64,
    pub is_complete: bool,
}

/// Export all rows from an arbitrary SQL query to a file.
/// Paginates through results with LIMIT/OFFSET and streams to file.
pub async fn export_query(
    connection_id: String,
    options: ExportQueryOptions,
    state: &AppState,
    progress_callback: Option<Box<dyn Fn(u64, bool) + Send>>,
) -> Result<ExportTableResult, String> {
    validate_file_path(&options.file_path)?;

    let pool = state.require_pool(&connection_id)?;

    let mut conn = pool.acquire().await.map_err(|e| e.to_string())?;

    // Set search_path if schema is specified
    if let Some(ref schema_name) = options.schema {
        set_search_path(&mut conn, schema_name, &state.settings().connections.search_path_suffix).await?;
    }

    let trimmed_sql = options.sql.trim().trim_end_matches(';').to_string();

    stream_export(
        &mut conn,
        &trimmed_sql,
        &options.file_path,
        &options.format,
        "\"_query_results\"",
        true,  // null_as_empty
        true,  // include_headers
        &options.csv,
        state.settings().data_export.batch_size as i64,
        progress_callback,
    )
    .await
}

// ============================================================================
// Shared Streaming Export Engine
// ============================================================================

/// Shared streaming export: paginates through a SQL query with LIMIT/OFFSET
/// and writes each batch to the target file in the specified format.
///
/// `base_sql` is the bare SELECT (no trailing semicolon).
/// `sql_insert_target` is the quoted table name used for SQL INSERT format output.
/// `null_as_empty` and `include_headers` control formatting behavior.
/// `dialect` shapes the CSV/TSV branch only; `batch_size` is the caller's, so
/// there is no 5000 hidden in here for a setting to disagree with.
#[allow(clippy::too_many_arguments)]
async fn stream_export(
    conn: &mut sqlx::pool::PoolConnection<sqlx::Postgres>,
    base_sql: &str,
    file_path: &str,
    format: &ExportFormat,
    sql_insert_target: &str,
    null_as_empty: bool,
    include_headers: bool,
    dialect: &CsvDialect,
    batch_size: i64,
    progress_callback: Option<Box<dyn Fn(u64, bool) + Send>>,
) -> Result<ExportTableResult, String> {
    use futures::StreamExt;

    // 0 would wedge the LIMIT/OFFSET loop on an empty batch forever.
    let batch_size: i64 = batch_size.max(1);
    let mut total_exported: u64 = 0;
    let mut offset: i64 = 0;
    let mut headers_written = false;
    let mut bom_written = false;
    let mut characters_substituted: u64 = 0;

    // Column metadata (populated from first batch)
    let mut col_names: Vec<String> = Vec::new();

    let file = File::create(file_path)
        .map_err(|e| format!("Failed to create file: {}", e))?;
    let mut writer = BufWriter::new(file);

    // JSON format: manually write array structure
    let is_json = matches!(format, ExportFormat::Json);
    if is_json {
        writer.write_all(b"[\n").map_err(|e| format!("Failed to write: {}", e))?;
    }

    // XLSX: build workbook in memory
    let is_xlsx = matches!(format, ExportFormat::Xlsx);
    let mut workbook = if is_xlsx { Some(rust_xlsxwriter::Workbook::new()) } else { None };
    let xlsx_header_offset: u32 = if include_headers { 1 } else { 0 };

    loop {
        let wrapped_sql = format!(
            "SELECT * FROM ({}) AS _pharos_export LIMIT {} OFFSET {}",
            base_sql, batch_size, offset
        );

        let mut stream = sqlx::query(&wrapped_sql).fetch(&mut **conn);
        let mut batch: Vec<sqlx::postgres::PgRow> = Vec::with_capacity(batch_size as usize);

        while let Some(row_result) = stream.next().await {
            match row_result {
                Ok(row) => batch.push(row),
                Err(e) => {
                    drop(stream);
                    return Err(format!("Failed to fetch rows: {}", e));
                }
            }
        }
        drop(stream);

        if batch.is_empty() {
            break;
        }

        // Populate column metadata from first batch
        if col_names.is_empty() {
            for col in batch[0].columns() {
                col_names.push(col.name().to_string());
            }
        }

        let batch_len = batch.len() as u64;

        // Write batch based on format
        match format {
            ExportFormat::Csv | ExportFormat::Tsv => {
                // A .tsv file is tab-separated by definition, so the
                // delimiter is not the dialect's to change there. Quoting,
                // the NULL literal and the encoding still are.
                let delimiter = match format {
                    ExportFormat::Tsv => b'\t',
                    _ => dialect.delimiter_byte(),
                };
                if !bom_written {
                    writer.write_all(encoding_bom(dialect.encoding))
                        .map_err(|e| format!("Failed to write: {}", e))?;
                    bom_written = true;
                }
                // Header and rows go through ONE pure function, so the bytes
                // a test asserts on are the bytes the file gets.
                let mut records: Vec<Vec<String>> = Vec::with_capacity(batch.len() + 1);
                if !headers_written && include_headers {
                    records.push(col_names.clone());
                    headers_written = true;
                }
                for row in &batch {
                    records.push(row.columns().iter().enumerate()
                        .map(|(i, col)| {
                            extract_text_value(row, i, &col.type_info().to_string(),
                                               &dialect.null_literal)
                        })
                        .collect());
                }
                let encoded = csv_chunk_bytes(&records, delimiter, dialect,
                                              &mut characters_substituted)?;
                writer.write_all(&encoded)
                    .map_err(|e| format!("Failed to write row: {}", e))?;
            }
            ExportFormat::Json => {
                for (i, row) in batch.iter().enumerate() {
                    if total_exported > 0 || i > 0 {
                        writer.write_all(b",\n").map_err(|e| format!("Failed to write: {}", e))?;
                    }
                    let obj = row_to_json_object(row, true);
                    let json_str = serde_json::to_string_pretty(&serde_json::Value::Object(obj))
                        .map_err(|e| format!("Failed to serialize: {}", e))?;
                    writer.write_all(json_str.as_bytes())
                        .map_err(|e| format!("Failed to write: {}", e))?;
                }
            }
            ExportFormat::JsonLines => {
                for row in &batch {
                    let obj = row_to_json_object(row, true);
                    let line = serde_json::to_string(&serde_json::Value::Object(obj))
                        .map_err(|e| format!("Failed to serialize: {}", e))?;
                    writeln!(writer, "{}", line).map_err(|e| format!("Failed to write: {}", e))?;
                }
            }
            ExportFormat::SqlInsert => {
                if !headers_written {
                    headers_written = true;
                }
                let col_list: String = col_names.iter()
                    .map(|n| format!("\"{}\"", escape_identifier(n)))
                    .collect::<Vec<_>>()
                    .join(", ");
                for row in &batch {
                    let values: Vec<String> = row.columns().iter().enumerate()
                        .map(|(i, col)| {
                            let type_name = col.type_info().to_string();
                            let text = extract_text_value(row, i, &type_name, "NULL");
                            if text == "NULL" {
                                "NULL".to_string()
                            } else {
                                format_sql_value(&text, &type_name)
                            }
                        })
                        .collect();
                    writeln!(writer, "INSERT INTO {} ({}) VALUES ({});",
                        sql_insert_target, col_list, values.join(", "))
                        .map_err(|e| format!("Failed to write: {}", e))?;
                }
            }
            ExportFormat::Markdown => {
                if !headers_written {
                    writeln!(writer, "| {} |", col_names.join(" | "))
                        .map_err(|e| format!("Failed to write: {}", e))?;
                    let sep: Vec<&str> = col_names.iter().map(|_| "---").collect();
                    writeln!(writer, "| {} |", sep.join(" | "))
                        .map_err(|e| format!("Failed to write: {}", e))?;
                    headers_written = true;
                }
                for row in &batch {
                    let values: Vec<String> = row.columns().iter().enumerate()
                        .map(|(i, col)| {
                            let text = extract_text_value(row, i, &col.type_info().to_string(), null_text(null_as_empty));
                            text.replace('|', "\\|")
                        })
                        .collect();
                    writeln!(writer, "| {} |", values.join(" | "))
                        .map_err(|e| format!("Failed to write: {}", e))?;
                }
            }
            ExportFormat::Xlsx => {
                if let Some(ref mut wb) = workbook {
                    let worksheet = wb.worksheet_from_index(0)
                        .map_err(|e| format!("Failed to get worksheet: {}", e))?;
                    if !headers_written && include_headers {
                        for (col_idx, name) in col_names.iter().enumerate() {
                            worksheet.write_string(0, col_idx as u16, name)
                                .map_err(|e| format!("Failed to write header: {}", e))?;
                        }
                        headers_written = true;
                    }
                    let row_start = (total_exported as u32) + xlsx_header_offset;
                    for (row_idx, row) in batch.iter().enumerate() {
                        for (col_idx, col) in row.columns().iter().enumerate() {
                            let type_name = col.type_info().to_string();
                            write_xlsx_cell(
                                worksheet,
                                row_start + (row_idx as u32),
                                col_idx as u16,
                                row,
                                col_idx,
                                &type_name,
                                null_as_empty,
                            ).map_err(|e| format!("Failed to write cell: {}", e))?;
                        }
                    }
                }
            }
        }

        total_exported += batch_len;
        offset += batch_len as i64;

        // Report progress
        if let Some(ref cb) = progress_callback {
            cb(total_exported, false);
        }

        // If batch was smaller than limit, we've reached the end
        if batch_len < batch_size as u64 {
            break;
        }
    }

    // Finalize format-specific writes
    if is_json {
        writer.write_all(b"\n]\n").map_err(|e| format!("Failed to write: {}", e))?;
    }
    writer.flush().map_err(|e| format!("Failed to flush: {}", e))?;

    // Save XLSX workbook
    if let Some(mut wb) = workbook {
        drop(writer); // Release the file handle first
        wb.save(file_path)
            .map_err(|e| format!("Failed to save XLSX: {}", e))?;
    }

    // Report completion
    if let Some(ref cb) = progress_callback {
        cb(total_exported, true);
    }

    Ok(ExportTableResult {
        success: true,
        rows_exported: total_exported,
        characters_substituted,
    })
}

/// The bytes one batch of CSV records becomes: written by `csv::Writer` in
/// the dialect's shape, then re-encoded for the dialect's encoding.
///
/// Pure, and per batch rather than per file, because a batch always ends on a
/// record boundary — so a document may be split here for any encoding. The
/// byte-order mark is the caller's, written once.
fn csv_chunk_bytes(
    records: &[Vec<String>],
    delimiter: u8,
    dialect: &CsvDialect,
    substitutions: &mut u64,
) -> Result<Vec<u8>, String> {
    let mut csv_writer = csv::WriterBuilder::new()
        .delimiter(delimiter)
        .quote(dialect.quote_byte())
        .quote_style(match dialect.quote_style {
            CsvQuoteStyle::Minimal => csv::QuoteStyle::Necessary,
            CsvQuoteStyle::Always => csv::QuoteStyle::Always,
            CsvQuoteStyle::Never => csv::QuoteStyle::Never,
        })
        .terminator(csv::Terminator::Any(b'\n'))
        .from_writer(Vec::new());
    for record in records {
        csv_writer.write_record(record)
            .map_err(|e| format!("Failed to write row: {}", e))?;
    }
    let bytes = csv_writer.into_inner()
        .map_err(|e| format!("Failed to write row: {}", e))?;
    let text = String::from_utf8(bytes)
        .map_err(|e| format!("Failed to write row: {}", e))?;
    Ok(encode_csv_chunk(&text, dialect.encoding, substitutions))
}

/// What a NULL is written as outside the CSV branch, where the dialect's own
/// `null_literal` decides instead. Keeps the old two-way flag honest now that
/// `extract_text_value` takes the text itself.
fn null_text(null_as_empty: bool) -> &'static str {
    if null_as_empty { "" } else { "NULL" }
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
    let first_char = name.chars().next()
        .ok_or_else(|| "Identifier cannot be empty".to_string())?;
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
pub(crate) fn escape_identifier(name: &str) -> String {
    name.replace('"', "\"\"")
}

/// Extract a value from a row as a text string (used by all text-based export formats)
fn extract_text_value(row: &sqlx::postgres::PgRow, index: usize, type_name: &str, null_text: &str) -> String {
    let upper_type = type_name.to_uppercase();

    // Helper for NULL handling
    let null_string = || null_text.to_string();

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
            if let Ok(v) = row.try_get::<Option<rust_decimal::Decimal>, _>(index) {
                return match v {
                    Some(d) => d.to_string(),
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

/// Convert a PgRow into a JSON object (used by JSON and JSONL export formats)
fn row_to_json_object(
    row: &sqlx::postgres::PgRow,
    null_as_empty: bool,
) -> serde_json::Map<String, serde_json::Value> {
    let mut obj = serde_json::Map::new();
    for (i, col) in row.columns().iter().enumerate() {
        let type_name = col.type_info().to_string();
        let text = extract_text_value(row, i, &type_name, null_text(null_as_empty));
        let val = text_to_json_value(&text, &type_name);
        obj.insert(col.name().to_string(), val);
    }
    obj
}

/// Convert a text value to a typed JSON value based on the PostgreSQL type
fn text_to_json_value(text: &str, type_name: &str) -> serde_json::Value {
    let upper = type_name.to_uppercase();
    match upper.as_str() {
        "INT2" | "SMALLINT" | "INT4" | "INTEGER" | "SERIAL" | "INT8" | "BIGINT" | "BIGSERIAL" => {
            if let Ok(n) = text.parse::<i64>() {
                return serde_json::Value::Number(serde_json::Number::from(n));
            }
        }
        "FLOAT4" | "REAL" | "FLOAT8" | "DOUBLE PRECISION" | "NUMERIC" | "DECIMAL" => {
            if let Ok(n) = text.parse::<f64>() {
                if let Some(num) = serde_json::Number::from_f64(n) {
                    return serde_json::Value::Number(num);
                }
            }
        }
        "BOOL" | "BOOLEAN" => {
            return serde_json::Value::Bool(text == "true");
        }
        "JSON" | "JSONB" => {
            if let Ok(v) = serde_json::from_str::<serde_json::Value>(text) {
                return v;
            }
        }
        _ => {}
    }
    serde_json::Value::String(text.to_string())
}

/// Format a text value as a SQL literal
fn format_sql_value(text: &str, type_name: &str) -> String {
    let upper = type_name.to_uppercase();
    match upper.as_str() {
        "INT2" | "SMALLINT" | "INT4" | "INTEGER" | "SERIAL" | "INT8" | "BIGINT" | "BIGSERIAL"
        | "FLOAT4" | "REAL" | "FLOAT8" | "DOUBLE PRECISION" | "NUMERIC" | "DECIMAL" => {
            text.to_string()
        }
        "BOOL" | "BOOLEAN" => {
            text.to_string()
        }
        _ => {
            // Escape single quotes for SQL string literals
            format!("'{}'", text.replace('\'', "''"))
        }
    }
}

/// Write a typed cell value from a PgRow to an XLSX worksheet
fn write_xlsx_cell(
    worksheet: &mut rust_xlsxwriter::Worksheet,
    row: u32,
    col: u16,
    pg_row: &sqlx::postgres::PgRow,
    index: usize,
    type_name: &str,
    null_as_empty: bool,
) -> Result<(), String> {
    let upper = type_name.to_uppercase();

    match upper.as_str() {
        "INT2" | "SMALLINT" => {
            if let Ok(Some(v)) = pg_row.try_get::<Option<i16>, _>(index) {
                worksheet.write_number(row, col, v as f64).map_err(|e| e.to_string())?;
                return Ok(());
            }
        }
        "INT4" | "INTEGER" | "SERIAL" => {
            if let Ok(Some(v)) = pg_row.try_get::<Option<i32>, _>(index) {
                worksheet.write_number(row, col, v as f64).map_err(|e| e.to_string())?;
                return Ok(());
            }
        }
        "INT8" | "BIGINT" | "BIGSERIAL" => {
            if let Ok(Some(v)) = pg_row.try_get::<Option<i64>, _>(index) {
                worksheet.write_number(row, col, v as f64).map_err(|e| e.to_string())?;
                return Ok(());
            }
        }
        "FLOAT4" | "REAL" => {
            if let Ok(Some(v)) = pg_row.try_get::<Option<f32>, _>(index) {
                worksheet.write_number(row, col, v as f64).map_err(|e| e.to_string())?;
                return Ok(());
            }
        }
        "FLOAT8" | "DOUBLE PRECISION" => {
            if let Ok(Some(v)) = pg_row.try_get::<Option<f64>, _>(index) {
                worksheet.write_number(row, col, v).map_err(|e| e.to_string())?;
                return Ok(());
            }
        }
        "NUMERIC" | "DECIMAL" => {
            if let Ok(Some(d)) = pg_row.try_get::<Option<rust_decimal::Decimal>, _>(index) {
                use rust_decimal::prelude::ToPrimitive;
                if let Some(n) = d.to_f64() {
                    worksheet.write_number(row, col, n).map_err(|e| e.to_string())?;
                } else {
                    worksheet.write_string(row, col, &d.to_string()).map_err(|e| e.to_string())?;
                }
                return Ok(());
            }
        }
        "BOOL" | "BOOLEAN" => {
            if let Ok(Some(v)) = pg_row.try_get::<Option<bool>, _>(index) {
                worksheet.write_boolean(row, col, v).map_err(|e| e.to_string())?;
                return Ok(());
            }
        }
        _ => {}
    }

    // Fallback: write as text
    let text = extract_text_value(pg_row, index, type_name, null_text(null_as_empty));
    if text == "NULL" && !null_as_empty {
        // Leave cell empty for NULL values in XLSX
        return Ok(());
    }
    worksheet.write_string(row, col, &text).map_err(|e| e.to_string())?;
    Ok(())
}

/// Write a JSON value to an XLSX cell (for export_results command)
fn write_xlsx_json_cell(
    worksheet: &mut rust_xlsxwriter::Worksheet,
    row: u32,
    col: u16,
    value: Option<&serde_json::Value>,
    _data_type: &str,
) -> Result<(), String> {
    match value {
        None | Some(serde_json::Value::Null) => {
            // Leave cell empty
            Ok(())
        }
        Some(serde_json::Value::Bool(b)) => {
            worksheet.write_boolean(row, col, *b).map(|_| ()).map_err(|e| e.to_string())
        }
        Some(serde_json::Value::Number(n)) => {
            if let Some(f) = n.as_f64() {
                worksheet.write_number(row, col, f).map(|_| ()).map_err(|e| e.to_string())
            } else {
                worksheet.write_string(row, col, &n.to_string()).map(|_| ()).map_err(|e| e.to_string())
            }
        }
        Some(serde_json::Value::String(s)) => {
            worksheet.write_string(row, col, s).map(|_| ()).map_err(|e| e.to_string())
        }
        Some(v) => {
            worksheet.write_string(row, col, &v.to_string()).map(|_| ()).map_err(|e| e.to_string())
        }
    }
}

#[cfg(test)]
mod csv_bytes_tests {
    use super::*;
    use crate::models::{CsvDelimiter, CsvEncoding};

    /// A representative table, already extracted to text: an ordinary row, a
    /// quote, an embedded delimiter, an embedded newline, a carriage return,
    /// a padded field, an empty field and non-ASCII text.
    fn representative() -> Vec<Vec<String>> {
        vec![
            vec!["id".into(), "name, full".into(), "note".into(), "amount".into(), "flag".into()],
            vec!["1".into(), "Ada".into(), "plain".into(), "3.50".into(), "t".into()],
            vec!["2".into(), "O\"Hara".into(), "has, comma".into(), "".into(), "f".into()],
            vec!["3".into(), "Bob".into(), "line1\nline2".into(), "NULL".into(), "t".into()],
            vec!["4".into(), " padded ".into(), "tab\there".into(), "-1".into(), "".into()],
            vec!["5".into(), "Ünïcodé".into(), "cr\rhere".into(), "0".into(), "t".into()],
        ]
    }

    fn bytes(records: &[Vec<String>], dialect: &CsvDialect) -> Vec<u8> {
        let mut subs = 0;
        let mut out = encoding_bom(dialect.encoding).to_vec();
        out.extend(csv_chunk_bytes(records, dialect.delimiter_byte(), dialect, &mut subs).unwrap());
        out
    }

    /// THE test that protects every existing user.
    ///
    /// The expected value was captured from the hand-rolled writer this
    /// branch replaced — `escape_csv_field` plus `writeln!`, run over
    /// `representative()` — BEFORE a line of it was changed. 158 bytes. If
    /// `csv::Writer` ever disagrees with what Pharos shipped, this fails.
    #[test]
    fn default_dialect_is_byte_identical_to_the_old_writer() {
        const CAPTURED: &[u8] = b"id,\"name, full\",note,amount,flag\n\
                                  1,Ada,plain,3.50,t\n\
                                  2,\"O\"\"Hara\",\"has, comma\",,f\n\
                                  3,Bob,\"line1\nline2\",NULL,t\n\
                                  4, padded ,tab\there,-1,\n\
                                  5,\xc3\x9cn\xc3\xafcod\xc3\xa9,\"cr\rhere\",0,t\n";
        assert_eq!(CAPTURED.len(), 158, "the captured reference is 158 bytes");
        assert_eq!(bytes(&representative(), &CsvDialect::default()), CAPTURED);
    }

    #[test]
    fn utf8_bom_prefixes_the_file() {
        let dialect = CsvDialect { encoding: CsvEncoding::Utf8Bom, ..CsvDialect::default() };
        let out = bytes(&[vec!["a".into(), "b".into()]], &dialect);
        assert_eq!(out, b"\xEF\xBB\xBFa,b\n");
    }

    #[test]
    fn semicolon_delimiter_separates_and_quotes_on_itself() {
        let dialect = CsvDialect { delimiter: CsvDelimiter::Semicolon, ..CsvDialect::default() };
        let out = bytes(&[vec!["a;b".into(), "c,d".into()]], &dialect);
        // The comma is now ordinary; the semicolon is what forces a quote.
        assert_eq!(out, b"\"a;b\";c,d\n");
    }

    #[test]
    fn always_quotes_every_field_including_the_header() {
        let dialect = CsvDialect { quote_style: CsvQuoteStyle::Always, ..CsvDialect::default() };
        let out = bytes(&[vec!["id".into(), "name".into()], vec!["1".into(), "".into()]], &dialect);
        assert_eq!(out, b"\"id\",\"name\"\n\"1\",\"\"\n");
    }

    #[test]
    fn custom_null_literal_is_written_for_a_null() {
        let dialect = CsvDialect { null_literal: "\\N".to_string(), ..CsvDialect::default() };
        // `extract_text_value` hands the literal straight through, so the
        // record here is what a NULL column produces.
        let out = bytes(&[vec!["1".into(), dialect.null_literal.clone()]], &dialect);
        assert_eq!(out, b"1,\\N\n");
    }

    #[test]
    fn a_value_holding_the_delimiter_a_quote_and_a_newline_survives() {
        let out = bytes(&[vec!["a,b\"c\nd".into(), "plain".into()]], &CsvDialect::default());
        assert_eq!(out, b"\"a,b\"\"c\nd\",plain\n");
        // And reading it back gives the value that went in.
        let mut reader = csv::ReaderBuilder::new().has_headers(false).from_reader(&out[..]);
        let record = reader.records().next().unwrap().unwrap();
        assert_eq!(&record[0], "a,b\"c\nd");
        assert_eq!(&record[1], "plain");
    }

    #[test]
    fn custom_quote_character_is_used_and_doubled() {
        let dialect = CsvDialect { quote_char: "'".to_string(), ..CsvDialect::default() };
        let out = bytes(&[vec!["it's, here".into()]], &dialect);
        assert_eq!(out, b"'it''s, here'\n");
    }

    #[test]
    fn utf16le_writes_a_mark_and_two_bytes_per_unit() {
        let dialect = CsvDialect { encoding: CsvEncoding::Utf16Le, ..CsvDialect::default() };
        let out = bytes(&[vec!["a".into(), "b".into()]], &dialect);
        assert_eq!(out, vec![0xFF, 0xFE, 0x61, 0x00, 0x2C, 0x00, 0x62, 0x00, 0x0A, 0x00]);
    }

    #[test]
    fn latin1_maps_bytes_and_counts_what_it_cannot_carry() {
        let dialect = CsvDialect { encoding: CsvEncoding::Latin1, ..CsvDialect::default() };
        let mut subs = 0;
        let out = csv_chunk_bytes(&[vec!["café".into(), "€".into()]],
                                  dialect.delimiter_byte(), &dialect, &mut subs).unwrap();
        assert_eq!(out, vec![b'c', b'a', b'f', 0xE9, b',', b'?', b'\n']);
        assert_eq!(subs, 1);
    }

    /// Export, then import: the rows that come back are the rows that went
    /// in, for the default dialect and for an awkward one.
    #[test]
    fn export_import_round_trip_returns_the_same_rows() {
        let rows = vec![
            vec!["a,b".to_string(), "c\"d".to_string(), "e\nf".to_string()],
            vec![" g ".to_string(), "".to_string(), "Ünïcodé".to_string()],
        ];
        for dialect in [
            CsvDialect::default(),
            CsvDialect { delimiter: CsvDelimiter::Semicolon, encoding: CsvEncoding::Utf8Bom,
                         ..CsvDialect::default() },
            CsvDialect { delimiter: CsvDelimiter::Pipe, quote_char: "'".to_string(),
                         quote_style: CsvQuoteStyle::Always, encoding: CsvEncoding::Utf16Le,
                         ..CsvDialect::default() },
        ] {
            let mut written = encoding_bom(dialect.encoding).to_vec();
            let mut subs = 0;
            written.extend(csv_chunk_bytes(&rows, dialect.delimiter_byte(), &dialect, &mut subs).unwrap());

            let text = decode_csv_bytes(&written, dialect.encoding).unwrap();
            let mut reader = csv::ReaderBuilder::new()
                .has_headers(false)
                .delimiter(dialect.delimiter_byte())
                .quote(dialect.quote_byte())
                .from_reader(text.as_bytes());
            let back: Vec<Vec<String>> = reader.records()
                .map(|r| r.unwrap().iter().map(|f| f.to_string()).collect())
                .collect();
            assert_eq!(back, rows, "round trip failed for {:?}", dialect);
        }
    }
}

/// Live CSV-import tests. They need a real PostgreSQL, so they are
/// `#[ignore]`d: `cargo test --lib live_import_tests -- --ignored --nocapture`.
///
/// The default URL is a local Postgres.app; `PHAROS_TEST_DATABASE_URL`
/// overrides it. Each test makes and drops its OWN table, so nothing has to
/// be loaded first.
#[cfg(test)]
mod live_import_tests {
    use super::*;
    use crate::models::ImportErrorPolicy;
    use crate::state::AppState;
    use rusqlite::Connection as SqliteConnection;
    use sqlx::postgres::PgPoolOptions;
    use sqlx::Row;
    use std::time::Duration;

    const DEFAULT_URL: &str = "postgres://nfinn@localhost:5432/nfinn";

    /// A file under $HOME, which is one of the three prefixes
    /// `validate_file_path` allows. `std::env::temp_dir()` is NOT: it
    /// canonicalizes to `/private/var/folders/…`, and the allowed prefix is
    /// `/var/folders/`.
    fn write_csv(name: &str, body: &str) -> String {
        let home = std::env::var("HOME").expect("HOME");
        let path = std::path::Path::new(&home).join(name);
        std::fs::write(&path, body).expect("write csv");
        path.to_string_lossy().to_string()
    }

    fn remove_csv(name: &str) {
        if let Ok(home) = std::env::var("HOME") {
            std::fs::remove_file(std::path::Path::new(&home).join(name)).ok();
        }
    }

    async fn live_pool(url: &str) -> sqlx::PgPool {
        PgPoolOptions::new()
            .max_connections(4)
            .acquire_timeout(Duration::from_secs(5))
            .connect(url)
            .await
            .unwrap_or_else(|e| panic!("cannot connect to {}: {}. Set PHAROS_TEST_DATABASE_URL.", url, e))
    }

    async fn reset_table(pool: &sqlx::PgPool, table: &str) {
        let drop_sql = format!("DROP TABLE IF EXISTS public.{}", table);
        sqlx::raw_sql(&drop_sql).execute(pool).await.expect("drop");
        let create_sql = format!(
            "CREATE TABLE public.{} (id integer PRIMARY KEY, label text NOT NULL)",
            table
        );
        sqlx::raw_sql(&create_sql).execute(pool).await.expect("create");
    }

    async fn count(pool: &sqlx::PgPool, table: &str) -> i64 {
        let sql = format!("SELECT count(*) AS n FROM public.{}", table);
        sqlx::raw_sql(&sql).fetch_one(pool).await.expect("count").try_get("n").expect("n")
    }

    fn url() -> String {
        std::env::var("PHAROS_TEST_DATABASE_URL").unwrap_or_else(|_| DEFAULT_URL.to_string())
    }

    /// skipRow leaves n−1 rows: one duplicate key is rolled back to its
    /// savepoint and the rows after it still land.
    #[test]
    #[ignore = "needs a live PostgreSQL"]
    fn skip_row_leaves_every_row_but_the_bad_one() {
        let rt = tokio::runtime::Runtime::new().expect("tokio runtime");
        rt.block_on(async {
            let pool = live_pool(&url()).await;
            reset_table(&pool, "pharos_import_skip").await;

            // Row 3 repeats id 1, so the primary key refuses it.
            let path = write_csv(
                "pharos_import_skip.csv",
                "id,label\n1,one\n2,two\n1,duplicate\n4,four\n5,five\n",
            );

            let state = AppState::new(SqliteConnection::open_in_memory().expect("sqlite"));
            state.add_pool("live-import".to_string(), pool.clone());

            let result = import_csv(
                "live-import".to_string(),
                ImportCsvOptions {
                    schema_name: "public".to_string(),
                    table_name: "pharos_import_skip".to_string(),
                    file_path: path,
                    has_headers: true,
                    csv: CsvDialect::default(),
                    on_error: ImportErrorPolicy::SkipRow,
                    commit_every: 0,
                },
                &state,
            )
            .await
            .expect("import should succeed under skipRow");

            println!("skipRow result: {:?}", result);
            assert_eq!(result.rows_imported, 4, "four good rows");
            assert_eq!(result.rows_skipped, 1, "one duplicate skipped");
            assert_eq!(result.errors.len(), 1, "one reported error");
            assert_eq!(count(&pool, "pharos_import_skip").await, 4, "four rows on the server");

            sqlx::raw_sql("DROP TABLE public.pharos_import_skip").execute(&pool).await.ok();
            remove_csv("pharos_import_skip.csv");
        });
    }

    /// `commit_every` persists the batches that finished, even though the
    /// import as a whole fails part way down the file.
    #[test]
    #[ignore = "needs a live PostgreSQL"]
    fn commit_every_keeps_completed_batches_after_a_mid_file_failure() {
        let rt = tokio::runtime::Runtime::new().expect("tokio runtime");
        rt.block_on(async {
            let pool = live_pool(&url()).await;
            reset_table(&pool, "pharos_import_batch").await;

            // Two clean batches of two, then a NULL into a NOT NULL column.
            let path = write_csv(
                "pharos_import_batch.csv",
                "id,label\n1,one\n2,two\n3,three\n4,four\n5,\n6,six\n",
            );

            let state = AppState::new(SqliteConnection::open_in_memory().expect("sqlite"));
            state.add_pool("live-import".to_string(), pool.clone());

            let error = import_csv(
                "live-import".to_string(),
                ImportCsvOptions {
                    schema_name: "public".to_string(),
                    table_name: "pharos_import_batch".to_string(),
                    file_path: path,
                    has_headers: true,
                    csv: CsvDialect::default(),
                    on_error: ImportErrorPolicy::Abort,
                    commit_every: 2,
                },
                &state,
            )
            .await
            .expect_err("row 5 violates NOT NULL, so the import aborts");

            println!("commit_every abort message: {}", error);
            let landed = count(&pool, "pharos_import_batch").await;
            println!("rows still on the server: {}", landed);
            assert_eq!(landed, 4, "the two committed batches survive the abort");

            sqlx::raw_sql("DROP TABLE public.pharos_import_batch").execute(&pool).await.ok();
            remove_csv("pharos_import_batch.csv");
        });
    }
}

/// The clone SQL, built without a server so the two statements that decide
/// what a copy IS can be read in one place.
#[cfg(test)]
mod clone_sql_tests {
    use super::*;

    fn options() -> CloneTableOptions {
        CloneTableOptions {
            source_schema: "archive".into(),
            source_table: "dns_log".into(),
            target_schema: "archive".into(),
            target_table: "dns_log_copy".into(),
            include_data: false,
            row_scope: CloneRowScope::OwnRows,
        }
    }

    #[test]
    fn a_plain_table_clones_exactly_as_it_always_did() {
        assert_eq!(
            build_clone_create_sql(&options(), None),
            r#"CREATE TABLE "archive"."dns_log_copy" (LIKE "archive"."dns_log" INCLUDING ALL)"#
        );
    }

    #[test]
    fn a_partitioned_source_carries_its_partition_clause() {
        // Without this the copy is relkind 'r' — a flat table wearing the
        // name of an archive's root.
        assert_eq!(
            build_clone_create_sql(&options(), Some("RANGE (seen)")),
            r#"CREATE TABLE "archive"."dns_log_copy" (LIKE "archive"."dns_log" INCLUDING ALL) PARTITION BY RANGE (seen)"#
        );
    }

    #[test]
    fn the_create_never_carries_inherits() {
        // There is no argument for it on purpose: a copy that joined the
        // source's tree would change what the source root returns.
        let sql = build_clone_create_sql(&options(), Some("LIST (region)"));
        assert!(!sql.contains("INHERITS"), "{}", sql);
    }

    #[test]
    fn the_default_row_scope_reads_only_the_table_itself() {
        assert_eq!(
            build_clone_insert_sql(&options()),
            r#"INSERT INTO "archive"."dns_log_copy" SELECT * FROM ONLY "archive"."dns_log""#
        );
    }

    #[test]
    fn the_whole_tree_scope_drops_only_and_nothing_else() {
        let mut opts = options();
        opts.row_scope = CloneRowScope::WholeTree;
        assert_eq!(
            build_clone_insert_sql(&opts),
            r#"INSERT INTO "archive"."dns_log_copy" SELECT * FROM "archive"."dns_log""#
        );
    }

    #[test]
    fn own_rows_is_what_a_caller_that_says_nothing_gets() {
        // The Swift side sends `rowScope`, but a partial or older caller must
        // not fall into the copy-the-whole-archive branch by omission.
        let json = r#"{"sourceSchema":"a","sourceTable":"b","targetSchema":"a","targetTable":"c","includeData":true}"#;
        let opts: CloneTableOptions = serde_json::from_str(json).expect("decode without rowScope");
        assert_eq!(opts.row_scope, CloneRowScope::OwnRows);
        assert!(build_clone_insert_sql(&opts).contains("FROM ONLY "));
    }

    #[test]
    fn the_scope_crosses_the_ffi_as_the_camel_case_name_swift_spells() {
        // JSONEncoder.pharos sets no key strategy, so these two strings are
        // the contract with Swift's `CloneRowScope`.
        assert_eq!(serde_json::to_string(&CloneRowScope::OwnRows).unwrap(), "\"ownRows\"");
        assert_eq!(serde_json::to_string(&CloneRowScope::WholeTree).unwrap(), "\"wholeTree\"");
        let round: CloneRowScope = serde_json::from_str("\"wholeTree\"").expect("decode");
        assert_eq!(round, CloneRowScope::WholeTree);
    }

    #[test]
    fn the_refusal_names_the_table_the_key_and_the_way_out() {
        let text = partitioned_rows_refusal(&options(), "RANGE (seen)");
        assert!(text.contains("\"archive\".\"dns_log\""), "{}", text);
        assert!(text.contains("RANGE (seen)"), "{}", text);
        assert!(text.contains("without rows"), "{}", text);
        assert!(text.contains("clone one partition"), "{}", text);
    }
}

/// Live clone tests against a real PostgreSQL. Ignored by default:
/// `cargo test --lib live_clone_tests -- --ignored --nocapture`.
///
/// These drive the REAL `clone_table`, not a copy of its SQL, so the shape
/// read, the refusal and the two statements are all under test together.
/// The default URL is a local Postgres.app; `PHAROS_TEST_DATABASE_URL`
/// overrides it. ONE SCHEMA PER TEST: `cargo test` runs them on separate
/// threads, and a shared name means one test drops what another is reading.
#[cfg(test)]
mod live_clone_tests {
    use super::*;
    use crate::state::AppState;
    use rusqlite::Connection as SqliteConnection;
    use sqlx::postgres::PgPoolOptions;
    use sqlx::Row;
    use std::time::Duration;

    const DEFAULT_URL: &str = "postgres://nfinn@localhost:5432/nfinn";
    const DECLARATIVE: &str = "pharos_clone_declarative";
    const REFUSAL: &str = "pharos_clone_refusal";
    const OWN_ROWS: &str = "pharos_clone_own_rows";
    const WHOLE_TREE: &str = "pharos_clone_whole_tree";
    const STANDALONE: &str = "pharos_clone_standalone";
    const SHAPE: &str = "pharos_clone_shape";

    fn url() -> String {
        std::env::var("PHAROS_TEST_DATABASE_URL").unwrap_or_else(|_| DEFAULT_URL.to_string())
    }

    async fn live_pool() -> sqlx::PgPool {
        let u = url();
        PgPoolOptions::new()
            // Each test acquires strictly one at a time, and six of them run
            // in parallel. A small pool and a patient timeout: one run
            // straight after a release build hit the 5s acquire timeout.
            .max_connections(2)
            .acquire_timeout(Duration::from_secs(15))
            .connect(&u)
            .await
            .unwrap_or_else(|e| panic!("cannot connect to {u}: {e}. Set PHAROS_TEST_DATABASE_URL."))
    }

    /// A declarative parent with a partition holding rows, and beside it a
    /// three-level inheritance tree whose root holds one row of its own and
    /// whose leaves hold three more.
    async fn build_fixture(pool: &sqlx::PgPool, schema: &str) {
        let sql = format!(
            "DROP SCHEMA IF EXISTS {s} CASCADE; \
             CREATE SCHEMA {s}; \
             CREATE TABLE {s}.ev (id bigint, seen timestamptz NOT NULL, note text DEFAULT 'x', \
                 PRIMARY KEY (id, seen)) PARTITION BY RANGE (seen); \
             CREATE INDEX ev_note_idx ON {s}.ev (note); \
             CREATE TABLE {s}.ev_2013 PARTITION OF {s}.ev \
                 FOR VALUES FROM ('2013-01-01') TO ('2014-01-01'); \
             INSERT INTO {s}.ev (id, seen) VALUES (1, '2013-06-01'), (2, '2013-07-01'); \
             CREATE TABLE {s}.lg (id integer, seen timestamptz); \
             CREATE TABLE {s}.lg_2013 () INHERITS ({s}.lg); \
             CREATE TABLE {s}.lg_201301 () INHERITS ({s}.lg_2013); \
             INSERT INTO {s}.lg (id) VALUES (100); \
             INSERT INTO {s}.lg_201301 (id) SELECT generate_series(1, 3);",
            s = schema
        );
        sqlx::raw_sql(&sql).execute(pool).await.expect("build the fixture");
    }

    async fn drop_fixture(pool: &sqlx::PgPool, schema: &str) {
        let sql = format!("DROP SCHEMA IF EXISTS {} CASCADE", schema);
        sqlx::raw_sql(&sql).execute(pool).await.expect("drop the schema");
    }

    fn state_with(pool: &sqlx::PgPool, id: &str) -> AppState {
        let state = AppState::new(SqliteConnection::open_in_memory().expect("sqlite"));
        state.add_pool(id.to_string(), pool.clone());
        state
    }

    fn clone_options(schema: &str, source: &str, target: &str) -> CloneTableOptions {
        CloneTableOptions {
            source_schema: schema.to_string(),
            source_table: source.to_string(),
            target_schema: schema.to_string(),
            target_table: target.to_string(),
            include_data: false,
            row_scope: CloneRowScope::OwnRows,
        }
    }

    /// Every query below casts its one column to text and names it `v`, so
    /// the read is the same for all of them. (`raw_sql` hands values back in
    /// the text format; an uncast internal type such as `relkind` would not
    /// decode — hence the `||` and `::text` in the queries.)
    async fn scalar(pool: &sqlx::PgPool, sql: &str) -> String {
        sqlx::raw_sql(sql)
            .fetch_one(pool)
            .await
            .expect("scalar query")
            .try_get::<String, _>("v")
            .expect("one text column named v")
    }

    /// The bug itself: before this change the copy came out `relkind = 'r'`.
    #[test]
    #[ignore = "needs a live PostgreSQL"]
    fn a_declarative_parents_copy_is_partitioned_the_same_way() {
        let rt = tokio::runtime::Runtime::new().expect("tokio runtime");
        rt.block_on(async {
            let pool = live_pool().await;
            build_fixture(&pool, DECLARATIVE).await;
            let state = state_with(&pool, "live-clone");

            clone_table("live-clone".into(), clone_options(DECLARATIVE, "ev", "ev_copy"), &state)
                .await
                .expect("the clone should succeed");

            let shape = format!(
                // relkind is pg's internal "char": without ::text the || is
                // ambiguous ("operator is not unique").
                "SELECT relkind::text || ' ' || coalesce(pg_get_partkeydef(oid), '-') AS v \
                 FROM pg_class WHERE oid = '{}.ev_copy'::regclass",
                DECLARATIVE
            );
            assert_eq!(scalar(&pool, &shape).await, "p RANGE (seen)");

            // INCLUDING ALL still carried the key and the plain index across.
            let idx = format!(
                "SELECT count(*)::text AS v FROM pg_indexes \
                 WHERE schemaname = '{}' AND tablename = 'ev_copy'",
                DECLARATIVE
            );
            assert_eq!(scalar(&pool, &idx).await, "2", "pkey and note index");

            // And it has no partitions of its own, which is why rows are refused.
            let parts = format!(
                "SELECT count(*)::text AS v FROM pg_inherits \
                 WHERE inhparent = '{}.ev_copy'::regclass",
                DECLARATIVE
            );
            assert_eq!(scalar(&pool, &parts).await, "0");

            drop_fixture(&pool, DECLARATIVE).await;
        });
    }

    /// Rows into a partitioned copy are refused with nothing left behind.
    #[test]
    #[ignore = "needs a live PostgreSQL"]
    fn rows_into_a_partitioned_copy_are_refused_before_anything_is_created() {
        let rt = tokio::runtime::Runtime::new().expect("tokio runtime");
        rt.block_on(async {
            let pool = live_pool().await;
            build_fixture(&pool, REFUSAL).await;
            let state = state_with(&pool, "live-clone-refusal");

            let mut options = clone_options(REFUSAL, "ev", "ev_copy");
            options.include_data = true;
            let err = clone_table("live-clone-refusal".into(), options, &state)
                .await
                .expect_err("PostgreSQL can only answer this with an error");
            println!("refusal: {err}");
            assert!(err.contains("RANGE (seen)"), "{err}");
            assert!(err.contains("clone one partition"), "{err}");

            // Refused BEFORE the CREATE: no half-built table is left over.
            let exists = format!(
                "SELECT count(*)::text AS v FROM pg_class c JOIN pg_namespace n ON n.oid = c.relnamespace \
                 WHERE n.nspname = '{}' AND c.relname = 'ev_copy'",
                REFUSAL
            );
            assert_eq!(scalar(&pool, &exists).await, "0");

            drop_fixture(&pool, REFUSAL).await;
        });
    }

    /// The default takes the parent's own row and leaves the archive alone.
    #[test]
    #[ignore = "needs a live PostgreSQL"]
    fn the_default_scope_copies_only_the_parents_own_rows() {
        let rt = tokio::runtime::Runtime::new().expect("tokio runtime");
        rt.block_on(async {
            let pool = live_pool().await;
            build_fixture(&pool, OWN_ROWS).await;
            let state = state_with(&pool, "live-clone-own");

            let mut options = clone_options(OWN_ROWS, "lg", "lg_copy");
            options.include_data = true;
            let result = clone_table("live-clone-own".into(), options, &state)
                .await
                .expect("the clone should succeed");

            // The tree holds 4; the root itself holds 1.
            assert_eq!(result.rows_copied, Some(1), "own rows only");
            let n = format!("SELECT count(*)::text AS v FROM {}.lg_copy", OWN_ROWS);
            assert_eq!(scalar(&pool, &n).await, "1");

            drop_fixture(&pool, OWN_ROWS).await;
        });
    }

    /// The flatten case, which the caller has to ask for by name.
    #[test]
    #[ignore = "needs a live PostgreSQL"]
    fn the_whole_tree_scope_flattens_every_descendant_into_the_copy() {
        let rt = tokio::runtime::Runtime::new().expect("tokio runtime");
        rt.block_on(async {
            let pool = live_pool().await;
            build_fixture(&pool, WHOLE_TREE).await;
            let state = state_with(&pool, "live-clone-tree");

            let mut options = clone_options(WHOLE_TREE, "lg", "lg_copy");
            options.include_data = true;
            options.row_scope = CloneRowScope::WholeTree;
            let result = clone_table("live-clone-tree".into(), options, &state)
                .await
                .expect("the clone should succeed");

            assert_eq!(result.rows_copied, Some(4), "the root's row and the leaf's three");

            drop_fixture(&pool, WHOLE_TREE).await;
        });
    }

    /// The shape that reaches the sheet, read from a real server.
    ///
    /// The unit tests pin what `compose_table_ddl` does with parts; this pins
    /// that the parts are right — the sheet disables its checkbox and shows
    /// its radios on the strength of these three fields.
    #[test]
    #[ignore = "needs a live PostgreSQL"]
    fn the_ddl_reports_the_shape_the_sheet_reads() {
        let rt = tokio::runtime::Runtime::new().expect("tokio runtime");
        rt.block_on(async {
            let pool = live_pool().await;
            build_fixture(&pool, SHAPE).await;
            let state = state_with(&pool, "live-clone-shape");

            let ddl_of = |table: &str| {
                let state = &state;
                let table = table.to_string();
                async move {
                    generate_table_ddl("live-clone-shape".into(), SHAPE.into(), table, state)
                        .await
                        .expect("generate the DDL")
                }
            };

            // The declarative parent: a key, no INHERITS children.
            let ev = ddl_of("ev").await;
            assert_eq!(ev.shape.partition_by.as_deref(), Some("RANGE (seen)"));
            assert!(!ev.shape.has_child_tables, "a partition is not an INHERITS child");
            assert!(ev.shape.inherits_from.is_empty());

            // The inheritance root: children, no key, no parents.
            let lg = ddl_of("lg").await;
            assert_eq!(lg.shape.partition_by, None);
            assert!(lg.shape.has_child_tables, "the root has children");
            assert!(lg.shape.inherits_from.is_empty());

            // A middle node: both a parent and a child.
            let mid = ddl_of("lg_2013").await;
            assert!(mid.shape.has_child_tables, "lg_201301 hangs off it");
            assert_eq!(
                mid.shape.inherits_from,
                vec![crate::commands::ddl::QualifiedName {
                    schema: SHAPE.to_string(),
                    table: "lg".to_string(),
                }],
                "named raw, for the sheet to escape per part"
            );

            // A leaf: nothing either way, so the sheet shows no chrome.
            let leaf = ddl_of("lg_201301").await;
            assert!(!leaf.shape.has_child_tables);
            assert_eq!(leaf.shape.partition_by, None);

            drop_fixture(&pool, SHAPE).await;
        });
    }

    /// A copy of a child keeps every inherited column and joins no tree.
    #[test]
    #[ignore = "needs a live PostgreSQL"]
    fn a_childs_copy_is_complete_and_standalone() {
        let rt = tokio::runtime::Runtime::new().expect("tokio runtime");
        rt.block_on(async {
            let pool = live_pool().await;
            build_fixture(&pool, STANDALONE).await;
            let state = state_with(&pool, "live-clone-standalone");

            let before = format!(
                "SELECT count(*)::text AS v FROM pg_inherits WHERE inhparent = '{}.lg_2013'::regclass",
                STANDALONE
            );
            assert_eq!(scalar(&pool, &before).await, "1");

            clone_table(
                "live-clone-standalone".into(),
                clone_options(STANDALONE, "lg_201301", "lg_201301_copy"),
                &state,
            )
            .await
            .expect("the clone should succeed");

            // Every column the parents contributed is present.
            let cols = format!(
                "SELECT string_agg(attname, ',' ORDER BY attnum) AS v FROM pg_attribute \
                 WHERE attrelid = '{}.lg_201301_copy'::regclass AND attnum > 0 AND NOT attisdropped",
                STANDALONE
            );
            assert_eq!(scalar(&pool, &cols).await, "id,seen");

            // And the source tree is exactly as it was: the copy did not join it.
            assert_eq!(scalar(&pool, &before).await, "1", "no new child");
            let parents = format!(
                "SELECT count(*)::text AS v FROM pg_inherits WHERE inhrelid = '{}.lg_201301_copy'::regclass",
                STANDALONE
            );
            assert_eq!(scalar(&pool, &parents).await, "0", "standalone");

            drop_fixture(&pool, STANDALONE).await;
        });
    }
}
