//! The navigator's catalog reads for DuckDB, on DuckDB's own `duckdb_*()`
//! table functions. DuckDB's `pg_catalog` views are thin projections with
//! constant columns and lack what Pharos's PostgreSQL catalog SQL needs, so
//! that SQL is not reused.
//!
//! Schema names: a schema of the database the record opened is its bare name
//! (`main`). A schema of another attached database is `database.schema`
//! (`other.main`), and every read here splits that form back with
//! `split_schema`.

use duckdb::{params, Connection};

use crate::commands::ddl::{TableDdl, TableShape};
use crate::models::{
    ColumnInfo, ConstraintInfo, DraftColumnFact, DraftEnum, DraftForeignKey, FunctionInfo, IndexInfo, SchemaColumnInfo,
    SchemaDraftFacts, SchemaInfo, TableInfo, TableType,
};

type Result<T> = std::result::Result<T, String>;

fn err(e: duckdb::Error) -> String {
    e.to_string()
}

/// A `VARCHAR[]` column as strings. duckdb-rs reads a LIST only as a `Value`.
fn list(row: &duckdb::Row<'_>, i: usize) -> duckdb::Result<Vec<String>> {
    Ok(list_or_none(row, i)?.unwrap_or_default())
}

fn list_or_none(row: &duckdb::Row<'_>, i: usize) -> duckdb::Result<Option<Vec<String>>> {
    use duckdb::types::Value;
    Ok(match row.get::<_, Value>(i)? {
        Value::Null => None,
        Value::List(items) | Value::Array(items) => Some(
            items
                .into_iter()
                .filter_map(|v| match v {
                    Value::Text(s) | Value::Enum(s) => Some(s),
                    Value::Null => None,
                    other => crate::db::duckdb::text::value_text(&other),
                })
                .collect(),
        ),
        other => crate::db::duckdb::text::value_text(&other).map(|s| vec![s]),
    })
}

/// The database the connection's names resolve against (`current_database()`).
pub fn current_database(conn: &Connection) -> Result<String> {
    conn.query_row("SELECT current_database()", [], |r| r.get(0)).map_err(err)
}

/// `(database, schema)` for a navigator schema name.
pub fn split_schema(conn: &Connection, name: &str) -> Result<(String, String)> {
    if let Some((db, schema)) = name.split_once('.') {
        let attached: bool = conn
            .query_row("SELECT count(*) > 0 FROM duckdb_databases() WHERE database_name = ?", params![db], |r| r.get(0))
            .map_err(err)?;
        if attached {
            return Ok((db.to_string(), schema.to_string()));
        }
    }
    Ok((current_database(conn)?, name.to_string()))
}

/// Every schema, the open file's first and unqualified, then the schemas of
/// other attached databases as `database.schema`. DuckDB's internal schemas
/// (`pg_catalog`, `information_schema`, the `system` catalog) show only with
/// "Show system schemas". The `temp` catalog never shows: catalog reads run
/// on a fresh connection, and temporary tables live on each tab's own, so it
/// was always empty here (a card lists its tab's with `SHOW ALL TABLES`).
/// `duckdb_schemas().internal` is not the system test: DuckDB marks `main`
/// itself internal.
pub fn schemas(conn: &Connection, include_system: bool) -> Result<Vec<SchemaInfo>> {
    let home = current_database(conn)?;
    let mut stmt = conn
        .prepare(
            "SELECT s.database_name, s.schema_name, d.internal \
             FROM duckdb_schemas() s JOIN duckdb_databases() d USING (database_name) \
             ORDER BY s.database_name <> current_database(), s.database_name, \
                      s.schema_name <> 'main', s.schema_name",
        )
        .map_err(err)?;
    let rows = stmt
        .query_map([], |r| Ok((r.get::<_, String>(0)?, r.get::<_, String>(1)?, r.get::<_, bool>(2)?)))
        .map_err(err)?;
    let mut out = Vec::new();
    for row in rows {
        let (db, schema, internal) = row.map_err(err)?;
        if db == "temp" {
            continue;
        }
        let system = internal || schema == "information_schema" || schema == "pg_catalog";
        if system && !include_system {
            continue;
        }
        let attached = db != home;
        let name = if attached { format!("{}.{}", db, schema) } else { schema };
        out.push(SchemaInfo { name, owner: None, attached_database: attached.then_some(db) });
    }
    Ok(out)
}

