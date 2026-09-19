//! Inline cell editing: apply a set of pending grid edits in ONE transaction.
//!
//! The Swift mirror of these types is `Pharos/Models/RowEdit.swift`.
//!
//! Every value crosses the FFI as text (PostgreSQL text form; `null` is SQL
//! NULL) and is **bound** here with a cast to the column's own `data_type`.
//! Nothing from the request is ever spliced into the statement text: values are
//! bound, identifiers go through `escape_identifier`, and the cast type comes
//! from a fixed allow-list, never from the caller's string.
//!
//! The statement for row *i* is
//!
//! ```text
//! UPDATE "schema"."table"
//!    SET "c1" = $1::t1, "c2" = $2::t2
//!  WHERE "k1" = $3::kt1
//!    AND "c1" IS NOT DISTINCT FROM $4::t1
//!    AND "c2" IS NOT DISTINCT FROM $5::t2
//! RETURNING 1
//! ```
//!
//! The old-value clauses are the only concurrency protection there is: a value
//! another session changed since the grid loaded it makes the row match 0 rows,
//! which rolls the whole transaction back. `IS NOT DISTINCT FROM` rather than
//! `=` so a NULL old value matches a NULL column.

use serde::{Deserialize, Serialize};
use std::time::Instant;

use super::query::format_db_error;
use super::table::escape_identifier;
use crate::db::sqlite;
use crate::models::QueryHistoryEntry;
use crate::state::AppState;

// ---------------------------------------------------------------------------
// Wire types (mirror of Pharos/Models/RowEdit.swift)
// ---------------------------------------------------------------------------

/// One column of the request: the name as it is in the table, and the
/// `data_type` the result reported for it.
#[derive(Debug, Clone, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct RowUpdateColumn {
    pub name: String,
    pub data_type: String,
}

/// One row's worth of the request. `key` aligns with `key_columns`;
/// `old_values` and `new_values` align with `columns`.
#[derive(Debug, Clone, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct RowUpdateRow {
    /// Key values, never null — a NULL key does not identify a row.
    pub key: Vec<String>,
    /// The values as the grid loaded them; they go into the WHERE clause.
    pub old_values: Vec<Option<String>>,
    /// The values to write.
    pub new_values: Vec<Option<String>>,
}

#[derive(Debug, Clone, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct RowUpdateRequest {
    pub schema: String,
    pub table: String,
    /// The key the rows are matched on: a primary key, or a NOT NULL unique index.
    pub key_columns: Vec<RowUpdateColumn>,
    /// A user-facing name for the key, e.g. "primary key" — recorded in history.
    pub key_description: String,
    /// The edited columns, in statement order.
    pub columns: Vec<RowUpdateColumn>,
    pub rows: Vec<RowUpdateRow>,
}

#[derive(Debug, Clone, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct RowUpdateResult {
    pub rows_updated: i64,
    pub execution_time_ms: u64,
    /// The query-history row this write was recorded under.
    #[serde(skip_serializing_if = "Option::is_none")]
    pub history_entry_id: Option<String>,
}

// ---------------------------------------------------------------------------
// Types allowed in v1
// ---------------------------------------------------------------------------

/// The cast type for a column, or `None` when inline editing refuses the type.
///
/// The returned string is a `&'static str` on purpose: the cast that reaches
/// the statement text is one of these literals and never the caller's own
/// string, so a hostile `data_type` cannot become SQL.
///
/// v1 is text, numeric, boolean, date, timestamp and uuid (design note D5,
/// open decision 7). Arrays, json/jsonb, bytea, ranges and composites are
/// refused: they need their own editors, and a wrong text cast on an array is a
/// silent data change.
pub(crate) fn cast_type_for_edit(data_type: &str) -> Option<&'static str> {
    let dt = data_type.trim().to_lowercase();

    // Arrays first: `_int4` is the catalogue spelling, `integer[]` the display one.
    if dt.starts_with('_') || dt.ends_with("[]") {
        return None;
    }

    match dt.as_str() {
        // Character
        "text" | "varchar" | "character varying" | "char" | "character" | "bpchar" | "name" => {
            Some("text")
        }

        // Numeric
        "numeric" | "decimal" => Some("numeric"),
        "int2" | "smallint" => Some("smallint"),
        "int4" | "int" | "integer" => Some("integer"),
        "int8" | "bigint" => Some("bigint"),
        "float4" | "real" => Some("real"),
        "float8" | "double precision" => Some("double precision"),

        // Boolean
        "bool" | "boolean" => Some("boolean"),

        // Date and time
        "date" => Some("date"),
        "timestamp" | "timestamp without time zone" => Some("timestamp"),
        "timestamptz" | "timestamp with time zone" => Some("timestamptz"),

        // Identifier
        "uuid" => Some("uuid"),

        _ => None,
    }
}

