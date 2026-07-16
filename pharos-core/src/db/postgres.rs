use sqlx::postgres::PgPoolOptions;
use sqlx::{Executor, PgPool, Row, ValueRef};
use std::collections::HashSet;
use std::time::{Duration, Instant};

use crate::models::{AnalyzeResult, ColumnInfo, ConnectionConfig, ConstraintInfo, FunctionInfo, IndexInfo, PartitionRef, PartitionStrategy, SchemaColumnInfo, SchemaInfo, TableInfo, TableType};
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

    // Try to set session-level safety timeouts. These are PostgreSQL-specific
    // and will fail (and may kill the connection) on non-PG servers like
    // ClickHouse, so we run them after pool creation on a separate connection
    // rather than in after_connect where a failure poisons every connection.
    if let Ok(mut conn) = pool.acquire().await {
        let ok = (&mut *conn)
            .execute(sqlx::raw_sql(
                "SET idle_in_transaction_session_timeout = '30s'",
            ))
            .await
            .is_ok();
        if ok {
            let _ = (&mut *conn)
                .execute(sqlx::raw_sql("SET statement_timeout = '300000'"))
                .await;
        }
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

    Ok(TableDdlParts {
        columns,
        constraints,
        index_defs,
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
