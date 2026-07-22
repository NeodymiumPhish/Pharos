use rusqlite::{Connection, Result as SqliteResult};
use std::path::Path;

use crate::models::{AppSettings, ConnectionConfig, CreateSavedQuery, QueryHistoryEntry, SavedQuery, SslMode, UpdateSavedQuery};

// ==================== Compression Helpers ====================

fn compress_data(data: &str) -> Result<Vec<u8>, String> {
    use flate2::write::GzEncoder;
    use flate2::Compression;
    use std::io::Write;
    let mut encoder = GzEncoder::new(Vec::new(), Compression::fast());
    encoder.write_all(data.as_bytes()).map_err(|e| e.to_string())?;
    encoder.finish().map_err(|e| e.to_string())
}

fn decompress_or_passthrough(data: Vec<u8>) -> Result<String, String> {
    if data.len() >= 2 && data[0] == 0x1f && data[1] == 0x8b {
        // Gzip compressed data
        use flate2::read::GzDecoder;
        use std::io::Read;
        let mut decoder = GzDecoder::new(&data[..]);
        let mut result = String::new();
        decoder.read_to_string(&mut result).map_err(|e| e.to_string())?;
        Ok(result)
    } else {
        // Legacy uncompressed text
        String::from_utf8(data).map_err(|e| e.to_string())
    }
}

// ==================== FTS5 Helpers ====================

/// Escape user input for safe use in FTS5 MATCH queries.
/// Each token is quoted as a literal with prefix matching (*).
fn escape_fts5_query(input: &str) -> String {
    input
        .split_whitespace()
        .map(|word| {
            let escaped = word.replace('"', "\"\"");
            format!("\"{}\"*", escaped)
        })
        .collect::<Vec<_>>()
        .join(" ")
}

/// Resolve a workspace's display name. Custom names win; otherwise use the
/// first-queried connection name, suffixed with " +N" when N additional
/// distinct databases were queried in the same workspace.
pub fn resolve_workspace_name(
    name: Option<&str>,
    name_is_custom: bool,
    connection_name: &str,
    distinct_db_count: i64,
) -> String {
    if name_is_custom {
        if let Some(n) = name {
            if !n.is_empty() {
                return n.to_string();
            }
        }
    }
    let base = if connection_name.is_empty() { "Untitled" } else { connection_name };
    if distinct_db_count > 1 {
        format!("{} +{}", base, distinct_db_count - 1)
    } else {
        base.to_string()
    }
}

/// Given a workspace's cached results as (id, blob_bytes) ordered OLDEST-FIRST,
/// return the ids whose blobs must be dropped so the total is <= budget_bytes.
pub fn results_to_demote(sizes_oldest_first: &[(String, i64)], budget_bytes: i64) -> Vec<String> {
    let mut total: i64 = sizes_oldest_first.iter().map(|(_, sz)| *sz).sum();
    let mut demote = Vec::new();
    for (id, sz) in sizes_oldest_first {
        if total <= budget_bytes {
            break;
        }
        demote.push(id.clone());
        total -= *sz;
    }
    demote
}