fn check_type(role: &str, column: &RowUpdateColumn) -> Result<&'static str, String> {
    cast_type_for_edit(&column.data_type).ok_or_else(|| {
        format!(
            "Inline editing does not support the type `{}` of {} \"{}\" yet. \
             Arrays, JSON, binary, ranges and composite types need their own editor.",
            column.data_type, role, column.name
        )
    })
}

// ---------------------------------------------------------------------------
// Validation
// ---------------------------------------------------------------------------

/// Everything that can be checked without a server. Run it BEFORE opening the
/// transaction so a malformed request never reaches the database at all.
pub(crate) fn validate_request(request: &RowUpdateRequest) -> Result<(), String> {
    if request.rows.is_empty() {
        return Err("There are no rows to update.".to_string());
    }
    if request.columns.is_empty() {
        return Err("There are no columns to update.".to_string());
    }
    if request.key_columns.is_empty() {
        return Err(
            "These rows have no key, so they cannot be identified for an update.".to_string(),
        );
    }
    if request.table.is_empty() {
        return Err("The table name is empty.".to_string());
    }

    for column in &request.columns {
        if column.name.is_empty() {
            return Err("A column to update has an empty name.".to_string());
        }
        check_type("column", column)?;
    }
    for column in &request.key_columns {
        if column.name.is_empty() {
            return Err("A key column has an empty name.".to_string());
        }
        check_type("key column", column)?;
    }

    for (index, row) in request.rows.iter().enumerate() {
        let number = index + 1;
        if row.key.len() != request.key_columns.len() {
            return Err(format!(
                "Row {}: {} key values were given for {} key columns.",
                number,
                row.key.len(),
                request.key_columns.len()
            ));
        }
        if row.old_values.len() != request.columns.len() {
            return Err(format!(
                "Row {}: {} old values were given for {} columns.",
                number,
                row.old_values.len(),
                request.columns.len()
            ));
        }
        if row.new_values.len() != request.columns.len() {
            return Err(format!(
                "Row {}: {} new values were given for {} columns.",
                number,
                row.new_values.len(),
                request.columns.len()
            ));
        }
    }

    Ok(())
}

// ---------------------------------------------------------------------------
// Statement construction (pure — unit-testable with no server)
// ---------------------------------------------------------------------------

/// Build the UPDATE for one row: the statement text, and the parameters in
/// bind order (new values, then key values, then old values).
///
/// Nothing but identifiers and the fixed cast literals reaches the text.
pub fn build_update_statement(
    request: &RowUpdateRequest,
    row_index: usize,
) -> Result<(String, Vec<Option<String>>), String> {
    let row = request
        .rows
        .get(row_index)
        .ok_or_else(|| format!("Row {} is not in the request.", row_index + 1))?;

    if row.key.len() != request.key_columns.len()
        || row.old_values.len() != request.columns.len()
        || row.new_values.len() != request.columns.len()
    {
        return Err(format!(
            "Row {}: the values do not line up with the columns.",
            row_index + 1
        ));
    }

    let mut params: Vec<Option<String>> = Vec::with_capacity(
        request.columns.len() * 2 + request.key_columns.len(),
    );
    let mut placeholder = 0usize;

    // SET "c" = $n::type, …
    let mut assignments = Vec::with_capacity(request.columns.len());
    for (i, column) in request.columns.iter().enumerate() {
        let cast = check_type("column", column)?;
        placeholder += 1;
        assignments.push(format!(
            "\"{}\" = ${}::{}",
            escape_identifier(&column.name),
            placeholder,
            cast
        ));
        params.push(row.new_values[i].clone());
    }

    // WHERE "k" = $n::type AND … — a key value is never NULL, so `=` is right.
    let mut conditions = Vec::with_capacity(request.key_columns.len() + request.columns.len());
    for (i, column) in request.key_columns.iter().enumerate() {
        let cast = check_type("key column", column)?;
        placeholder += 1;
        conditions.push(format!(
            "\"{}\" = ${}::{}",
            escape_identifier(&column.name),
            placeholder,
            cast
        ));
        params.push(Some(row.key[i].clone()));
    }

    // … AND "c" IS NOT DISTINCT FROM $n::type — the old-value guard. NULL-safe
    // on both sides, so a NULL that is still NULL matches and a NULL that was
    // changed does not.
    for (i, column) in request.columns.iter().enumerate() {
        let cast = check_type("column", column)?;
        placeholder += 1;
        conditions.push(format!(
            "\"{}\" IS NOT DISTINCT FROM ${}::{}",
            escape_identifier(&column.name),
            placeholder,
            cast
        ));
        params.push(row.old_values[i].clone());
    }

    let sql = format!(
        "UPDATE \"{}\".\"{}\" SET {} WHERE {} RETURNING 1",
        escape_identifier(&request.schema),
        escape_identifier(&request.table),
        assignments.join(", "),
        conditions.join(" AND ")
    );

    Ok((sql, params))
}

