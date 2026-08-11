use sqlx::postgres::PgPoolOptions;
use sqlx::{Executor, PgPool, Row, ValueRef};
use std::collections::{HashMap, HashSet};
use std::time::{Duration, Instant};

use crate::models::{AnalyzeResult, ColumnInfo, ConnectionConfig, ConstraintInfo, FunctionInfo, IndexInfo, KeyCandidate, PartitionRef, PartitionStrategy, SchemaColumnInfo, SchemaInfo, TableInfo, TableKeyInfo, TableType};
use crate::commands::ddl::{DdlColumn, DdlConstraint, TableDdlParts};

/// Escape a string for safe use as a SQL string literal (防 SQL injection).
/// Replaces single quotes with doubled single quotes.
fn escape_sql_literal(s: &str) -> String {
    s.replace('\'', "''")
}

/// Read a column value as a raw text string, bypassing type OID checks.
/// Works reliably with non-PG servers (ClickHouse, CockroachDB) that may
/// report non-standard type OIDs via the simple query protocol.
fn raw_str(row: &sqlx::postgres::PgRow, col: &str) -> Option<String> {
    match row.try_get_raw(col) {
        Ok(raw) => {
            if raw.is_null() {
                None
            } else {
                raw.as_str().ok().map(|s| s.to_string())
            }
        }
        Err(_) => None,
    }
}

/// Build a connection string with proper URL encoding and SSL mode
fn build_connection_string(config: &ConnectionConfig) -> String {
    // URL encode all user-provided fields to prevent parameter injection
    let username = urlencoding::encode(&config.username);
    let password = urlencoding::encode(&config.password);
    let host = urlencoding::encode(&config.host);
    let database = urlencoding::encode(&config.database);

    format!(
        "postgres://{}:{}@{}:{}/{}?sslmode={}",
        username,
        password,
        host,
        config.port,
        database,
        config.ssl_mode
    )
}

/// Create a PostgreSQL connection pool for the given configuration
pub async fn create_pool(config: &ConnectionConfig) -> Result<PgPool, sqlx::Error> {
    let connection_string = build_connection_string(config);

    let pool = PgPoolOptions::new()
        .max_connections(5)
        .acquire_timeout(Duration::from_secs(10))
        .idle_timeout(Duration::from_secs(600))
        .max_lifetime(Duration::from_secs(1800))
        .connect(&connection_string)
        .await?;

    // Try to set a session-level idle-in-transaction guard. This is
    // PostgreSQL-specific and will fail (and may kill the connection) on
    // non-PG servers like ClickHouse, so we run it after pool creation on a
    // separate connection rather than in after_connect where a failure
    // poisons every connection. The query timeout is applied per query on
    // the executing connection (see commands/query.rs), not here.
    if let Ok(mut conn) = pool.acquire().await {
        let _ = (&mut *conn)
            .execute(sqlx::raw_sql(
                "SET idle_in_transaction_session_timeout = '30s'",
            ))
            .await;
    }

    Ok(pool)
}

/// Test a PostgreSQL connection and return latency
pub async fn test_connection(config: &ConnectionConfig) -> Result<u64, sqlx::Error> {
    let connection_string = build_connection_string(config);

    let start = Instant::now();

    let pool = PgPoolOptions::new()
        .max_connections(1)
        .acquire_timeout(Duration::from_secs(10))
        .idle_timeout(Duration::from_secs(600))
        .max_lifetime(Duration::from_secs(1800))
        .connect(&connection_string)
        .await?;

    // Use raw_sql (simple query protocol) for compatibility with
    // non-PostgreSQL servers (e.g. ClickHouse) that don't support
    // the extended query protocol's ParameterDescription message.
    sqlx::raw_sql("SELECT 1").execute(&pool).await?;

    let latency = start.elapsed().as_millis() as u64;

    // Close the test pool
    pool.close().await;

    Ok(latency)
}