/// Initialize the SQLite database and create tables if they don't exist
pub fn init_database(app_data_dir: &Path) -> SqliteResult<Connection> {
    std::fs::create_dir_all(app_data_dir).ok();
    let db_path = app_data_dir.join("pharos.db");

    let conn = Connection::open(&db_path)?;

    // Enable WAL mode for better concurrent read/write performance
    conn.execute_batch(
        "PRAGMA journal_mode=WAL;
         PRAGMA synchronous=NORMAL;
         PRAGMA busy_timeout=5000;"
    )?;

    // Create tables
    conn.execute_batch(
        r#"
        -- Connection configurations (passwords stored in OS keychain, not here)
        CREATE TABLE IF NOT EXISTS connections (
            id TEXT PRIMARY KEY,
            name TEXT NOT NULL,
            host TEXT NOT NULL,
            port INTEGER NOT NULL,
            database TEXT NOT NULL,
            username TEXT NOT NULL,
            ssl_mode TEXT NOT NULL DEFAULT 'prefer',
            sort_order INTEGER NOT NULL DEFAULT 0,
            created_at TEXT DEFAULT CURRENT_TIMESTAMP,
            updated_at TEXT DEFAULT CURRENT_TIMESTAMP
        );

        "#,
    )?;

    // Migration: Check if old schema with password column exists and migrate
    let has_password_column: bool = conn
        .prepare("SELECT COUNT(*) FROM pragma_table_info('connections') WHERE name = 'password'")?
        .query_row([], |row| row.get::<_, i64>(0))
        .map(|count| count > 0)
        .unwrap_or(false);

    if has_password_column {
        // Migrate: recreate table without password column
        conn.execute_batch(
            r#"
            -- Create new table without password column
            CREATE TABLE IF NOT EXISTS connections_new (
                id TEXT PRIMARY KEY,
                name TEXT NOT NULL,
                host TEXT NOT NULL,
                port INTEGER NOT NULL,
                database TEXT NOT NULL,
                username TEXT NOT NULL,
                ssl_mode TEXT NOT NULL DEFAULT 'prefer',
                sort_order INTEGER NOT NULL DEFAULT 0,
                created_at TEXT DEFAULT CURRENT_TIMESTAMP,
                updated_at TEXT DEFAULT CURRENT_TIMESTAMP
            );

            -- Copy data from old table (excluding password)
            INSERT OR IGNORE INTO connections_new (id, name, host, port, database, username, ssl_mode, sort_order, created_at, updated_at)
            SELECT id, name, host, port, database, username, COALESCE(ssl_mode, 'prefer'), 0, created_at, updated_at
            FROM connections;

            -- Drop old table and rename new one
            DROP TABLE connections;
            ALTER TABLE connections_new RENAME TO connections;
            "#,
        )?;
    } else {
        // Migration: Add ssl_mode column if it doesn't exist (for databases without password but missing ssl_mode)
        let has_ssl_mode: bool = conn
            .prepare("SELECT COUNT(*) FROM pragma_table_info('connections') WHERE name = 'ssl_mode'")?
            .query_row([], |row| row.get::<_, i64>(0))
            .map(|count| count > 0)
            .unwrap_or(false);

        if !has_ssl_mode {
            conn.execute(
                "ALTER TABLE connections ADD COLUMN ssl_mode TEXT NOT NULL DEFAULT 'prefer'",
                [],
            )?;
        }
    }

    // Migration: Add sort_order column if it doesn't exist
    let has_sort_order: bool = conn
        .prepare("SELECT COUNT(*) FROM pragma_table_info('connections') WHERE name = 'sort_order'")?
        .query_row([], |row| row.get::<_, i64>(0))
        .map(|count| count > 0)
        .unwrap_or(false);

    if !has_sort_order {
        conn.execute(
            "ALTER TABLE connections ADD COLUMN sort_order INTEGER NOT NULL DEFAULT 0",
            [],
        )?;
    }

    // Migration: Add color column if it doesn't exist
    let has_color: bool = conn
        .prepare("SELECT COUNT(*) FROM pragma_table_info('connections') WHERE name = 'color'")?
        .query_row([], |row| row.get::<_, i64>(0))
        .map(|count| count > 0)
        .unwrap_or(false);

    if !has_color {
        conn.execute(
            "ALTER TABLE connections ADD COLUMN color TEXT",
            [],
        )?;
    }

    // Migration: Add default_schema column if it doesn't exist
    let has_default_schema: bool = conn
        .prepare("SELECT COUNT(*) FROM pragma_table_info('connections') WHERE name = 'default_schema'")?
        .query_row([], |row| row.get::<_, i64>(0))
        .map(|count| count > 0)
        .unwrap_or(false);

    if !has_default_schema {
        conn.execute(
            "ALTER TABLE connections ADD COLUMN default_schema TEXT",
            [],
        )?;
    }

    conn.execute_batch(
        r#"

        -- Schema metadata cache
        CREATE TABLE IF NOT EXISTS schema_cache (
            connection_id TEXT NOT NULL,
            schema_name TEXT NOT NULL,
            updated_at TEXT DEFAULT CURRENT_TIMESTAMP,
            PRIMARY KEY (connection_id, schema_name),
            FOREIGN KEY (connection_id) REFERENCES connections(id) ON DELETE CASCADE
        );

        -- Table metadata cache
        CREATE TABLE IF NOT EXISTS table_cache (
            connection_id TEXT NOT NULL,
            schema_name TEXT NOT NULL,
            table_name TEXT NOT NULL,
            table_type TEXT NOT NULL,
            row_count_estimate INTEGER,
            updated_at TEXT DEFAULT CURRENT_TIMESTAMP,
            PRIMARY KEY (connection_id, schema_name, table_name),
            FOREIGN KEY (connection_id) REFERENCES connections(id) ON DELETE CASCADE
        );

        -- Column metadata cache
        CREATE TABLE IF NOT EXISTS column_cache (
            connection_id TEXT NOT NULL,
            schema_name TEXT NOT NULL,
            table_name TEXT NOT NULL,
            column_name TEXT NOT NULL,
            data_type TEXT NOT NULL,
            is_nullable INTEGER NOT NULL,
            is_primary_key INTEGER NOT NULL,
            ordinal_position INTEGER NOT NULL,
            column_default TEXT,
            updated_at TEXT DEFAULT CURRENT_TIMESTAMP,
            PRIMARY KEY (connection_id, schema_name, table_name, column_name),
            FOREIGN KEY (connection_id) REFERENCES connections(id) ON DELETE CASCADE
        );

        -- Saved queries
        CREATE TABLE IF NOT EXISTS saved_queries (
            id TEXT PRIMARY KEY,
            name TEXT NOT NULL,
            folder TEXT,
            sql TEXT NOT NULL,
            connection_id TEXT,
            variables TEXT,
            created_at TEXT DEFAULT CURRENT_TIMESTAMP,
            updated_at TEXT DEFAULT CURRENT_TIMESTAMP,
            FOREIGN KEY (connection_id) REFERENCES connections(id) ON DELETE SET NULL
        );

        -- App settings (single row)
        CREATE TABLE IF NOT EXISTS app_settings (
            id INTEGER PRIMARY KEY CHECK (id = 1),
            settings_json TEXT NOT NULL,
            updated_at TEXT DEFAULT CURRENT_TIMESTAMP
        );

        -- Query history
        CREATE TABLE IF NOT EXISTS query_history (
            id TEXT PRIMARY KEY,
            connection_id TEXT NOT NULL,
            connection_name TEXT NOT NULL,
            sql TEXT NOT NULL,
            row_count INTEGER,
            execution_time_ms INTEGER NOT NULL,
            executed_at TEXT NOT NULL
        );

        CREATE INDEX IF NOT EXISTS idx_query_history_executed_at
            ON query_history(executed_at DESC);

        CREATE INDEX IF NOT EXISTS idx_query_history_connection
            ON query_history(connection_id, executed_at DESC);

        -- FTS5 virtual table for full-text search on query history
        CREATE VIRTUAL TABLE IF NOT EXISTS query_history_fts USING fts5(
            sql,
            connection_name,
            content='query_history',
            content_rowid='rowid'
        );

        -- Triggers to keep FTS5 index in sync
        CREATE TRIGGER IF NOT EXISTS query_history_ai AFTER INSERT ON query_history BEGIN
            INSERT INTO query_history_fts(rowid, sql, connection_name)
            VALUES (new.rowid, new.sql, new.connection_name);
        END;

        CREATE TRIGGER IF NOT EXISTS query_history_ad AFTER DELETE ON query_history BEGIN
            INSERT INTO query_history_fts(query_history_fts, rowid, sql, connection_name)
            VALUES ('delete', old.rowid, old.sql, old.connection_name);
        END;

        -- Workspaces: one per editor-tab working session
        CREATE TABLE IF NOT EXISTS workspaces (
            id TEXT PRIMARY KEY,
            name TEXT,
            name_is_custom INTEGER NOT NULL DEFAULT 0,
            connection_id TEXT NOT NULL,
            connection_name TEXT NOT NULL,
            editor_text TEXT NOT NULL DEFAULT '',
            variables_json TEXT NOT NULL DEFAULT '[]',
            cursor_position INTEGER,
            created_at TEXT NOT NULL,
            last_activity_at TEXT NOT NULL
        );

        CREATE INDEX IF NOT EXISTS idx_workspaces_last_activity
            ON workspaces(last_activity_at DESC);
        "#,
    )?;

    // Migration: Add result storage columns to query_history
    let has_result_columns: bool = conn
        .prepare("SELECT COUNT(*) FROM pragma_table_info('query_history') WHERE name = 'result_columns'")?
        .query_row([], |row| row.get::<_, i64>(0))
        .map(|count| count > 0)
        .unwrap_or(false);

    if !has_result_columns {
        conn.execute_batch(
            "ALTER TABLE query_history ADD COLUMN result_columns TEXT;
             ALTER TABLE query_history ADD COLUMN result_rows TEXT;"
        )?;
    }

    // Migration: Add schema, column_count, table_names columns to query_history
    let has_schema_column: bool = conn
        .prepare("SELECT COUNT(*) FROM pragma_table_info('query_history') WHERE name = 'schema'")?
        .query_row([], |row| row.get::<_, i64>(0))
        .map(|count| count > 0)
        .unwrap_or(false);

    if !has_schema_column {
        conn.execute_batch(
            "ALTER TABLE query_history ADD COLUMN schema TEXT;
             ALTER TABLE query_history ADD COLUMN column_count INTEGER;
             ALTER TABLE query_history ADD COLUMN table_names TEXT;"
        )?;
    }

    // Migration: Add workspace association columns to query_history
    let has_workspace_col: bool = conn
        .prepare("SELECT COUNT(*) FROM pragma_table_info('query_history') WHERE name = 'workspace_id'")?
        .query_row([], |row| row.get::<_, i64>(0))
        .map(|count| count > 0)
        .unwrap_or(false);

    if !has_workspace_col {
        // Single execute_batch => one implicit transaction, so the column adds,
        // index, FTS table, and triggers all commit or fail as a unit. (If these
        // were split, a crash between them could leave the guard column present
        // but workspaces_fts missing, with no self-heal path.)
        conn.execute_batch(
            "ALTER TABLE query_history ADD COLUMN workspace_id TEXT;
             ALTER TABLE query_history ADD COLUMN result_order INTEGER;
             ALTER TABLE query_history ADD COLUMN color_index INTEGER;
             ALTER TABLE query_history ADD COLUMN custom_label TEXT;
             CREATE INDEX IF NOT EXISTS idx_query_history_workspace
                 ON query_history(workspace_id, result_order);
             CREATE VIRTUAL TABLE IF NOT EXISTS workspaces_fts USING fts5(
                 name, editor_text, content='workspaces', content_rowid='rowid'
             );
             CREATE TRIGGER IF NOT EXISTS workspaces_ai AFTER INSERT ON workspaces BEGIN
                 INSERT INTO workspaces_fts(rowid, name, editor_text)
                 VALUES (new.rowid, COALESCE(new.name,''), new.editor_text);
             END;
             CREATE TRIGGER IF NOT EXISTS workspaces_ad AFTER DELETE ON workspaces BEGIN
                 INSERT INTO workspaces_fts(workspaces_fts, rowid, name, editor_text)
                 VALUES ('delete', old.rowid, COALESCE(old.name,''), old.editor_text);
             END;
             CREATE TRIGGER IF NOT EXISTS workspaces_au AFTER UPDATE ON workspaces BEGIN
                 INSERT INTO workspaces_fts(workspaces_fts, rowid, name, editor_text)
                 VALUES ('delete', old.rowid, COALESCE(old.name,''), old.editor_text);
                 INSERT INTO workspaces_fts(rowid, name, editor_text)
                 VALUES (new.rowid, COALESCE(new.name,''), new.editor_text);
             END;"
        )?;
    }

    // Migration: Add chart view-state blob to query_history
    let has_chart_col: bool = conn
        .prepare("SELECT COUNT(*) FROM pragma_table_info('query_history') WHERE name = 'chart_view_state_json'")?
        .query_row([], |row| row.get::<_, i64>(0))
        .map(|count| count > 0)
        .unwrap_or(false);

    if !has_chart_col {
        conn.execute_batch(
            "ALTER TABLE query_history ADD COLUMN chart_view_state_json TEXT;"
        )?;
    }

    // Migration: Add source tag column to query_history (e.g. "chart-aggregation"
    // for push-down server-aggregation runs, so they stay labelled in the audit trail).
    let has_source_col: bool = conn
        .prepare("SELECT COUNT(*) FROM pragma_table_info('query_history') WHERE name = 'source'")?
        .query_row([], |row| row.get::<_, i64>(0))
        .map(|count| count > 0)
        .unwrap_or(false);

    if !has_source_col {
        conn.execute_batch(
            "ALTER TABLE query_history ADD COLUMN source TEXT;"
        )?;
    }

    // Migration: Add raw (pre-substitution, {{var}}-form) SQL column to query_history.
    // Holds the editor segment text used to re-locate a result's query for highlighting;
    // `sql` keeps the substituted text that actually ran. Migration-only (no base CREATE
    // entry), matching the convention of every other later column here.
    let has_raw_sql_col: bool = conn
        .prepare("SELECT COUNT(*) FROM pragma_table_info('query_history') WHERE name = 'raw_sql'")?
        .query_row([], |row| row.get::<_, i64>(0))
        .map(|count| count > 0)
        .unwrap_or(false);

    if !has_raw_sql_col {
        conn.execute_batch(
            "ALTER TABLE query_history ADD COLUMN raw_sql TEXT;"
        )?;
    }

    // Migration: Backfill FTS5 index if it's empty but history has data
    let fts_count: i64 = conn
        .query_row("SELECT COUNT(*) FROM query_history_fts", [], |row| row.get(0))
        .unwrap_or(0);
    let history_count: i64 = conn
        .query_row("SELECT COUNT(*) FROM query_history", [], |row| row.get(0))
        .unwrap_or(0);

    if fts_count == 0 && history_count > 0 {
        conn.execute_batch(
            "INSERT INTO query_history_fts(rowid, sql, connection_name)
             SELECT rowid, sql, connection_name FROM query_history;"
        )?;
    }

    // Migration: Add variables column to saved_queries if it doesn't exist
    let has_variables_column: bool = conn
        .prepare("SELECT COUNT(*) FROM pragma_table_info('saved_queries') WHERE name = 'variables'")?
        .query_row([], |row| row.get::<_, i64>(0))
        .map(|count| count > 0)
        .unwrap_or(false);

    if !has_variables_column {
        conn.execute("ALTER TABLE saved_queries ADD COLUMN variables TEXT", [])?;
    }

    Ok(conn)
}