/// The one synthetic line recorded in Query History for a set of cell edits.
///
/// A comment, not the real statements: the statements carry `$n` placeholders
/// rather than values, so pasting them back into the editor would be useless
/// and running them impossible. A comment is safe to copy and safe to re-run.
pub(crate) fn history_sql(request: &RowUpdateRequest, rows_updated: i64) -> String {
    format!(
        "-- Pharos cell edits: UPDATE \"{}\".\"{}\" × {} row{} (matched on the {})",
        escape_identifier(&request.schema),
        escape_identifier(&request.table),
        rows_updated,
        if rows_updated == 1 { "" } else { "s" },
        request.key_description
    )
}

// ---------------------------------------------------------------------------
// The command
// ---------------------------------------------------------------------------

/// Apply the pending cell edits in ONE transaction.
///
/// Every row must match exactly one row. 0 means the row is gone, its key
/// changed, or another session changed a value since it was loaded; more than 1
/// means the key is not unique after all — the dangerous case this check exists
/// for. Either rolls the whole transaction back.
pub async fn apply_row_updates(
    connection_id: String,
    request: RowUpdateRequest,
    state: &AppState,
) -> Result<RowUpdateResult, String> {
    validate_request(&request)?;

    // The grid's own write path. Refused before the transaction opens.
    state.require_writable(&connection_id)?;

    let pool = state.require_pool(&connection_id)?;

    let start = Instant::now();

    let mut tx = pool
        .begin()
        .await
        .map_err(|e| format!("Failed to begin transaction: {}", e))?;

    let mut rows_updated: i64 = 0;

    for row_index in 0..request.rows.len() {
        let (sql, params) = match build_update_statement(&request, row_index) {
            Ok(pair) => pair,
            Err(e) => {
                tx.rollback().await.ok();
                return Err(e);
            }
        };

        let mut query = sqlx::query(&sql);
        for value in &params {
            query = query.bind(value.clone());
        }

        let returned = match query.fetch_all(&mut *tx).await {
            Ok(rows) => rows,
            Err(e) => {
                tx.rollback().await.ok();
                return Err(format!(
                    "Row {} could not be updated: {}. Nothing was changed.",
                    row_index + 1,
                    format_db_error(&e)
                ));
            }
        };

        match returned.len() {
            1 => rows_updated += 1,
            0 => {
                tx.rollback().await.ok();
                return Err(format!(
                    "Row {} was not updated: the row is gone, its key changed, or another \
                     session changed a value since it was loaded. Nothing was changed.",
                    row_index + 1
                ));
            }
            n => {
                tx.rollback().await.ok();
                return Err(format!(
                    "Row {}: the key matched more than one row ({}); nothing was changed.",
                    row_index + 1,
                    n
                ));
            }
        }
    }

    tx.commit()
        .await
        .map_err(|e| format!("Failed to commit transaction: {}", e))?;

    let execution_time_ms = start.elapsed().as_millis() as u64;

    // Record the write in Query History, the way execute_statement does
    // (query.rs:790-812). Non-fatal: the data is already committed.
    let history_entry_id = uuid::Uuid::new_v4().to_string();
    {
        let connection_name = state
            .get_config(&connection_id)
            .map(|c| c.name)
            .unwrap_or_else(|| connection_id.clone());
        let entry = QueryHistoryEntry {
            id: history_entry_id.clone(),
            connection_id: connection_id.clone(),
            connection_name,
            sql: history_sql(&request, rows_updated),
            row_count: Some(rows_updated),
            execution_time_ms: execution_time_ms as i64,
            executed_at: chrono::Utc::now().to_rfc3339(),
            has_results: false,
            schema: Some(request.schema.clone()),
            column_count: None,
            table_names: Some(format!("{}.{}", request.schema, request.table)),
            source: None,
            status: crate::models::HISTORY_STATUS_OK.to_string(),
            error_message: None,
        };
        if let Ok(db) = state.metadata_db.lock() {
            if let Err(e) = sqlite::save_query_history(&db, &entry, None, None, None) {
                log::warn!("Failed to save query history for cell edits: {}", e);
            }
        }
    }

    Ok(RowUpdateResult {
        rows_updated,
        execution_time_ms,
        history_entry_id: Some(history_entry_id),
    })
}