/// Get all schemas in the database
pub async fn get_schemas(pool: &PgPool) -> Result<Vec<SchemaInfo>, sqlx::Error> {
    // No parameters needed — use raw_sql for simple protocol compatibility
    let rows = sqlx::raw_sql(
        "SELECT schema_name, schema_owner \
         FROM information_schema.schemata \
         WHERE schema_name NOT IN ('pg_catalog', 'information_schema', 'pg_toast') \
         ORDER BY schema_name",
    )
    .fetch_all(pool)
    .await?;

    let schemas = rows
        .into_iter()
        .filter_map(|row| {
            Some(SchemaInfo {
                name: raw_str(&row, "schema_name")?,
                owner: raw_str(&row, "schema_owner"),
            })
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
    let escaped_schema = escape_sql_literal(schema_name);
    let sql = format!(
        "SELECT c.relname as table_name \
         FROM pg_catalog.pg_class c \
         JOIN pg_catalog.pg_namespace n ON n.oid = c.relnamespace \
         WHERE n.nspname = '{}' \
           AND c.relkind = 'r' \
           AND c.reltuples = -1",
        escaped_schema
    );

    // pg_catalog may not exist on non-PG servers — return empty result on failure
    let unanalyzed: Vec<String> = match sqlx::raw_sql(&sql).fetch_all(pool).await {
        Ok(rows) => rows.into_iter().map(|row| row.get::<String, _>("table_name")).collect(),
        Err(_) => return Ok(AnalyzeResult {
            had_unanalyzed: false,
            permission_denied_tables: vec![],
            tables: vec![],
        }),
    };

    let had_unanalyzed = !unanalyzed.is_empty();
    let mut permission_denied_tables = Vec::new();

    // Filter out tables already known to be permission-denied
    let to_analyze: Vec<&String> = unanalyzed.iter()
        .filter(|t| !skip_denied.contains(*t))
        .collect();
    for t in &unanalyzed {
        if skip_denied.contains(t) {
            permission_denied_tables.push(t.clone());
        }
    }

    if !to_analyze.is_empty() {
        // Try batched ANALYZE first (single round-trip for all tables)
        let escaped_schema_ident = schema_name.replace('"', "\"\"");
        let table_list: Vec<String> = to_analyze.iter()
            .map(|t| format!("\"{}\".\"{}\"", escaped_schema_ident, t.replace('"', "\"\"")))
            .collect();
        let batch_sql = format!("ANALYZE {}", table_list.join(", "));

        if let Err(_) = sqlx::raw_sql(&batch_sql).execute(pool).await {
            // Batch failed (likely permission denied on one+ tables).
            // Fall back to per-table ANALYZE to identify which ones failed.
            for table_name in &to_analyze {
                let analyze_sql = format!(
                    "ANALYZE \"{}\".\"{}\"",
                    escaped_schema_ident,
                    table_name.replace('"', "\"\"")
                );
                if let Err(e) = sqlx::raw_sql(&analyze_sql).execute(pool).await {
                    let msg = e.to_string().to_lowercase();
                    if msg.contains("permission denied") || msg.contains("only table or database owner can analyze") {
                        permission_denied_tables.push((*table_name).clone());
                    }
                }
            }
        }
    }

    // Re-fetch tables so callers get the post-ANALYZE row count estimates in
    // the same FFI round-trip. Falls back to an empty vec on read failure —
    // the caller still gets a valid AnalyzeResult.
    let tables = get_tables(pool, schema_name).await.unwrap_or_default();

    Ok(AnalyzeResult {
        had_unanalyzed,
        permission_denied_tables,
        tables,
    })
}

/// Get all tables and views in a schema
pub async fn get_tables(pool: &PgPool, schema_name: &str) -> Result<Vec<TableInfo>, sqlx::Error> {
    let escaped = escape_sql_literal(schema_name);

    // Try pg_catalog first for full metadata (row estimates, sizes, foreign tables)
    let pg_catalog_sql = format!(
        "SELECT \
            c.relname as table_name, \
            CASE c.relkind \
                WHEN 'r' THEN 'BASE TABLE' \
                WHEN 'v' THEN 'VIEW' \
                WHEN 'm' THEN 'VIEW' \
                WHEN 'f' THEN 'FOREIGN TABLE' \
                WHEN 'p' THEN 'PARTITIONED TABLE' \
                ELSE 'BASE TABLE' \
            END as table_type, \
            CASE \
                WHEN c.relkind = 'p' THEN ( \
                    SELECT COALESCE(SUM(lc.reltuples), 0)::bigint \
                    FROM pg_partition_tree(c.oid) pt \
                    JOIN pg_class lc ON lc.oid = pt.relid \
                    WHERE pt.isleaf) \
                WHEN c.reltuples >= 0 THEN c.reltuples::bigint \
                WHEN s.n_live_tup IS NOT NULL THEN s.n_live_tup \
                ELSE NULL \
            END as row_estimate, \
            CASE \
                WHEN c.relkind = 'p' THEN ( \
                    SELECT COALESCE(SUM(pg_total_relation_size(pt.relid)), 0)::bigint \
                    FROM pg_partition_tree(c.oid) pt WHERE pt.isleaf) \
                WHEN c.relkind IN ('r', 'm') THEN pg_total_relation_size(c.oid) \
                ELSE NULL \
            END as total_size_bytes, \
            (c.relkind = 'p') as is_partitioned, \
            CASE WHEN c.relkind = 'p' THEN pt2.partstrat::text ELSE NULL END as part_strat, \
            CASE WHEN c.relkind = 'p' THEN pg_get_partkeydef(c.oid) ELSE NULL END as part_key, \
            CASE WHEN c.relkind = 'p' THEN ( \
                SELECT count(*) FROM pg_inherits WHERE inhparent = c.oid)::bigint \
                ELSE NULL END as part_count \
         FROM pg_catalog.pg_class c \
         JOIN pg_catalog.pg_namespace n ON n.oid = c.relnamespace \
         LEFT JOIN pg_catalog.pg_stat_all_tables s ON s.relid = c.oid \
         LEFT JOIN pg_catalog.pg_partitioned_table pt2 ON pt2.partrelid = c.oid \
         WHERE n.nspname = '{}' \
           AND c.relkind IN ('r', 'v', 'm', 'f', 'p') \
           AND c.relispartition = false \
         ORDER BY \
            CASE c.relkind \
                WHEN 'r' THEN 1 \
                WHEN 'p' THEN 1 \
                WHEN 'f' THEN 2 \
                WHEN 'v' THEN 3 \
                WHEN 'm' THEN 4 \
            END, \
            c.relname",
        escaped
    );

    if let Ok(rows) = sqlx::raw_sql(&pg_catalog_sql).fetch_all(pool).await {
        let tables = rows
            .into_iter()
            .map(|row| {
                let table_type_str: String = row.get("table_type");
                let is_partitioned: bool = row.try_get("is_partitioned").unwrap_or(false);
                let part_strat: Option<String> = row.try_get("part_strat").ok().flatten();
                let partition_strategy = part_strat
                    .as_deref()
                    .and_then(|s| s.chars().next())
                    .and_then(PartitionStrategy::from_pg_char);
                TableInfo {
                    name: row.get("table_name"),
                    schema_name: schema_name.to_string(),
                    table_type: match table_type_str.as_str() {
                        "VIEW" => TableType::View,
                        "FOREIGN TABLE" => TableType::ForeignTable,
                        "PARTITIONED TABLE" => TableType::PartitionedTable,
                        _ => TableType::Table,
                    },
                    row_count_estimate: row.try_get("row_estimate").ok(),
                    total_size_bytes: row.try_get("total_size_bytes").ok().flatten(),
                    is_partitioned,
                    is_partition: false,
                    partition_strategy,
                    partition_key: row.try_get("part_key").ok().flatten(),
                    partition_bound: None,
                    partition_count: row.try_get("part_count").ok().flatten(),
                }
            })
            .collect();

        return Ok(tables);
    }

    // Fallback: use information_schema (works on ClickHouse and other PG-compatible servers)
    let fallback_sql = format!(
        "SELECT table_name, table_type \
         FROM information_schema.tables \
         WHERE table_schema = '{}' \
         ORDER BY table_type, table_name",
        escaped
    );

    let rows = sqlx::raw_sql(&fallback_sql).fetch_all(pool).await?;

    let tables = rows
        .into_iter()
        .filter_map(|row| {
            let table_type_str = raw_str(&row, "table_type").unwrap_or_default();
            Some(TableInfo {
                name: raw_str(&row, "table_name")?,
                schema_name: schema_name.to_string(),
                table_type: match table_type_str.as_str() {
                    "VIEW" => TableType::View,
                    "FOREIGN TABLE" => TableType::ForeignTable,
                    _ => TableType::Table,
                },
                row_count_estimate: None,
                total_size_bytes: None,
                is_partitioned: false,
                is_partition: false,
                partition_strategy: None,
                partition_key: None,
                partition_bound: None,
                partition_count: None,
            })
        })
        .collect();

    Ok(tables)
}

/// Get the direct child partitions of a partitioned parent table.
pub async fn get_partitions(
    pool: &PgPool,
    schema_name: &str,
    parent_table: &str,
) -> Result<Vec<TableInfo>, sqlx::Error> {
    let escaped_schema = escape_sql_literal(schema_name);
    let escaped_parent = escape_sql_literal(parent_table);

    let sql = format!(
        "SELECT \
            c.relname as table_name, \
            c.relkind::text as relkind, \
            CASE \
                WHEN c.relkind = 'p' THEN ( \
                    SELECT COALESCE(SUM(lc.reltuples), 0)::bigint \
                    FROM pg_partition_tree(c.oid) pt \
                    JOIN pg_class lc ON lc.oid = pt.relid WHERE pt.isleaf) \
                WHEN c.reltuples >= 0 THEN c.reltuples::bigint \
                ELSE NULL \
            END as row_estimate, \
            CASE \
                WHEN c.relkind = 'p' THEN ( \
                    SELECT COALESCE(SUM(pg_total_relation_size(pt.relid)), 0)::bigint \
                    FROM pg_partition_tree(c.oid) pt WHERE pt.isleaf) \
                WHEN c.relkind = 'r' THEN pg_total_relation_size(c.oid) \
                ELSE NULL \
            END as total_size_bytes, \
            pg_get_expr(c.relpartbound, c.oid) as part_bound, \
            (c.relkind = 'p') as is_partitioned, \
            CASE WHEN c.relkind = 'p' THEN pt2.partstrat::text ELSE NULL END as part_strat, \
            CASE WHEN c.relkind = 'p' THEN pg_get_partkeydef(c.oid) ELSE NULL END as part_key, \
            CASE WHEN c.relkind = 'p' THEN ( \
                SELECT count(*) FROM pg_inherits WHERE inhparent = c.oid)::bigint \
                ELSE NULL END as part_count, \
            cn.nspname as child_schema \
         FROM pg_catalog.pg_inherits i \
         JOIN pg_catalog.pg_class parent ON parent.oid = i.inhparent \
         JOIN pg_catalog.pg_namespace pn ON pn.oid = parent.relnamespace \
         JOIN pg_catalog.pg_class c ON c.oid = i.inhrelid \
         JOIN pg_catalog.pg_namespace cn ON cn.oid = c.relnamespace \
         LEFT JOIN pg_catalog.pg_partitioned_table pt2 ON pt2.partrelid = c.oid \
         WHERE pn.nspname = '{}' AND parent.relname = '{}' \
         ORDER BY c.relname",
        escaped_schema, escaped_parent
    );

    let rows = sqlx::raw_sql(&sql).fetch_all(pool).await?;
    let partitions = rows
        .into_iter()
        .map(|row| {
            let relkind: String = row.get("relkind");
            let is_partitioned: bool = row.try_get("is_partitioned").unwrap_or(false);
            let part_strat: Option<String> = row.try_get("part_strat").ok().flatten();
            let partition_strategy = part_strat
                .as_deref()
                .and_then(|s| s.chars().next())
                .and_then(PartitionStrategy::from_pg_char);
            let table_type = match relkind.as_str() {
                "p" => TableType::PartitionedTable,
                "f" => TableType::ForeignTable,
                _ => TableType::Table,
            };
            TableInfo {
                name: row.get("table_name"),
                schema_name: row.get("child_schema"),
                table_type,
                row_count_estimate: row.try_get("row_estimate").ok().flatten(),
                total_size_bytes: row.try_get("total_size_bytes").ok().flatten(),
                is_partitioned,
                is_partition: true,
                partition_strategy,
                partition_key: row.try_get("part_key").ok().flatten(),
                partition_bound: row.try_get("part_bound").ok().flatten(),
                partition_count: row.try_get("part_count").ok().flatten(),
            }
        })
        .collect();

    Ok(partitions)
}

/// Get a flat parent→child name map for all partitioned parents in a schema.
/// Used to populate the sidebar filter index without loading full partition detail.
pub async fn get_partition_map(
    pool: &PgPool,
    schema_name: &str,
) -> Result<Vec<PartitionRef>, sqlx::Error> {
    let escaped = escape_sql_literal(schema_name);
    let sql = format!(
        "SELECT parent.relname as parent_name, c.relname as name \
         FROM pg_catalog.pg_inherits i \
         JOIN pg_catalog.pg_class parent ON parent.oid = i.inhparent \
         JOIN pg_catalog.pg_namespace pn ON pn.oid = parent.relnamespace \
         JOIN pg_catalog.pg_class c ON c.oid = i.inhrelid \
         WHERE pn.nspname = '{}' AND parent.relkind = 'p'",
        escaped
    );
    let rows = sqlx::raw_sql(&sql).fetch_all(pool).await?;
    let refs = rows
        .into_iter()
        .map(|row| PartitionRef {
            parent_name: row.get("parent_name"),
            name: row.get("name"),
        })
        .collect();
    Ok(refs)
}

/// Get all columns for a table
pub async fn get_columns(
    pool: &PgPool,
    schema_name: &str,
    table_name: &str,
) -> Result<Vec<ColumnInfo>, sqlx::Error> {
    let escaped_schema = escape_sql_literal(schema_name);
    let escaped_table = escape_sql_literal(table_name);

    // Try the full query with PK detection first
    let full_sql = format!(
        "SELECT \
            c.column_name, \
            c.data_type, \
            c.is_nullable, \
            c.ordinal_position, \
            c.column_default, \
            CASE WHEN pk.column_name IS NOT NULL THEN true ELSE false END as is_primary_key \
         FROM information_schema.columns c \
         LEFT JOIN ( \
            SELECT kcu.column_name \
            FROM information_schema.table_constraints tc \
            JOIN information_schema.key_column_usage kcu \
                ON tc.constraint_name = kcu.constraint_name \
                AND tc.table_schema = kcu.table_schema \
            WHERE tc.constraint_type = 'PRIMARY KEY' \
                AND tc.table_schema = '{}' \
                AND tc.table_name = '{}' \
         ) pk ON c.column_name = pk.column_name \
         WHERE c.table_schema = '{}' \
           AND c.table_name = '{}' \
         ORDER BY c.ordinal_position",
        escaped_schema, escaped_table, escaped_schema, escaped_table
    );

    if let Ok(rows) = sqlx::raw_sql(&full_sql).fetch_all(pool).await {
        let columns: Vec<ColumnInfo> = rows
            .into_iter()
            .filter_map(|row| {
                let is_pk_str = raw_str(&row, "is_primary_key").unwrap_or_default();
                Some(ColumnInfo {
                    name: raw_str(&row, "column_name")?,
                    data_type: raw_str(&row, "data_type").unwrap_or_default(),
                    is_nullable: raw_str(&row, "is_nullable").as_deref() == Some("YES"),
                    is_primary_key: matches!(is_pk_str.as_str(), "t" | "true" | "1"),
                    ordinal_position: raw_str(&row, "ordinal_position")
                        .and_then(|s| s.parse().ok())
                        .unwrap_or(0),
                    column_default: raw_str(&row, "column_default"),
                })
            })
            .collect();
        if !columns.is_empty() {
            return Ok(columns);
        }
    }

    // Fallback: simpler query without PK detection
    let fallback_sql = format!(
        "SELECT \
            column_name, \
            data_type, \
            is_nullable, \
            ordinal_position, \
            column_default \
         FROM information_schema.columns \
         WHERE table_schema = '{}' \
           AND table_name = '{}' \
         ORDER BY ordinal_position",
        escaped_schema, escaped_table
    );

    let rows = sqlx::raw_sql(&fallback_sql).fetch_all(pool).await?;

    let columns = rows
        .into_iter()
        .filter_map(|row| {
            Some(ColumnInfo {
                name: raw_str(&row, "column_name")?,
                data_type: raw_str(&row, "data_type").unwrap_or_default(),
                is_nullable: raw_str(&row, "is_nullable").as_deref() == Some("YES"),
                is_primary_key: false,
                ordinal_position: raw_str(&row, "ordinal_position")
                    .and_then(|s| s.parse().ok())
                    .unwrap_or(0),
                column_default: raw_str(&row, "column_default"),
            })
        })
        .collect();

    Ok(columns)
}

/// Get all columns for all tables in a schema (batch query).
/// Returns columns grouped by table name via the table_name field on each row.
pub async fn get_schema_columns(
    pool: &PgPool,
    schema_name: &str,
) -> Result<Vec<SchemaColumnInfo>, sqlx::Error> {
    let escaped_schema = escape_sql_literal(schema_name);

    // Try the full query with PK detection first
    let full_sql = format!(
        "SELECT \
            c.table_name, \
            c.column_name, \
            c.data_type, \
            c.is_nullable, \
            c.ordinal_position, \
            c.column_default, \
            CASE WHEN pk.column_name IS NOT NULL THEN true ELSE false END as is_primary_key \
         FROM information_schema.columns c \
         LEFT JOIN ( \
            SELECT kcu.table_name, kcu.column_name \
            FROM information_schema.table_constraints tc \
            JOIN information_schema.key_column_usage kcu \
                ON tc.constraint_name = kcu.constraint_name \
                AND tc.table_schema = kcu.table_schema \
            WHERE tc.constraint_type = 'PRIMARY KEY' \
                AND tc.table_schema = '{}' \
         ) pk ON c.table_name = pk.table_name AND c.column_name = pk.column_name \
         WHERE c.table_schema = '{}' \
         ORDER BY c.table_name, c.ordinal_position",
        escaped_schema, escaped_schema
    );

    if let Ok(rows) = sqlx::raw_sql(&full_sql).fetch_all(pool).await {
        let columns: Vec<SchemaColumnInfo> = rows
            .into_iter()
            .filter_map(|row| {
                let is_pk_str = raw_str(&row, "is_primary_key").unwrap_or_default();
                Some(SchemaColumnInfo {
                    table_name: raw_str(&row, "table_name")?,
                    name: raw_str(&row, "column_name")?,
                    data_type: raw_str(&row, "data_type").unwrap_or_default(),
                    is_nullable: raw_str(&row, "is_nullable").as_deref() == Some("YES"),
                    is_primary_key: matches!(is_pk_str.as_str(), "t" | "true" | "1"),
                    ordinal_position: raw_str(&row, "ordinal_position")
                        .and_then(|s| s.parse().ok())
                        .unwrap_or(0),
                    column_default: raw_str(&row, "column_default"),
                })
            })
            .collect();
        if !columns.is_empty() {
            return Ok(columns);
        }
    }

    // Fallback: simpler query without PK detection
    let fallback_sql = format!(
        "SELECT \
            table_name, \
            column_name, \
            data_type, \
            is_nullable, \
            ordinal_position, \
            column_default \
         FROM information_schema.columns \
         WHERE table_schema = '{}' \
         ORDER BY table_name, ordinal_position",
        escaped_schema
    );

    let rows = sqlx::raw_sql(&fallback_sql).fetch_all(pool).await?;

    let columns = rows
        .into_iter()
        .filter_map(|row| {
            Some(SchemaColumnInfo {
                table_name: raw_str(&row, "table_name")?,
                name: raw_str(&row, "column_name")?,
                data_type: raw_str(&row, "data_type").unwrap_or_default(),
                is_nullable: raw_str(&row, "is_nullable").as_deref() == Some("YES"),
                is_primary_key: false,
                ordinal_position: raw_str(&row, "ordinal_position")
                    .and_then(|s| s.parse().ok())
                    .unwrap_or(0),
                column_default: raw_str(&row, "column_default"),
            })
        })
        .collect();

    Ok(columns)
}

/// Get indexes for a table
pub async fn get_table_indexes(
    pool: &PgPool,
    schema_name: &str,
    table_name: &str,
) -> Result<Vec<IndexInfo>, sqlx::Error> {
    let escaped_schema = escape_sql_literal(schema_name);
    let escaped_table = escape_sql_literal(table_name);

    let sql = format!(
        "SELECT \
            i.relname AS index_name, \
            am.amname AS index_type, \
            ix.indisunique AS is_unique, \
            ix.indisprimary AS is_primary, \
            pg_relation_size(i.oid) AS size_bytes, \
            ARRAY( \
                SELECT a.attname \
                FROM unnest(ix.indkey) WITH ORDINALITY AS k(attnum, ord) \
                JOIN pg_attribute a ON a.attrelid = t.oid AND a.attnum = k.attnum \
                ORDER BY k.ord \
            ) AS columns \
         FROM pg_index ix \
         JOIN pg_class t ON t.oid = ix.indrelid \
         JOIN pg_class i ON i.oid = ix.indexrelid \
         JOIN pg_namespace n ON n.oid = t.relnamespace \
         JOIN pg_am am ON am.oid = i.relam \
         WHERE n.nspname = '{}' AND t.relname = '{}' \
         ORDER BY ix.indisprimary DESC, i.relname",
        escaped_schema, escaped_table
    );

    let rows = sqlx::raw_sql(&sql).fetch_all(pool).await?;

    let indexes = rows
        .into_iter()
        .map(|row| IndexInfo {
            name: row.get("index_name"),
            columns: row.get("columns"),
            is_unique: row.get("is_unique"),
            is_primary: row.get("is_primary"),
            index_type: row.get("index_type"),
            size_bytes: row.try_get("size_bytes").ok(),
        })
        .collect();

    Ok(indexes)
}

/// Get constraints for a table
pub async fn get_table_constraints(
    pool: &PgPool,
    schema_name: &str,
    table_name: &str,
) -> Result<Vec<ConstraintInfo>, sqlx::Error> {
    let escaped_schema = escape_sql_literal(schema_name);
    let escaped_table = escape_sql_literal(table_name);

    let sql = format!(
        "SELECT \
            con.conname AS constraint_name, \
            CASE con.contype \
                WHEN 'p' THEN 'PRIMARY KEY' \
                WHEN 'f' THEN 'FOREIGN KEY' \
                WHEN 'u' THEN 'UNIQUE' \
                WHEN 'c' THEN 'CHECK' \
                WHEN 'x' THEN 'EXCLUSION' \
                ELSE 'OTHER' \
            END AS constraint_type, \
            ARRAY( \
                SELECT a.attname \
                FROM unnest(con.conkey) WITH ORDINALITY AS k(attnum, ord) \
                JOIN pg_attribute a ON a.attrelid = con.conrelid AND a.attnum = k.attnum \
                ORDER BY k.ord \
            ) AS columns, \
            CASE WHEN con.contype = 'f' THEN \
                (SELECT n2.nspname || '.' || c2.relname \
                 FROM pg_class c2 \
                 JOIN pg_namespace n2 ON n2.oid = c2.relnamespace \
                 WHERE c2.oid = con.confrelid) \
            ELSE NULL END AS referenced_table, \
            CASE WHEN con.contype = 'f' THEN \
                ARRAY( \
                    SELECT a.attname \
                    FROM unnest(con.confkey) WITH ORDINALITY AS k(attnum, ord) \
                    JOIN pg_attribute a ON a.attrelid = con.confrelid AND a.attnum = k.attnum \
                    ORDER BY k.ord \
                ) \
            ELSE NULL END AS referenced_columns, \
            CASE WHEN con.contype = 'c' THEN \
                pg_get_constraintdef(con.oid) \
            ELSE NULL END AS check_clause \
         FROM pg_constraint con \
         JOIN pg_class t ON t.oid = con.conrelid \
         JOIN pg_namespace n ON n.oid = t.relnamespace \
         WHERE n.nspname = '{}' AND t.relname = '{}' \
         ORDER BY \
            CASE con.contype \
                WHEN 'p' THEN 1 \
                WHEN 'u' THEN 2 \
                WHEN 'f' THEN 3 \
                WHEN 'c' THEN 4 \
                ELSE 5 \
            END, \
            con.conname",
        escaped_schema, escaped_table
    );

    let rows = sqlx::raw_sql(&sql).fetch_all(pool).await?;

    let constraints = rows
        .into_iter()
        .map(|row| ConstraintInfo {
            name: row.get("constraint_name"),
            constraint_type: row.get("constraint_type"),
            columns: row.get("columns"),
            referenced_table: row.try_get("referenced_table").ok().flatten(),
            referenced_columns: row.try_get("referenced_columns").ok().flatten(),
            check_clause: row.try_get("check_clause").ok().flatten(),
        })
        .collect();

    Ok(constraints)
}

/// Read the raw parts (columns, constraints, non-constraint indexes) needed to
/// reconstruct a table's CREATE TABLE DDL.
pub async fn get_table_ddl_parts(
    pool: &PgPool,
    schema_name: &str,
    table_name: &str,
) -> Result<TableDdlParts, sqlx::Error> {
    let escaped_schema = escape_sql_literal(schema_name);
    let escaped_table = escape_sql_literal(table_name);

    // Columns — precise types via format_type, defaults via pg_get_expr,
    // identity/generated via attidentity/attgenerated (cast ::text).
    let col_sql = format!(
        "SELECT \
            a.attname AS name, \
            pg_catalog.format_type(a.atttypid, a.atttypmod) AS type, \
            a.attnotnull AS not_null, \
            pg_get_expr(ad.adbin, ad.adrelid) AS default_expr, \
            a.attidentity::text AS identity, \
            a.attgenerated::text AS generated \
         FROM pg_attribute a \
         JOIN pg_class t ON t.oid = a.attrelid \
         JOIN pg_namespace n ON n.oid = t.relnamespace \
         LEFT JOIN pg_attrdef ad ON ad.adrelid = a.attrelid AND ad.adnum = a.attnum \
         WHERE n.nspname = '{}' AND t.relname = '{}' \
           AND a.attnum > 0 AND NOT a.attisdropped \
         ORDER BY a.attnum",
        escaped_schema, escaped_table
    );
    let col_rows = sqlx::raw_sql(&col_sql).fetch_all(pool).await?;
    let columns: Vec<DdlColumn> = col_rows
        .into_iter()
        .filter_map(|row| {
            Some(DdlColumn {
                name: raw_str(&row, "name")?,
                type_str: raw_str(&row, "type").unwrap_or_default(),
                not_null: raw_str(&row, "not_null").as_deref() == Some("t"),
                default_expr: raw_str(&row, "default_expr"),
                identity: raw_str(&row, "identity").unwrap_or_default(),
                generated: raw_str(&row, "generated").unwrap_or_default(),
            })
        })
        .collect();

    // Constraints — full definitions via pg_get_constraintdef, ordered PK, UNIQUE, CHECK, FK.
    // EXCLUDE ('x') constraints are out of scope for reconstructed DDL.
    let con_sql = format!(
        "SELECT con.conname AS name, pg_get_constraintdef(con.oid) AS def \
         FROM pg_constraint con \
         JOIN pg_class t ON t.oid = con.conrelid \
         JOIN pg_namespace n ON n.oid = t.relnamespace \
         WHERE n.nspname = '{}' AND t.relname = '{}' \
           AND con.contype IN ('p', 'u', 'c', 'f') \
         ORDER BY CASE con.contype \
             WHEN 'p' THEN 1 WHEN 'u' THEN 2 WHEN 'c' THEN 3 WHEN 'f' THEN 4 ELSE 5 END, \
           con.conname",
        escaped_schema, escaped_table
    );
    let con_rows = sqlx::raw_sql(&con_sql).fetch_all(pool).await?;
    let constraints: Vec<DdlConstraint> = con_rows
        .into_iter()
        .filter_map(|row| {
            Some(DdlConstraint {
                name: raw_str(&row, "name")?,
                definition: raw_str(&row, "def").unwrap_or_default(),
            })
        })
        .collect();

    // Non-constraint indexes only — exclude the PK index and any index backing a
    // constraint (those are already emitted as constraints).
    let idx_sql = format!(
        "SELECT pg_get_indexdef(ix.indexrelid) AS def \
         FROM pg_index ix \
         JOIN pg_class i ON i.oid = ix.indexrelid \
         JOIN pg_class t ON t.oid = ix.indrelid \
         JOIN pg_namespace n ON n.oid = t.relnamespace \
         WHERE n.nspname = '{}' AND t.relname = '{}' \
           AND NOT ix.indisprimary \
           AND NOT EXISTS (SELECT 1 FROM pg_constraint c WHERE c.conindid = ix.indexrelid) \
         ORDER BY i.relname",
        escaped_schema, escaped_table
    );
    let idx_rows = sqlx::raw_sql(&idx_sql).fetch_all(pool).await?;
    let index_defs: Vec<String> = idx_rows
        .into_iter()
        .filter_map(|row| raw_str(&row, "def"))
        .collect();

    // Partition clause (NULL for non-partitioned tables).
    let part_sql = format!(
        "SELECT pg_get_partkeydef(t.oid) AS def \
         FROM pg_class t \
         JOIN pg_namespace n ON n.oid = t.relnamespace \
         WHERE n.nspname = '{}' AND t.relname = '{}'",
        escaped_schema, escaped_table
    );
    let part_rows = sqlx::raw_sql(&part_sql).fetch_all(pool).await?;
    let partition_by: Option<String> = part_rows.into_iter().next().and_then(|row| raw_str(&row, "def"));

    Ok(TableDdlParts {
        columns,
        constraints,
        index_defs,
        partition_by,
    })
}

/// Get functions and procedures in a schema
pub async fn get_schema_functions(
    pool: &PgPool,
    schema_name: &str,
) -> Result<Vec<FunctionInfo>, sqlx::Error> {
    let escaped_schema = escape_sql_literal(schema_name);

    let sql = format!(
        "SELECT \
            p.proname AS func_name, \
            n.nspname AS schema_name, \
            pg_catalog.format_type(p.prorettype, NULL) AS return_type, \
            pg_catalog.pg_get_function_arguments(p.oid) AS argument_types, \
            CASE p.prokind \
                WHEN 'f' THEN 'function' \
                WHEN 'p' THEN 'procedure' \
                WHEN 'a' THEN 'aggregate' \
                WHEN 'w' THEN 'window' \
                ELSE 'function' \
            END AS function_type, \
            l.lanname AS language \
         FROM pg_catalog.pg_proc p \
         JOIN pg_catalog.pg_namespace n ON n.oid = p.pronamespace \
         JOIN pg_catalog.pg_language l ON l.oid = p.prolang \
         WHERE n.nspname = '{}' AND p.prokind IN ('f', 'p') \
         ORDER BY p.proname",
        escaped_schema
    );

    let rows = sqlx::raw_sql(&sql).fetch_all(pool).await?;

    let functions = rows
        .into_iter()
        .map(|row| FunctionInfo {
            name: row.get("func_name"),
            schema_name: row.get("schema_name"),
            return_type: row.get("return_type"),
            argument_types: row.get("argument_types"),
            function_type: row.get("function_type"),
            language: row.get("language"),
        })
        .collect();

    Ok(functions)
}

/// Fetch the display name and the key indexes of each table OID.
///
/// The OIDs are formatted into the SQL, not bound. `raw_sql` (the simple query
/// protocol this codebase uses for metadata) accepts no bind parameter. The
/// OIDs arrive from the server as `u32`, so a formatted integer list is safe;
/// they never pass through a string escape.
pub async fn get_table_key_info(
    pool: &PgPool,
    oids: &[u32],
) -> Result<HashMap<u32, TableKeyInfo>, sqlx::Error> {
    if oids.is_empty() {
        return Ok(HashMap::new());
    }
    let oid_list = oids
        .iter()
        .map(|o| o.to_string())
        .collect::<Vec<_>>()
        .join(", ");

    // 1. Display names. A table with no row here was dropped between the query
    //    and this lookup; it simply gets no entry.
    let name_sql = format!(
        "SELECT c.oid::text AS oid, n.nspname || '.' || c.relname AS display \
         FROM pg_class c \
         JOIN pg_namespace n ON n.oid = c.relnamespace \
         WHERE c.oid IN ({})",
        oid_list
    );
    let mut out: HashMap<u32, TableKeyInfo> = HashMap::new();
    let name_rows = sqlx::raw_sql(&name_sql).fetch_all(pool).await?;
    for row in name_rows {
        let oid_str: String = row.try_get("oid")?;
        let display: String = row.try_get("display")?;
        if let Ok(oid) = oid_str.parse::<u32>() {
            out.insert(oid, TableKeyInfo { display, candidates: Vec::new() });
        }
    }

    // 2. Key indexes.
    //    - `k.ord <= ix.indnkeyatts` drops INCLUDE columns: PostgreSQL 11 and
    //      later put them into indkey AFTER the key columns.
    //    - `indisvalid` drops a failed CREATE INDEX CONCURRENTLY, which is not
    //      unique in fact. `indimmediate` drops a DEFERRABLE INITIALLY
    //      DEFERRED constraint, which permits duplicate rows inside a
    //      transaction. It does NOT drop DEFERRABLE INITIALLY IMMEDIATE, which
    //      SET CONSTRAINTS can still defer; accepted, because we read
    //      committed data.
    //    - `indexprs IS NULL` is load-bearing, and NOT for the obvious reason.
    //      A pure expression index never reaches the output anyway: its indkey
    //      entry is 0 and the pg_attribute join matches no row. The guard is
    //      for a MIXED index such as UNIQUE (n, lower(tag)), indkey "1 0",
    //      where the join drops only the expression half and keeps the plain
    //      half — reporting key_attnums = {1}, a false claim that n alone is
    //      unique. Verified on a live server; do not remove after testing only
    //      a pure expression index. See scripts/tagtest-schema.sql.
    //    - `unnest(...) WITH ORDINALITY` keeps the key column order, the same
    //      idiom `get_table_indexes` uses above.
    //    - `indisprimary` and `attnotnull` are real booleans and decode with
    //      no cast. Only the OID and the int2vector need care.
    let index_sql = format!(
        "SELECT ix.indrelid::text AS table_oid, \
                ix.indisprimary AS is_primary, \
                bool_and(a.attnotnull) AS all_not_null, \
                array_agg(k.attnum ORDER BY k.ord)::text AS key_attnums \
         FROM pg_index ix \
         CROSS JOIN unnest(ix.indkey) WITH ORDINALITY AS k(attnum, ord) \
         JOIN pg_attribute a ON a.attrelid = ix.indrelid AND a.attnum = k.attnum \
         WHERE ix.indrelid IN ({}) \
           AND k.ord <= ix.indnkeyatts \
           AND (ix.indisprimary OR ix.indisunique) \
           AND ix.indisvalid AND ix.indimmediate \
           AND ix.indpred IS NULL AND ix.indexprs IS NULL \
         GROUP BY ix.indrelid, ix.indexrelid, ix.indisprimary",
        oid_list
    );
    let index_rows = sqlx::raw_sql(&index_sql).fetch_all(pool).await?;
    for row in index_rows {
        let oid_str: String = row.try_get("table_oid")?;
        let is_primary: bool = row.try_get("is_primary")?;
        let all_not_null: bool = row.try_get("all_not_null").unwrap_or(false);
        let attnums_str: String = row.try_get("key_attnums")?;
        let Ok(oid) = oid_str.parse::<u32>() else { continue };

        let column_attnums = parse_int_array(&attnums_str);
        if column_attnums.is_empty() {
            continue;
        }
        if let Some(info) = out.get_mut(&oid) {
            info.candidates.push(KeyCandidate { column_attnums, is_primary, all_not_null });
        }
    }

    Ok(out)
}

/// Parse a PostgreSQL integer array literal such as "{1,2}" into i16 values.
/// Used for `indkey` attnums, which arrive as text because an int2vector has no
/// sqlx decoder.
fn parse_int_array(text: &str) -> Vec<i16> {
    text.trim_matches(|c| c == '{' || c == '}')
        .split(',')
        .filter(|s| !s.trim().is_empty())
        .filter_map(|s| s.trim().parse::<i16>().ok())
        .collect()
}

#[cfg(test)]
mod parse_int_array_tests {
    use super::parse_int_array;

    #[test]
    fn parses_a_single_column_key() {
        assert_eq!(parse_int_array("{1}"), vec![1]);
    }
    #[test]
    fn parses_a_compound_key_in_order() {
        assert_eq!(parse_int_array("{3,1}"), vec![3, 1]);
    }
    #[test]
    fn an_empty_array_is_empty() {
        assert_eq!(parse_int_array("{}"), Vec::<i16>::new());
    }
}

/// Opt-in live test of the catalogue query. `cargo test` skips it; run it with
///
///   cargo test --release get_table_key_info -- --ignored --nocapture
///
/// It exists because the three `parse_int_array` tests prove string parsing and
/// NOTHING about the sqlx decode seam, and that seam has already hidden a bug
/// here: a PostgreSQL internal type can panic or silently yield `None` in a
/// decode. Only a real connection exercises it.
///
/// Fixture: `scripts/tagtest-schema.sql`.
#[cfg(test)]
mod live_key_info_tests {
    use super::get_table_key_info;
    use crate::models::KeyCandidate;
    use sqlx::postgres::PgPoolOptions;
    use sqlx::Row;
    use std::collections::HashMap;

    const DEFAULT_URL: &str = "postgres://nfinn@localhost:5432/nfinn";

    /// Look up the OIDs of the named `tagtest` tables. An empty map means the
    /// fixture schema is absent.
    async fn tagtest_oids(pool: &sqlx::PgPool) -> HashMap<String, u32> {
        let sql = "SELECT c.relname AS name, c.oid::text AS oid \
                   FROM pg_class c \
                   JOIN pg_namespace n ON n.oid = c.relnamespace \
                   WHERE n.nspname = 'tagtest' AND c.relkind = 'r'";
        let rows = sqlx::raw_sql(sql).fetch_all(pool).await.expect("catalogue lookup failed");
        let mut map = HashMap::new();
        for row in rows {
            let name: String = row.try_get("name").expect("name decode failed");
            let oid_str: String = row.try_get("oid").expect("oid decode failed");
            if let Ok(oid) = oid_str.parse::<u32>() {
                map.insert(name, oid);
            }
        }
        map
    }

    /// The candidate whose `column_attnums` match, or a panic naming what the
    /// table actually returned. A blind `candidates[0]` would hide an ordering
    /// change; this reports the whole set on failure.
    fn candidate_with<'a>(
        candidates: &'a [KeyCandidate],
        attnums: &[i16],
        table: &str,
    ) -> &'a KeyCandidate {
        candidates
            .iter()
            .find(|c| c.column_attnums == attnums)
            .unwrap_or_else(|| {
                panic!("{}: no candidate with attnums {:?}; got {:?}", table, attnums, candidates)
            })
    }

    #[test]
    #[ignore = "needs a live PostgreSQL with scripts/tagtest-schema.sql loaded"]
    fn get_table_key_info_reads_the_live_catalogue() {
        let url = std::env::var("PHAROS_TEST_DATABASE_URL")
            .unwrap_or_else(|_| DEFAULT_URL.to_string());
        let rt = tokio::runtime::Runtime::new().expect("tokio runtime");

        rt.block_on(async move {
            let pool = PgPoolOptions::new()
                .max_connections(1)
                .connect(&url)
                .await
                .unwrap_or_else(|e| {
                    panic!(
                        "cannot connect to {}: {}. Set PHAROS_TEST_DATABASE_URL.",
                        url, e
                    )
                });

            let oids = tagtest_oids(&pool).await;
            if oids.is_empty() {
                eprintln!(
                    "SKIP: schema `tagtest` not found in {}. Load the fixture first: \
                     psql -d <db> -f scripts/tagtest-schema.sql",
                    url
                );
                return;
            }
            for needed in ["users", "memberships", "include_demo", "nullable_codes"] {
                if !oids.contains_key(needed) {
                    eprintln!(
                        "SKIP: schema `tagtest` is present but table `{}` is missing. \
                         Reload scripts/tagtest-schema.sql",
                        needed
                    );
                    return;
                }
            }

            let users_oid = oids["users"];
            let memberships_oid = oids["memberships"];
            let include_oid = oids["include_demo"];
            let nullable_oid = oids["nullable_codes"];

            let info = get_table_key_info(
                &pool,
                &[users_oid, memberships_oid, include_oid, nullable_oid],
            )
            .await
            .expect("get_table_key_info failed");

            // --- users: a primary key AND a unique key ----------------------
            let users = info.get(&users_oid).expect("no entry for tagtest.users");
            assert_eq!(users.display, "tagtest.users", "display name");
            assert_eq!(
                users.candidates.len(),
                2,
                "users should have 2 candidates, got {:?}",
                users.candidates
            );
            let pk = candidate_with(&users.candidates, &[1], "users");
            assert!(pk.is_primary, "users {{1}} should be the primary key");
            assert!(pk.all_not_null, "users.id is NOT NULL");
            let uq = candidate_with(&users.candidates, &[2], "users");
            assert!(!uq.is_primary, "users {{2}} is a unique key, not the pk");
            assert!(uq.all_not_null, "users.email is NOT NULL");

            // --- memberships: a COMPOUND primary key, order matters ---------
            let memberships =
                info.get(&memberships_oid).expect("no entry for tagtest.memberships");
            assert_eq!(
                memberships.candidates.len(),
                1,
                "memberships should have 1 candidate, got {:?}",
                memberships.candidates
            );
            let compound = &memberships.candidates[0];
            assert!(compound.is_primary, "memberships candidate is the pk");
            assert_eq!(
                compound.column_attnums,
                vec![1, 2],
                "compound key must keep index order (user_id, team_id)"
            );

            // --- include_demo: the INCLUDE-column guard ---------------------
            // Without `k.ord <= ix.indnkeyatts` this reads {1,2} and
            // all_not_null flips to false, discarding a good key.
            let include = info.get(&include_oid).expect("no entry for tagtest.include_demo");
            assert_eq!(
                include.candidates.len(),
                1,
                "include_demo should have 1 candidate, got {:?}",
                include.candidates
            );
            assert_eq!(
                include.candidates[0].column_attnums,
                vec![1],
                "INCLUDE column must not enter the key: {:?}",
                include.candidates
            );
            assert!(
                include.candidates[0].all_not_null,
                "include_demo.k is NOT NULL; payload's nullability must not leak in"
            );

            // --- nullable_codes: reported, but all_not_null = false ---------
            let nullable =
                info.get(&nullable_oid).expect("no entry for tagtest.nullable_codes");
            assert_eq!(
                nullable.candidates.len(),
                1,
                "nullable_codes should have 1 candidate, got {:?}",
                nullable.candidates
            );
            assert!(
                !nullable.candidates[0].all_not_null,
                "a unique index on a NULLABLE column must report all_not_null = false"
            );

            println!("live catalogue read OK:");
            for (oid, entry) in &info {
                println!("  {} oid={} candidates={:?}", entry.display, oid, entry.candidates);
            }
        });
    }
}