/// Tables and views of one schema. `estimated_size` is DuckDB's row count
/// estimate, which it keeps exact for a table it wrote itself.
pub fn tables(conn: &Connection, schema: &str) -> Result<Vec<TableInfo>> {
    let (db, schema_name) = split_schema(conn, schema)?;
    let mut stmt = conn
        .prepare(
            "SELECT table_name, 'table', estimated_size FROM duckdb_tables() \
               WHERE database_name = ? AND schema_name = ? AND NOT internal \
             UNION ALL \
             SELECT view_name, 'view', NULL FROM duckdb_views() \
               WHERE database_name = ? AND schema_name = ? AND NOT internal \
             ORDER BY 1",
        )
        .map_err(err)?;
    let rows = stmt
        .query_map(params![db, schema_name, db, schema_name], |r| {
            Ok((r.get::<_, String>(0)?, r.get::<_, String>(1)?, r.get::<_, Option<i64>>(2)?))
        })
        .map_err(err)?;
    let mut out = Vec::new();
    for row in rows {
        let (name, kind, estimate) = row.map_err(err)?;
        out.push(TableInfo {
            name,
            schema_name: schema.to_string(),
            table_type: if kind == "view" { TableType::View } else { TableType::Table },
            row_count_estimate: estimate,
            total_size_bytes: None,
            is_partitioned: false,
            is_partition: false,
            partition_strategy: None,
            partition_key: None,
            partition_bound: None,
            partition_count: None,
            partition_mechanism: None,
            has_child_tables: false,
        });
    }
    Ok(out)
}

/// Exact row counts for every table of a schema ("Refresh row counts").
pub fn exact_row_counts(conn: &Connection, schema: &str) -> Result<Vec<TableInfo>> {
    let mut tables = tables(conn, schema)?;
    let (db, schema_name) = split_schema(conn, schema)?;
    for t in tables.iter_mut().filter(|t| t.table_type == TableType::Table) {
        let sql = format!(
            "SELECT count(*) FROM {}.{}.{}",
            quote_ident(&db),
            quote_ident(&schema_name),
            quote_ident(&t.name)
        );
        t.row_count_estimate = conn.query_row(&sql, [], |r| r.get::<_, i64>(0)).ok();
    }
    Ok(tables)
}

fn primary_key_columns(conn: &Connection, db: &str, schema: &str, table: &str) -> Result<Vec<String>> {
    let mut stmt = conn
        .prepare(
            "SELECT constraint_column_names FROM duckdb_constraints() \
             WHERE database_name = ? AND schema_name = ? AND table_name = ? AND constraint_type = 'PRIMARY KEY'",
        )
        .map_err(err)?;
    let rows = stmt.query_map(params![db, schema, table], |r| list(r, 0)).map_err(err)?;
    let mut out = Vec::new();
    for row in rows {
        out.extend(row.map_err(err)?);
    }
    Ok(out)
}