// ---------------------------------------------------------------------------
// Tests
// ---------------------------------------------------------------------------

#[cfg(test)]
mod tests {
    use super::*;

    fn column(name: &str, data_type: &str) -> RowUpdateColumn {
        RowUpdateColumn {
            name: name.to_string(),
            data_type: data_type.to_string(),
        }
    }

    fn request(
        key_columns: Vec<RowUpdateColumn>,
        columns: Vec<RowUpdateColumn>,
        rows: Vec<RowUpdateRow>,
    ) -> RowUpdateRequest {
        RowUpdateRequest {
            schema: "public".to_string(),
            table: "users".to_string(),
            key_columns,
            key_description: "primary key".to_string(),
            columns,
            rows,
        }
    }

    fn row(key: &[&str], old: &[Option<&str>], new: &[Option<&str>]) -> RowUpdateRow {
        RowUpdateRow {
            key: key.iter().map(|s| s.to_string()).collect(),
            old_values: old.iter().map(|v| v.map(|s| s.to_string())).collect(),
            new_values: new.iter().map(|v| v.map(|s| s.to_string())).collect(),
        }
    }

    #[test]
    fn one_column_one_key_builds_the_expected_statement() {
        let r = request(
            vec![column("id", "int4")],
            vec![column("email", "text")],
            vec![row(&["7"], &[Some("a@b.co")], &[Some("c@d.co")])],
        );
        let (sql, params) = build_update_statement(&r, 0).expect("build");
        assert_eq!(
            sql,
            "UPDATE \"public\".\"users\" SET \"email\" = $1::text \
             WHERE \"id\" = $2::integer AND \"email\" IS NOT DISTINCT FROM $3::text \
             RETURNING 1"
        );
        // Bind order: new values, then key values, then old values.
        assert_eq!(
            params,
            vec![
                Some("c@d.co".to_string()),
                Some("7".to_string()),
                Some("a@b.co".to_string())
            ]
        );
    }

    #[test]
    fn a_compound_key_ands_every_key_column_and_numbers_in_order() {
        let r = request(
            vec![column("tenant", "uuid"), column("n", "bigint")],
            vec![column("name", "varchar"), column("score", "numeric")],
            vec![row(
                &["11111111-1111-1111-1111-111111111111", "4"],
                &[Some("old"), Some("1.5")],
                &[Some("new"), Some("2.5")],
            )],
        );
        let (sql, params) = build_update_statement(&r, 0).expect("build");
        assert_eq!(
            sql,
            "UPDATE \"public\".\"users\" SET \"name\" = $1::text, \"score\" = $2::numeric \
             WHERE \"tenant\" = $3::uuid AND \"n\" = $4::bigint \
             AND \"name\" IS NOT DISTINCT FROM $5::text \
             AND \"score\" IS NOT DISTINCT FROM $6::numeric \
             RETURNING 1"
        );
        assert_eq!(params.len(), 6, "two columns + two key columns + two old values");
        assert_eq!(params[2], Some("11111111-1111-1111-1111-111111111111".to_string()));
        assert_eq!(params[3], Some("4".to_string()));
    }