/// Save a connection configuration to the database (password stored separately in keychain)
pub fn save_connection(conn: &Connection, config: &ConnectionConfig) -> SqliteResult<()> {
    // Get the next sort_order value for new connections
    let next_order: i32 = conn
        .query_row(
            "SELECT COALESCE(MAX(sort_order), -1) + 1 FROM connections",
            [],
            |row| row.get(0),
        )
        .unwrap_or(0);

    conn.execute(
        r#"
        INSERT INTO connections (id, name, host, port, database, username, ssl_mode, sort_order, color, default_schema, updated_at)
        VALUES (?1, ?2, ?3, ?4, ?5, ?6, ?7, ?8, ?9, ?10, CURRENT_TIMESTAMP)
        ON CONFLICT(id) DO UPDATE SET
            name = excluded.name,
            host = excluded.host,
            port = excluded.port,
            database = excluded.database,
            username = excluded.username,
            ssl_mode = excluded.ssl_mode,
            color = excluded.color,
            default_schema = excluded.default_schema,
            updated_at = CURRENT_TIMESTAMP
        "#,
        (
            &config.id,
            &config.name,
            &config.host,
            config.port,
            &config.database,
            &config.username,
            &config.ssl_mode.to_string(),
            next_order,
            &config.color,
            &config.default_schema,
        ),
    )?;
    Ok(())
}

/// Load all connection configurations from the database (passwords loaded from keychain separately)
pub fn load_connections(conn: &Connection) -> SqliteResult<Vec<ConnectionConfig>> {
    let mut stmt = conn.prepare(
        "SELECT id, name, host, port, database, username, COALESCE(ssl_mode, 'prefer') as ssl_mode, color, default_schema FROM connections ORDER BY sort_order, name",
    )?;

    let configs = stmt.query_map([], |row| {
        let ssl_mode_str: String = row.get(6)?;
        let ssl_mode = match ssl_mode_str.as_str() {
            "disable" => SslMode::Disable,
            "require" => SslMode::Require,
            _ => SslMode::Prefer,
        };
        Ok(ConnectionConfig {
            id: row.get(0)?,
            name: row.get(1)?,
            host: row.get(2)?,
            port: row.get(3)?,
            database: row.get(4)?,
            username: row.get(5)?,
            password: String::new(), // Password loaded from keychain separately
            ssl_mode,
            color: row.get(7)?,
            default_schema: row.get(8)?,
        })
    })?;

    configs.collect()
}

/// Delete a connection configuration from the database
pub fn delete_connection(conn: &Connection, connection_id: &str) -> SqliteResult<()> {
    conn.execute("DELETE FROM connections WHERE id = ?1", [connection_id])?;
    Ok(())
}

/// Persist a new ordering of connections. `ids` is the ordered list of
/// connection IDs (top-to-bottom in the UI); each row's sort_order is
/// rewritten to match its index in the slice. IDs not present in the slice
/// are left untouched, so callers should pass the full current list.
pub fn reorder_connections(conn: &mut Connection, ids: &[String]) -> SqliteResult<()> {
    let tx = conn.transaction()?;
    for (idx, id) in ids.iter().enumerate() {
        tx.execute(
            "UPDATE connections SET sort_order = ?1 WHERE id = ?2",
            (idx as i32, id),
        )?;
    }
    tx.commit()
}

// ==================== Saved Queries ====================

/// Create a new saved query
pub fn create_saved_query(conn: &Connection, id: &str, query: &CreateSavedQuery) -> SqliteResult<SavedQuery> {
    let now = chrono::Utc::now().to_rfc3339();

    conn.execute(
        r#"
        INSERT INTO saved_queries (id, name, folder, sql, connection_id, variables, created_at, updated_at)
        VALUES (?1, ?2, ?3, ?4, ?5, ?6, ?7, ?8)
        "#,
        (
            id,
            &query.name,
            &query.folder,
            &query.sql,
            &query.connection_id,
            &query.variables,
            &now,
            &now,
        ),
    )?;

    Ok(SavedQuery {
        id: id.to_string(),
        name: query.name.clone(),
        folder: query.folder.clone(),
        sql: query.sql.clone(),
        connection_id: query.connection_id.clone(),
        variables: query.variables.clone(),
        created_at: now.clone(),
        updated_at: now,
    })
}

/// Load all saved queries
pub fn load_saved_queries(conn: &Connection) -> SqliteResult<Vec<SavedQuery>> {
    let mut stmt = conn.prepare(
        "SELECT id, name, folder, sql, connection_id, created_at, updated_at, variables FROM saved_queries ORDER BY name",
    )?;

    let queries = stmt.query_map([], |row| {
        Ok(SavedQuery {
            id: row.get(0)?,
            name: row.get(1)?,
            folder: row.get(2)?,
            sql: row.get(3)?,
            connection_id: row.get(4)?,
            created_at: row.get(5)?,
            updated_at: row.get(6)?,
            variables: row.get(7)?,
        })
    })?;

    queries.collect()
}