pub fn columns(conn: &Connection, schema: &str, table: &str) -> Result<Vec<ColumnInfo>> {
    let (db, schema_name) = split_schema(conn, schema)?;
    let pk = primary_key_columns(conn, &db, &schema_name, table)?;
    let mut stmt = conn
        .prepare(
            "SELECT column_name, data_type, is_nullable, column_index, column_default FROM duckdb_columns() \
             WHERE database_name = ? AND schema_name = ? AND table_name = ? ORDER BY column_index",
        )
        .map_err(err)?;
    let rows = stmt
        .query_map(params![db, schema_name, table], |r| {
            Ok((
                r.get::<_, String>(0)?,
                r.get::<_, String>(1)?,
                r.get::<_, bool>(2)?,
                r.get::<_, i64>(3)?,
                r.get::<_, Option<String>>(4)?,
            ))
        })
        .map_err(err)?;
    let mut out = Vec::new();
    for row in rows {
        let (name, data_type, is_nullable, index, default) = row.map_err(err)?;
        out.push(ColumnInfo {
            is_primary_key: pk.contains(&name),
            name,
            data_type,
            is_nullable,
            ordinal_position: index as i32,
            column_default: default,
        });
    }
    Ok(out)
}

pub fn schema_columns(conn: &Connection, schema: &str) -> Result<Vec<SchemaColumnInfo>> {
    let (db, schema_name) = split_schema(conn, schema)?;
    let mut pk_stmt = conn
        .prepare(
            "SELECT table_name, unnest(constraint_column_names) FROM duckdb_constraints() \
             WHERE database_name = ? AND schema_name = ? AND constraint_type = 'PRIMARY KEY'",
        )
        .map_err(err)?;
    let pks: Vec<(String, String)> = pk_stmt
        .query_map(params![db, schema_name], |r| Ok((r.get(0)?, r.get(1)?)))
        .map_err(err)?
        .collect::<std::result::Result<_, _>>()
        .map_err(err)?;
    let mut stmt = conn
        .prepare(
            "SELECT table_name, column_name, data_type, is_nullable, column_index, column_default FROM duckdb_columns() \
             WHERE database_name = ? AND schema_name = ? AND NOT internal ORDER BY table_name, column_index",
        )
        .map_err(err)?;
    let rows = stmt
        .query_map(params![db, schema_name], |r| {
            Ok((
                r.get::<_, String>(0)?,
                r.get::<_, String>(1)?,
                r.get::<_, String>(2)?,
                r.get::<_, bool>(3)?,
                r.get::<_, i64>(4)?,
                r.get::<_, Option<String>>(5)?,
            ))
        })
        .map_err(err)?;
    let mut out = Vec::new();
    for row in rows {
        let (table_name, name, data_type, is_nullable, index, default) = row.map_err(err)?;
        let is_primary_key = pks.iter().any(|(t, c)| t == &table_name && c == &name);
        out.push(SchemaColumnInfo {
            table_name,
            name,
            data_type,
            is_nullable,
            is_primary_key,
            ordinal_position: index as i32,
            column_default: default,
        });
    }
    Ok(out)
}

/// Explicit indexes from `duckdb_indexes()`, plus the PRIMARY KEY and UNIQUE
/// constraints, which DuckDB backs with ART indexes it does not list there.
pub fn indexes(conn: &Connection, schema: &str, table: &str) -> Result<Vec<IndexInfo>> {
    let (db, schema_name) = split_schema(conn, schema)?;
    let mut out = Vec::new();
    let mut stmt = conn
        .prepare(
            "SELECT constraint_type, constraint_column_names, constraint_name FROM duckdb_constraints() \
             WHERE database_name = ? AND schema_name = ? AND table_name = ? \
               AND constraint_type IN ('PRIMARY KEY', 'UNIQUE') ORDER BY constraint_index",
        )
        .map_err(err)?;
    let rows = stmt
        .query_map(params![db, schema_name, table], |r| {
            Ok((r.get::<_, String>(0)?, list(r, 1)?, r.get::<_, Option<String>>(2)?))
        })
        .map_err(err)?;
    for row in rows {
        let (kind, columns, name) = row.map_err(err)?;
        let primary = kind == "PRIMARY KEY";
        out.push(IndexInfo {
            name: name.unwrap_or_else(|| format!("{}_{}", table, if primary { "pkey" } else { "key" })),
            columns,
            is_unique: true,
            is_primary: primary,
            index_type: "art".to_string(),
            size_bytes: None,
        });
    }
    let mut stmt = conn
        .prepare(
            "SELECT index_name, is_unique, is_primary, sql, expressions FROM duckdb_indexes() \
             WHERE database_name = ? AND schema_name = ? AND table_name = ? ORDER BY index_name",
        )
        .map_err(err)?;
    let rows = stmt
        .query_map(params![db, schema_name, table], |r| {
            Ok((
                r.get::<_, String>(0)?,
                r.get::<_, bool>(1)?,
                r.get::<_, bool>(2)?,
                r.get::<_, Option<String>>(3)?,
                r.get::<_, Option<String>>(4)?,
            ))
        })
        .map_err(err)?;
    for row in rows {
        let (name, is_unique, is_primary, sql, expressions) = row.map_err(err)?;
        out.push(IndexInfo {
            name,
            columns: index_columns(sql.as_deref(), expressions.as_deref()),
            is_unique,
            is_primary,
            index_type: "art".to_string(),
            size_bytes: None,
        });
    }
    Ok(out)
}