    #[test]
    fn a_hostile_column_name_is_escaped_and_never_breaks_out_of_its_quotes() {
        let r = request(
            vec![column("id\"; DROP TABLE users; --", "int4")],
            vec![column("weird\"name", "text")],
            vec![row(&["1"], &[None], &[Some("x")])],
        );
        let (sql, _) = build_update_statement(&r, 0).expect("build");
        assert_eq!(
            sql,
            "UPDATE \"public\".\"users\" SET \"weird\"\"name\" = $1::text \
             WHERE \"id\"\"; DROP TABLE users; --\" = $2::integer \
             AND \"weird\"\"name\" IS NOT DISTINCT FROM $3::text \
             RETURNING 1"
        );
        // Every quote in the text is either a delimiter or half a doubled pair,
        // so the count is even and no bare quote escapes.
        assert_eq!(sql.matches('"').count() % 2, 0, "unbalanced quoting");
        assert!(!sql.contains("DROP TABLE users;\""), "the payload stayed inside its quotes");
    }

    #[test]
    fn a_null_new_value_binds_as_none_and_the_set_still_carries_the_cast() {
        let r = request(
            vec![column("id", "int4")],
            vec![column("note", "text")],
            vec![row(&["3"], &[Some("was here")], &[None])],
        );
        let (sql, params) = build_update_statement(&r, 0).expect("build");
        assert!(sql.contains("SET \"note\" = $1::text"), "cast is on the SET: {}", sql);
        assert_eq!(params[0], None, "the new value binds as SQL NULL");
        assert_eq!(params[2], Some("was here".to_string()));
    }

    #[test]
    fn a_null_old_value_still_uses_the_null_safe_comparison() {
        let r = request(
            vec![column("id", "int4")],
            vec![column("note", "text")],
            vec![row(&["3"], &[None], &[Some("now set")])],
        );
        let (sql, params) = build_update_statement(&r, 0).expect("build");
        // `=` would never match a NULL column; IS NOT DISTINCT FROM does.
        assert!(
            sql.contains("\"note\" IS NOT DISTINCT FROM $3::text"),
            "NULL-safe comparison missing: {}",
            sql
        );
        assert!(!sql.contains("WHERE \"note\" ="), "must not use plain equality");
        assert_eq!(params[2], None, "the old value binds as SQL NULL");
    }

    #[test]
    fn a_refused_type_is_reported_by_name() {
        for bad in [
            "jsonb", "json", "bytea", "int4range", "_int4", "integer[]", "point", "tsvector",
            "interval", "time", "money",
        ] {
            let r = request(
                vec![column("id", "int4")],
                vec![column("payload", bad)],
                vec![row(&["1"], &[Some("a")], &[Some("b")])],
            );
            let err = validate_request(&r).expect_err(&format!("{} must be refused", bad));
            assert!(err.contains(bad), "the message must name the type: {}", err);
            assert!(err.contains("payload"), "the message must name the column: {}", err);
            // And the builder refuses it too, so no caller can route round validation.
            assert!(build_update_statement(&r, 0).is_err(), "builder accepted {}", bad);
        }
    }

    #[test]
    fn every_v1_type_is_accepted_and_casts_to_its_own_type() {
        let cases: &[(&str, &str)] = &[
            ("text", "text"),
            ("varchar", "text"),
            ("character varying", "text"),
            ("char", "text"),
            ("bpchar", "text"),
            ("name", "text"),
            ("numeric", "numeric"),
            ("decimal", "numeric"),
            ("int2", "smallint"),
            ("smallint", "smallint"),
            ("int4", "integer"),
            ("integer", "integer"),
            ("int8", "bigint"),
            ("bigint", "bigint"),
            ("float4", "real"),
            ("real", "real"),
            ("float8", "double precision"),
            ("double precision", "double precision"),
            ("bool", "boolean"),
            ("boolean", "boolean"),
            ("date", "date"),
            ("timestamp", "timestamp"),
            ("timestamp without time zone", "timestamp"),
            ("timestamptz", "timestamptz"),
            ("timestamp with time zone", "timestamptz"),
            ("uuid", "uuid"),
        ];
        for (data_type, expected) in cases {
            assert_eq!(
                cast_type_for_edit(data_type),
                Some(*expected),
                "cast for {}",
                data_type
            );
            // Case does not matter — the catalogue and the display spellings differ.
            assert_eq!(
                cast_type_for_edit(&data_type.to_uppercase()),
                Some(*expected),
                "cast for {} in upper case",
                data_type
            );
        }
    }

