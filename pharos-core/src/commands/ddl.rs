//! Pure reconstruction of a table's CREATE TABLE DDL from raw pg_catalog parts.

use crate::commands::table::escape_identifier;
use serde::{Deserialize, Serialize};

/// One column's raw DDL ingredients, as read from pg_catalog.
#[derive(Debug, Clone)]
pub struct DdlColumn {
    pub name: String,
    pub type_str: String,
    pub not_null: bool,
    pub default_expr: Option<String>,
    /// pg_attribute.attidentity as text: "" (none), "a" (always), "d" (by default)
    pub identity: String,
    /// pg_attribute.attgenerated as text: "" (none), "s" (stored)
    pub generated: String,
}

/// One constraint, name + full definition from pg_get_constraintdef.
#[derive(Debug, Clone)]
pub struct DdlConstraint {
    pub name: String,
    pub definition: String,
}

/// All raw parts needed to compose a table's DDL.
#[derive(Debug, Clone, Default)]
pub struct TableDdlParts {
    pub columns: Vec<DdlColumn>,
    pub constraints: Vec<DdlConstraint>,
    /// Full `CREATE INDEX ...` statements (no trailing semicolon) from pg_get_indexdef,
    /// excluding indexes that back a constraint.
    pub index_defs: Vec<String>,
    /// The partition clause from pg_get_partkeydef (e.g. "RANGE (created_at)"),
    /// or None for a non-partitioned table.
    pub partition_by: Option<String>,
    /// The (schema, table) pairs this table INHERITS from, in inhseqno
    /// order. Empty for almost every table; legacy partitioning is built out
    /// of these, and without the clause a child's DDL reads as an unrelated
    /// standalone table. A declarative partition is NOT listed here: its
    /// parent is attached with ALTER TABLE, not INHERITS.
    pub inherits: Vec<(String, String)>,
    /// Whether anything INHERITS from this table. False for a declarative
    /// parent. It is not in the rendered DDL — a parent's own DDL says
    /// nothing about its children — but a clone of this table depends on it,
    /// so the sheet that offers the clone needs it.
    pub has_child_tables: bool,
    /// The (schema, table) this one is a declarative PARTITION OF. A
    /// declarative partition is attached with ALTER TABLE, not INHERITS, so
    /// it appears in neither `inherits` above nor anywhere in the CREATE —
    /// without this the child's DDL reads as an unrelated standalone table
    /// that can be pasted and run to produce exactly that.
    pub partition_of: Option<(String, String)>,
    /// This partition's bound, as `pg_get_expr(relpartbound)` spells it:
    /// "FOR VALUES FROM (...) TO (...)", "FOR VALUES IN (...)",
    /// "FOR VALUES WITH (...)" or the bare word "DEFAULT". Present exactly
    /// when `partition_of` is.
    pub partition_bound: Option<String>,
}

/// One schema-qualified name, sent to Swift RAW: unquoted and unescaped.
///
/// The DDL strings above are SQL, so they quote and double-quote their
/// identifiers. These are not — they are shown in the sheet's own prose, where
/// the per-part display escaping (`DisplayEscape.escapedQualified`) is what
/// makes an invisible scalar in a name visible. Escaping here would save the
/// escape tokens into the SQL-quoted form and defeat it.
#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct QualifiedName {
    pub schema: String,
    pub table: String,
}

/// What a table's shape means for CLONING it, sent alongside the DDL.
///
/// `LIKE ... INCLUDING ALL` carries neither `PARTITION BY` nor `INHERITS`, so
/// these three facts decide what the copy can be and which rows it may take.
/// The sheet reads them to say so before the analyst commits to it.
#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct TableShape {
    /// The partition clause the copy must carry, e.g. "RANGE (created_at)".
    /// `Some` means the copy is created with NO partitions and can hold no rows.
    pub partition_by: Option<String>,
    /// The parents this table inherits from. The copy will NOT inherit from
    /// them — it is standalone — and the sheet says so, naming them.
    pub inherits_from: Vec<QualifiedName>,
    /// Whether descendants exist, and therefore whether the row scope is a
    /// real choice rather than one answer under two names.
    pub has_child_tables: bool,
    /// The parent this table is a declarative partition of. `LIKE ...
    /// INCLUDING ALL` carries no attachment, so the copy stands alone —
    /// the same fact `inherits_from` states for a legacy child, and the
    /// sheet says it the same way.
    pub partition_of: Option<QualifiedName>,
}