/// Get a single saved query by ID
pub fn get_saved_query(conn: &Connection, query_id: &str) -> SqliteResult<Option<SavedQuery>> {
    let mut stmt = conn.prepare(
        "SELECT id, name, folder, sql, connection_id, created_at, updated_at, variables FROM saved_queries WHERE id = ?1",
    )?;

    let mut rows = stmt.query([query_id])?;

    if let Some(row) = rows.next()? {
        Ok(Some(SavedQuery {
            id: row.get(0)?,
            name: row.get(1)?,
            folder: row.get(2)?,
            sql: row.get(3)?,
            connection_id: row.get(4)?,
            created_at: row.get(5)?,
            updated_at: row.get(6)?,
            variables: row.get(7)?,
        }))
    } else {
        Ok(None)
    }
}

/// Update a saved query
pub fn update_saved_query(conn: &Connection, update: &UpdateSavedQuery) -> SqliteResult<Option<SavedQuery>> {
    let now = chrono::Utc::now().to_rfc3339();

    // Build dynamic update query based on which fields are provided
    let mut params: Vec<Box<dyn rusqlite::ToSql>> = vec![Box::new(now.clone())];

    if let Some(ref name) = update.name {
        params.push(Box::new(name.clone()));
    }
    if let Some(ref folder) = update.folder {
        params.push(Box::new(folder.clone()));
    }
    if let Some(ref sql) = update.sql {
        params.push(Box::new(sql.clone()));
    }
    if let Some(ref variables) = update.variables {
        params.push(Box::new(variables.clone()));
    }

    params.push(Box::new(update.id.clone()));

    // Build the SQL with proper placeholders
    let mut sql_parts = vec!["updated_at = ?1".to_string()];
    let mut idx = 2;
    if update.name.is_some() {
        sql_parts.push(format!("name = ?{}", idx));
        idx += 1;
    }
    if update.folder.is_some() {
        sql_parts.push(format!("folder = ?{}", idx));
        idx += 1;
    }
    if update.sql.is_some() {
        sql_parts.push(format!("sql = ?{}", idx));
        idx += 1;
    }
    if update.variables.is_some() {
        sql_parts.push(format!("variables = ?{}", idx));
        idx += 1;
    }

    let sql = format!(
        "UPDATE saved_queries SET {} WHERE id = ?{}",
        sql_parts.join(", "),
        idx
    );

    let params_refs: Vec<&dyn rusqlite::ToSql> = params.iter().map(|p| p.as_ref()).collect();
    conn.execute(&sql, params_refs.as_slice())?;

    get_saved_query(conn, &update.id)
}

/// Delete a saved query
pub fn delete_saved_query(conn: &Connection, query_id: &str) -> SqliteResult<bool> {
    let rows_affected = conn.execute("DELETE FROM saved_queries WHERE id = ?1", [query_id])?;
    Ok(rows_affected > 0)
}

/// Batch delete saved queries by IDs
pub fn batch_delete_saved_queries(conn: &Connection, ids: &[String]) -> SqliteResult<usize> {
    if ids.is_empty() {
        return Ok(0);
    }
    let placeholders: Vec<String> = (1..=ids.len()).map(|i| format!("?{}", i)).collect();
    let sql = format!(
        "DELETE FROM saved_queries WHERE id IN ({})",
        placeholders.join(", ")
    );
    let params: Vec<&dyn rusqlite::ToSql> =
        ids.iter().map(|id| id as &dyn rusqlite::ToSql).collect();
    conn.execute(&sql, params.as_slice())
}

// ==================== App Settings ====================

/// Load app settings from the database, returns default if none exist
pub fn load_settings(conn: &Connection) -> SqliteResult<AppSettings> {
    let mut stmt = conn.prepare("SELECT settings_json FROM app_settings WHERE id = 1")?;
    let mut rows = stmt.query([])?;

    if let Some(row) = rows.next()? {
        let json: String = row.get(0)?;
        match serde_json::from_str(&json) {
            Ok(settings) => Ok(settings),
            Err(_) => Ok(AppSettings::default()),
        }
    } else {
        Ok(AppSettings::default())
    }
}

/// Save app settings to the database
pub fn save_settings(conn: &Connection, settings: &AppSettings) -> SqliteResult<()> {
    let json = serde_json::to_string(settings).unwrap_or_else(|_| "{}".to_string());

    conn.execute(
        r#"
        INSERT INTO app_settings (id, settings_json, updated_at)
        VALUES (1, ?1, CURRENT_TIMESTAMP)
        ON CONFLICT(id) DO UPDATE SET
            settings_json = excluded.settings_json,
            updated_at = CURRENT_TIMESTAMP
        "#,
        [&json],
    )?;
    Ok(())
}

// ==================== Query History ====================

const HISTORY_RETENTION_DAYS: i64 = 90;

/// Save a query history entry with optional cached results (and prune entries older than 90 days)
pub fn save_query_history(
    conn: &Connection,
    entry: &QueryHistoryEntry,
    result_columns_json: Option<&str>,
    result_rows_json: Option<&str>,
) -> SqliteResult<()> {
    // Compress result data if present
    let compressed_columns = result_columns_json.and_then(|s| compress_data(s).ok());
    let compressed_rows = result_rows_json.and_then(|s| compress_data(s).ok());

    conn.execute(
        r#"
        INSERT INTO query_history (id, connection_id, connection_name, sql, row_count, execution_time_ms, executed_at, result_columns, result_rows, schema, column_count, table_names, source)
        VALUES (?1, ?2, ?3, ?4, ?5, ?6, ?7, ?8, ?9, ?10, ?11, ?12, ?13)
        "#,
        (
            &entry.id,
            &entry.connection_id,
            &entry.connection_name,
            &entry.sql,
            &entry.row_count,
            entry.execution_time_ms,
            &entry.executed_at,
            &compressed_columns.as_deref(),
            &compressed_rows.as_deref(),
            &entry.schema,
            &entry.column_count,
            &entry.table_names,
            &entry.source,
        ),
    )?;

    // Prune old entries roughly every 100 queries to reduce write overhead
    use std::sync::atomic::{AtomicU32, Ordering};
    static PRUNE_COUNTER: AtomicU32 = AtomicU32::new(0);
    if PRUNE_COUNTER.fetch_add(1, Ordering::Relaxed) % 100 == 0 {
        let cutoff = format!("-{} days", HISTORY_RETENTION_DAYS);
        // Drop stale workspaces (by last activity) and their children.
        conn.execute(
            "DELETE FROM query_history WHERE workspace_id IN
                (SELECT id FROM workspaces WHERE datetime(last_activity_at) < datetime('now', ?1))",
            [&cutoff],
        )?;
        conn.execute(
            "DELETE FROM workspaces WHERE datetime(last_activity_at) < datetime('now', ?1)",
            [&cutoff],
        )?;
        // Drop stale legacy (workspace_id IS NULL) rows by their own executed_at.
        conn.execute(
            "DELETE FROM query_history WHERE workspace_id IS NULL AND datetime(executed_at) < datetime('now', ?1)",
            [&cutoff],
        )?;
    }

    Ok(())
}

/// Create or update a workspace. Connection identity + created_at are set only
/// on first insert. Editor snapshot fields are always refreshed. A non-custom
/// upsert never overwrites an existing custom name.
pub fn upsert_workspace(conn: &Connection, w: &crate::models::WorkspaceUpsert) -> SqliteResult<()> {
    let now = chrono::Utc::now().to_rfc3339();
    conn.execute(
        r#"
        INSERT INTO workspaces
            (id, name, name_is_custom, connection_id, connection_name,
             editor_text, variables_json, cursor_position, created_at, last_activity_at)
        VALUES (?1, ?2, ?3, ?4, ?5, ?6, ?7, ?8, ?9, ?9)
        ON CONFLICT(id) DO UPDATE SET
            editor_text = excluded.editor_text,
            variables_json = excluded.variables_json,
            cursor_position = excluded.cursor_position,
            last_activity_at = excluded.last_activity_at,
            name = CASE WHEN excluded.name_is_custom = 1 THEN excluded.name ELSE workspaces.name END,
            name_is_custom = CASE WHEN excluded.name_is_custom = 1 THEN 1 ELSE workspaces.name_is_custom END
        "#,
        (
            &w.id,
            &w.name,
            &(w.name_is_custom as i64),
            &w.connection_id,
            &w.connection_name,
            &w.editor_text,
            &w.variables_json,
            &w.cursor_position,
            &now,
        ),
    )?;
    Ok(())
}