/// The column list of an index: `expressions` when DuckDB fills it, else
/// the parenthesised part of its `CREATE INDEX` text.
fn index_columns(sql: Option<&str>, expressions: Option<&str>) -> Vec<String> {
    let source = match expressions.filter(|e| !e.trim().is_empty() && e.trim() != "[]") {
        Some(e) => e.trim().trim_start_matches('[').trim_end_matches(']').to_string(),
        None => match sql.and_then(|s| s.find('(').map(|open| (s, open))) {
            Some((s, open)) => {
                let close = s.rfind(')').unwrap_or(s.len());
                s[open + 1..close.max(open + 1)].to_string()
            }
            None => return vec![],
        },
    };
    source
        .split(',')
        .map(|c| c.trim().trim_matches('\'').trim_matches('"').to_string())
        .filter(|c| !c.is_empty())
        .collect()
}

pub fn constraints(conn: &Connection, schema: &str, table: &str) -> Result<Vec<ConstraintInfo>> {
    let (db, schema_name) = split_schema(conn, schema)?;
    let mut stmt = conn
        .prepare(
            "SELECT constraint_name, constraint_type, constraint_column_names, referenced_table, \
                    referenced_column_names, constraint_text \
             FROM duckdb_constraints() \
             WHERE database_name = ? AND schema_name = ? AND table_name = ? AND constraint_type <> 'NOT NULL' \
             ORDER BY constraint_index",
        )
        .map_err(err)?;
    let rows = stmt
        .query_map(params![db, schema_name, table], |r| {
            Ok((
                r.get::<_, Option<String>>(0)?,
                r.get::<_, String>(1)?,
                list(r, 2)?,
                r.get::<_, Option<String>>(3)?,
                list_or_none(r, 4)?,
                r.get::<_, Option<String>>(5)?,
            ))
        })
        .map_err(err)?;
    let mut out = Vec::new();
    for (i, row) in rows.enumerate() {
        let (name, kind, columns, referenced_table, referenced_columns, text) = row.map_err(err)?;
        let is_check = kind == "CHECK";
        out.push(ConstraintInfo {
            name: name.unwrap_or_else(|| format!("{}_{}_{}", table, kind.to_lowercase().replace(' ', "_"), i + 1)),
            constraint_type: kind,
            columns,
            referenced_table,
            referenced_columns: referenced_columns.filter(|c| !c.is_empty()),
            check_clause: if is_check { text } else { None },
        });
    }
    Ok(out)
}