    #[test]
    fn a_length_mismatch_is_refused_with_the_row_number() {
        // Too few key values.
        let r = request(
            vec![column("a", "int4"), column("b", "int4")],
            vec![column("n", "text")],
            vec![
                row(&["1", "2"], &[Some("x")], &[Some("y")]),
                row(&["1"], &[Some("x")], &[Some("y")]),
            ],
        );
        let err = validate_request(&r).expect_err("short key must be refused");
        assert!(err.starts_with("Row 2:"), "must name the 1-based row: {}", err);
        assert!(err.contains("key values"), "{}", err);

        // Too many old values.
        let r = request(
            vec![column("a", "int4")],
            vec![column("n", "text")],
            vec![row(&["1"], &[Some("x"), Some("z")], &[Some("y")])],
        );
        let err = validate_request(&r).expect_err("long old values must be refused");
        assert!(err.starts_with("Row 1:"), "{}", err);
        assert!(err.contains("old values"), "{}", err);

        // Too few new values.
        let r = request(
            vec![column("a", "int4")],
            vec![column("n", "text"), column("m", "text")],
            vec![row(&["1"], &[Some("x"), Some("z")], &[Some("y")])],
        );
        let err = validate_request(&r).expect_err("short new values must be refused");
        assert!(err.starts_with("Row 1:"), "{}", err);
        assert!(err.contains("new values"), "{}", err);
    }

    #[test]
    fn an_empty_request_is_refused_before_any_connection_is_touched() {
        let no_rows = request(vec![column("id", "int4")], vec![column("n", "text")], vec![]);
        assert_eq!(
            validate_request(&no_rows).expect_err("empty rows"),
            "There are no rows to update."
        );

        let no_columns = request(
            vec![column("id", "int4")],
            vec![],
            vec![row(&["1"], &[], &[])],
        );
        assert_eq!(
            validate_request(&no_columns).expect_err("empty columns"),
            "There are no columns to update."
        );

        let no_key = request(vec![], vec![column("n", "text")], vec![row(&[], &[Some("a")], &[Some("b")])]);
        assert!(
            validate_request(&no_key)
                .expect_err("empty key columns")
                .contains("no key"),
            "must explain that the rows cannot be identified"
        );
    }

    #[test]
    fn a_good_request_validates() {
        let r = request(
            vec![column("id", "int4")],
            vec![column("name", "text"), column("flag", "bool")],
            vec![
                row(&["1"], &[Some("a"), Some("t")], &[Some("b"), Some("f")]),
                row(&["2"], &[None, None], &[Some("c"), None]),
            ],
        );
        assert!(validate_request(&r).is_ok(), "{:?}", validate_request(&r));
        assert!(build_update_statement(&r, 1).is_ok());
        assert!(
            build_update_statement(&r, 2).is_err(),
            "a row index past the end must not panic"
        );
    }

    #[test]
    fn the_request_decodes_from_the_swift_camel_case_json() {
        // Every optional/multi-word key present: this is what pins the casing.
        // A mis-cased REQUIRED field fails loudly here (see tasks/lessons.md).
        let json = r#"{
            "schema": "public",
            "table": "users",
            "keyColumns": [{"name": "id", "dataType": "int4"}],
            "keyDescription": "primary key",
            "columns": [{"name": "email", "dataType": "text"}],
            "rows": [{"key": ["7"], "oldValues": ["a@b.co"], "newValues": [null]}]
        }"#;
        let r: RowUpdateRequest = serde_json::from_str(json).expect("decode");
        assert_eq!(r.key_columns[0].data_type, "int4");
        assert_eq!(r.key_description, "primary key");
        assert_eq!(r.rows[0].old_values, vec![Some("a@b.co".to_string())]);
        assert_eq!(r.rows[0].new_values, vec![None], "JSON null is SQL NULL");
    }

    #[test]
    fn the_result_encodes_to_the_swift_camel_case_json() {
        let json = serde_json::to_string(&RowUpdateResult {
            rows_updated: 2,
            execution_time_ms: 13,
            history_entry_id: Some("h-1".to_string()),
        })
        .expect("encode");
        assert!(json.contains("\"rowsUpdated\":2"), "{}", json);
        assert!(json.contains("\"executionTimeMs\":13"), "{}", json);
        assert!(json.contains("\"historyEntryId\":\"h-1\""), "{}", json);
    }

    #[test]
    fn the_history_line_is_a_comment_naming_the_table_and_the_key() {
        let r = request(
            vec![column("id", "int4")],
            vec![column("n", "text")],
            vec![row(&["1"], &[Some("a")], &[Some("b")])],
        );
        let line = history_sql(&r, 3);
        assert!(line.starts_with("-- "), "must be a comment: {}", line);
        assert!(line.contains("\"public\".\"users\""), "{}", line);
        assert!(line.contains("× 3 rows"), "{}", line);
        assert!(line.contains("primary key"), "{}", line);
        assert_eq!(
            history_sql(&r, 1).contains("× 1 row ("),
            true,
            "singular for one row: {}",
            history_sql(&r, 1)
        );
    }
}

