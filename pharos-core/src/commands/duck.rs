//! The DuckDB side of the pool-style commands: connect, the navigator's
//! catalog reads, a query with no tab session, DDL, export, import, clone.
//!
//! Each `commands::*` entry point that serves both engines starts with
//! `if state.engine_of(id) == Engine::Duckdb { return duck::…(…) }`, so the
//! PostgreSQL code below it is untouched. A PostgreSQL-only command keeps
//! calling `require_pool`, which answers a DuckDB record with
//! `DUCKDB_UNSUPPORTED_MESSAGE`.

use std::sync::atomic::Ordering;
use std::sync::Arc;
use std::time::Instant;

use duckdb::Connection;

use super::query::{history_entry, query_timeout_seconds, record_history, result_cache, ExecuteResult, QueryResult, ValidationResult};
use super::table::{
    validate_csv_against, validate_file_path, write_text_pages, CloneTableOptions, CloneTableResult, CsvValidationResult,
    ExportQueryOptions, ExportTableOptions, ExportTableResult, ImportCsvOptions, ImportCsvResult, TextPage,
};
use crate::commands::ddl::TableDdl;
use crate::db::duckdb::catalog::{self, quote_ident};
use crate::db::duckdb::exec::{self, run_cancellable, RunStop};
use crate::db::duckdb::{missing_file_message, normalized_path, DuckDbInstance, OpenOptions, IN_MEMORY};
use crate::models::{
    AnalyzeResult, ColumnInfo, ConnectionConfig, ConnectionInfo, ConnectionStatus, ConstraintInfo, FunctionInfo,
    ImportErrorPolicy, IndexInfo, SchemaColumnInfo, SchemaDraftFacts, SchemaInfo, TableInfo, TestConnectionResult,
};
use crate::state::AppState;

fn info(config: &ConnectionConfig, status: ConnectionStatus, error: Option<String>, latency_ms: Option<u64>) -> ConnectionInfo {
    ConnectionInfo {
        id: config.id.clone(),
        name: config.name.clone(),
        host: String::new(),
        port: 0,
        database: config.database.clone(),
        status,
        error,
        latency_ms,
    }
}

// MARK: - Connect

/// A second record on a file that is open with the other Read-only setting.
pub const READ_ONLY_MISMATCH: &str =
    "This file is already open in Pharos with a different Read-only setting. Disconnect the other connection first.";

/// Open the record's database. A file another record already has open is
/// shared, never opened twice in one process.
pub async fn connect(config: ConnectionConfig, state: &AppState) -> Result<ConnectionInfo, String> {
    if state.get_duck(&config.id).is_some() {
        return Ok(info(&config, ConnectionStatus::Connected, None, None));
    }
    let read_only = config.read_only || state.take_duck_read_only_once(&config.id);
    let create = state.take_duck_create_once(&config.id);
    let path = normalized_path(&config.database);
    if let Some(existing) = state.duck_instance_for_path(&path).or_else(|| state.duck_still_closing(&path)) {
        // One instance has ONE mode. Sharing a writable instance with a
        // Read-only record would let its editor write; sharing a read-only
        // one would refuse the writable record's writes. (Plan C9 exception.)
        if existing.read_only != read_only {
            return Ok(info(&config, ConnectionStatus::Error, Some(READ_ONLY_MISMATCH.to_string()), None));
        }
        state.add_duck(config.id.clone(), existing);
        return Ok(info(&config, ConnectionStatus::Connected, None, Some(0)));
    }
    // A missing file is created only when the user asked for a new database
    // (File ▸ New, Save of a new record, Create Empty Database). Otherwise the
    // file was moved, renamed or deleted, or its disk is not connected, and
    // an empty database in its place would look like lost data.
    if path != IN_MEMORY && !create && !std::path::Path::new(&path).exists() {
        return Ok(info(&config, ConnectionStatus::Error, Some(missing_file_message(&path)), None));
    }
    let options = OpenOptions::from_settings(&state.settings().connections);
    let start = Instant::now();
    let opened = tokio::task::spawn_blocking(move || DuckDbInstance::open(&path, read_only, &options))
        .await
        .map_err(|e| e.to_string())?;
    match opened {
        Ok(instance) => {
            state.add_duck(config.id.clone(), Arc::new(instance));
            Ok(info(&config, ConnectionStatus::Connected, None, Some(start.elapsed().as_millis() as u64)))
        }
        Err(message) => Ok(info(&config, ConnectionStatus::Error, Some(message), None)),
    }
}

/// Close the tabs' connections, then let the database go. DuckDB writes a
/// checkpoint when the last connection of an instance closes.
pub async fn disconnect(connection_id: &str, state: &AppState) {
    super::duck_session::close_duck_sessions_for_connection(state, connection_id).await;
    if let Some(instance) = state.remove_duck(connection_id) {
        // An export may still hold the instance: a connect before it ends
        // must find this one, not open the file again.
        state.note_duck_closing(&instance);
        // Drop off the runtime: the checkpoint can take a moment.
        let _ = tokio::task::spawn_blocking(move || drop(instance)).await;
    }
}