/// User macros and table macros: DuckDB's equivalent of functions. Built-in
/// functions are left out, as PostgreSQL's `pg_catalog` functions are.
pub fn functions(conn: &Connection, schema: &str) -> Result<Vec<FunctionInfo>> {
    let (db, schema_name) = split_schema(conn, schema)?;
    let mut stmt = conn
        .prepare(
            "SELECT function_name, function_type, coalesce(return_type, ''), \
                    array_to_string(parameters, ', ') \
             FROM duckdb_functions() \
             WHERE database_name = ? AND schema_name = ? AND NOT internal \
             ORDER BY function_name",
        )
        .map_err(err)?;
    let rows = stmt
        .query_map(params![db, schema_name], |r| {
            Ok((r.get::<_, String>(0)?, r.get::<_, String>(1)?, r.get::<_, String>(2)?, r.get::<_, Option<String>>(3)?))
        })
        .map_err(err)?;
    let mut out = Vec::new();
    for row in rows {
        let (name, kind, return_type, arguments) = row.map_err(err)?;
        let function_type = match kind.as_str() {
            "table_macro" => "table macro".to_string(),
            "macro" => "macro".to_string(),
            other => other.to_string(),
        };
        out.push(FunctionInfo {
            name,
            schema_name: schema.to_string(),
            return_type: if return_type.is_empty() && kind == "table_macro" { "TABLE".into() } else { return_type },
            argument_types: arguments.unwrap_or_default(),
            function_type,
            language: "SQL".to_string(),
        });
    }
    Ok(out)
}

/// Foreign keys, enum labels, real type names and comments for one schema.
pub fn draft_facts(conn: &Connection, schema: &str) -> Result<SchemaDraftFacts> {
    let (db, schema_name) = split_schema(conn, schema)?;
    let mut facts = SchemaDraftFacts::default();

    let mut stmt = conn
        .prepare("SELECT table_name, comment FROM duckdb_tables() WHERE database_name = ? AND schema_name = ? AND comment IS NOT NULL")
        .map_err(err)?;
    for row in stmt
        .query_map(params![db, schema_name], |r| Ok((r.get::<_, String>(0)?, r.get::<_, String>(1)?)))
        .map_err(err)?
    {
        let (t, c) = row.map_err(err)?;
        facts.table_comments.insert(t, c);
    }

    let mut stmt = conn
        .prepare(
            "SELECT table_name, column_name, data_type, comment FROM duckdb_columns() \
             WHERE database_name = ? AND schema_name = ? AND NOT internal ORDER BY table_name, column_index",
        )
        .map_err(err)?;
    for row in stmt
        .query_map(params![db, schema_name], |r| {
            Ok(DraftColumnFact { table: r.get(0)?, name: r.get(1)?, type_name: r.get(2)?, comment: r.get(3)? })
        })
        .map_err(err)?
    {
        facts.columns.push(row.map_err(err)?);
    }

    let mut stmt = conn
        .prepare(
            "SELECT table_name, constraint_column_names, referenced_table, referenced_column_names FROM duckdb_constraints() \
             WHERE database_name = ? AND schema_name = ? AND constraint_type = 'FOREIGN KEY'",
        )
        .map_err(err)?;
    for row in stmt
        .query_map(params![db, schema_name], |r| {
            Ok(DraftForeignKey {
                table: r.get(0)?,
                columns: list(r, 1)?,
                ref_schema: schema.to_string(),
                ref_table: r.get::<_, Option<String>>(2)?.unwrap_or_default(),
                ref_columns: list_or_none(r, 3)?.unwrap_or_default(),
            })
        })
        .map_err(err)?
    {
        facts.foreign_keys.push(row.map_err(err)?);
    }

    let mut stmt = conn
        .prepare(
            "SELECT type_name, labels FROM duckdb_types() \
             WHERE database_name = ? AND schema_name = ? AND logical_type = 'ENUM' AND NOT internal",
        )
        .map_err(err)?;
    for row in stmt
        .query_map(params![db, schema_name], |r| {
            Ok(DraftEnum { type_name: r.get(0)?, labels: list_or_none(r, 1)?.unwrap_or_default() })
        })
        .map_err(err)?
    {
        facts.enums.push(row.map_err(err)?);
    }
    Ok(facts)
}