/// The three ready-to-display DDL variants sent to Swift.
#[derive(Debug, Clone, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct TableDdl {
    pub columns_only: String,
    pub with_constraints: String,
    pub full: String,
    pub shape: TableShape,
}

/// Render a single column definition line (indented, no trailing comma).
fn render_column(col: &DdlColumn) -> String {
    let mut s = format!("    \"{}\" {}", escape_identifier(&col.name), col.type_str);
    if col.generated == "s" {
        if let Some(expr) = &col.default_expr {
            s.push_str(&format!(" GENERATED ALWAYS AS ({}) STORED", expr));
        }
        if col.not_null {
            s.push_str(" NOT NULL");
        }
    } else if col.identity == "a" {
        s.push_str(" GENERATED ALWAYS AS IDENTITY");
    } else if col.identity == "d" {
        s.push_str(" GENERATED BY DEFAULT AS IDENTITY");
    } else {
        if let Some(expr) = &col.default_expr {
            s.push_str(&format!(" DEFAULT {}", expr));
        }
        if col.not_null {
            s.push_str(" NOT NULL");
        }
    }
    s
}

/// Render a constraint line (indented, no trailing comma).
fn render_constraint(con: &DdlConstraint) -> String {
    format!("    CONSTRAINT \"{}\" {}", escape_identifier(&con.name), con.definition)
}

/// Render a CREATE TABLE statement from column lines and optional constraint lines.
fn render_create_table(
    schema: &str,
    table: &str,
    col_lines: &[String],
    constraint_lines: &[String],
    partition_by: Option<&str>,
    inherits: &[(String, String)],
) -> String {
    let mut body: Vec<String> = col_lines.to_vec();
    body.extend_from_slice(constraint_lines);
    let partition = match partition_by {
        Some(p) => format!(" PARTITION BY {}", p),
        None => String::new(),
    };
    // INHERITS comes before PARTITION BY, which is the order the grammar
    // takes them in. The inherited columns stay in the list above: naming a
    // column the parent already has is legal — PostgreSQL merges the two —
    // and a reader wants to see what the table holds.
    let inherit_clause = if inherits.is_empty() {
        String::new()
    } else {
        let parents: Vec<String> = inherits
            .iter()
            .map(|(s, t)| format!("\"{}\".\"{}\"", escape_identifier(s), escape_identifier(t)))
            .collect();
        format!(" INHERITS ({})", parents.join(", "))
    };
    format!(
        "CREATE TABLE \"{}\".\"{}\" (\n{}\n){}{};",
        escape_identifier(schema),
        escape_identifier(table),
        body.join(",\n"),
        inherit_clause,
        partition
    )
}

/// Render the `ALTER TABLE ... ATTACH PARTITION` that puts a declarative
/// partition back under its parent.
///
/// `CREATE TABLE ... PARTITION OF` is the form pg_dump writes, but the
/// grammar forbids a column list in it, and the sheet's "Columns" and
/// "+ Constraints" levels exist to show exactly that list. ATTACH says the
/// same thing as a separate statement, so all three levels keep their
/// content and the pair is still runnable end to end.
///
/// `bound` arrives from `pg_get_expr(relpartbound)` already carrying its own
/// keywords — "FOR VALUES ..." or the bare word "DEFAULT". A one-word bound
/// stays on the line; a long one gets its own, as the CREATE's clauses do.
fn render_attach_partition(
    parent: &(String, String),
    schema: &str,
    table: &str,
    bound: &str,
) -> String {
    let head = format!(
        "ALTER TABLE \"{}\".\"{}\" ATTACH PARTITION \"{}\".\"{}\"",
        escape_identifier(&parent.0),
        escape_identifier(&parent.1),
        escape_identifier(schema),
        escape_identifier(table)
    );
    let bound = bound.trim();
    if bound.contains(' ') {
        format!("{}\n    {};", head, bound)
    } else {
        format!("{} {};", head, bound)
    }
}