// ---------------------------------------------------------------------------
// Live tests — a real PostgreSQL, run with `cargo test --release -- --ignored row_edit`
// ---------------------------------------------------------------------------

#[cfg(test)]
mod live_row_edit_tests {
    use super::*;
    use rusqlite::Connection as SqliteConnection;
    use sqlx::postgres::PgPoolOptions;
    use sqlx::Row as _;
    use std::time::Duration;

    const DEFAULT_URL: &str = "postgres://nfinn@127.0.0.1:5432/nfinn?sslmode=disable";
    const CONN: &str = "live-row-edit-test";

    fn column(name: &str, data_type: &str) -> RowUpdateColumn {
        RowUpdateColumn {
            name: name.to_string(),
            data_type: data_type.to_string(),
        }
    }

    fn row(key: &[&str], old: &[Option<&str>], new: &[Option<&str>]) -> RowUpdateRow {
        RowUpdateRow {
            key: key.iter().map(|s| s.to_string()).collect(),
            old_values: old.iter().map(|v| v.map(|s| s.to_string())).collect(),
            new_values: new.iter().map(|v| v.map(|s| s.to_string())).collect(),
        }
    }

    /// The `(name, n, flag)` of every row, ordered by id.
    async fn read_back(
        pool: &sqlx::PgPool,
        table: &str,
    ) -> Vec<(Option<String>, Option<String>, Option<bool>)> {
        let sql = format!(
            "SELECT name, n::text AS n_text, flag FROM public.\"{}\" ORDER BY id",
            table
        );
        sqlx::raw_sql(&sql)
            .fetch_all(pool)
            .await
            .expect("read back failed")
            .iter()
            .map(|r| {
                (
                    r.try_get::<Option<String>, _>("name").expect("name"),
                    r.try_get::<Option<String>, _>("n_text").expect("n"),
                    r.try_get::<Option<bool>, _>("flag").expect("flag"),
                )
            })
            .collect()
    }