/// The DDL DuckDB stored for a table or view, with its indexes. DuckDB keeps
/// the statement that created the object, so all three variants carry the
/// same table text; "columns only" drops the constraints DuckDB wrote inline
/// when it can tell, and otherwise repeats the stored text.
pub fn table_ddl(conn: &Connection, schema: &str, table: &str) -> Result<TableDdl> {
    let (db, schema_name) = split_schema(conn, schema)?;
    let table_sql: Option<String> = conn
        .query_row(
            "SELECT sql FROM duckdb_tables() WHERE database_name = ? AND schema_name = ? AND table_name = ? \
             UNION ALL SELECT sql FROM duckdb_views() WHERE database_name = ? AND schema_name = ? AND view_name = ? \
             LIMIT 1",
            params![db, schema_name, table, db, schema_name, table],
            |r| r.get(0),
        )
        .map_err(err)?;
    let table_sql = table_sql.ok_or_else(|| format!("No DDL is stored for {}.{}", schema, table))?;
    let mut stmt = conn
        .prepare(
            "SELECT sql FROM duckdb_indexes() WHERE database_name = ? AND schema_name = ? AND table_name = ? AND sql IS NOT NULL \
             ORDER BY index_name",
        )
        .map_err(err)?;
    let index_sql: Vec<String> = stmt
        .query_map(params![db, schema_name, table], |r| r.get::<_, String>(0))
        .map_err(err)?
        .collect::<std::result::Result<_, _>>()
        .map_err(err)?;

    let with_semicolon = |s: &str| {
        let t = s.trim();
        if t.ends_with(';') { t.to_string() } else { format!("{};", t) }
    };
    let table_text = with_semicolon(&table_sql);
    let columns_only = columns_only_ddl(conn, &db, &schema_name, schema, table).unwrap_or_else(|| table_text.clone());
    let mut full = table_text.clone();
    for idx in &index_sql {
        full.push_str("\n\n");
        full.push_str(&with_semicolon(idx));
    }
    Ok(TableDdl {
        columns_only,
        with_constraints: table_text,
        full,
        shape: TableShape { partition_by: None, inherits_from: vec![], has_child_tables: false, partition_of: None },
    })
}

/// `CREATE TABLE` with names and types only, built from `duckdb_columns()`.
/// None for a view.
fn columns_only_ddl(conn: &Connection, db: &str, schema_name: &str, shown_schema: &str, table: &str) -> Option<String> {
    let is_table: bool = conn
        .query_row(
            "SELECT count(*) > 0 FROM duckdb_tables() WHERE database_name = ? AND schema_name = ? AND table_name = ?",
            params![db, schema_name, table],
            |r| r.get(0),
        )
        .ok()?;
    if !is_table {
        return None;
    }
    let cols = columns(conn, shown_schema, table).ok()?;
    let lines: Vec<String> = cols.iter().map(|c| format!("    {} {}", quote_ident(&c.name), c.data_type)).collect();
    Some(format!("CREATE TABLE {}.{} (\n{}\n);", quote_ident(schema_name), quote_ident(table), lines.join(",\n")))
}

/// A DuckDB identifier, double-quoted with `"` doubled.
pub fn quote_ident(name: &str) -> String {
    format!("\"{}\"", name.replace('"', "\"\""))
}

/// The keywords and function names for the editor's completion list.
pub fn vocabulary(conn: &Connection) -> Result<(Vec<String>, Vec<String>)> {
    let mut stmt = conn.prepare("SELECT keyword_name FROM duckdb_keywords() ORDER BY 1").map_err(err)?;
    let keywords: Vec<String> = stmt
        .query_map([], |r| r.get(0))
        .map_err(err)?
        .collect::<std::result::Result<_, _>>()
        .map_err(err)?;
    let mut stmt = conn
        .prepare("SELECT DISTINCT function_name FROM duckdb_functions() WHERE NOT starts_with(function_name, '__') ORDER BY 1")
        .map_err(err)?;
    let functions: Vec<String> = stmt
        .query_map([], |r| r.get(0))
        .map_err(err)?
        .collect::<std::result::Result<_, _>>()
        .map_err(err)?;
    Ok((keywords, functions))
}

