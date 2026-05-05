use std::collections::{HashMap, HashSet};
use std::sync::Mutex;
use std::sync::atomic::{AtomicBool, AtomicU64, Ordering};
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

    /// Tables where ANALYZE was denied due to insufficient privileges.
    /// Keyed by connection_id -> schema_name -> set of table names.
    /// Cleared on disconnect so permissions are re-checked on reconnect.
    pub analyze_denied: Mutex<HashMap<String, HashMap<String, HashSet<String>>>>,

    /// Live row counters for in-progress CSV imports.
    /// Keyed by `"{connection_id}|{schema}|{table}"`.
    pub import_progress: Mutex<HashMap<String, Arc<AtomicU64>>>,
}

impl AppState {
    pub fn new(metadata_db: SqliteConnection) -> Self {
        Self {
            connections: Mutex::new(HashMap::new()),
            connection_configs: Mutex::new(HashMap::new()),
            metadata_db: Mutex::new(metadata_db),
            running_queries: Mutex::new(HashMap::new()),
            password_cache: Mutex::new(HashMap::new()),
            analyze_denied: Mutex::new(HashMap::new()),
            import_progress: Mutex::new(HashMap::new()),
        }
    }

    /// Register a new in-progress import. Returns a shared counter to increment per row.
    pub fn register_import_progress(&self, key: String) -> Arc<AtomicU64> {
        let counter = Arc::new(AtomicU64::new(0));
        let mut map = self.import_progress.lock().unwrap_or_else(|e| e.into_inner());
        map.insert(key, counter.clone());
        counter
    }

    /// Remove an import progress entry (call on completion or error).
    pub fn unregister_import_progress(&self, key: &str) {
        let mut map = self.import_progress.lock().unwrap_or_else(|e| e.into_inner());
        map.remove(key);
    }

    /// Read the current row count for an in-progress import. None if not active.
    pub fn get_import_progress(&self, key: &str) -> Option<u64> {
        let map = self.import_progress.lock().unwrap_or_else(|e| e.into_inner());
        map.get(key).map(|c| c.load(Ordering::Relaxed))
    }

    /// Initialize the password cache from the keychain (call once at startup)
    pub fn init_password_cache(&self, passwords: HashMap<String, String>) {
        let mut cache = self.password_cache.lock().unwrap_or_else(|e| e.into_inner());
        *cache = passwords;
    }

    /// Get a password from the cache
    pub fn get_cached_password(&self, connection_id: &str) -> Option<String> {
        let cache = self.password_cache.lock().unwrap_or_else(|e| e.into_inner());
        cache.get(connection_id).cloned()
    }

    /// Get a connection pool by ID
    pub fn get_pool(&self, connection_id: &str) -> Option<PgPool> {
        let connections = self.connections.lock().unwrap_or_else(|e| e.into_inner());
        connections.get(connection_id).cloned()
    }

    /// Add a connection pool
    pub fn add_pool(&self, connection_id: String, pool: PgPool) {
        let mut connections = self.connections.lock().unwrap_or_else(|e| e.into_inner());
        connections.insert(connection_id, pool);
    }

    /// Remove a connection pool
    pub fn remove_pool(&self, connection_id: &str) -> Option<PgPool> {
        let mut connections = self.connections.lock().unwrap_or_else(|e| e.into_inner());
        connections.remove(connection_id)
    }

    /// Check if a connection pool exists
    pub fn has_pool(&self, connection_id: &str) -> bool {
        let connections = self.connections.lock().unwrap_or_else(|e| e.into_inner());
        connections.contains_key(connection_id)
    }

    /// Get a connection config by ID
    pub fn get_config(&self, connection_id: &str) -> Option<ConnectionConfig> {
        let configs = self.connection_configs.lock().unwrap_or_else(|e| e.into_inner());
        configs.get(connection_id).cloned()
    }

    /// Add or update a connection config
    pub fn set_config(&self, config: ConnectionConfig) {
        let mut configs = self.connection_configs.lock().unwrap_or_else(|e| e.into_inner());
        configs.insert(config.id.clone(), config);
    }

    /// Remove a connection config
    pub fn remove_config(&self, connection_id: &str) -> Option<ConnectionConfig> {
        let mut configs = self.connection_configs.lock().unwrap_or_else(|e| e.into_inner());
        configs.remove(connection_id)
    }

    /// Register a running query
    pub fn register_query(&self, query_id: String, backend_pid: i32) -> Arc<AtomicBool> {
        let cancelled = Arc::new(AtomicBool::new(false));
        let running_query = RunningQuery {
            backend_pid,
            cancelled: cancelled.clone(),
        };
        let mut queries = self.running_queries.lock().unwrap_or_else(|e| e.into_inner());
        queries.insert(query_id, running_query);
        cancelled
    }

    /// Unregister a running query
    pub fn unregister_query(&self, query_id: &str) {
        let mut queries = self.running_queries.lock().unwrap_or_else(|e| e.into_inner());
        queries.remove(query_id);
    }

    /// Get a running query's backend PID
    pub fn get_query_backend_pid(&self, query_id: &str) -> Option<i32> {
        let queries = self.running_queries.lock().unwrap_or_else(|e| e.into_inner());
        queries.get(query_id).map(|q| q.backend_pid)
    }

    /// Get the set of tables denied ANALYZE for a connection+schema
    pub fn get_analyze_denied(&self, connection_id: &str, schema_name: &str) -> HashSet<String> {
        let cache = self.analyze_denied.lock().unwrap_or_else(|e| e.into_inner());
        cache
            .get(connection_id)
            .and_then(|schemas| schemas.get(schema_name))
            .cloned()
            .unwrap_or_default()
    }

    /// Record tables that were denied ANALYZE
    pub fn add_analyze_denied(&self, connection_id: &str, schema_name: &str, tables: &[String]) {
        if tables.is_empty() {
            return;
        }
        let mut cache = self.analyze_denied.lock().unwrap_or_else(|e| e.into_inner());
        let schemas = cache.entry(connection_id.to_string()).or_default();
        let denied = schemas.entry(schema_name.to_string()).or_default();
        for table in tables {
            denied.insert(table.clone());
        }
    }

    /// Clear analyze-denied cache for a connection (called on disconnect)
    pub fn clear_analyze_denied(&self, connection_id: &str) {
        let mut cache = self.analyze_denied.lock().unwrap_or_else(|e| e.into_inner());
        cache.remove(connection_id);
    }

    /// Mark a query as cancelled
    pub fn mark_query_cancelled(&self, query_id: &str) -> bool {
        let queries = self.running_queries.lock().unwrap_or_else(|e| e.into_inner());
        if let Some(query) = queries.get(query_id) {
            query.cancelled.store(true, Ordering::SeqCst);
            true
        } else {
            false
        }
    }
}
