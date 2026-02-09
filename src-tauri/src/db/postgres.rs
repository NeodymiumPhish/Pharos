use sqlx::postgres::PgPoolOptions;
use sqlx::{PgPool, Row};
use std::collections::HashSet;
use std::time::{Duration, Instant};

use crate::models::{AnalyzeResult, ColumnInfo, ConnectionConfig, SchemaInfo, TableInfo, TableType};

/// Build a connection string with proper URL encoding and SSL mode
fn build_connection_string(config: &ConnectionConfig) -> String {
    // URL encode username and password to handle special characters safely
    let username = urlencoding::encode(&config.username);
    let password = urlencoding::encode(&config.password);

    format!(
        "postgres://{}:{}@{}:{}/{}?sslmode={}",
        username,
        password,
        config.host,
        config.port,
        config.database,
        config.ssl_mode
    )
}

/// Create a PostgreSQL connection pool for the given configuration
pub async fn create_pool(config: &ConnectionConfig) -> Result<PgPool, sqlx::Error> {
    let connection_string = build_connection_string(config);

    let pool = PgPoolOptions::new()
        .max_connections(5)
        .acquire_timeout(Duration::from_secs(10))
        .connect(&connection_string)
        .await?;

    Ok(pool)
}

/// Test a PostgreSQL connection and return latency
pub async fn test_connection(config: &ConnectionConfig) -> Result<u64, sqlx::Error> {
    let connection_string = build_connection_string(config);

    let start = Instant::now();

    let pool = PgPoolOptions::new()
        .max_connections(1)
        .acquire_timeout(Duration::from_secs(10))
        .connect(&connection_string)
        .await?;

    // Run a simple query to verify connection
    sqlx::query("SELECT 1").execute(&pool).await?;

    let latency = start.elapsed().as_millis() as u64;

    // Close the test pool
    pool.close().await;

    Ok(latency)
}

/// Get all schemas in the database
pub async fn get_schemas(pool: &PgPool) -> Result<Vec<SchemaInfo>, sqlx::Error> {
    let rows = sqlx::query(
        r#"
        SELECT schema_name, schema_owner
        FROM information_schema.schemata
        WHERE schema_name NOT IN ('pg_catalog', 'information_schema', 'pg_toast')
        ORDER BY schema_name
        "#,
    )
    .fetch_all(pool)
    .await?;

    let schemas = rows
        .into_iter()
        .map(|row| SchemaInfo {
            name: row.get("schema_name"),
            owner: row.try_get("schema_owner").ok(),
        })
        .collect();

    Ok(schemas)
}

/// Analyze tables in a schema that have never been analyzed (reltuples = -1).
/// Returns which tables were attempted and which had permission errors.
/// Tables in `skip_denied` are known to be permission-denied from a previous
/// attempt in this session and are excluded from re-analysis.
pub async fn analyze_schema(
    pool: &PgPool,
    schema_name: &str,
    skip_denied: &HashSet<String>,
) -> Result<AnalyzeResult, sqlx::Error> {
    let unanalyzed: Vec<String> = sqlx::query(
        r#"
        SELECT c.relname as table_name
        FROM pg_catalog.pg_class c
        JOIN pg_catalog.pg_namespace n ON n.oid = c.relnamespace
        WHERE n.nspname = $1
          AND c.relkind = 'r'
          AND c.reltuples = -1
        "#,
    )
    .bind(schema_name)
    .fetch_all(pool)
    .await?
    .into_iter()
    .map(|row| row.get::<String, _>("table_name"))
    .collect();

    let had_unanalyzed = !unanalyzed.is_empty();
    let mut permission_denied_tables = Vec::new();

    for table_name in &unanalyzed {
        // Skip tables already known to be permission-denied this session
        if skip_denied.contains(table_name) {
            permission_denied_tables.push(table_name.clone());
            continue;
        }

        let analyze_sql = format!(
            "ANALYZE \"{}\".\"{}\"",
            schema_name.replace('"', "\"\""),
            table_name.replace('"', "\"\"")
        );
        if let Err(e) = sqlx::query(&analyze_sql).execute(pool).await {
            let msg = e.to_string().to_lowercase();
            if msg.contains("permission denied") || msg.contains("only table or database owner can analyze") {
                permission_denied_tables.push(table_name.clone());
            }
            // Other errors (e.g., unreachable foreign servers) are silently ignored
        }
    }

    Ok(AnalyzeResult {
        had_unanalyzed,
        permission_denied_tables,
    })
}