const WORKSPACE_BUDGET_BYTES: i64 = 100 * 1024 * 1024; // 100 MB compressed

/// Stamp a query_history row with its workspace association + result-tab display
/// metadata, then enforce the per-workspace blob budget by demoting oldest cached
/// results to "SQL only".
pub fn associate_result_to_workspace(
    conn: &Connection,
    history_id: &str,
    workspace_id: &str,
    result_order: i64,
    color_index: i64,
) -> SqliteResult<()> {
    conn.execute(
        "UPDATE query_history SET workspace_id = ?1, result_order = ?2, color_index = ?3 WHERE id = ?4",
        (workspace_id, result_order, color_index, history_id),
    )?;
    enforce_workspace_budget(conn, workspace_id)?;
    Ok(())
}

/// Drop cached blobs from the oldest results in a workspace until the total
/// compressed blob size is within WORKSPACE_BUDGET_BYTES. Rows are kept (SQL only).
pub fn enforce_workspace_budget(conn: &Connection, workspace_id: &str) -> SqliteResult<()> {
    let mut stmt = conn.prepare(
        "SELECT id, COALESCE(LENGTH(result_columns),0) + COALESCE(LENGTH(result_rows),0) AS sz
         FROM query_history
         WHERE workspace_id = ?1 AND result_columns IS NOT NULL
         ORDER BY result_order ASC, executed_at ASC",
    )?;
    let sizes: Vec<(String, i64)> = stmt
        .query_map([workspace_id], |row| Ok((row.get::<_, String>(0)?, row.get::<_, i64>(1)?)))?
        .collect::<SqliteResult<Vec<_>>>()?;

    for id in results_to_demote(&sizes, WORKSPACE_BUDGET_BYTES) {
        conn.execute(
            "UPDATE query_history SET result_columns = NULL, result_rows = NULL WHERE id = ?1",
            [&id],
        )?;
    }
    Ok(())
}

/// Load workspace summaries, newest activity first. When `search` is set, a
/// workspace matches if its name/editor_text match OR any child query SQL matches.
pub fn load_workspaces(
    conn: &Connection,
    search: Option<&str>,
    limit: i64,
    offset: i64,
) -> SqliteResult<Vec<crate::models::WorkspaceSummary>> {
    let mut sql = String::from(
        "SELECT w.id, w.name, w.name_is_custom, w.connection_name, w.last_activity_at,
                (SELECT COUNT(*) FROM query_history qh WHERE qh.workspace_id = w.id) AS query_count,
                (SELECT COUNT(DISTINCT qh.connection_id) FROM query_history qh WHERE qh.workspace_id = w.id) AS distinct_db_count
         FROM workspaces w WHERE 1=1",
    );
    let mut params: Vec<Box<dyn rusqlite::ToSql>> = Vec::new();
    let mut idx = 1;

    if let Some(q) = search {
        if !q.is_empty() {
            let escaped = escape_fts5_query(q);
            sql.push_str(&format!(
                " AND (w.rowid IN (SELECT rowid FROM workspaces_fts WHERE workspaces_fts MATCH ?{i})
                       OR w.id IN (SELECT qh.workspace_id FROM query_history qh
                                   WHERE qh.workspace_id IS NOT NULL
                                     AND qh.rowid IN (SELECT rowid FROM query_history_fts WHERE query_history_fts MATCH ?{i})))",
                i = idx
            ));
            params.push(Box::new(escaped));
            idx += 1;
        }
    }

    sql.push_str(&format!(" ORDER BY w.last_activity_at DESC LIMIT ?{} OFFSET ?{}", idx, idx + 1));
    params.push(Box::new(limit));
    params.push(Box::new(offset));

    let params_refs: Vec<&dyn rusqlite::ToSql> = params.iter().map(|p| p.as_ref()).collect();
    let mut stmt = conn.prepare(&sql)?;
    let rows = stmt.query_map(params_refs.as_slice(), |row| {
        let name: Option<String> = row.get(1)?;
        let name_is_custom: i64 = row.get(2)?;
        let connection_name: String = row.get(3)?;
        let distinct_db_count: i64 = row.get(6)?;
        Ok(crate::models::WorkspaceSummary {
            id: row.get(0)?,
            name: resolve_workspace_name(name.as_deref(), name_is_custom != 0, &connection_name, distinct_db_count),
            connection_name,
            distinct_db_count,
            query_count: row.get(5)?,
            last_activity_at: row.get(4)?,
        })
    })?;
    rows.collect()
}

/// Load a workspace with its ordered child results (metadata only; blobs are
/// fetched per-result via get_query_history_result).
pub fn load_workspace(conn: &Connection, id: &str) -> SqliteResult<Option<crate::models::WorkspaceDetail>> {
    let head = conn.query_row(
        "SELECT id, name, name_is_custom, connection_id, connection_name, editor_text, variables_json, cursor_position
         FROM workspaces WHERE id = ?1",
        [id],
        |row| {
            let name: Option<String> = row.get(1)?;
            let name_is_custom: i64 = row.get(2)?;
            let connection_name: String = row.get(4)?;
            Ok((
                row.get::<_, String>(0)?,
                resolve_workspace_name(name.as_deref(), name_is_custom != 0, &connection_name, 1),
                row.get::<_, String>(3)?,
                connection_name,
                row.get::<_, String>(5)?,
                row.get::<_, String>(6)?,
                row.get::<_, Option<i64>>(7)?,
            ))
        },
    );

    let (wid, resolved_name, connection_id, connection_name, editor_text, variables_json, cursor_position) =
        match head {
            Ok(v) => v,
            Err(rusqlite::Error::QueryReturnedNoRows) => return Ok(None),
            Err(e) => return Err(e),
        };

    let mut stmt = conn.prepare(
        "SELECT id, sql, result_order, color_index, custom_label, row_count, column_count,
                schema, table_names, (result_columns IS NOT NULL) AS has_results,
                execution_time_ms, executed_at, chart_view_state_json
         FROM query_history WHERE workspace_id = ?1
         ORDER BY result_order ASC, executed_at ASC",
    )?;
    let results = stmt
        .query_map([id], |row| {
            Ok(crate::models::WorkspaceResultMeta {
                id: row.get(0)?,
                sql: row.get(1)?,
                result_order: row.get(2)?,
                color_index: row.get(3)?,
                custom_label: row.get(4)?,
                row_count: row.get(5)?,
                column_count: row.get(6)?,
                schema: row.get(7)?,
                table_names: row.get(8)?,
                has_results: row.get(9)?,
                execution_time_ms: row.get(10)?,
                executed_at: row.get(11)?,
                chart_view_state_json: row.get(12)?,
            })
        })?
        .collect::<SqliteResult<Vec<_>>>()?;

    Ok(Some(crate::models::WorkspaceDetail {
        id: wid,
        name: resolved_name,
        connection_id,
        connection_name,
        editor_text,
        variables_json,
        cursor_position,
        results,
    }))
}

/// Rename a workspace (sets it custom so auto-naming stops overriding it). Also
/// bumps last_activity_at so a workspace the user deliberately renamed to keep
/// isn't pruned out from under them at the retention horizon.
pub fn rename_workspace(conn: &Connection, id: &str, name: &str) -> SqliteResult<bool> {
    let now = chrono::Utc::now().to_rfc3339();
    let n = conn.execute(
        "UPDATE workspaces SET name = ?1, name_is_custom = 1, last_activity_at = ?3 WHERE id = ?2",
        (name, id, &now),
    )?;
    Ok(n > 0)
}