/// Compose the three DDL variants from raw parts. Pure — no I/O.
pub fn compose_table_ddl(schema: &str, table: &str, parts: &TableDdlParts) -> TableDdl {
    let col_lines: Vec<String> = parts.columns.iter().map(render_column).collect();
    let constraint_lines: Vec<String> = parts.constraints.iter().map(render_constraint).collect();

    let mut columns_only = render_create_table(
        schema, table, &col_lines, &[], parts.partition_by.as_deref(), &parts.inherits);
    let mut with_constraints = render_create_table(
        schema, table, &col_lines, &constraint_lines, parts.partition_by.as_deref(), &parts.inherits);

    let shape = TableShape {
        partition_by: parts.partition_by.clone(),
        inherits_from: parts
            .inherits
            .iter()
            .map(|(s, t)| QualifiedName { schema: s.clone(), table: t.clone() })
            .collect(),
        has_child_tables: parts.has_child_tables,
        partition_of: parts
            .partition_of
            .as_ref()
            .map(|(s, t)| QualifiedName { schema: s.clone(), table: t.clone() }),
    };

    let mut full = with_constraints.clone();
    if !parts.index_defs.is_empty() {
        full.push_str("\n\n");
        full.push_str(
            &parts
                .index_defs
                .iter()
                .map(|d| format!("{};", d))
                .collect::<Vec<_>>()
                .join("\n"),
        );
    }

    // The attachment is a statement, not a clause, so every variant carries
    // it: a CREATE without it produces a DETACHED table at any detail level.
    // It goes last, after the indexes in `full`, because ATTACH matches the
    // child's existing indexes to the parent's partitioned ones — run the
    // other way round it leaves a duplicate pair behind.
    if let (Some(parent), Some(bound)) = (&parts.partition_of, &parts.partition_bound) {
        let attach = render_attach_partition(parent, schema, table, bound);
        for variant in [&mut columns_only, &mut with_constraints, &mut full] {
            variant.push_str("\n\n");
            variant.push_str(&attach);
        }
    }

    TableDdl {
        columns_only,
        with_constraints,
        full,
        shape,
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    fn sample_parts() -> TableDdlParts {
        TableDdlParts {
            columns: vec![
                DdlColumn {
                    name: "id".into(),
                    type_str: "bigint".into(),
                    not_null: true,
                    default_expr: None,
                    identity: "a".into(),
                    generated: "".into(),
                },
                DdlColumn {
                    name: "cust_id".into(),
                    type_str: "bigint".into(),
                    not_null: true,
                    default_expr: None,
                    identity: "".into(),
                    generated: "".into(),
                },
                DdlColumn {
                    name: "total".into(),
                    type_str: "numeric(10,2)".into(),
                    not_null: false,
                    default_expr: Some("0".into()),
                    identity: "".into(),
                    generated: "".into(),
                },
                DdlColumn {
                    name: "total_with_tax".into(),
                    type_str: "numeric(10,2)".into(),
                    not_null: false,
                    default_expr: Some("(total * 1.2)".into()),
                    identity: "".into(),
                    generated: "s".into(),
                },
                DdlColumn {
                    name: "created_at".into(),
                    type_str: "timestamp with time zone".into(),
                    not_null: true,
                    default_expr: Some("now()".into()),
                    identity: "".into(),
                    generated: "".into(),
                },
            ],
            constraints: vec![
                DdlConstraint {
                    name: "orders_pkey".into(),
                    definition: "PRIMARY KEY (id)".into(),
                },
                DdlConstraint {
                    name: "orders_total_check".into(),
                    definition: "CHECK ((total >= (0)::numeric))".into(),
                },
                DdlConstraint {
                    name: "orders_cust_fkey".into(),
                    definition: "FOREIGN KEY (cust_id) REFERENCES customers(id)".into(),
                },
            ],
            index_defs: vec![
                "CREATE INDEX orders_cust_idx ON public.orders USING btree (cust_id)".into(),
            ],
            partition_by: None,
            inherits: vec![],
            has_child_tables: false,
            partition_of: None,
            partition_bound: None,
        }
    }

    #[test]
    fn columns_only_has_no_constraints_or_indexes() {
        let ddl = compose_table_ddl("public", "orders", &sample_parts());
        assert!(ddl.columns_only.starts_with("CREATE TABLE \"public\".\"orders\" ("));
        assert!(!ddl.columns_only.contains("CONSTRAINT"));
        assert!(!ddl.columns_only.contains("CREATE INDEX"));
        assert!(ddl.columns_only.contains("\"id\" bigint GENERATED ALWAYS AS IDENTITY"));
        assert!(ddl.columns_only.contains("\"total\" numeric(10,2) DEFAULT 0"));
    }

    #[test]
    fn not_null_column_with_default_renders_default_before_not_null() {
        let ddl = compose_table_ddl("public", "orders", &sample_parts());
        assert!(ddl
            .columns_only
            .contains("\"created_at\" timestamp with time zone DEFAULT now() NOT NULL"));
    }

    #[test]
    fn generated_column_renders_stored_expression() {
        let ddl = compose_table_ddl("public", "orders", &sample_parts());
        assert!(ddl
            .columns_only
            .contains("\"total_with_tax\" numeric(10,2) GENERATED ALWAYS AS ((total * 1.2)) STORED"));
    }

    #[test]
    fn with_constraints_has_constraints_but_no_indexes() {
        let ddl = compose_table_ddl("public", "orders", &sample_parts());
        assert!(ddl.with_constraints.contains("CONSTRAINT \"orders_pkey\" PRIMARY KEY (id)"));
        assert!(ddl
            .with_constraints
            .contains("CONSTRAINT \"orders_cust_fkey\" FOREIGN KEY (cust_id) REFERENCES customers(id)"));
        assert!(!ddl.with_constraints.contains("CREATE INDEX"));
    }

    #[test]
    fn full_appends_create_index_with_semicolon() {
        let ddl = compose_table_ddl("public", "orders", &sample_parts());
        assert!(ddl.full.contains("CONSTRAINT \"orders_pkey\""));
        assert!(ddl
            .full
            .contains("CREATE INDEX orders_cust_idx ON public.orders USING btree (cust_id);"));
    }

    #[test]
    fn no_indexes_means_full_equals_with_constraints() {
        let mut parts = sample_parts();
        parts.index_defs.clear();
        let ddl = compose_table_ddl("public", "orders", &parts);
        assert_eq!(ddl.full, ddl.with_constraints);
    }

    #[test]
    fn partitioned_table_renders_partition_by_clause() {
        let mut parts = sample_parts();
        parts.partition_by = Some("RANGE (created_at)".into());
        let ddl = compose_table_ddl("public", "orders", &parts);
        assert!(ddl.columns_only.contains(") PARTITION BY RANGE (created_at);"));
        assert!(ddl.with_constraints.contains(") PARTITION BY RANGE (created_at);"));
        assert!(ddl.full.contains(") PARTITION BY RANGE (created_at);"));
    }

    #[test]
    fn an_inherited_table_renders_its_inherits_clause() {
        let mut parts = sample_parts();
        parts.inherits = vec![("public".into(), "dns_log_201301".into())];
        let ddl = compose_table_ddl("public", "dns_log_20130101", &parts);
        for variant in [&ddl.columns_only, &ddl.with_constraints, &ddl.full] {
            assert!(
                variant.contains(") INHERITS (\"public\".\"dns_log_201301\");"),
                "{variant}"
            );
        }
    }

    #[test]
    fn several_parents_are_listed_in_order_and_quoted() {
        let mut parts = sample_parts();
        parts.inherits = vec![
            ("public".into(), "a".into()),
            ("other".into(), "b\"evil".into()),
        ];
        let ddl = compose_table_ddl("public", "both", &parts);
        assert!(
            ddl.columns_only.contains(") INHERITS (\"public\".\"a\", \"other\".\"b\"\"evil\");"),
            "{}",
            ddl.columns_only
        );
    }

    #[test]
    fn inherits_comes_before_partition_by() {
        // The grammar takes them in that order. Both at once is a strange
        // table, but the renderer must not invent invalid SQL for it.
        let mut parts = sample_parts();
        parts.inherits = vec![("public".into(), "parent".into())];
        parts.partition_by = Some("RANGE (created_at)".into());
        let ddl = compose_table_ddl("public", "orders", &parts);
        let i = ddl.columns_only.find("INHERITS").unwrap();
        let p = ddl.columns_only.find("PARTITION BY").unwrap();
        assert!(i < p, "{}", ddl.columns_only);
    }

    #[test]
    fn a_table_with_no_parents_renders_no_clause() {
        let ddl = compose_table_ddl("public", "orders", &sample_parts());
        assert!(!ddl.full.contains("INHERITS"), "{}", ddl.full);
    }

    #[test]
    fn uuid_named_table_is_quoted_not_rejected() {
        // A UUID-named table/schema is a legal quoted PostgreSQL identifier
        // (common in multi-tenant / event-sourced DBs). The composer must quote
        // it, and the read path must NOT reject digit-started identifiers.
        let uuid = "9d56a337-0e17-4c6e-8ebc-ea490bef2923";
        let ddl = compose_table_ddl(uuid, uuid, &sample_parts());
        assert!(ddl
            .columns_only
            .starts_with("CREATE TABLE \"9d56a337-0e17-4c6e-8ebc-ea490bef2923\".\"9d56a337-0e17-4c6e-8ebc-ea490bef2923\" ("));
    }

    // ---- a declarative partition's attachment ----

    fn partition_parts() -> TableDdlParts {
        let mut parts = sample_parts();
        parts.partition_of = Some(("public".into(), "events".into()));
        parts.partition_bound =
            Some("FOR VALUES FROM ('2013-01-01') TO ('2014-01-01')".into());
        parts
    }

    #[test]
    fn every_variant_carries_the_attach_statement() {
        // A CREATE alone produces a DETACHED table, whichever detail level
        // the analyst copied it from.
        let ddl = compose_table_ddl("public", "events_2013", &partition_parts());
        for variant in [&ddl.columns_only, &ddl.with_constraints, &ddl.full] {
            assert!(
                variant.contains(
                    "ALTER TABLE \"public\".\"events\" ATTACH PARTITION \"public\".\"events_2013\"\n    FOR VALUES FROM ('2013-01-01') TO ('2014-01-01');"
                ),
                "{variant}"
            );
        }
    }

    #[test]
    fn the_attach_comes_after_the_indexes() {
        // ATTACH matches the child's existing indexes to the parent's
        // partitioned ones; run before them it leaves a duplicate pair.
        let ddl = compose_table_ddl("public", "events_2013", &partition_parts());
        let idx = ddl.full.find("CREATE INDEX").unwrap();
        let attach = ddl.full.find("ATTACH PARTITION").unwrap();
        assert!(idx < attach, "{}", ddl.full);
    }

    #[test]
    fn a_default_partition_keeps_its_bound_on_one_line() {
        let mut parts = partition_parts();
        parts.partition_bound = Some("DEFAULT".into());
        let ddl = compose_table_ddl("public", "events_rest", &parts);
        assert!(
            ddl.columns_only.contains(
                "ALTER TABLE \"public\".\"events\" ATTACH PARTITION \"public\".\"events_rest\" DEFAULT;"
            ),
            "{}",
            ddl.columns_only
        );
    }

    #[test]
    fn the_attach_quotes_every_name_it_prints() {
        let mut parts = partition_parts();
        parts.partition_of = Some(("od\"d".into(), "pa\"rent".into()));
        let ddl = compose_table_ddl("sc\"h", "ch\"ild", &parts);
        assert!(
            ddl.columns_only.contains(
                "ALTER TABLE \"od\"\"d\".\"pa\"\"rent\" ATTACH PARTITION \"sc\"\"h\".\"ch\"\"ild\""
            ),
            "{}",
            ddl.columns_only
        );
    }

    #[test]
    fn a_half_read_attachment_renders_nothing() {
        // The pair is taken together or dropped together — half an ALTER
        // TABLE is worse than none.
        let mut parts = partition_parts();
        parts.partition_bound = None;
        assert!(!compose_table_ddl("public", "events_2013", &parts)
            .full
            .contains("ATTACH PARTITION"));
        let mut parts = partition_parts();
        parts.partition_of = None;
        assert!(!compose_table_ddl("public", "events_2013", &parts)
            .full
            .contains("ATTACH PARTITION"));
    }

    #[test]
    fn a_plain_table_and_an_inherits_child_render_no_attach() {
        assert!(!compose_table_ddl("public", "orders", &sample_parts())
            .full
            .contains("ATTACH PARTITION"));
        let mut parts = sample_parts();
        parts.inherits = vec![("public".into(), "dns_log".into())];
        let ddl = compose_table_ddl("public", "dns_log_2013", &parts);
        assert!(!ddl.full.contains("ATTACH PARTITION"), "{}", ddl.full);
        assert!(ddl.full.contains("INHERITS (\"public\".\"dns_log\")"), "{}", ddl.full);
    }

    #[test]
    fn the_shape_names_the_parent_raw_for_the_clone_note() {
        // RAW, for the same reason `inherits_from` is: the sheet escapes it
        // for display, and pre-escaping would save the tokens into the name.
        let mut parts = partition_parts();
        parts.partition_of = Some(("other".into(), "b\"evil".into()));
        let shape = compose_table_ddl("public", "events_2013", &parts).shape;
        assert_eq!(
            shape.partition_of,
            Some(QualifiedName { schema: "other".into(), table: "b\"evil".into() })
        );
        // A declarative partition is not an INHERITS child.
        assert!(shape.inherits_from.is_empty());
    }

    #[test]
    fn a_table_that_is_not_a_partition_reports_no_parent() {
        assert_eq!(
            compose_table_ddl("public", "orders", &sample_parts()).shape.partition_of,
            None
        );
    }

    // ---- the clone shape carried alongside the DDL ----

    #[test]
    fn a_plain_table_reports_a_shape_with_nothing_in_it() {
        let shape = compose_table_ddl("public", "orders", &sample_parts()).shape;
        assert_eq!(shape.partition_by, None);
        assert!(shape.inherits_from.is_empty());
        assert!(!shape.has_child_tables);
    }

    #[test]
    fn the_shape_carries_the_partition_key_the_copy_must_keep() {
        let mut parts = sample_parts();
        parts.partition_by = Some("RANGE (created_at)".into());
        let shape = compose_table_ddl("public", "orders", &parts).shape;
        assert_eq!(shape.partition_by.as_deref(), Some("RANGE (created_at)"));
        // A declarative parent's partitions are not INHERITS children.
        assert!(!shape.has_child_tables);
    }

    #[test]
    fn the_shape_lists_parents_raw_and_in_order() {
        // RAW: no quotes and no doubled quotes. The DDL string above is SQL
        // and quotes them; this is prose the sheet escapes for display, and
        // pre-escaping here would save the escape tokens into the name.
        let mut parts = sample_parts();
        parts.inherits = vec![
            ("public".into(), "a".into()),
            ("other".into(), "b\"evil".into()),
        ];
        let shape = compose_table_ddl("public", "orders", &parts).shape;
        assert_eq!(
            shape.inherits_from,
            vec![
                QualifiedName { schema: "public".into(), table: "a".into() },
                QualifiedName { schema: "other".into(), table: "b\"evil".into() },
            ]
        );
    }

    #[test]
    fn a_parent_reports_its_children_although_its_own_ddl_never_names_them() {
        let mut parts = sample_parts();
        parts.has_child_tables = true;
        let ddl = compose_table_ddl("public", "orders", &parts);
        assert!(ddl.shape.has_child_tables);
        assert!(!ddl.full.contains("INHERITS"), "a parent's DDL names no child: {}", ddl.full);
    }

    #[test]
    fn the_shape_serialises_camel_case_for_swift() {
        let mut parts = sample_parts();
        parts.partition_by = Some("RANGE (created_at)".into());
        parts.inherits = vec![("public".into(), "logs_2013".into())];
        parts.has_child_tables = true;
        let ddl = compose_table_ddl("public", "orders", &parts);
        let json = serde_json::to_string(&ddl).expect("serialise");
        // JSONDecoder.pharos sets no key strategy, so each of these names has
        // to be on the wire exactly as Swift spells its property.
        for key in ["\"shape\"", "\"partitionBy\"", "\"inheritsFrom\"", "\"hasChildTables\"", "\"partitionOf\"", "\"schema\"", "\"table\""] {
            assert!(json.contains(key), "{} missing from {}", key, json);
        }
    }

    #[test]
    fn a_shape_with_no_partition_key_sends_null_not_a_missing_key() {
        // Swift decodes it into `String?`; a missing key would also work for
        // an Optional, but null is what the struct promises and what the
        // fixture in TableDDLTests.swift pins.
        let json = serde_json::to_string(&compose_table_ddl("public", "orders", &sample_parts()))
            .expect("serialise");
        assert!(json.contains("\"partitionBy\":null"), "{}", json);
    }
}