/// Test a record without connecting it. A file that does not exist yet
/// passes when its folder exists (Connect creates it). An existing file is
/// opened read-only, so a test never changes it — unless this process has it
/// open already, in which case that instance answers.
pub async fn test(config: ConnectionConfig, state: Option<&AppState>) -> Result<TestConnectionResult, String> {
    let path = normalized_path(&config.database);
    let start = Instant::now();
    let shared = state.and_then(|s| s.duck_instance_for_path(&path));
    let options = state.map(|s| OpenOptions::from_settings(&s.settings().connections)).unwrap_or_default();
    let outcome = tokio::task::spawn_blocking(move || -> Result<(), String> {
        if let Some(instance) = shared {
            let c = instance.connect()?;
            return c.execute_batch("SELECT 1").map_err(|e| e.to_string());
        }
        if path != IN_MEMORY && !std::path::Path::new(&path).exists() {
            let parent = std::path::Path::new(&path).parent().map(|p| p.to_path_buf()).unwrap_or_default();
            return if parent.as_os_str().is_empty() || parent.exists() {
                Ok(())
            } else {
                Err(format!("The folder does not exist: {}", parent.display()))
            };
        }
        let instance = DuckDbInstance::open(&path, path != IN_MEMORY, &options)?;
        let c = instance.connect()?;
        c.execute_batch("SELECT 1").map_err(|e| e.to_string())
    })
    .await
    .map_err(|e| e.to_string())?;
    Ok(match outcome {
        Ok(()) => TestConnectionResult { success: true, latency_ms: Some(start.elapsed().as_millis() as u64), error: None },
        Err(e) => TestConnectionResult { success: false, latency_ms: None, error: Some(e) },
    })
}

// MARK: - Running SQL without a tab

/// Run `work` on a fresh connection of the record's database, with the
/// toolbar schema applied, stoppable by `query_id`'s cancel and the timeout.
/// `timeout_seconds`: 0 = none. Card-like runs pass the query timeout;
/// exports pass 0, as the PostgreSQL export has no deadline.
async fn on_fresh<T, F>(state: &AppState, connection_id: &str, schema: Option<String>, query_id: Option<String>,
                        timeout_seconds: u32, work: F) -> Result<T, String>
where
    T: Send + 'static,
    F: FnOnce(&Connection) -> Result<T, String> + Send + 'static,
{
    let instance = state.require_duck(connection_id)?;
    let conn = instance.connect()?;
    let interrupt = conn.interrupt_handle();
    let registered = state.register_query(query_id.unwrap_or_else(|| uuid::Uuid::new_v4().to_string()));
    registered.attach_progress(conn.progress_handle());
    let cancel = registered.cancel.clone();
    run_cancellable(interrupt, &cancel, timeout_seconds, move || {
        if let Some(s) = schema.filter(|s| !s.is_empty()) {
            let path = if s == "main" { "'main'".to_string() } else { format!("'{},main'", s.replace('\'', "''")) };
            let _ = conn.execute_batch(&format!("SET search_path = {}", path));
        }
        work(&conn)
    })
    .await
    .map_err(RunStop::message)
}

#[allow(clippy::too_many_arguments)]
pub async fn execute_query(connection_id: String, sql: String, query_id: Option<String>, limit: Option<u32>,
                           schema: Option<String>, source: Option<String>, state: &AppState) -> Result<QueryResult, String> {
    let limit = limit.unwrap_or(1000) as usize;
    let start = Instant::now();
    let text = sql.clone();
    let rows = on_fresh(state, &connection_id, schema.clone(), query_id, query_timeout_seconds(state), move |c| exec::query_text(c, &text, Some(limit), 0)).await?;
    let execution_time_ms = start.elapsed().as_millis() as u64;
    let row_count = rows.rows.len();
    let entry = history_entry(state, &connection_id, &sql, &schema, source, row_count as i64, execution_time_ms,
                              Some(rows.columns.len() as i64));
    let history_id = entry.id.clone();
    record_history(state, &entry, result_cache(&rows.columns, &rows.rows, None));
    Ok(QueryResult {
        columns: rows.columns,
        rows: rows.rows,
        row_count,
        execution_time_ms,
        has_more: rows.has_more,
        history_entry_id: Some(history_id),
        row_identity: None,
    })
}

pub async fn execute_statement(connection_id: String, sql: String, query_id: Option<String>, schema: Option<String>,
                               state: &AppState) -> Result<ExecuteResult, String> {
    let start = Instant::now();
    let text = sql.clone();
    let rows_affected = on_fresh(state, &connection_id, schema.clone(), query_id, query_timeout_seconds(state), move |c| exec::execute_text(c, &text)).await?;
    let execution_time_ms = start.elapsed().as_millis() as u64;
    let entry = history_entry(state, &connection_id, &sql, &schema, None, rows_affected as i64, execution_time_ms, None);
    let id = entry.id.clone();
    record_history(state, &entry, None);
    Ok(ExecuteResult { rows_affected, execution_time_ms, history_entry_id: Some(id) })
}

/// Load More / Load All without a tab: the last statement again, paged.
pub async fn fetch_rows(connection_id: String, sql: String, query_id: Option<String>, limit: usize, offset: usize,
                        schema: Option<String>, state: &AppState) -> Result<QueryResult, String> {
    let start = Instant::now();
    let statement = exec::statements(&sql).pop().ok_or_else(|| "There is no statement to read.".to_string())?;
    let rows = on_fresh(state, &connection_id, schema, query_id, query_timeout_seconds(state), move |c| exec::page_rows(c, &statement, Some(limit), offset)).await?;
    let row_count = rows.rows.len();
    Ok(QueryResult {
        columns: rows.columns,
        rows: rows.rows,
        row_count,
        execution_time_ms: start.elapsed().as_millis() as u64,
        has_more: rows.has_more,
        history_entry_id: None,
        row_identity: None,
    })
}