/// Delete a workspace and cascade-delete its child results.
pub fn delete_workspace(conn: &Connection, id: &str) -> SqliteResult<bool> {
    conn.execute("DELETE FROM query_history WHERE workspace_id = ?1", [id])?;
    let n = conn.execute("DELETE FROM workspaces WHERE id = ?1", [id])?;
    Ok(n > 0)
}

/// Delete a single child result from a workspace.
pub fn delete_workspace_result(conn: &Connection, result_id: &str) -> SqliteResult<bool> {
    let n = conn.execute(
        "DELETE FROM query_history WHERE id = ?1 AND workspace_id IS NOT NULL",
        [result_id],
    )?;
    Ok(n > 0)
}

/// Update a child result's display metadata (custom label and/or color index).
pub fn update_result_meta(
    conn: &Connection,
    result_id: &str,
    custom_label: Option<&str>,
    color_index: Option<i64>,
) -> SqliteResult<bool> {
    let n = conn.execute(
        "UPDATE query_history
         SET custom_label = COALESCE(?2, custom_label),
             color_index  = COALESCE(?3, color_index)
         WHERE id = ?1",
        (result_id, custom_label, color_index),
    )?;
    Ok(n > 0)
}

/// Persist a chart view-state JSON blob (view mode + chart config) for a result.
pub fn update_result_chart_state(
    conn: &Connection,
    result_id: &str,
    json: &str,
) -> SqliteResult<bool> {
    let n = conn.execute(
        "UPDATE query_history SET chart_view_state_json = ?2 WHERE id = ?1",
        (result_id, json),
    )?;
    Ok(n > 0)
}

/// Duplicate a workspace (new id) including its children and cached blobs.
/// Returns the new workspace id.
pub fn duplicate_workspace(conn: &Connection, id: &str) -> SqliteResult<Option<String>> {
    let exists: bool = conn
        .query_row("SELECT COUNT(*) FROM workspaces WHERE id = ?1", [id], |r| r.get::<_, i64>(0))
        .map(|c| c > 0)
        .unwrap_or(false);
    if !exists {
        return Ok(None);
    }
    let new_id = uuid::Uuid::new_v4().to_string();
    let now = chrono::Utc::now().to_rfc3339();
    conn.execute(
        "INSERT INTO workspaces
            (id, name, name_is_custom, connection_id, connection_name, editor_text, variables_json, cursor_position, created_at, last_activity_at)
         SELECT ?1,
                CASE WHEN name IS NULL THEN NULL ELSE name || ' (copy)' END,
                name_is_custom, connection_id, connection_name, editor_text, variables_json, cursor_position, ?2, ?2
         FROM workspaces WHERE id = ?3",
        (&new_id, &now, id),
    )?;
    // Copy children with fresh ids, preserving order/blobs/metadata.
    let mut stmt = conn.prepare(
        "SELECT connection_id, connection_name, sql, row_count, execution_time_ms, executed_at,
                result_columns, result_rows, schema, column_count, table_names,
                result_order, color_index, custom_label
         FROM query_history WHERE workspace_id = ?1 ORDER BY result_order ASC, executed_at ASC",
    )?;
    let rows: Vec<_> = stmt
        .query_map([id], |r| {
            Ok((
                r.get::<_, String>(0)?, r.get::<_, String>(1)?, r.get::<_, String>(2)?,
                r.get::<_, Option<i64>>(3)?, r.get::<_, i64>(4)?, r.get::<_, String>(5)?,
                r.get::<_, Option<Vec<u8>>>(6)?, r.get::<_, Option<Vec<u8>>>(7)?,
                r.get::<_, Option<String>>(8)?, r.get::<_, Option<i64>>(9)?, r.get::<_, Option<String>>(10)?,
                r.get::<_, Option<i64>>(11)?, r.get::<_, Option<i64>>(12)?, r.get::<_, Option<String>>(13)?,
            ))
        })?
        .collect::<SqliteResult<Vec<_>>>()?;
    for row in rows {
        let child_id = uuid::Uuid::new_v4().to_string();
        conn.execute(
            "INSERT INTO query_history
                (id, connection_id, connection_name, sql, row_count, execution_time_ms, executed_at,
                 result_columns, result_rows, schema, column_count, table_names,
                 workspace_id, result_order, color_index, custom_label)
             VALUES (?1,?2,?3,?4,?5,?6,?7,?8,?9,?10,?11,?12,?13,?14,?15,?16)",
            (
                &child_id, &row.0, &row.1, &row.2, &row.3, &row.4, &row.5,
                &row.6, &row.7, &row.8, &row.9, &row.10,
                &new_id, &row.11, &row.12, &row.13,
            ),
        )?;
    }
    Ok(Some(new_id))
}

/// Load query history entries with optional filters
pub fn load_query_history(
    conn: &Connection,
    connection_id: Option<&str>,
    search: Option<&str>,
    limit: i64,
    offset: i64,
    only_legacy: bool,
) -> SqliteResult<Vec<QueryHistoryEntry>> {
    let mut sql = String::from(
        "SELECT id, connection_id, connection_name, sql, row_count, execution_time_ms, executed_at, (result_columns IS NOT NULL) as has_results, schema, column_count, table_names, source FROM query_history WHERE 1=1"
    );
    let mut params: Vec<Box<dyn rusqlite::ToSql>> = Vec::new();
    let mut param_idx = 1;

    if only_legacy {
        sql.push_str(" AND workspace_id IS NULL");
    }

    if let Some(cid) = connection_id {
        sql.push_str(&format!(" AND connection_id = ?{}", param_idx));
        params.push(Box::new(cid.to_string()));
        param_idx += 1;
    }

    if let Some(q) = search {
        if !q.is_empty() {
            let escaped = escape_fts5_query(q);
            sql.push_str(&format!(
                " AND rowid IN (SELECT rowid FROM query_history_fts WHERE query_history_fts MATCH ?{})",
                param_idx
            ));
            params.push(Box::new(escaped));
            param_idx += 1;
        }
    }

    sql.push_str(&format!(" ORDER BY executed_at DESC LIMIT ?{} OFFSET ?{}", param_idx, param_idx + 1));
    params.push(Box::new(limit));
    params.push(Box::new(offset));

    let params_refs: Vec<&dyn rusqlite::ToSql> = params.iter().map(|p| p.as_ref()).collect();

    let mut stmt = conn.prepare(&sql)?;
    let entries = stmt.query_map(params_refs.as_slice(), |row| {
        Ok(QueryHistoryEntry {
            id: row.get(0)?,
            connection_id: row.get(1)?,
            connection_name: row.get(2)?,
            sql: row.get(3)?,
            row_count: row.get(4)?,
            execution_time_ms: row.get(5)?,
            executed_at: row.get(6)?,
            has_results: row.get(7)?,
            schema: row.get(8)?,
            column_count: row.get(9)?,
            table_names: row.get(10)?,
            source: row.get(11)?,
        })
    })?;

    entries.collect()
}

/// Delete a single query history entry
pub fn delete_query_history_entry(conn: &Connection, entry_id: &str) -> SqliteResult<bool> {
    let rows_affected = conn.execute("DELETE FROM query_history WHERE id = ?1", [entry_id])?;
    Ok(rows_affected > 0)
}

/// Batch delete query history entries by IDs
pub fn batch_delete_query_history_entries(conn: &Connection, ids: &[String]) -> SqliteResult<usize> {
    if ids.is_empty() {
        return Ok(0);
    }
    let placeholders: Vec<String> = (1..=ids.len()).map(|i| format!("?{}", i)).collect();
    let sql = format!(
        "DELETE FROM query_history WHERE id IN ({})",
        placeholders.join(", ")
    );
    let params: Vec<&dyn rusqlite::ToSql> =
        ids.iter().map(|id| id as &dyn rusqlite::ToSql).collect();
    conn.execute(&sql, params.as_slice())
}

