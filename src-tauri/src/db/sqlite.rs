use rusqlite::{Connection, Result as SqliteResult};
use std::path::Path;

use crate::models::{AppSettings, ConnectionConfig, CreateSavedQuery, QueryHistoryEntry, SavedQuery, SslMode, UpdateSavedQuery};

/// Initialize the SQLite database and create tables if they don't exist
pub fn init_database(app_data_dir: &Path) -> SqliteResult<Connection> {
    std::fs::create_dir_all(app_data_dir).ok();
    let db_path = app_data_dir.join("pharos.db");

    let conn = Connection::open(&db_path)?;

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
        INSERT INTO connections (id, name, host, port, database, username, ssl_mode, sort_order, color, updated_at)
        VALUES (?1, ?2, ?3, ?4, ?5, ?6, ?7, ?8, ?9, CURRENT_TIMESTAMP)
        ON CONFLICT(id) DO UPDATE SET
            name = excluded.name,
            host = excluded.host,
            port = excluded.port,
            database = excluded.database,
            username = excluded.username,
            ssl_mode = excluded.ssl_mode,
            color = excluded.color,
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
        ),
    )?;
    Ok(())
}

/// Load all connection configurations from the database (passwords loaded from keychain separately)
pub fn load_connections(conn: &Connection) -> SqliteResult<Vec<ConnectionConfig>> {
    let mut stmt = conn.prepare(
        "SELECT id, name, host, port, database, username, COALESCE(ssl_mode, 'prefer') as ssl_mode, color FROM connections ORDER BY sort_order, name",
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
        })
    })?;

    configs.collect()
}

/// Delete a connection configuration from the database
pub fn delete_connection(conn: &Connection, connection_id: &str) -> SqliteResult<()> {
    conn.execute("DELETE FROM connections WHERE id = ?1", [connection_id])?;
    Ok(())
}

/// Update the sort order of connections
pub fn reorder_connections(conn: &Connection, connection_ids: &[String]) -> SqliteResult<()> {
    for (index, id) in connection_ids.iter().enumerate() {
        conn.execute(
            "UPDATE connections SET sort_order = ?1 WHERE id = ?2",
            (index as i32, id),
        )?;
    }
    Ok(())
}

// ==================== Saved Queries ====================

/// Create a new saved query
pub fn create_saved_query(conn: &Connection, id: &str, query: &CreateSavedQuery) -> SqliteResult<SavedQuery> {
    let now = chrono::Utc::now().to_rfc3339();

    conn.execute(
        r#"
        INSERT INTO saved_queries (id, name, folder, sql, connection_id, created_at, updated_at)
        VALUES (?1, ?2, ?3, ?4, ?5, ?6, ?7)
        "#,
        (
            id,
            &query.name,
            &query.folder,
            &query.sql,
            &query.connection_id,
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
        created_at: now.clone(),
        updated_at: now,
    })
}

/// Load all saved queries
pub fn load_saved_queries(conn: &Connection) -> SqliteResult<Vec<SavedQuery>> {
    let mut stmt = conn.prepare(
        "SELECT id, name, folder, sql, connection_id, created_at, updated_at FROM saved_queries ORDER BY name",
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
        })
    })?;

    queries.collect()
}

/// Get a single saved query by ID
pub fn get_saved_query(conn: &Connection, query_id: &str) -> SqliteResult<Option<SavedQuery>> {
    let mut stmt = conn.prepare(
        "SELECT id, name, folder, sql, connection_id, created_at, updated_at FROM saved_queries WHERE id = ?1",
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

const MAX_HISTORY_ENTRIES: i64 = 10_000;

/// Save a query history entry with optional cached results (and prune old entries if needed)
pub fn save_query_history(
    conn: &Connection,
    entry: &QueryHistoryEntry,
    result_columns_json: Option<&str>,
    result_rows_json: Option<&str>,
) -> SqliteResult<()> {
    conn.execute(
        r#"
        INSERT INTO query_history (id, connection_id, connection_name, sql, row_count, execution_time_ms, executed_at, result_columns, result_rows)
        VALUES (?1, ?2, ?3, ?4, ?5, ?6, ?7, ?8, ?9)
        "#,
        (
            &entry.id,
            &entry.connection_id,
            &entry.connection_name,
            &entry.sql,
            &entry.row_count,
            entry.execution_time_ms,
            &entry.executed_at,
            &result_columns_json,
            &result_rows_json,
        ),
    )?;

    // Prune old entries beyond the limit
    conn.execute(
        r#"
        DELETE FROM query_history WHERE id NOT IN (
            SELECT id FROM query_history ORDER BY executed_at DESC LIMIT ?1
        )
        "#,
        [MAX_HISTORY_ENTRIES],
    )?;

    Ok(())
}

/// Load query history entries with optional filters
pub fn load_query_history(
    conn: &Connection,
    connection_id: Option<&str>,
    search: Option<&str>,
    limit: i64,
    offset: i64,
) -> SqliteResult<Vec<QueryHistoryEntry>> {
    let mut sql = String::from(
        "SELECT id, connection_id, connection_name, sql, row_count, execution_time_ms, executed_at, (result_columns IS NOT NULL) as has_results FROM query_history WHERE 1=1"
    );
    let mut params: Vec<Box<dyn rusqlite::ToSql>> = Vec::new();
    let mut param_idx = 1;

    if let Some(cid) = connection_id {
        sql.push_str(&format!(" AND connection_id = ?{}", param_idx));
        params.push(Box::new(cid.to_string()));
        param_idx += 1;
    }

    if let Some(q) = search {
        if !q.is_empty() {
            sql.push_str(&format!(" AND sql LIKE ?{}", param_idx));
            params.push(Box::new(format!("%{}%", q)));
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
        })
    })?;

    entries.collect()
}

/// Delete a single query history entry
pub fn delete_query_history_entry(conn: &Connection, entry_id: &str) -> SqliteResult<bool> {
    let rows_affected = conn.execute("DELETE FROM query_history WHERE id = ?1", [entry_id])?;
    Ok(rows_affected > 0)
}

/// Clear all query history
pub fn clear_query_history(conn: &Connection) -> SqliteResult<()> {
    conn.execute("DELETE FROM query_history", [])?;
    Ok(())
}

/// Update cached results for a history entry (e.g. after loading more rows)
pub fn update_query_history_results(
    conn: &Connection,
    entry_id: &str,
    row_count: i64,
    result_columns_json: &str,
    result_rows_json: &str,
) -> SqliteResult<bool> {
    let rows_affected = conn.execute(
        "UPDATE query_history SET row_count = ?1, result_columns = ?2, result_rows = ?3 WHERE id = ?4",
        rusqlite::params![row_count, result_columns_json, result_rows_json, entry_id],
    )?;
    Ok(rows_affected > 0)
}

/// Load cached result data for a specific history entry
pub fn get_query_history_result(conn: &Connection, entry_id: &str) -> SqliteResult<Option<(String, String)>> {
    let mut stmt = conn.prepare(
        "SELECT result_columns, result_rows FROM query_history WHERE id = ?1 AND result_columns IS NOT NULL"
    )?;
    let mut rows = stmt.query([entry_id])?;
    if let Some(row) = rows.next()? {
        Ok(Some((row.get(0)?, row.get(1)?)))
    } else {
        Ok(None)
    }
}
