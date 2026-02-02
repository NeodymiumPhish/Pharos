use rusqlite::{Connection, Result as SqliteResult};
use std::path::Path;

use crate::models::{AppSettings, ConnectionConfig, CreateSavedQuery, SavedQuery, UpdateSavedQuery};

/// Initialize the SQLite database and create tables if they don't exist
pub fn init_database(app_data_dir: &Path) -> SqliteResult<Connection> {
    std::fs::create_dir_all(app_data_dir).ok();
    let db_path = app_data_dir.join("pharos.db");

    let conn = Connection::open(&db_path)?;

    // Create tables
    conn.execute_batch(
        r#"
        -- Connection configurations
        CREATE TABLE IF NOT EXISTS connections (
            id TEXT PRIMARY KEY,
            name TEXT NOT NULL,
            host TEXT NOT NULL,
            port INTEGER NOT NULL,
            database TEXT NOT NULL,
            username TEXT NOT NULL,
            password TEXT NOT NULL,
            created_at TEXT DEFAULT CURRENT_TIMESTAMP,
            updated_at TEXT DEFAULT CURRENT_TIMESTAMP
        );

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
        "#,
    )?;

    Ok(conn)
}

/// Save a connection configuration to the database
pub fn save_connection(conn: &Connection, config: &ConnectionConfig) -> SqliteResult<()> {
    conn.execute(
        r#"
        INSERT INTO connections (id, name, host, port, database, username, password, updated_at)
        VALUES (?1, ?2, ?3, ?4, ?5, ?6, ?7, CURRENT_TIMESTAMP)
        ON CONFLICT(id) DO UPDATE SET
            name = excluded.name,
            host = excluded.host,
            port = excluded.port,
            database = excluded.database,
            username = excluded.username,
            password = excluded.password,
            updated_at = CURRENT_TIMESTAMP
        "#,
        (
            &config.id,
            &config.name,
            &config.host,
            config.port,
            &config.database,
            &config.username,
            &config.password,
        ),
    )?;
    Ok(())
}

/// Load all connection configurations from the database
pub fn load_connections(conn: &Connection) -> SqliteResult<Vec<ConnectionConfig>> {
    let mut stmt = conn.prepare(
        "SELECT id, name, host, port, database, username, password FROM connections ORDER BY name",
    )?;

    let configs = stmt.query_map([], |row| {
        Ok(ConnectionConfig {
            id: row.get(0)?,
            name: row.get(1)?,
            host: row.get(2)?,
            port: row.get(3)?,
            database: row.get(4)?,
            username: row.get(5)?,
            password: row.get(6)?,
        })
    })?;

    configs.collect()
}

/// Delete a connection configuration from the database
pub fn delete_connection(conn: &Connection, connection_id: &str) -> SqliteResult<()> {
    conn.execute("DELETE FROM connections WHERE id = ?1", [connection_id])?;
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