/// Load cached result data for a specific history entry (decompresses if gzip-compressed)
pub fn get_query_history_result(conn: &Connection, entry_id: &str) -> SqliteResult<Option<(String, String)>> {
    let mut stmt = conn.prepare(
        "SELECT result_columns, result_rows FROM query_history WHERE id = ?1 AND result_columns IS NOT NULL"
    )?;
    let mut rows = stmt.query([entry_id])?;
    if let Some(row) = rows.next()? {
        let columns_raw: Vec<u8> = row.get(0)?;
        let rows_raw: Vec<u8> = row.get(1)?;
        let columns = decompress_or_passthrough(columns_raw)
            .map_err(|e| rusqlite::Error::ToSqlConversionFailure(Box::new(std::io::Error::new(std::io::ErrorKind::InvalidData, e))))?;
        let rows_str = decompress_or_passthrough(rows_raw)
            .map_err(|e| rusqlite::Error::ToSqlConversionFailure(Box::new(std::io::Error::new(std::io::ErrorKind::InvalidData, e))))?;
        Ok(Some((columns, rows_str)))
    } else {
        Ok(None)
    }
}

#[cfg(test)]
mod workspace_name_tests {
    use super::resolve_workspace_name;

    #[test]
    fn custom_name_wins() {
        assert_eq!(resolve_workspace_name(Some("My Analysis"), true, "prod-db", 3), "My Analysis");
    }
    #[test]
    fn single_db_uses_connection_name() {
        assert_eq!(resolve_workspace_name(None, false, "prod-db", 1), "prod-db");
    }
    #[test]
    fn multi_db_appends_plus_n() {
        assert_eq!(resolve_workspace_name(None, false, "prod-db", 3), "prod-db +2");
    }
    #[test]
    fn zero_dbs_falls_back_to_connection_name() {
        assert_eq!(resolve_workspace_name(None, false, "prod-db", 0), "prod-db");
    }
    #[test]
    fn empty_connection_name_is_untitled() {
        assert_eq!(resolve_workspace_name(None, false, "", 1), "Untitled");
    }
    #[test]
    fn custom_but_empty_falls_back() {
        assert_eq!(resolve_workspace_name(Some(""), true, "prod-db", 1), "prod-db");
    }
}

#[cfg(test)]
mod budget_tests {
    use super::results_to_demote;

    fn ids(v: &[&str]) -> Vec<String> { v.iter().map(|s| s.to_string()).collect() }

    #[test]
    fn under_budget_demotes_nothing() {
        let sizes = vec![("a".into(), 10i64), ("b".into(), 20)];
        assert_eq!(results_to_demote(&sizes, 100), Vec::<String>::new());
    }
    #[test]
    fn demotes_oldest_first_until_under_budget() {
        let sizes = vec![("a".into(), 50i64), ("b".into(), 40), ("c".into(), 30)];
        assert_eq!(results_to_demote(&sizes, 100), ids(&["a"]));
    }
    #[test]
    fn demotes_multiple_when_needed() {
        let sizes = vec![("a".into(), 60i64), ("b".into(), 60), ("c".into(), 60)];
        assert_eq!(results_to_demote(&sizes, 100), ids(&["a", "b"]));
    }
    #[test]
    fn exactly_at_budget_demotes_nothing() {
        let sizes = vec![("a".into(), 100i64)];
        assert_eq!(results_to_demote(&sizes, 100), Vec::<String>::new());
    }
}

/// Real SQLite round-trip tests for the workspace storage layer: init_database
/// creates a real on-disk DB, and every assertion here reads back through the
/// actual rusqlite row -> struct decode path (not hand-built structs), per the
/// project lesson that pure composer tests miss decode bugs.
#[cfg(test)]
mod workspace_roundtrip_tests {
    use super::*;
    use crate::models::WorkspaceUpsert;
    use std::path::PathBuf;

    /// Unique temp dir per test so parallel `cargo test` runs never collide.
    fn temp_db_dir(tag: &str) -> PathBuf {
        std::env::temp_dir().join(format!("pharos_test_{}_{}", tag, uuid::Uuid::new_v4()))
    }

    /// Real "now" (offset by a few seconds for ordering) so entries never trip
    /// the 90-day retention prune that save_query_history runs periodically.
    fn now_offset(seconds: i64) -> String {
        (chrono::Utc::now() + chrono::Duration::seconds(seconds)).to_rfc3339()
    }

    fn history_entry(id: &str, connection_id: &str, connection_name: &str, executed_at: &str) -> QueryHistoryEntry {
        QueryHistoryEntry {
            id: id.to_string(),
            connection_id: connection_id.to_string(),
            connection_name: connection_name.to_string(),
            sql: format!("SELECT * FROM t_{}", id),
            row_count: Some(3),
            execution_time_ms: 12,
            executed_at: executed_at.to_string(),
            has_results: false, // not written by save_query_history; derived on read
            schema: Some("public".to_string()),
            column_count: Some(2),
            table_names: Some("t".to_string()),
            source: None,
        }
    }

