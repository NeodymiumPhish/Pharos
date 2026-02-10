use sqlx::postgres::PgPoolOptions;
use sqlx::{PgPool, Row};
use std::collections::HashSet;
use std::time::{Duration, Instant};

use crate::models::{AnalyzeResult, ColumnInfo, ConnectionConfig, ConstraintInfo, FunctionInfo, IndexInfo, SchemaInfo, TableInfo, TableType};

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
            CASE WHEN c.reltuples >= 0 THEN c.reltuples::bigint ELSE NULL END as row_estimate,
            CASE WHEN c.relkind IN ('r', 'm') THEN pg_total_relation_size(c.oid) ELSE NULL END as total_size_bytes
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
                total_size_bytes: row.try_get("total_size_bytes").ok().flatten(),
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

/// Get indexes for a table
pub async fn get_table_indexes(
    pool: &PgPool,
    schema_name: &str,
    table_name: &str,
) -> Result<Vec<IndexInfo>, sqlx::Error> {
    let rows = sqlx::query(
        r#"
        SELECT
            i.relname AS index_name,
            am.amname AS index_type,
            ix.indisunique AS is_unique,
            ix.indisprimary AS is_primary,
            pg_relation_size(i.oid) AS size_bytes,
            ARRAY(
                SELECT a.attname
                FROM unnest(ix.indkey) WITH ORDINALITY AS k(attnum, ord)
                JOIN pg_attribute a ON a.attrelid = t.oid AND a.attnum = k.attnum
                ORDER BY k.ord
            ) AS columns
        FROM pg_index ix
        JOIN pg_class t ON t.oid = ix.indrelid
        JOIN pg_class i ON i.oid = ix.indexrelid
        JOIN pg_namespace n ON n.oid = t.relnamespace
        JOIN pg_am am ON am.oid = i.relam
        WHERE n.nspname = $1 AND t.relname = $2
        ORDER BY ix.indisprimary DESC, i.relname
        "#,
    )
    .bind(schema_name)
    .bind(table_name)
    .fetch_all(pool)
    .await?;

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
    let rows = sqlx::query(
        r#"
        SELECT
            con.conname AS constraint_name,
            CASE con.contype
                WHEN 'p' THEN 'PRIMARY KEY'
                WHEN 'f' THEN 'FOREIGN KEY'
                WHEN 'u' THEN 'UNIQUE'
                WHEN 'c' THEN 'CHECK'
                WHEN 'x' THEN 'EXCLUSION'
                ELSE 'OTHER'
            END AS constraint_type,
            ARRAY(
                SELECT a.attname
                FROM unnest(con.conkey) WITH ORDINALITY AS k(attnum, ord)
                JOIN pg_attribute a ON a.attrelid = con.conrelid AND a.attnum = k.attnum
                ORDER BY k.ord
            ) AS columns,
            CASE WHEN con.contype = 'f' THEN
                (SELECT n2.nspname || '.' || c2.relname
                 FROM pg_class c2
                 JOIN pg_namespace n2 ON n2.oid = c2.relnamespace
                 WHERE c2.oid = con.confrelid)
            ELSE NULL END AS referenced_table,
            CASE WHEN con.contype = 'f' THEN
                ARRAY(
                    SELECT a.attname
                    FROM unnest(con.confkey) WITH ORDINALITY AS k(attnum, ord)
                    JOIN pg_attribute a ON a.attrelid = con.confrelid AND a.attnum = k.attnum
                    ORDER BY k.ord
                )
            ELSE NULL END AS referenced_columns,
            CASE WHEN con.contype = 'c' THEN
                pg_get_constraintdef(con.oid)
            ELSE NULL END AS check_clause
        FROM pg_constraint con
        JOIN pg_class t ON t.oid = con.conrelid
        JOIN pg_namespace n ON n.oid = t.relnamespace
        WHERE n.nspname = $1 AND t.relname = $2
        ORDER BY
            CASE con.contype
                WHEN 'p' THEN 1
                WHEN 'u' THEN 2
                WHEN 'f' THEN 3
                WHEN 'c' THEN 4
                ELSE 5
            END,
            con.conname
        "#,
    )
    .bind(schema_name)
    .bind(table_name)
    .fetch_all(pool)
    .await?;

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

/// Get functions and procedures in a schema
pub async fn get_schema_functions(
    pool: &PgPool,
    schema_name: &str,
) -> Result<Vec<FunctionInfo>, sqlx::Error> {
    let rows = sqlx::query(
        r#"
        SELECT
            p.proname AS func_name,
            n.nspname AS schema_name,
            pg_catalog.format_type(p.prorettype, NULL) AS return_type,
            pg_catalog.pg_get_function_arguments(p.oid) AS argument_types,
            CASE p.prokind
                WHEN 'f' THEN 'function'
                WHEN 'p' THEN 'procedure'
                WHEN 'a' THEN 'aggregate'
                WHEN 'w' THEN 'window'
                ELSE 'function'
            END AS function_type,
            l.lanname AS language
        FROM pg_catalog.pg_proc p
        JOIN pg_catalog.pg_namespace n ON n.oid = p.pronamespace
        JOIN pg_catalog.pg_language l ON l.oid = p.prolang
        WHERE n.nspname = $1 AND p.prokind IN ('f', 'p')
        ORDER BY p.proname
        "#,
    )
    .bind(schema_name)
    .fetch_all(pool)
    .await?;

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

/// Generate CREATE TABLE DDL for a table
pub async fn generate_table_ddl(
    pool: &PgPool,
    schema_name: &str,
    table_name: &str,
) -> Result<String, sqlx::Error> {
    let columns = get_columns(pool, schema_name, table_name).await?;
    let constraints = get_table_constraints(pool, schema_name, table_name).await?;

    let mut ddl = format!(
        "CREATE TABLE \"{}\".\"{}\" (\n",
        schema_name.replace('"', "\"\""),
        table_name.replace('"', "\"\"")
    );

    // Column definitions
    let col_defs: Vec<String> = columns
        .iter()
        .map(|col| {
            let mut def = format!(
                "    \"{}\" {}",
                col.name.replace('"', "\"\""),
                col.data_type
            );
            if !col.is_nullable {
                def.push_str(" NOT NULL");
            }
            if let Some(ref default) = col.column_default {
                def.push_str(&format!(" DEFAULT {}", default));
            }
            def
        })
        .collect();

    // Constraint definitions
    let con_defs: Vec<String> = constraints
        .iter()
        .map(|con| {
            let cols = con
                .columns
                .iter()
                .map(|c| format!("\"{}\"", c.replace('"', "\"\"")))
                .collect::<Vec<_>>()
                .join(", ");

            match con.constraint_type.as_str() {
                "PRIMARY KEY" => {
                    format!("    CONSTRAINT \"{}\" PRIMARY KEY ({})", con.name, cols)
                }
                "UNIQUE" => {
                    format!("    CONSTRAINT \"{}\" UNIQUE ({})", con.name, cols)
                }
                "FOREIGN KEY" => {
                    let mut fk = format!(
                        "    CONSTRAINT \"{}\" FOREIGN KEY ({}) REFERENCES {}",
                        con.name,
                        cols,
                        con.referenced_table.as_deref().unwrap_or("?")
                    );
                    if let Some(ref ref_cols) = con.referenced_columns {
                        let rc = ref_cols
                            .iter()
                            .map(|c| format!("\"{}\"", c.replace('"', "\"\"")))
                            .collect::<Vec<_>>()
                            .join(", ");
                        fk.push_str(&format!(" ({})", rc));
                    }
                    fk
                }
                "CHECK" => {
                    if let Some(ref clause) = con.check_clause {
                        format!("    CONSTRAINT \"{}\" CHECK {}", con.name, clause)
                    } else {
                        format!("    CONSTRAINT \"{}\" CHECK (?)", con.name)
                    }
                }
                _ => {
                    format!("    CONSTRAINT \"{}\" {}", con.name, con.constraint_type)
                }
            }
        })
        .collect();

    let all_defs: Vec<String> = col_defs.into_iter().chain(con_defs).collect();
    ddl.push_str(&all_defs.join(",\n"));
    ddl.push_str("\n);");

    Ok(ddl)
}

/// Generate CREATE INDEX DDL using pg_get_indexdef
pub async fn generate_index_ddl(
    pool: &PgPool,
    schema_name: &str,
    index_name: &str,
) -> Result<String, sqlx::Error> {
    let row = sqlx::query(
        r#"
        SELECT pg_get_indexdef(i.oid) AS index_def
        FROM pg_class i
        JOIN pg_namespace n ON n.oid = i.relnamespace
        WHERE n.nspname = $1 AND i.relname = $2
        "#,
    )
    .bind(schema_name)
    .bind(index_name)
    .fetch_one(pool)
    .await?;

    let def: String = row.get("index_def");
    Ok(format!("{};", def))
}