/// Get all tables and views in a schema
pub async fn get_tables(pool: &PgPool, schema_name: &str) -> Result<Vec<TableInfo>, sqlx::Error> {
    // Use pg_catalog directly to get all relation types including foreign tables
    // information_schema.tables doesn't reliably include foreign tables
    let rows = sqlx::query(
        r#"
        SELECT
            c.relname as table_name,
            CASE c.relkind
                WHEN 'r' THEN 'BASE TABLE'
                WHEN 'v' THEN 'VIEW'
                WHEN 'm' THEN 'VIEW'
                WHEN 'f' THEN 'FOREIGN TABLE'
                ELSE 'BASE TABLE'
            END as table_type,
            CASE WHEN c.reltuples >= 0 THEN c.reltuples::bigint ELSE NULL END as row_estimate
        FROM pg_catalog.pg_class c
        JOIN pg_catalog.pg_namespace n ON n.oid = c.relnamespace
        WHERE n.nspname = $1
          AND c.relkind IN ('r', 'v', 'm', 'f')
        ORDER BY
            CASE c.relkind
                WHEN 'r' THEN 1
                WHEN 'f' THEN 2
                WHEN 'v' THEN 3
                WHEN 'm' THEN 4
            END,
            c.relname
        "#,
    )
    .bind(schema_name)
    .fetch_all(pool)
    .await?;

    let tables = rows
        .into_iter()
        .map(|row| {
            let table_type_str: String = row.get("table_type");
            TableInfo {
                name: row.get("table_name"),
                schema_name: schema_name.to_string(),
                table_type: match table_type_str.as_str() {
                    "VIEW" => TableType::View,
                    "FOREIGN TABLE" => TableType::ForeignTable,
                    _ => TableType::Table,
                },
                row_count_estimate: row.try_get("row_estimate").ok(),
            }
        })
        .collect();

    Ok(tables)
}

/// Get all columns for a table
pub async fn get_columns(
    pool: &PgPool,
    schema_name: &str,
    table_name: &str,
) -> Result<Vec<ColumnInfo>, sqlx::Error> {
    let rows = sqlx::query(
        r#"
        SELECT
            c.column_name,
            c.data_type,
            c.is_nullable,
            c.ordinal_position,
            c.column_default,
            CASE WHEN pk.column_name IS NOT NULL THEN true ELSE false END as is_primary_key
        FROM information_schema.columns c
        LEFT JOIN (
            SELECT kcu.column_name
            FROM information_schema.table_constraints tc
            JOIN information_schema.key_column_usage kcu
                ON tc.constraint_name = kcu.constraint_name
                AND tc.table_schema = kcu.table_schema
            WHERE tc.constraint_type = 'PRIMARY KEY'
                AND tc.table_schema = $1
                AND tc.table_name = $2
        ) pk ON c.column_name = pk.column_name
        WHERE c.table_schema = $1
          AND c.table_name = $2
        ORDER BY c.ordinal_position
        "#,
    )
    .bind(schema_name)
    .bind(table_name)
    .fetch_all(pool)
    .await?;

    let columns = rows
        .into_iter()
        .map(|row| {
            let is_nullable_str: String = row.get("is_nullable");
            ColumnInfo {
                name: row.get("column_name"),
                data_type: row.get("data_type"),
                is_nullable: is_nullable_str == "YES",
                is_primary_key: row.get("is_primary_key"),
                ordinal_position: row.get("ordinal_position"),
                column_default: row.try_get("column_default").ok(),
            }
        })
        .collect();

    Ok(columns)
}