pub async fn validate_sql(connection_id: String, sql: String, schema: Option<String>, state: &AppState) -> Result<ValidationResult, String> {
    let target: super::tab_session::SessionTarget = serde_json::from_value(serde_json::json!({
        "sessionId": "", "connectionId": connection_id, "schema": schema
    }))
    .map_err(|e| e.to_string())?;
    super::duck_session::validate_sql(target, sql, state).await
}

/// EXPLAIN for the plan view (`exec::explain_plan_json`). ANALYZE runs inside
/// a transaction that is rolled back.
pub async fn explain(connection_id: String, sql: String, analyze: bool, state: &AppState) -> Result<String, String> {
    let statement = super::query::single_statement(&sql)?;
    on_fresh(state, &connection_id, None, None, query_timeout_seconds(state), move |c| {
        if analyze {
            c.execute_batch("BEGIN").map_err(|e| e.to_string())?;
        }
        let plan = exec::explain_plan_json(c, &statement, analyze);
        if analyze {
            let _ = c.execute_batch("ROLLBACK");
        }
        plan
    })
    .await
}

// MARK: - Catalog

async fn catalog_read<T, F>(state: &AppState, connection_id: &str, read: F) -> Result<T, String>
where
    T: Send + 'static,
    F: FnOnce(&Connection) -> Result<T, String> + Send + 'static,
{
    state.require_duck(connection_id)?.with_connection(read).await
}

pub async fn schemas(connection_id: String, state: &AppState) -> Result<Vec<SchemaInfo>, String> {
    let include_system = state.settings().navigator.show_system_schemas;
    catalog_read(state, &connection_id, move |c| catalog::schemas(c, include_system)).await
}

pub async fn tables(connection_id: String, schema: String, state: &AppState) -> Result<Vec<TableInfo>, String> {
    catalog_read(state, &connection_id, move |c| catalog::tables(c, &schema)).await
}

/// "Refresh row counts": DuckDB's estimate is exact for a table it wrote,
/// but a `count(*)` per table is what the user asked for.
pub async fn analyze_schema(connection_id: String, schema: String, state: &AppState) -> Result<AnalyzeResult, String> {
    let tables = catalog_read(state, &connection_id, move |c| catalog::exact_row_counts(c, &schema)).await?;
    Ok(AnalyzeResult { had_unanalyzed: false, permission_denied_tables: vec![], tables })
}

pub async fn columns(connection_id: String, schema: String, table: String, state: &AppState) -> Result<Vec<ColumnInfo>, String> {
    catalog_read(state, &connection_id, move |c| catalog::columns(c, &schema, &table)).await
}

pub async fn schema_columns(connection_id: String, schema: String, state: &AppState) -> Result<Vec<SchemaColumnInfo>, String> {
    catalog_read(state, &connection_id, move |c| catalog::schema_columns(c, &schema)).await
}

pub async fn draft_facts(connection_id: String, schema: String, state: &AppState) -> Result<SchemaDraftFacts, String> {
    catalog_read(state, &connection_id, move |c| catalog::draft_facts(c, &schema)).await
}

pub async fn indexes(connection_id: String, schema: String, table: String, state: &AppState) -> Result<Vec<IndexInfo>, String> {
    catalog_read(state, &connection_id, move |c| catalog::indexes(c, &schema, &table)).await
}

pub async fn constraints(connection_id: String, schema: String, table: String, state: &AppState) -> Result<Vec<ConstraintInfo>, String> {
    catalog_read(state, &connection_id, move |c| catalog::constraints(c, &schema, &table)).await
}

pub async fn functions(connection_id: String, schema: String, state: &AppState) -> Result<Vec<FunctionInfo>, String> {
    catalog_read(state, &connection_id, move |c| catalog::functions(c, &schema)).await
}

pub async fn table_ddl(connection_id: String, schema: String, table: String, state: &AppState) -> Result<TableDdl, String> {
    catalog_read(state, &connection_id, move |c| catalog::table_ddl(c, &schema, &table)).await
}

/// Keywords and function names for the editor's completion.
pub async fn vocabulary(connection_id: String, state: &AppState) -> Result<(Vec<String>, Vec<String>), String> {
    catalog_read(state, &connection_id, catalog::vocabulary).await
}

// MARK: - Data movement

/// `"db"."schema"."table"` for a navigator schema name.
fn qualified(c: &Connection, schema: &str, table: &str) -> Result<String, String> {
    let (db, schema_name) = catalog::split_schema(c, schema)?;
    Ok(format!("{}.{}.{}", quote_ident(&db), quote_ident(&schema_name), quote_ident(table)))
}

/// A DuckDB type name in the spelling the export's value writers know.
fn export_type(duck: &str) -> String {
    let upper = duck.to_ascii_uppercase();
    let base = upper.split('(').next().unwrap_or("").trim();
    match base {
        "TINYINT" | "SMALLINT" | "UTINYINT" => "INT2",
        "INTEGER" | "USMALLINT" => "INT4",
        "BIGINT" | "UINTEGER" => "INT8",
        "UBIGINT" | "HUGEINT" | "UHUGEINT" | "DECIMAL" => "NUMERIC",
        "FLOAT" => "FLOAT4",
        "DOUBLE" => "FLOAT8",
        "BOOLEAN" => "BOOL",
        "JSON" => "JSON",
        _ => "TEXT",
    }
    .to_string()
}