#[cfg(test)]
mod tests {
    use super::*;

    fn sample() -> Connection {
        let c = Connection::open_in_memory().unwrap();
        c.execute_batch(
            "CREATE TYPE mood AS ENUM ('sad', 'ok', 'happy');
             CREATE TABLE customers (id INTEGER PRIMARY KEY, email VARCHAR UNIQUE NOT NULL, m mood, score INTEGER CHECK (score >= 0));
             COMMENT ON TABLE customers IS 'people';
             CREATE TABLE orders (id INTEGER PRIMARY KEY, customer_id INTEGER REFERENCES customers(id), total DECIMAL(10,2) DEFAULT 0);
             CREATE INDEX orders_total ON orders(total);
             CREATE VIEW big AS SELECT * FROM orders WHERE total > 100;
             INSERT INTO customers VALUES (1, 'a@x', 'ok', 3), (2, 'b@x', 'sad', 0);
             CREATE SCHEMA sales;
             CREATE TABLE sales.leads (n INTEGER);
             CREATE MACRO add_one(x) AS x + 1;
             CREATE MACRO first_n(n) AS TABLE SELECT * FROM range(n);
             ATTACH ':memory:' AS other;
             CREATE TABLE other.main.far (v INTEGER);",
        )
        .unwrap();
        c
    }

    #[test]
    fn schemas_put_main_first_and_qualify_other_databases() {
        let c = sample();
        let names: Vec<String> = schemas(&c, false).unwrap().into_iter().map(|s| s.name).collect();
        assert_eq!(names, ["main", "sales", "other.main"]);
        let attached: Vec<Option<String>> =
            schemas(&c, false).unwrap().into_iter().map(|s| s.attached_database).collect();
        assert_eq!(attached, [None, None, Some("other".to_string())], "an attached schema names its database");
        let all: Vec<String> = schemas(&c, true).unwrap().into_iter().map(|s| s.name).collect();
        assert!(all.len() > names.len(), "{all:?}");
        // The temp catalog is always empty on a catalog connection: never listed.
        assert!(!all.iter().any(|n| n.starts_with("temp.") || n == "temp"), "{all:?}");
        assert!(all.iter().any(|n| n.starts_with("system.")), "the system database still shows: {all:?}");
    }

    #[test]
    fn tables_views_and_row_estimates() {
        let c = sample();
        let t = tables(&c, "main").unwrap();
        let summary: Vec<(String, TableType, Option<i64>)> =
            t.iter().map(|t| (t.name.clone(), t.table_type, t.row_count_estimate)).collect();
        assert_eq!(
            summary,
            vec![
                ("big".into(), TableType::View, None),
                ("customers".into(), TableType::Table, Some(2)),
                ("orders".into(), TableType::Table, Some(0)),
            ]
        );
        assert_eq!(tables(&c, "sales").unwrap()[0].name, "leads");
        let far = tables(&c, "other.main").unwrap();
        assert_eq!(far[0].name, "far");
        assert_eq!(far[0].schema_name, "other.main");
        assert_eq!(exact_row_counts(&c, "main").unwrap().iter().find(|t| t.name == "customers").unwrap().row_count_estimate, Some(2));
    }

