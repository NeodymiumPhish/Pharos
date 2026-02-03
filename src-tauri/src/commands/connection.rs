use tauri::State;

use crate::db::{credentials, postgres, sqlite};
use crate::models::{ConnectionConfig, ConnectionInfo, ConnectionStatus, TestConnectionResult};
use crate::state::AppState;

/// Sanitize error messages to remove sensitive data like passwords
fn sanitize_error(error: &str) -> String {
    // Remove anything that looks like a postgres connection URL
    let mut sanitized = error.to_string();

    // Replace postgres:// URLs with credentials hidden
    if sanitized.contains("postgres://") {
        // Pattern: postgres://user:pass@host:port/db
        if let Some(start) = sanitized.find("postgres://") {
            if let Some(at_pos) = sanitized[start..].find('@') {
                let end = start + at_pos + 1;
                sanitized = format!(
                    "{}postgres://[credentials]@{}",
                    &sanitized[..start],
                    &sanitized[end..]
                );
            }
        }
    }

    // Also remove any password= parameters
    while let Some(start) = sanitized.find("password=") {
        let after = &sanitized[start + 9..];
        let end_offset = after
            .find(|c: char| c.is_whitespace() || c == '&' || c == '"' || c == '\'' || c == ';')
            .unwrap_or(after.len());
        sanitized = format!(
            "{}password=[hidden]{}",
            &sanitized[..start],
            &after[end_offset..]
        );
    }

    sanitized
}

/// Save a new connection configuration
#[tauri::command]
pub async fn save_connection(
    config: ConnectionConfig,
    state: State<'_, AppState>,
) -> Result<(), String> {
    // Store password securely in OS keychain
    if !config.password.is_empty() {
        credentials::store_password(&config.id, &config.password)?;
    }

    // Save metadata to SQLite (without password)
    {
        let db = state.metadata_db.lock().map_err(|e| e.to_string())?;
        sqlite::save_connection(&db, &config).map_err(|e| e.to_string())?;
    }

    // Update in-memory cache (with password for active use)
    state.set_config(config);

    Ok(())
}

/// Delete a connection configuration
#[tauri::command]
pub async fn delete_connection(
    connection_id: String,
    state: State<'_, AppState>,
) -> Result<(), String> {
    // Disconnect if connected
    if state.has_pool(&connection_id) {
        if let Some(pool) = state.remove_pool(&connection_id) {
            pool.close().await;
        }
    }

    // Delete password from keychain
    credentials::delete_password(&connection_id)?;

    // Delete from SQLite
    {
        let db = state.metadata_db.lock().map_err(|e| e.to_string())?;
        sqlite::delete_connection(&db, &connection_id).map_err(|e| e.to_string())?;
    }

    // Remove from in-memory cache
    state.remove_config(&connection_id);

    Ok(())
}

/// Load all saved connection configurations
#[tauri::command]
pub async fn load_connections(state: State<'_, AppState>) -> Result<Vec<ConnectionConfig>, String> {
    let mut configs = {
        let db = state.metadata_db.lock().map_err(|e| e.to_string())?;
        sqlite::load_connections(&db).map_err(|e| e.to_string())?
    };

    // Load passwords from keychain
    for config in &mut configs {
        if let Ok(Some(password)) = credentials::get_password(&config.id) {
            config.password = password;
        }
    }

    // Update in-memory cache
    for config in &configs {
        state.set_config(config.clone());
    }

    Ok(configs)
}

/// Connect to a PostgreSQL database
#[tauri::command]
pub async fn connect_postgres(
    connection_id: String,
    state: State<'_, AppState>,
) -> Result<ConnectionInfo, String> {
    // Get the connection config
    let config = state
        .get_config(&connection_id)
        .ok_or_else(|| format!("Connection not found: {}", connection_id))?;

    // Check if already connected
    if state.has_pool(&connection_id) {
        return Ok(ConnectionInfo {
            id: config.id,
            name: config.name,
            host: config.host,
            port: config.port,
            database: config.database,
            status: ConnectionStatus::Connected,
            error: None,
            latency_ms: None,
        });
    }

    // Create the connection pool
    match postgres::create_pool(&config).await {
        Ok(pool) => {
            state.add_pool(connection_id.clone(), pool);
            Ok(ConnectionInfo {
                id: config.id,
                name: config.name,
                host: config.host,
                port: config.port,
                database: config.database,
                status: ConnectionStatus::Connected,
                error: None,
                latency_ms: None,
            })
        }
        Err(e) => Ok(ConnectionInfo {
            id: config.id,
            name: config.name,
            host: config.host,
            port: config.port,
            database: config.database,
            status: ConnectionStatus::Error,
            error: Some(sanitize_error(&e.to_string())),
            latency_ms: None,
        }),
    }
}

/// Disconnect from a PostgreSQL database
#[tauri::command]
pub async fn disconnect_postgres(
    connection_id: String,
    state: State<'_, AppState>,
) -> Result<(), String> {
    if let Some(pool) = state.remove_pool(&connection_id) {
        pool.close().await;
    }
    Ok(())
}

/// Test a connection configuration without saving it
#[tauri::command]
pub async fn test_connection(config: ConnectionConfig) -> Result<TestConnectionResult, String> {
    match postgres::test_connection(&config).await {
        Ok(latency) => Ok(TestConnectionResult {
            success: true,
            latency_ms: Some(latency),
            error: None,
        }),
        Err(e) => Ok(TestConnectionResult {
            success: false,
            latency_ms: None,
            error: Some(sanitize_error(&e.to_string())),
        }),
    }
}

/// Get connection status
#[tauri::command]
pub async fn get_connection_status(
    connection_id: String,
    state: State<'_, AppState>,
) -> Result<ConnectionInfo, String> {
    let config = state
        .get_config(&connection_id)
        .ok_or_else(|| format!("Connection not found: {}", connection_id))?;

    let status = if state.has_pool(&connection_id) {
        ConnectionStatus::Connected
    } else {
        ConnectionStatus::Disconnected
    };

    Ok(ConnectionInfo {
        id: config.id,
        name: config.name,
        host: config.host,
        port: config.port,
        database: config.database,
        status,
        error: None,
        latency_ms: None,
    })
}