    #[test]
    fn workspace_full_lifecycle_roundtrip() {
        let dir = temp_db_dir("workspace_full");
        let conn = init_database(&dir).expect("init_database");

        // 1 + 2. Upsert workspace, connection "prod-db".
        let ws = WorkspaceUpsert {
            id: "ws1".to_string(),
            name: None,
            name_is_custom: false,
            connection_id: "c1".to_string(),
            connection_name: "prod-db".to_string(),
            editor_text: "SELECT 1".to_string(),
            variables_json: r#"[{"id":"v1","name":"x","value":"1","type":"literal"}]"#.to_string(),
            cursor_position: Some(5),
        };
        upsert_workspace(&conn, &ws).expect("upsert_workspace");

        // 3. Two history rows on distinct connections; only h1 gets a cached blob.
        let h1 = history_entry("h1", "c1", "prod-db", &now_offset(0));
        let h2 = history_entry("h2", "c2", "other-db", &now_offset(1));
        save_query_history(&conn, &h1, Some(r#"[{"name":"id"}]"#), Some(r#"[[1]]"#)).expect("save h1");
        save_query_history(&conn, &h2, None, None).expect("save h2");
        associate_result_to_workspace(&conn, "h1", "ws1", 0, 0).expect("associate h1");
        associate_result_to_workspace(&conn, "h2", "ws1", 1, 1).expect("associate h2");

        // 4. load_workspaces: resolved name ("prod-db +1" for 2 distinct dbs),
        // query_count, distinct_db_count all come back through the real decode.
        let summaries = load_workspaces(&conn, None, 50, 0).expect("load_workspaces");
        let summary = summaries.iter().find(|s| s.id == "ws1").expect("ws1 present in summaries");
        assert_eq!(summary.name, "prod-db +1");
        assert_eq!(summary.query_count, 2);
        assert_eq!(summary.distinct_db_count, 2);

        // 5. load_workspace: editor snapshot verbatim + ordered, correctly-decoded children.
        let detail = load_workspace(&conn, "ws1").expect("load_workspace").expect("ws1 exists");
        assert_eq!(detail.id, "ws1");
        assert_eq!(detail.connection_id, "c1");
        assert_eq!(detail.connection_name, "prod-db");
        assert_eq!(detail.editor_text, "SELECT 1");
        assert_eq!(detail.variables_json, ws.variables_json);
        assert_eq!(detail.cursor_position, Some(5));
        assert_eq!(detail.results.len(), 2);

        let r0 = &detail.results[0];
        assert_eq!(r0.id, "h1");
        assert_eq!(r0.sql, h1.sql);
        assert_eq!(r0.result_order, Some(0));
        assert_eq!(r0.color_index, Some(0));
        assert!(r0.has_results, "h1 was saved with a cached blob");
        assert_eq!(r0.row_count, Some(3));
        assert_eq!(r0.column_count, Some(2));
        assert_eq!(r0.schema.as_deref(), Some("public"));
        assert_eq!(r0.table_names.as_deref(), Some("t"));
        assert_eq!(r0.execution_time_ms, 12);
        assert_eq!(r0.executed_at, h1.executed_at);

        let r1 = &detail.results[1];
        assert_eq!(r1.id, "h2");
        assert_eq!(r1.result_order, Some(1));
        assert!(!r1.has_results, "h2 was saved without a cached blob");

        // 6. rename_workspace: custom name wins over auto-resolved name.
        assert!(rename_workspace(&conn, "ws1", "My WS").expect("rename_workspace"));
        let summaries2 = load_workspaces(&conn, None, 50, 0).expect("load_workspaces after rename");
        let summary2 = summaries2.iter().find(|s| s.id == "ws1").expect("ws1 present after rename");
        assert_eq!(summary2.name, "My WS");

        // 7. delete_workspace: cascades to child query_history rows.
        assert!(delete_workspace(&conn, "ws1").expect("delete_workspace"));
        assert!(load_workspace(&conn, "ws1").expect("load_workspace after delete").is_none());
        let remaining_children: i64 = conn
            .query_row("SELECT COUNT(*) FROM query_history WHERE workspace_id = 'ws1'", [], |r| r.get(0))
            .expect("count remaining children");
        assert_eq!(remaining_children, 0);

        drop(conn);
        let _ = std::fs::remove_dir_all(&dir);
    }

    #[test]
    fn enforce_workspace_budget_demotes_oldest_over_budget() {
        let dir = temp_db_dir("workspace_budget");
        let conn = init_database(&dir).expect("init_database");

        let ws = WorkspaceUpsert {
            id: "ws2".to_string(),
            name: None,
            name_is_custom: false,
            connection_id: "c1".to_string(),
            connection_name: "prod-db".to_string(),
            editor_text: String::new(),
            variables_json: "[]".to_string(),
            cursor_position: None,
        };
        upsert_workspace(&conn, &ws).expect("upsert_workspace");

        for (i, id) in ["h3", "h4", "h5"].iter().enumerate() {
            let entry = history_entry(id, "c1", "prod-db", &now_offset(i as i64));
            save_query_history(&conn, &entry, Some("[]"), Some("[]")).expect("save history row");
            associate_result_to_workspace(&conn, id, "ws2", i as i64, 0).expect("associate");
        }

        // Overwrite with large blobs (bypassing gzip so sizes are exact) to exercise
        // the real byte-budget SQL: 50MB/40MB/30MB, sum 120MB > 100MB budget, so the
        // oldest (result_order 0) should be demoted, leaving 70MB which fits.
        let blob = |mb: usize| vec![b'a'; mb * 1024 * 1024];
        for (id, mb) in [("h3", 50usize), ("h4", 40), ("h5", 30)] {
            conn.execute(
                "UPDATE query_history SET result_columns = ?1, result_rows = ?2 WHERE id = ?3",
                (blob(mb), Vec::<u8>::new(), id),
            )
            .expect("seed oversized blob");
        }

        enforce_workspace_budget(&conn, "ws2").expect("enforce_workspace_budget");

        let mut stmt = conn
            .prepare("SELECT id, result_columns IS NOT NULL FROM query_history WHERE workspace_id = 'ws2' ORDER BY result_order ASC")
            .expect("prepare");
        let rows: Vec<(String, bool)> = stmt
            .query_map([], |r| Ok((r.get::<_, String>(0)?, r.get::<_, bool>(1)?)))
            .expect("query_map")
            .collect::<SqliteResult<Vec<_>>>()
            .expect("collect");

        assert_eq!(rows[0], ("h3".to_string(), false), "oldest over-budget result should be demoted");
        assert_eq!(rows[1], ("h4".to_string(), true));
        assert_eq!(rows[2], ("h5".to_string(), true));

        drop(stmt);
        drop(conn);
        let _ = std::fs::remove_dir_all(&dir);
    }

    #[test]
    fn chart_view_state_round_trips() {
        let dir = temp_db_dir("chart_view_state");
        let conn = init_database(&dir).expect("init_database");

        let ws = WorkspaceUpsert {
            id: "ws1".to_string(),
            name: None,
            name_is_custom: false,
            connection_id: "c1".to_string(),
            connection_name: "prod-db".to_string(),
            editor_text: "SELECT 1".to_string(),
            variables_json: "[]".to_string(),
            cursor_position: None,
        };
        upsert_workspace(&conn, &ws).expect("upsert_workspace");

        let h1 = history_entry("h1", "c1", "prod-db", &now_offset(0));
        save_query_history(&conn, &h1, Some(r#"[{"name":"id"}]"#), Some(r#"[[1]]"#)).expect("save h1");
        associate_result_to_workspace(&conn, "h1", "ws1", 0, 0).expect("associate h1");

        let json = r#"{"viewMode":"chart","chartConfig":{"chartType":"bar"}}"#;
        let ok = update_result_chart_state(&conn, "h1", json).expect("update_result_chart_state");
        assert!(ok, "update returns true");

        let detail = load_workspace(&conn, "ws1").expect("load_workspace").expect("ws1 exists");
        let r = detail.results.iter().find(|r| r.id == "h1").expect("h1 present");
        assert_eq!(r.chart_view_state_json.as_deref(), Some(json));

        drop(conn);
        let _ = std::fs::remove_dir_all(&dir);
    }

    #[test]
    fn raw_sql_migration_is_idempotent_and_present() {
        let dir = temp_db_dir("raw_sql_migration");
        let conn = init_database(&dir).expect("init 1");
        drop(conn);
        // Second init must not error (idempotent guarded ALTER).
        let conn = init_database(&dir).expect("init 2 idempotent");
        let count: i64 = conn
            .prepare("SELECT COUNT(*) FROM pragma_table_info('query_history') WHERE name = 'raw_sql'")
            .expect("prepare")
            .query_row([], |r| r.get(0))
            .expect("query_row");
        assert_eq!(count, 1, "raw_sql column present after migration");
        drop(conn);
        let _ = std::fs::remove_dir_all(&dir);
    }
}

/// `source` tag column on query_history: chart-aggregation runs (and any other
/// tagged origin) round-trip through save_query_history -> load_query_history,
/// while normal (untagged) runs read back as None. Real on-disk DB + real
/// decode path, per the project lesson that hand-built structs miss decode bugs.
#[cfg(test)]
mod history_source_tests {
    use super::*;
    use std::path::PathBuf;

    fn temp_db_dir(tag: &str) -> PathBuf {
        std::env::temp_dir().join(format!("pharos_test_{}_{}", tag, uuid::Uuid::new_v4()))
    }

    fn history_entry(id: &str, source: Option<&str>) -> QueryHistoryEntry {
        QueryHistoryEntry {
            id: id.to_string(),
            connection_id: "c1".to_string(),
            connection_name: "prod-db".to_string(),
            sql: format!("SELECT * FROM t_{}", id),
            row_count: Some(3),
            execution_time_ms: 12,
            executed_at: chrono::Utc::now().to_rfc3339(),
            has_results: false,
            schema: None,
            column_count: Some(2),
            table_names: None,
            source: source.map(|s| s.to_string()),
        }
    }

    #[test]
    fn source_tag_round_trips_and_defaults_to_none() {
        let dir = temp_db_dir("history_source");
        let conn = init_database(&dir).expect("init_database");

        let tagged = history_entry("h_tagged", Some("chart-aggregation"));
        let untagged = history_entry("h_untagged", None);
        save_query_history(&conn, &tagged, None, None).expect("save tagged");
        save_query_history(&conn, &untagged, None, None).expect("save untagged");

        let loaded = load_query_history(&conn, Some("c1"), None, 10, 0, false).expect("load_query_history");
        let loaded_tagged = loaded.iter().find(|e| e.id == "h_tagged").expect("tagged entry present");
        let loaded_untagged = loaded.iter().find(|e| e.id == "h_untagged").expect("untagged entry present");

        assert_eq!(loaded_tagged.source.as_deref(), Some("chart-aggregation"));
        assert_eq!(loaded_untagged.source, None);

        drop(conn);
        let _ = std::fs::remove_dir_all(&dir);
    }
}
