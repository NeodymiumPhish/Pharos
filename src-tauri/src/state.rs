use std::collections::HashMap;
use std::sync::Mutex;
use std::sync::atomic::{AtomicBool, Ordering};
use std::sync::Arc;
use sqlx::PgPool;
use rusqlite::Connection as SqliteConnection;

use crate::models::ConnectionConfig;

/// Represents a running query that can be cancelled
pub struct RunningQuery {
    /// The PostgreSQL backend PID for this query
    pub backend_pid: i32,
    /// Flag to signal cancellation
    pub cancelled: Arc<AtomicBool>,
}

/// Application state managed by Tauri
pub struct AppState {
    /// Active PostgreSQL connection pools, keyed by connection ID
    pub connections: Mutex<HashMap<String, PgPool>>,

    /// Saved connection configurations (cached from SQLite)
    pub connection_configs: Mutex<HashMap<String, ConnectionConfig>>,

    /// Local SQLite database for storing connection configs and metadata cache
    pub metadata_db: Mutex<SqliteConnection>,

    /// Currently running queries, keyed by query ID
    pub running_queries: Mutex<HashMap<String, RunningQuery>>,

    /// In-memory cache of passwords (loaded once from keychain at startup)
    pub password_cache: Mutex<HashMap<String, String>>,
}

impl AppState {
    pub fn new(metadata_db: SqliteConnection) -> Self {
        Self {
            connections: Mutex::new(HashMap::new()),
            connection_configs: Mutex::new(HashMap::new()),
            metadata_db: Mutex::new(metadata_db),
            running_queries: Mutex::new(HashMap::new()),
            password_cache: Mutex::new(HashMap::new()),
        }
    }

    /// Initialize the password cache from the keychain (call once at startup)
    pub fn init_password_cache(&self, passwords: HashMap<String, String>) {
        let mut cache = self.password_cache.lock().unwrap();
        *cache = passwords;
    }

    /// Get a password from the cache
    pub fn get_cached_password(&self, connection_id: &str) -> Option<String> {
        let cache = self.password_cache.lock().unwrap();
        cache.get(connection_id).cloned()
    }

    /// Get a connection pool by ID
    pub fn get_pool(&self, connection_id: &str) -> Option<PgPool> {
        let connections = self.connections.lock().unwrap();
        connections.get(connection_id).cloned()
    }

    /// Add a connection pool
    pub fn add_pool(&self, connection_id: String, pool: PgPool) {
        let mut connections = self.connections.lock().unwrap();
        connections.insert(connection_id, pool);
    }

    /// Remove a connection pool
    pub fn remove_pool(&self, connection_id: &str) -> Option<PgPool> {
        let mut connections = self.connections.lock().unwrap();
        connections.remove(connection_id)
    }

    /// Check if a connection pool exists
    pub fn has_pool(&self, connection_id: &str) -> bool {
        let connections = self.connections.lock().unwrap();
        connections.contains_key(connection_id)
    }

    /// Get a connection config by ID
    pub fn get_config(&self, connection_id: &str) -> Option<ConnectionConfig> {
        let configs = self.connection_configs.lock().unwrap();
        configs.get(connection_id).cloned()
    }

    /// Add or update a connection config
    pub fn set_config(&self, config: ConnectionConfig) {
        let mut configs = self.connection_configs.lock().unwrap();
        configs.insert(config.id.clone(), config);
    }

    /// Remove a connection config
    pub fn remove_config(&self, connection_id: &str) -> Option<ConnectionConfig> {
        let mut configs = self.connection_configs.lock().unwrap();
        configs.remove(connection_id)
    }

    /// Register a running query
    pub fn register_query(&self, query_id: String, backend_pid: i32) -> Arc<AtomicBool> {
        let cancelled = Arc::new(AtomicBool::new(false));
        let running_query = RunningQuery {
            backend_pid,
            cancelled: cancelled.clone(),
        };
        let mut queries = self.running_queries.lock().unwrap();
        queries.insert(query_id, running_query);
        cancelled
    }

    /// Unregister a running query
    pub fn unregister_query(&self, query_id: &str) {
        let mut queries = self.running_queries.lock().unwrap();
        queries.remove(query_id);
    }

    /// Get a running query's backend PID
    pub fn get_query_backend_pid(&self, query_id: &str) -> Option<i32> {
        let queries = self.running_queries.lock().unwrap();
        queries.get(query_id).map(|q| q.backend_pid)
    }

    /// Mark a query as cancelled
    pub fn mark_query_cancelled(&self, query_id: &str) -> bool {
        let queries = self.running_queries.lock().unwrap();
        if let Some(query) = queries.get(query_id) {
            query.cancelled.store(true, Ordering::SeqCst);
            true
        } else {
            false
        }
    }
}