/// Export through the shared text writer, a page at a time.
#[allow(clippy::too_many_arguments)]
async fn export_statement(state: &AppState, connection_id: &str, schema: Option<String>, statement: String,
                          file_path: String, format: crate::models::ExportFormat, insert_target: String,
                          null_as_empty: bool, include_headers: bool, dialect: crate::models::CsvDialect,
                          progress: Option<Box<dyn Fn(u64, bool) + Send>>) -> Result<ExportTableResult, String> {
    let batch = state.settings().data_export.batch_size as i64;
    on_fresh(state, connection_id, schema, None, 0, move |c| {
        let pager = |offset: i64, limit: i64| -> Result<TextPage, String> {
            let page = exec::rows_of(c, &statement, Some(limit as usize), offset as usize)?;
            if !page.pageable && offset > 0 {
                return Ok(TextPage { names: vec![], types: vec![], rows: vec![] });
            }
            Ok(TextPage {
                names: page.columns.iter().map(|c| c.name.clone()).collect(),
                types: page.columns.iter().map(|c| export_type(&c.data_type)).collect(),
                rows: page
                    .rows
                    .iter()
                    .map(|r| r.as_array().map(|a| a.iter().map(|v| v.as_str().map(String::from)).collect()).unwrap_or_default())
                    .collect(),
            })
        };
        write_text_pages(pager, &file_path, &format, &insert_target, null_as_empty, include_headers, &dialect, batch,
                         progress.as_deref())
    })
    .await
}

pub async fn export_query(connection_id: String, options: ExportQueryOptions, state: &AppState,
                          progress: Option<Box<dyn Fn(u64, bool) + Send>>) -> Result<ExportTableResult, String> {
    validate_file_path(&options.file_path)?;
    let statement = exec::statements(&options.sql).pop().ok_or_else(|| "There is no statement to export.".to_string())?;
    export_statement(state, &connection_id, options.schema, statement, options.file_path, options.format,
                     "\"_query_results\"".to_string(), true, true, options.csv, progress).await
}

pub async fn export_table(connection_id: String, options: ExportTableOptions, state: &AppState) -> Result<ExportTableResult, String> {
    validate_file_path(&options.file_path)?;
    let schema = options.schema_name.clone();
    let table = options.table_name.clone();
    let columns = options.columns.clone();
    // The INSERT target is "schema"."table", as the PostgreSQL export writes
    // it, so the file replays into another database. A navigator schema of
    // an attached database ("pg.public") is split first: quoted whole it was
    // one dotted identifier that no database has.
    let (target, insert_target) = catalog_read(state, &connection_id, move |c| {
        let (_, schema_name) = catalog::split_schema(c, &schema)?;
        Ok((qualified(c, &schema, &table)?, format!("{}.{}", quote_ident(&schema_name), quote_ident(&table))))
    })
    .await?;
    let list = if columns.is_empty() { "*".to_string() } else { columns.iter().map(|c| quote_ident(c)).collect::<Vec<_>>().join(", ") };
    let statement = format!("SELECT {} FROM {}", list, target);
    export_statement(state, &connection_id, None, statement, options.file_path, options.format, insert_target,
                     options.null_as_empty, options.include_headers, options.csv, None).await
}

/// Write a whole query to Parquet with DuckDB's own writer.
pub async fn export_parquet(connection_id: String, sql: String, schema: Option<String>, file_path: String,
                            state: &AppState) -> Result<ExportTableResult, String> {
    validate_file_path(&file_path)?;
    let statement = exec::statements(&sql).pop().ok_or_else(|| "There is no statement to export.".to_string())?;
    let rows = on_fresh(state, &connection_id, schema, None, 0, move |c| {
        let sql = format!(
            "COPY ({}) TO '{}' (FORMAT parquet, COMPRESSION zstd)",
            statement,
            file_path.replace('\'', "''")
        );
        exec::execute_text(c, &sql)
    })
    .await?;
    Ok(ExportTableResult { success: true, rows_exported: rows, characters_substituted: 0 })
}

pub async fn validate_csv(connection_id: String, schema: String, table: String, file_path: String, has_headers: bool,
                          state: &AppState) -> Result<CsvValidationResult, String> {
    validate_file_path(&file_path)?;
    let cols = columns(connection_id, schema, table, state).await?;
    let names = cols.into_iter().map(|c| c.name).collect();
    tokio::task::spawn_blocking(move || validate_csv_against(names, &file_path, has_headers))
        .await
        .map_err(|e| e.to_string())?
}