    #[test]
    fn columns_carry_types_keys_and_defaults() {
        let c = sample();
        let cols = columns(&c, "main", "orders").unwrap();
        assert_eq!(cols.iter().map(|c| c.name.as_str()).collect::<Vec<_>>(), ["id", "customer_id", "total"]);
        assert!(cols[0].is_primary_key && !cols[0].is_nullable);
        assert_eq!(cols[2].data_type, "DECIMAL(10,2)");
        assert_eq!(cols[2].column_default.as_deref(), Some("0"));
        let all = schema_columns(&c, "main").unwrap();
        assert!(all.iter().any(|c| c.table_name == "customers" && c.name == "id" && c.is_primary_key));
        assert_eq!(columns(&c, "other.main", "far").unwrap()[0].name, "v");
    }

    #[test]
    fn indexes_include_key_constraints() {
        let c = sample();
        let idx = indexes(&c, "main", "orders").unwrap();
        assert!(idx.iter().any(|i| i.is_primary && i.columns == ["id"]), "{idx:?}");
        assert!(idx.iter().any(|i| i.name == "orders_total" && i.columns == ["total"]), "{idx:?}");
        let idx = indexes(&c, "main", "customers").unwrap();
        assert!(idx.iter().any(|i| !i.is_primary && i.is_unique && i.columns == ["email"]), "{idx:?}");
    }

    #[test]
    fn constraints_name_kind_and_references() {
        let c = sample();
        let cons = constraints(&c, "main", "orders").unwrap();
        let fk = cons.iter().find(|c| c.constraint_type == "FOREIGN KEY").expect("fk");
        assert_eq!(fk.columns, ["customer_id"]);
        assert_eq!(fk.referenced_table.as_deref(), Some("customers"));
        assert_eq!(fk.referenced_columns.as_deref(), Some(&["id".to_string()][..]));
        let check = constraints(&c, "main", "customers").unwrap();
        assert!(check.iter().any(|c| c.constraint_type == "CHECK" && c.check_clause.as_deref().unwrap_or("").contains("score")));
    }

    #[test]
    fn macros_are_the_functions() {
        let c = sample();
        let f = functions(&c, "main").unwrap();
        let names: Vec<(&str, &str)> = f.iter().map(|f| (f.name.as_str(), f.function_type.as_str())).collect();
        assert_eq!(names, [("add_one", "macro"), ("first_n", "table macro")]);
        assert_eq!(f[0].argument_types, "x");
    }

    #[test]
    fn draft_facts_have_fks_enums_and_comments() {
        let c = sample();
        let facts = draft_facts(&c, "main").unwrap();
        assert_eq!(facts.table_comments.get("customers").map(String::as_str), Some("people"));
        assert_eq!(facts.foreign_keys.len(), 1);
        assert_eq!(facts.enums.len(), 1);
        assert_eq!(facts.enums[0].labels, ["sad", "ok", "happy"]);
        assert!(facts.columns.iter().any(|c| c.table == "customers" && c.type_name == "ENUM('sad', 'ok', 'happy')"));
    }

    #[test]
    fn ddl_comes_from_duckdb() {
        let c = sample();
        let ddl = table_ddl(&c, "main", "orders").unwrap();
        assert!(ddl.with_constraints.starts_with("CREATE TABLE orders"), "{}", ddl.with_constraints);
        assert!(ddl.with_constraints.contains("REFERENCES"), "{}", ddl.with_constraints);
        assert!(ddl.full.contains("CREATE INDEX orders_total"), "{}", ddl.full);
        assert!(ddl.columns_only.contains("\"total\" DECIMAL(10,2)") && !ddl.columns_only.contains("REFERENCES"));
        let view = table_ddl(&c, "main", "big").unwrap();
        assert!(view.full.starts_with("CREATE VIEW"), "{}", view.full);
        assert!(table_ddl(&c, "main", "nope").is_err());
    }

    #[test]
    fn vocabulary_has_keywords_and_functions() {
        let c = sample();
        let (kw, f) = vocabulary(&c).unwrap();
        assert!(kw.iter().any(|k| k.eq_ignore_ascii_case("qualify")));
        assert!(f.iter().any(|f| f == "list_transform"));
    }
}
