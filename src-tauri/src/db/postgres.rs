use sqlx::postgres::PgPoolOptions;
use sqlx::{PgPool, Row};
use std::time::{Duration, Instant};

use crate::models::{ColumnInfo, ConnectionConfig, SchemaInfo, TableInfo, TableType};

/// Create a PostgreSQL connection pool for the given configuration
pub async fn create_pool(config: &ConnectionConfig) -> Result<PgPool, sqlx::Error> {
    let connection_string = format!(
        "postgres://{}:{}@{}:{}/{}",
        config.username, config.password, config.host, config.port, config.database
    );

    let pool = PgPoolOptions::new()
        .max_connections(5)
        .acquire_timeout(Duration::from_secs(10))
        .connect(&connection_string)
        .await?;

    Ok(pool)
}

/// Test a PostgreSQL connection and return latency
pub async fn test_connection(config: &ConnectionConfig) -> Result<u64, sqlx::Error> {
    let connection_string = format!(
        "postgres://{}:{}@{}:{}/{}",
        config.username, config.password, config.host, config.port, config.database
    );

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

/// Get all tables and views in a schema
pub async fn get_tables(pool: &PgPool, schema_name: &str) -> Result<Vec<TableInfo>, sqlx::Error> {
    let rows = sqlx::query(
        r#"
        SELECT
            t.table_name,
            t.table_type,
            COALESCE(
                (SELECT reltuples::bigint
                 FROM pg_class c
                 JOIN pg_namespace n ON n.oid = c.relnamespace
                 WHERE n.nspname = t.table_schema AND c.relname = t.table_name),
                0
            ) as row_estimate
        FROM information_schema.tables t
        WHERE t.table_schema = $1
          AND t.table_type IN ('BASE TABLE', 'VIEW')
        ORDER BY t.table_type, t.table_name
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
                table_type: if table_type_str == "VIEW" {
                    TableType::View
                } else {
                    TableType::Table
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