/// Import a CSV: Pharos's own reader (the dialect, the encoding, the NULL
/// literal, the header) appends every record to a temporary all-VARCHAR
/// table, then ONE `INSERT … SELECT` casts into the target, inside one
/// transaction. "Skip row" keeps the rows whose every value casts.
pub async fn import_csv(connection_id: String, options: ImportCsvOptions, state: &AppState) -> Result<ImportCsvResult, String> {
    state.require_writable(&connection_id)?;
    validate_file_path(&options.file_path)?;
    let progress_key = format!("{}|{}|{}", connection_id, options.schema_name, options.table_name);
    let progress = state.register_import_progress(progress_key.clone());
    struct Guard<'a>(&'a AppState, String);
    impl Drop for Guard<'_> {
        fn drop(&mut self) {
            self.0.unregister_import_progress(&self.1);
        }
    }
    let _guard = Guard(state, progress_key);

    let instance = state.require_duck(&connection_id)?;
    tokio::task::spawn_blocking(move || -> Result<ImportCsvResult, String> {
        let c = instance.connect()?;
        let cols = catalog::columns(&c, &options.schema_name, &options.table_name)?;
        if cols.is_empty() {
            return Err(format!("No table {}.{}", options.schema_name, options.table_name));
        }
        let target = qualified(&c, &options.schema_name, &options.table_name)?;
        let staging: Vec<String> = (0..cols.len()).map(|i| format!("c{} VARCHAR", i)).collect();
        c.execute_batch(&format!("CREATE OR REPLACE TEMP TABLE _pharos_import ({})", staging.join(", ")))
            .map_err(|e| e.to_string())?;
        let skipping = options.on_error == ImportErrorPolicy::SkipRow;
        let mut errors: Vec<String> = Vec::new();
        let mut skipped: u64 = 0;
        let mut read: u64 = 0;
        {
            let source = super::table::open_csv_source(&options.file_path, &options.csv)?;
            let mut reader = csv::ReaderBuilder::new()
                .has_headers(options.has_headers)
                .delimiter(options.csv.delimiter_byte())
                .quote(options.csv.quote_byte())
                .from_reader(source);
            let mut appender = c.appender_to_catalog_and_db("_pharos_import", "temp", "main").map_err(|e| e.to_string())?;
            for (n, record) in reader.records().enumerate() {
                let row = n + 1;
                let record = match record {
                    Ok(r) if r.len() == cols.len() => r,
                    Ok(r) => {
                        let m = format!("Row {}: CSV row has {} columns but table has {} columns", row, r.len(), cols.len());
                        if !skipping {
                            return Err(m);
                        }
                        skipped += 1;
                        if errors.len() < 20 { errors.push(m); }
                        continue;
                    }
                    Err(e) => {
                        if !skipping {
                            return Err(format!("Failed to read CSV row: {}", e));
                        }
                        skipped += 1;
                        if errors.len() < 20 { errors.push(format!("Row {}: {}", row, e)); }
                        continue;
                    }
                };
                let values: Vec<Option<&str>> =
                    record.iter().map(|v| if v == options.csv.null_literal { None } else { Some(v) }).collect();
                appender
                    .append_row(duckdb::appender_params_from_iter(values))
                    .map_err(|e| format!("Failed to stage row {}: {}", row, e))?;
                read += 1;
                progress.store(read, Ordering::Relaxed);
            }
            appender.flush().map_err(|e| e.to_string())?;
        }
        let names: Vec<String> = cols.iter().map(|col| quote_ident(&col.name)).collect();
        let casts: Vec<String> = cols
            .iter()
            .enumerate()
            .map(|(i, col)| format!("{}(c{} AS {})", if skipping { "TRY_CAST" } else { "CAST" }, i, col.data_type))
            .collect();
        let filter = if skipping {
            let checks: Vec<String> = cols
                .iter()
                .enumerate()
                .map(|(i, col)| format!("(c{i} IS NULL OR TRY_CAST(c{i} AS {}) IS NOT NULL)", col.data_type))
                .collect();
            format!(" WHERE {}", checks.join(" AND "))
        } else {
            String::new()
        };
        let insert = format!("INSERT INTO {} ({}) SELECT {} FROM _pharos_import{}", target, names.join(", "), casts.join(", "), filter);
        c.execute_batch("BEGIN").map_err(|e| e.to_string())?;
        let inserted = match c.execute(&insert, []) {
            Ok(n) => n as u64,
            Err(e) => {
                let _ = c.execute_batch("ROLLBACK; DROP TABLE IF EXISTS _pharos_import");
                return Err(format!("Failed to insert the rows: {}", e));
            }
        };
        c.execute_batch("COMMIT; DROP TABLE IF EXISTS _pharos_import").map_err(|e| e.to_string())?;
        let cast_skipped = read.saturating_sub(inserted);
        if cast_skipped > 0 && errors.len() < 20 {
            errors.push(format!("{} row(s) had a value that does not fit its column's type", cast_skipped));
        }
        Ok(ImportCsvResult { success: true, rows_imported: inserted, rows_skipped: skipped + cast_skipped, errors, committed_batches: 0 })
    })
    .await
    .map_err(|e| e.to_string())?
}