    #[test]
    #[ignore = "needs a live PostgreSQL (Postgres.app on 127.0.0.1:5432)"]
    fn row_edit_commits_a_clean_sweep_and_rolls_back_a_stale_row() {
        let url = std::env::var("PHAROS_TEST_DATABASE_URL")
            .unwrap_or_else(|_| DEFAULT_URL.to_string());
        let rt = tokio::runtime::Runtime::new().expect("tokio runtime");

        rt.block_on(async move {
            let pool = PgPoolOptions::new()
                .max_connections(3)
                .acquire_timeout(Duration::from_secs(5))
                .connect(&url)
                .await
                .unwrap_or_else(|e| {
                    panic!("cannot connect to {}: {}. Set PHAROS_TEST_DATABASE_URL.", url, e)
                });

            let suffix = uuid::Uuid::new_v4().simple().to_string();
            let table = format!("pharos_d5_{}", &suffix[..12]);
            let dup_table = format!("pharos_d5_dup_{}", &suffix[..12]);

            let create = format!(
                "CREATE TABLE public.\"{t}\" (id int PRIMARY KEY, name text, n numeric, flag bool); \
                 INSERT INTO public.\"{t}\" VALUES (1, 'one', 1.5, true), \
                                                  (2, 'two', 2.5, false), \
                                                  (3, NULL, NULL, NULL);",
                t = table
            );
            sqlx::raw_sql(&create).execute(&pool).await.expect("create fixture");

            let state = AppState::new(SqliteConnection::open_in_memory().expect("sqlite"));
            state.add_pool(CONN.to_string(), pool.clone());

            let base = |rows: Vec<RowUpdateRow>| RowUpdateRequest {
                schema: "public".to_string(),
                table: table.clone(),
                key_columns: vec![column("id", "int4")],
                key_description: "primary key".to_string(),
                columns: vec![column("name", "text"), column("n", "numeric"), column("flag", "bool")],
                rows,
            };

            // --- 1. A clean sweep of two rows commits ------------------------
            let request = base(vec![
                row(
                    &["1"],
                    &[Some("one"), Some("1.5"), Some("true")],
                    &[Some("ONE"), Some("11.5"), Some("false")],
                ),
                // Row 3 is all NULL: proves the NULL-safe old-value guard matches.
                row(&["3"], &[None, None, None], &[Some("three"), Some("3.5"), Some("true")]),
            ]);
            let result = apply_row_updates(CONN.to_string(), request, &state)
                .await
                .expect("the clean sweep must commit");
            assert_eq!(result.rows_updated, 2, "two rows updated");
            assert!(result.history_entry_id.is_some(), "a history row was recorded");

            let after = read_back(&pool, &table).await;
            assert_eq!(after[0].0, Some("ONE".to_string()), "row 1 name committed");
            assert_eq!(after[0].1, Some("11.5".to_string()), "row 1 numeric committed");
            assert_eq!(after[0].2, Some(false), "row 1 bool committed");
            assert_eq!(after[1].0, Some("two".to_string()), "row 2 untouched");
            assert_eq!(after[2].0, Some("three".to_string()), "the all-NULL row matched");

            // --- 2. A stale second row rolls the FIRST one back --------------
            let request = base(vec![
                // Row 1: valid — it would succeed on its own.
                row(
                    &["1"],
                    &[Some("ONE"), Some("11.5"), Some("false")],
                    &[Some("ROLLED BACK"), Some("99"), Some("true")],
                ),
                // Row 2: the old name is stale, so it matches 0 rows.
                row(
                    &["2"],
                    &[Some("STALE"), Some("2.5"), Some("false")],
                    &[Some("never"), Some("0"), Some("true")],
                ),
            ]);
            let err = apply_row_updates(CONN.to_string(), request, &state)
                .await
                .expect_err("a stale old value must fail");
            assert!(err.starts_with("Row 2"), "the error must name row 2: {}", err);
            assert!(
                err.contains("changed a value since it was loaded"),
                "the error must explain the 0-row case: {}",
                err
            );

            let after = read_back(&pool, &table).await;
            assert_eq!(
                after[0].0,
                Some("ONE".to_string()),
                "ROLLBACK: row 1's change must NOT be applied"
            );
            assert_eq!(after[1].0, Some("two".to_string()), "row 2 untouched");

            // --- 3. A key that matches TWO rows rolls back -------------------
            // A primary key cannot do this, so use a table with a non-unique
            // "key" column — the dangerous case the RETURNING count exists for.
            let create_dup = format!(
                "CREATE TABLE public.\"{t}\" (id int, name text); \
                 INSERT INTO public.\"{t}\" VALUES (1, 'a'), (1, 'a'), (2, 'b');",
                t = dup_table
            );
            sqlx::raw_sql(&create_dup).execute(&pool).await.expect("create dup fixture");

            let dup_request = RowUpdateRequest {
                schema: "public".to_string(),
                table: dup_table.clone(),
                key_columns: vec![column("id", "int4")],
                key_description: "unique index (id)".to_string(),
                columns: vec![column("name", "text")],
                rows: vec![
                    // Row 1 matches exactly one row and would commit on its own.
                    row(&["2"], &[Some("b")], &[Some("B CHANGED")]),
                    // Row 2's key matches two rows.
                    row(&["1"], &[Some("a")], &[Some("BOOM")]),
                ],
            };
            let err = apply_row_updates(CONN.to_string(), dup_request, &state)
                .await
                .expect_err("a key matching two rows must fail");
            assert!(err.starts_with("Row 2"), "the error must name row 2: {}", err);
            assert!(
                err.contains("matched more than one row"),
                "the error must explain the >1 case: {}",
                err
            );

            let dup_after = sqlx::raw_sql(&format!(
                "SELECT name FROM public.\"{}\" ORDER BY id, name",
                dup_table
            ))
            .fetch_all(&pool)
            .await
            .expect("dup read back")
            .iter()
            .map(|r| r.try_get::<String, _>("name").expect("name"))
            .collect::<Vec<_>>();
            assert_eq!(
                dup_after,
                vec!["a".to_string(), "a".to_string(), "b".to_string()],
                "ROLLBACK: nothing at all changed, including the first row"
            );

            // --- clean up ----------------------------------------------------
            sqlx::raw_sql(&format!(
                "DROP TABLE public.\"{}\"; DROP TABLE public.\"{}\";",
                table, dup_table
            ))
            .execute(&pool)
            .await
            .expect("drop fixtures");
        });
    }
}