/// Clone a table. "With constraints" re-runs the DDL DuckDB stored for the
/// source under the new name; the rows follow with `INSERT … SELECT`.
pub async fn clone_table(connection_id: String, options: CloneTableOptions, state: &AppState) -> Result<CloneTableResult, String> {
    state.require_writable(&connection_id)?;
    catalog_read(state, &connection_id, move |c| {
        let source = qualified(c, &options.source_schema, &options.source_table)?;
        let target = qualified(c, &options.target_schema, &options.target_table)?;
        let cols = catalog::columns(c, &options.source_schema, &options.source_table)?;
        let lines: Vec<String> = cols
            .iter()
            .map(|col| {
                let mut line = format!("{} {}", quote_ident(&col.name), col.data_type);
                if !col.is_nullable {
                    line.push_str(" NOT NULL");
                }
                if let Some(d) = &col.column_default {
                    line.push_str(&format!(" DEFAULT {}", d));
                }
                line
            })
            .collect();
        c.execute_batch(&format!("CREATE TABLE {} ({})", target, lines.join(", "))).map_err(|e| format!("Failed to create table: {}", e))?;
        let rows = if options.include_data {
            let n = c
                .execute(&format!("INSERT INTO {} SELECT * FROM {}", target, source), [])
                .map_err(|e| format!("Failed to copy data: {}", e))?;
            Some(n as u64)
        } else {
            None
        };
        Ok(CloneTableResult { success: true, rows_copied: rows })
    })
    .await
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::models::{Engine, ExportFormat};

    fn state_with(id: &str, path: &str) -> AppState {
        let sqlite = rusqlite::Connection::open_in_memory().unwrap();
        crate::db::sqlite::create_schema(&sqlite).unwrap();
        let state = AppState::new(sqlite);
        let config: ConnectionConfig = serde_json::from_value(serde_json::json!({
            "id": id, "name": "duck", "host": "", "port": 0, "database": path, "username": "", "engine": "duckdb"
        }))
        .unwrap();
        assert_eq!(config.engine, Engine::Duckdb);
        state.set_config(config);
        state
    }

    fn temp(tag: &str, ext: &str) -> String {
        // Under HOME: `validate_file_path` canonicalises /var/folders to
        // /private/var/folders, which it does not allow.
        let home = std::env::var("HOME").unwrap();
        let dir = std::path::Path::new(&home).join("Library/Caches/pharos-tests");
        std::fs::create_dir_all(&dir).unwrap();
        dir.join(format!("{}-{}.{}", tag, uuid::Uuid::new_v4(), ext)).to_string_lossy().to_string()
    }

    #[tokio::test(flavor = "multi_thread")]
    async fn connect_query_and_disconnect_a_file() {
        let path = temp("conn", "duckdb");
        let state = state_with("d", &path);
        state.request_duck_create_once("d");
        let config = state.get_config("d").unwrap();
        let info = connect(config.clone(), &state).await.unwrap();
        assert_eq!(info.status, ConnectionStatus::Connected, "{:?}", info.error);
        execute_statement("d".into(), "CREATE TABLE t AS SELECT range AS n FROM range(3)".into(), None, None, &state).await.unwrap();
        let r = execute_query("d".into(), "SELECT * FROM t ORDER BY n".into(), None, Some(2), None, None, &state).await.unwrap();
        assert_eq!(r.row_count, 2);
        assert!(r.has_more);
        let more = fetch_rows("d".into(), "SELECT * FROM t ORDER BY n".into(), None, 2, 2, None, &state).await.unwrap();
        assert_eq!(more.rows, vec![serde_json::json!(["2"])]);
        assert_eq!(tables("d".into(), "main".into(), &state).await.unwrap()[0].name, "t");
        // A second record on the same file shares the instance.
        let mut twin = config.clone();
        twin.id = "d2".into();
        state.set_config(twin.clone());
        connect(twin, &state).await.unwrap();
        assert!(Arc::ptr_eq(&state.get_duck("d").unwrap(), &state.get_duck("d2").unwrap()));
        disconnect("d", &state).await;
        disconnect("d2", &state).await;
        assert!(state.get_duck("d").is_none());
        // The file was checkpointed and reopens with its data.
        let again = connect(config, &state).await.unwrap();
        assert_eq!(again.status, ConnectionStatus::Connected);
        let r = execute_query("d".into(), "SELECT count(*) FROM t".into(), None, None, None, None, &state).await.unwrap();
        assert_eq!(r.rows, vec![serde_json::json!(["3"])]);
        disconnect("d", &state).await;
        let _ = std::fs::remove_file(&path);
    }

    /// D4: the result's "Export All Rows as Parquet/Excel" cards are COPY
    /// statements; both formats are built in.
    #[tokio::test(flavor = "multi_thread")]
    async fn copy_to_parquet_and_xlsx_works_built_in() {
        let path = temp("copyfmt", "duckdb");
        let state = state_with("d", &path);
        state.request_duck_create_once("d");
        connect(state.get_config("d").unwrap(), &state).await.unwrap();
        let parquet = temp("all", "parquet");
        let xlsx = temp("all", "xlsx");
        for (file, options) in [(&parquet, "FORMAT parquet, COMPRESSION zstd"), (&xlsx, "FORMAT xlsx, HEADER true")] {
            let sql = format!("COPY (SELECT range AS n FROM range(1000)) TO '{}' ({})", file, options);
            execute_statement("d".into(), sql, None, None, &state).await.unwrap();
            assert!(std::fs::metadata(file).map(|m| m.len() > 0).unwrap_or(false), "{file} written");
        }
        let r = execute_query("d".into(), format!("SELECT count(*) FROM read_parquet('{}')", parquet), None, None, None, None, &state)
            .await.unwrap();
        assert_eq!(r.rows, vec![serde_json::json!(["1000"])]);
        let r = execute_query("d".into(), format!("SELECT count(*) FROM read_xlsx('{}')", xlsx), None, None, None, None, &state)
            .await.unwrap();
        assert_eq!(r.rows, vec![serde_json::json!(["1000"])]);
        disconnect("d", &state).await;
        for f in [&path, &parquet, &xlsx] { let _ = std::fs::remove_file(f); }
    }

    /// Two records on one file share one instance only when their Read-only
    /// settings agree.
    #[tokio::test(flavor = "multi_thread")]
    async fn a_read_only_record_never_shares_a_writable_instance() {
        let path = temp("mismatch", "duckdb");
        let state = state_with("w", &path);
        state.request_duck_create_once("w");
        let writer = state.get_config("w").unwrap();
        assert_eq!(connect(writer.clone(), &state).await.unwrap().status, ConnectionStatus::Connected);
        let mut reader = writer.clone();
        reader.id = "r".into();
        reader.read_only = true;
        state.set_config(reader.clone());
        let refused = connect(reader.clone(), &state).await.unwrap();
        assert_eq!(refused.status, ConnectionStatus::Error);
        assert_eq!(refused.error.as_deref(), Some(READ_ONLY_MISMATCH));
        assert!(state.get_duck("r").is_none());
        // Same setting: shared as before.
        let mut twin = writer.clone();
        twin.id = "w2".into();
        state.set_config(twin.clone());
        assert_eq!(connect(twin, &state).await.unwrap().status, ConnectionStatus::Connected);
        disconnect("w", &state).await;
        disconnect("w2", &state).await;
        // With the writer gone, the read-only record opens the file itself.
        let alone = connect(reader, &state).await.unwrap();
        assert_eq!(alone.status, ConnectionStatus::Connected, "{:?}", alone.error);
        assert!(state.get_duck("r").unwrap().read_only);
        disconnect("r", &state).await;
        let _ = std::fs::remove_file(&path);
    }

    /// A file disconnected while something still holds its instance (an
    /// export) is found again by the next connect, never opened twice.
    #[tokio::test(flavor = "multi_thread")]
    async fn a_connect_while_the_file_is_closing_reuses_the_instance() {
        let path = temp("closing", "duckdb");
        let state = state_with("d", &path);
        state.request_duck_create_once("d");
        let config = state.get_config("d").unwrap();
        connect(config.clone(), &state).await.unwrap();
        let held = state.get_duck("d").unwrap(); // an export in flight
        disconnect("d", &state).await;
        assert!(state.get_duck("d").is_none());
        let again = connect(config.clone(), &state).await.unwrap();
        assert_eq!(again.status, ConnectionStatus::Connected, "{:?}", again.error);
        assert!(Arc::ptr_eq(&held, &state.get_duck("d").unwrap()), "the live instance is reused");
        disconnect("d", &state).await;
        drop(held);
        // Once nothing holds it, the file opens afresh.
        assert!(state.duck_still_closing(&normalized_path(&path)).is_none());
        let fresh = connect(config, &state).await.unwrap();
        assert_eq!(fresh.status, ConnectionStatus::Connected);
        disconnect("d", &state).await;
        let _ = std::fs::remove_file(&path);
    }

    /// A missing file is never created by a plain connect: the record's file
    /// may have moved. Only a connect that asked for a new database creates
    /// it, once.
    #[tokio::test(flavor = "multi_thread")]
    async fn connect_refuses_a_missing_file_unless_asked_to_create_it() {
        let path = temp("missing", "duckdb");
        let state = state_with("d", &path);
        let info = connect(state.get_config("d").unwrap(), &state).await.unwrap();
        assert_eq!(info.status, ConnectionStatus::Error);
        let message = info.error.unwrap_or_default();
        assert!(message.starts_with(crate::db::duckdb::MISSING_MARKER), "{message}");
        assert!(message.contains(&path), "{message}");
        assert!(!std::path::Path::new(&path).exists(), "no empty database in its place");

        state.request_duck_create_once("d");
        let created = connect(state.get_config("d").unwrap(), &state).await.unwrap();
        assert_eq!(created.status, ConnectionStatus::Connected, "{:?}", created.error);
        assert!(std::path::Path::new(&path).exists());
        disconnect("d", &state).await;
        assert!(!state.take_duck_create_once("d"), "the request is used up");

        // In-memory needs no file.
        let mem = state_with("m", IN_MEMORY);
        assert_eq!(connect(mem.get_config("m").unwrap(), &mem).await.unwrap().status, ConnectionStatus::Connected);
        let _ = std::fs::remove_file(&path);
    }

    /// An export has no deadline (as the PostgreSQL export): it finishes
    /// even when it runs longer than the statement timeout a card obeys.
    #[tokio::test(flavor = "multi_thread")]
    async fn an_export_ignores_the_statement_timeout() {
        let state = state_with("d", IN_MEMORY);
        let mut settings = (*state.settings()).clone();
        settings.query.timeout_seconds = 1;
        state.replace_settings(settings);
        connect(state.get_config("d").unwrap(), &state).await.unwrap();
        let slow = "SELECT count(DISTINCT hash(range) % 1000000007) AS n FROM range(150000000)";
        let started = Instant::now();
        let card = execute_query("d".into(), slow.into(), None, None, None, None, &state).await;
        assert!(card.unwrap_err().contains("timed out"), "a card obeys the timeout");
        let path = temp("slow", "csv");
        let exported = export_query(
            "d".into(),
            serde_json::from_value(serde_json::json!({ "sql": slow, "filePath": path, "format": "csv" })).unwrap(),
            &state,
            None,
        )
        .await
        .expect("the export runs to the end");
        assert_eq!(exported.rows_exported, 1);
        assert!(started.elapsed().as_secs_f64() > 1.0, "the export ran past the timeout");
        let _ = std::fs::remove_file(&path);
    }

    /// A table of an attached database exports as SQL INSERT into
    /// "schema"."table", never into one dotted identifier.
    #[tokio::test(flavor = "multi_thread")]
    async fn an_attached_table_exports_a_two_part_insert_target() {
        let state = state_with("d", IN_MEMORY);
        connect(state.get_config("d").unwrap(), &state).await.unwrap();
        execute_statement("d".into(), "ATTACH ':memory:' AS other; CREATE TABLE other.main.t AS SELECT 1 AS a".into(),
                          None, None, &state).await.unwrap();
        let path = temp("insert", "sql");
        export_table(
            "d".into(),
            serde_json::from_value(serde_json::json!({
                "schemaName": "other.main", "tableName": "t", "columns": [], "includeHeaders": true,
                "nullAsEmpty": true, "filePath": path, "format": "sqlInsert"
            }))
            .unwrap(),
            &state,
        )
        .await
        .unwrap();
        let text = std::fs::read_to_string(&path).unwrap();
        assert!(text.contains("INSERT INTO \"main\".\"t\""), "{text}");
        assert!(!text.contains("other.main"), "{text}");
        let _ = std::fs::remove_file(&path);
    }

    #[tokio::test(flavor = "multi_thread")]
    async fn a_postgres_only_command_says_so() {
        let state = state_with("d", IN_MEMORY);
        let err = state.require_pool("d").unwrap_err();
        assert_eq!(err, crate::state::DUCKDB_UNSUPPORTED_MESSAGE);
    }

    #[tokio::test(flavor = "multi_thread")]
    async fn test_does_not_create_or_change_the_file() {
        let path = temp("test", "duckdb");
        let state = state_with("d", &path);
        let r = test(state.get_config("d").unwrap(), Some(&state)).await.unwrap();
        assert!(r.success);
        assert!(!std::path::Path::new(&path).exists(), "Test must not create the file");
        let mut bad = state.get_config("d").unwrap();
        bad.database = "/no/such/dir/x.duckdb".into();
        assert!(!test(bad, None).await.unwrap().success);
    }

    #[tokio::test(flavor = "multi_thread")]
    async fn export_import_round_trip_and_clone() {
        let state = state_with("d", IN_MEMORY);
        connect(state.get_config("d").unwrap(), &state).await.unwrap();
        execute_statement(
            "d".into(),
            "CREATE TABLE src (id INTEGER NOT NULL, name VARCHAR, score DECIMAL(5,1)); \
             INSERT INTO src VALUES (1, 'a,b', 1.5), (2, NULL, NULL), (3, 'c', 3.0)"
                .into(),
            None,
            None,
            &state,
        )
        .await
        .unwrap();
        let csv_path = temp("export", "csv");
        let exported = export_table(
            "d".into(),
            serde_json::from_value(serde_json::json!({
                "schemaName": "main", "tableName": "src", "columns": [], "includeHeaders": true,
                "nullAsEmpty": true, "filePath": csv_path, "format": "csv"
            }))
            .unwrap(),
            &state,
        )
        .await
        .unwrap();
        assert_eq!(exported.rows_exported, 3);
        let text = std::fs::read_to_string(&csv_path).unwrap();
        assert_eq!(text, "id,name,score\n1,\"a,b\",1.5\n2,,\n3,c,3.0\n");

        clone_table(
            "d".into(),
            serde_json::from_value(serde_json::json!({
                "sourceSchema": "main", "sourceTable": "src", "targetSchema": "main", "targetTable": "dst", "includeData": false
            }))
            .unwrap(),
            &state,
        )
        .await
        .unwrap();
        let imported = import_csv(
            "d".into(),
            serde_json::from_value(serde_json::json!({
                "schemaName": "main", "tableName": "dst", "filePath": csv_path, "hasHeaders": true
            }))
            .unwrap(),
            &state,
        )
        .await
        .unwrap();
        assert_eq!(imported.rows_imported, 3);
        let r = execute_query("d".into(), "SELECT name FROM dst ORDER BY id".into(), None, None, None, None, &state).await.unwrap();
        assert_eq!(r.rows, vec![serde_json::json!(["a,b"]), serde_json::json!([null]), serde_json::json!(["c"])]);

        // Skip row: a value that does not cast is skipped, not fatal.
        std::fs::write(&csv_path, "id,name,score\n4,x,1\nnope,y,2\n").unwrap();
        let imported = import_csv(
            "d".into(),
            serde_json::from_value(serde_json::json!({
                "schemaName": "main", "tableName": "dst", "filePath": csv_path, "hasHeaders": true, "onError": "skipRow"
            }))
            .unwrap(),
            &state,
        )
        .await
        .unwrap();
        assert_eq!((imported.rows_imported, imported.rows_skipped), (1, 1));

        let parquet = temp("export", "parquet");
        let p = export_parquet("d".into(), "SELECT * FROM src".into(), None, parquet.clone(), &state).await.unwrap();
        assert_eq!(p.rows_exported, 3);
        let back = execute_query("d".into(), format!("SELECT count(*) FROM '{}'", parquet), None, None, None, None, &state).await.unwrap();
        assert_eq!(back.rows, vec![serde_json::json!(["3"])]);

        for (format, ext) in [(ExportFormat::Json, "json"), (ExportFormat::Xlsx, "xlsx"), (ExportFormat::SqlInsert, "sql"), (ExportFormat::Markdown, "md")] {
            let path = temp("export", ext);
            let options: ExportQueryOptions = serde_json::from_value(serde_json::json!({
                "sql": "SELECT * FROM src ORDER BY id", "schema": null, "filePath": path, "format": format
            }))
            .unwrap();
            let r = export_query("d".into(), options, &state, None).await.unwrap();
            assert_eq!(r.rows_exported, 3, "{ext}");
            if ext == "sql" {
                let text = std::fs::read_to_string(&path).unwrap();
                assert!(text.contains("VALUES (1, 'a,b', 1.5);"), "{text}");
            }
            let _ = std::fs::remove_file(&path);
        }
        let _ = std::fs::remove_file(&csv_path);
        let _ = std::fs::remove_file(&parquet);
    }
}
