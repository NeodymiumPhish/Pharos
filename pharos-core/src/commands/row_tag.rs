use crate::db::sqlite;
use crate::models::{CreateTagLabel, RowTag, TagLabel, UpdateTagLabel, UpsertRowTag};
use crate::state::AppState;

// ---------------------------------------------------------------------------
// Labels
// ---------------------------------------------------------------------------

pub async fn load_tag_labels(state: &AppState) -> Result<Vec<TagLabel>, String> {
    let db = state.metadata_db.lock().map_err(|e| e.to_string())?;

    sqlite::load_tag_labels(&db).map_err(|e| format!("Failed to load tag labels: {}", e))
}

/// The id is minted here, not in the CRUD, matching `create_saved_query`.
pub async fn create_tag_label(
    state: &AppState,
    label: CreateTagLabel,
) -> Result<TagLabel, String> {
    let id = uuid::Uuid::new_v4().to_string();
    let db = state.metadata_db.lock().map_err(|e| e.to_string())?;

    sqlite::create_tag_label(&db, &id, &label)
        .map_err(|e| format!("Failed to create tag label: {}", e))
}

pub async fn update_tag_label(
    state: &AppState,
    update: UpdateTagLabel,
) -> Result<Option<TagLabel>, String> {
    let db = state.metadata_db.lock().map_err(|e| e.to_string())?;

    sqlite::update_tag_label(&db, &update)
        .map_err(|e| format!("Failed to update tag label: {}", e))
}

/// Returns 0 for an unknown label. That is not an error: the caller asks this
/// only to phrase a delete confirmation.
pub async fn count_tags_for_label(state: &AppState, label_id: String) -> Result<i64, String> {
    let db = state.metadata_db.lock().map_err(|e| e.to_string())?;

    sqlite::count_tags_for_label(&db, &label_id)
        .map_err(|e| format!("Failed to count tags for label: {}", e))
}

/// Returns false for an unknown label, exactly as `delete_saved_query` does.
pub async fn delete_tag_label(state: &AppState, label_id: String) -> Result<bool, String> {
    let db = state.metadata_db.lock().map_err(|e| e.to_string())?;

    sqlite::delete_tag_label(&db, &label_id)
        .map_err(|e| format!("Failed to delete tag label: {}", e))
}

// ---------------------------------------------------------------------------
// Row tags
// ---------------------------------------------------------------------------

pub async fn load_row_tags(
    state: &AppState,
    connection_id: String,
) -> Result<Vec<RowTag>, String> {
    let db = state.metadata_db.lock().map_err(|e| e.to_string())?;

    sqlite::load_row_tags(&db, &connection_id)
        .map_err(|e| format!("Failed to load row tags: {}", e))
}

/// The CRUD mints the tag id AND opens its own transaction. So no id is made
/// here, and nothing wraps the call: a second `BEGIN` on this connection would
/// be refused.
pub async fn upsert_row_tag(state: &AppState, upsert: UpsertRowTag) -> Result<RowTag, String> {
    let db = state.metadata_db.lock().map_err(|e| e.to_string())?;

    sqlite::upsert_row_tag(&db, &upsert).map_err(|e| format!("Failed to save row tag: {}", e))
}

pub async fn delete_row_tag(state: &AppState, tag_id: String) -> Result<bool, String> {
    let db = state.metadata_db.lock().map_err(|e| e.to_string())?;

    sqlite::delete_row_tag(&db, &tag_id).map_err(|e| format!("Failed to delete row tag: {}", e))
}

/// The count is the number of rows actually removed, which can be fewer than
/// `tag_ids.len()`. Like `upsert_row_tag`, the CRUD holds its own transaction.
pub async fn delete_row_tags(
    state: &AppState,
    tag_ids: Vec<String>,
) -> Result<usize, String> {
    let db = state.metadata_db.lock().map_err(|e| e.to_string())?;

    sqlite::delete_row_tags(&db, &tag_ids)
        .map_err(|e| format!("Failed to delete row tags: {}", e))
}

/// Live end-to-end verification of the tag round trip.
///
///   cargo test --release round_trip -- --ignored --nocapture
///
/// PHASE 1'S HEADLINE CLAIM, and the one seam no offline test can reach: a tag
/// set from a result that CARRIES the primary key must still attach to the same
/// physical row in a later result that DROPS the primary key and keeps only a
/// unique key. Every part of that path is unit-tested on its own — the catalogue
/// read, the candidate choice, the key encoding, the key-set-aware write — and
/// each one passing says nothing about the joins between them. Only a real
/// server reports the source-table OIDs that make the whole path possible.
///
/// Fixture: `scripts/tagtest-schema.sql`.
#[cfg(test)]
mod live_row_tag_tests {
    use crate::commands::row_identity::{KeySet, RowIdentity};
    use crate::commands::{
        count_tags_for_label, create_tag_label, delete_tag_label, execute_query, load_row_tags,
        upsert_row_tag, QueryResult,
    };
    use crate::models::{CreateTagLabel, RowTag, RowTagKey, UpsertRowTag};
    use crate::state::AppState;
    use rusqlite::Connection as SqliteConnection;
    use sqlx::postgres::PgPoolOptions;
    use sqlx::Row;
    use std::collections::HashMap;
    use std::time::Duration;

    const DEFAULT_URL: &str = "postgres://nfinn@localhost:5432/nfinn";
    const CONN: &str = "live-row-tag-test";

    /// The fixture tables these tests read.
    const NEEDED: [&str; 2] = ["users", "memberships"];

    /// Connect, then check the fixture. `None` means the caller must return
    /// WITHOUT asserting.
    ///
    /// A dead host is always a failure. A missing fixture is a skip on the
    /// DEFAULT database only: if the caller named a database in
    /// PHAROS_TEST_DATABASE_URL, they meant that one, and reporting `ok` for a
    /// test that never ran is worse than a failure, because it looks like proof.
    async fn live_pool() -> Option<sqlx::PgPool> {
        let explicit = std::env::var("PHAROS_TEST_DATABASE_URL").ok();
        let url = explicit.clone().unwrap_or_else(|| DEFAULT_URL.to_string());

        let pool = PgPoolOptions::new()
            .max_connections(2)
            // Without this a dead host takes the 30s default to fail.
            .acquire_timeout(Duration::from_secs(5))
            .connect(&url)
            .await
            .unwrap_or_else(|e| {
                panic!("cannot connect to {}: {}. Set PHAROS_TEST_DATABASE_URL.", url, e)
            });

        let sql = "SELECT c.relname AS name \
                   FROM pg_class c \
                   JOIN pg_namespace n ON n.oid = c.relnamespace \
                   WHERE n.nspname = 'tagtest' AND c.relkind = 'r'";
        let rows = sqlx::raw_sql(sql).fetch_all(&pool).await.expect("catalogue lookup failed");
        let present: Vec<String> =
            rows.iter().map(|r| r.try_get::<String, _>("name").expect("name decode")).collect();

        let missing: Vec<&str> =
            NEEDED.iter().copied().filter(|n| !present.iter().any(|r| r == n)).collect();
        if missing.is_empty() {
            return Some(pool);
        }

        let reason = format!(
            "schema `tagtest` in {} is missing {:?}. Load the fixture first: \
             psql -d <db> -f scripts/tagtest-schema.sql",
            url, missing
        );
        if explicit.is_some() {
            panic!(
                "{}\nPHAROS_TEST_DATABASE_URL named this database, so this is a \
                 failure, not a skip.",
                reason
            );
        }
        eprintln!("SKIP: {}", reason);
        None
    }

    /// A metadata database carrying the REAL schema.
    ///
    /// An empty in-memory connection will not do here, unlike in
    /// `live_query_identity_tests`: `execute_query` writes a query-history row,
    /// and the tag CRUD needs its three tables and their foreign keys.
    fn metadata_db() -> SqliteConnection {
        let conn = SqliteConnection::open_in_memory().expect("sqlite");
        crate::db::sqlite::create_schema(&conn).expect("metadata schema");
        conn
    }

    fn live_state(pool: &sqlx::PgPool) -> AppState {
        let state = AppState::new(metadata_db());
        state.add_pool(CONN.to_string(), pool.clone());
        state
    }

    /// The OID of one `tagtest` table, read from the catalogue rather than from
    /// the block under test, so the assertions cannot merely agree with
    /// themselves.
    async fn relation_oid(pool: &sqlx::PgPool, name: &str) -> u32 {
        let sql = format!(
            "SELECT c.oid AS oid FROM pg_class c \
             JOIN pg_namespace n ON n.oid = c.relnamespace \
             WHERE n.nspname = 'tagtest' AND c.relname = '{}'",
            name
        );
        let row = sqlx::raw_sql(&sql)
            .fetch_all(pool)
            .await
            .expect("oid lookup failed")
            .into_iter()
            .next()
            .unwrap_or_else(|| panic!("no tagtest table named {}", name));
        row.try_get::<sqlx::postgres::types::Oid, _>("oid").expect("oid decode").0
    }

    async fn run(state: &AppState, sql: &str) -> QueryResult {
        execute_query(CONN.to_string(), sql.to_string(), None, None, None, None, state)
            .await
            .unwrap_or_else(|e| panic!("execute_query failed for `{}`: {}", sql, e))
    }

    /// The candidate of the named kind, or a panic showing the whole set. Never
    /// index by position: an ordering change must fail loudly rather than assert
    /// silently against the wrong key.
    fn keyset<'a>(id: &'a RowIdentity, kind: &str) -> &'a KeySet {
        id.candidates
            .iter()
            .find(|c| c.kind == kind)
            .unwrap_or_else(|| panic!("no `{}` candidate; got {:?}", kind, id.candidates))
    }

    /// One row's value in the named result column. Every value crossed the wire
    /// as PostgreSQL text, so text or NULL is all that can appear.
    fn value_at(result: &QueryResult, row_index: usize, column: &str) -> Option<String> {
        let idx = result
            .columns
            .iter()
            .position(|c| c.name == column)
            .unwrap_or_else(|| panic!("no column named `{}`", column));
        let row = result.rows[row_index].as_array().expect("a result row is an array");
        match row.get(idx) {
            Some(serde_json::Value::String(s)) => Some(s.clone()),
            Some(serde_json::Value::Null) | None => None,
            Some(other) => panic!("a result value must be text or null; got {}", other),
        }
    }

    /// The values a tag stores for display. This is the work Swift will do:
    /// `identity_values` holds the raw column text, NOT an encoded key.
    fn values_for(result: &QueryResult, row_index: usize, columns: &[String]) -> Vec<Option<String>> {
        columns.iter().map(|c| value_at(result, row_index, c)).collect()
    }

    /// The matcher Phase 2 will build in Swift, written here in Rust: index
    /// EVERY key of EVERY tag, so a tag saved under two candidates is found
    /// through either one.
    fn key_index(tags: &[RowTag]) -> HashMap<(String, String, String), &RowTag> {
        let mut index = HashMap::new();
        for tag in tags {
            for key in &tag.keys {
                index.insert(
                    (
                        tag.table_key.clone(),
                        key.identity_kind.clone(),
                        key.identity_value.clone(),
                    ),
                    tag,
                );
            }
        }
        index
    }

    // -----------------------------------------------------------------------
    // The round trip
    // -----------------------------------------------------------------------

    #[test]
    #[ignore = "needs a live PostgreSQL with scripts/tagtest-schema.sql loaded"]
    fn a_tag_set_from_the_primary_key_is_found_again_by_the_round_trip_of_a_unique_key() {
        let rt = tokio::runtime::Runtime::new().expect("tokio runtime");
        rt.block_on(async move {
            let Some(pool) = live_pool().await else { return };
            let users_oid = relation_oid(&pool, "users").await;
            let state = live_state(&pool);

            // --- 1. A result carrying BOTH keys ---------------------------
            let sql = "SELECT * FROM tagtest.users ORDER BY id";
            let source = run(&state, sql).await;
            let source_id =
                source.row_identity.as_ref().expect("step 1: expected an identity block");
            assert_eq!(
                source_id.candidates.len(),
                2,
                "step 1: `SELECT *` must satisfy both keys; got {:?}",
                source_id.candidates
            );
            let pk = keyset(source_id, "pk").clone();
            let unique = keyset(source_id, "unique").clone();
            assert_eq!(pk.key_columns, vec!["id"], "step 1 pk columns");
            assert_eq!(unique.key_columns, vec!["email"], "step 1 unique columns");
            assert_eq!(
                source_id.table_key,
                format!("oid:{}", users_oid),
                "step 1: table_key must name tagtest.users"
            );

            // Row 0 is the row being tagged. Name it from the DATA, not from the
            // ORDER BY: if the fixture ever changes, this must fail here rather
            // than quietly tag someone else and still pass.
            const TAGGED_ROW: usize = 0;
            assert_eq!(
                value_at(&source, TAGGED_ROW, "name").as_deref(),
                Some("Ann"),
                "step 1: row 0 of `ORDER BY id` must be Ann"
            );

            // --- 2. A label, through the command layer --------------------
            let label = create_tag_label(
                &state,
                CreateTagLabel { name: "round-trip probe".to_string(), color_index: 3 },
            )
            .await
            .expect("step 2: create_tag_label failed");

            // --- 3. Tag row 0, carrying BOTH candidate keys ---------------
            // The two keys are the whole point: the pk key is what this result
            // can offer, and the unique key is what a LATER result will be able
            // to look up. Saving only the pk key would make step 6 impossible.
            let saved = upsert_row_tag(
                &state,
                UpsertRowTag {
                    connection_id: CONN.to_string(),
                    label_id: label.id.clone(),
                    note: Some("set from SELECT *".to_string()),
                    primary_kind: "pk".to_string(),
                    table_key: source_id.table_key.clone(),
                    table_display: source_id.table_display.clone(),
                    identity_columns: pk.key_columns.clone(),
                    identity_values: values_for(&source, TAGGED_ROW, &pk.key_columns),
                    keys: vec![
                        RowTagKey {
                            identity_kind: pk.kind.clone(),
                            identity_value: pk.keys[TAGGED_ROW].clone(),
                        },
                        RowTagKey {
                            identity_kind: unique.kind.clone(),
                            identity_value: unique.keys[TAGGED_ROW].clone(),
                        },
                    ],
                },
            )
            .await
            .expect("step 3: upsert_row_tag failed");
            assert_eq!(saved.keys.len(), 2, "step 3: both keys must be stored");
            assert_eq!(
                saved.identity_values,
                vec![Some("1".to_string())],
                "step 3: the stored values must be Ann's id"
            );

            println!("\n=== the round trip =====================================");
            println!("  tagged from: {}", sql);
            println!("    row {} is {:?}", TAGGED_ROW, value_at(&source, TAGGED_ROW, "name"));
            println!("    label:     {} ({})", label.name, label.id);
            println!("    table_key: {}", saved.table_key);
            for key in &saved.keys {
                println!("    stored key {:>7}: {}", key.identity_kind, key.identity_value);
            }

            // --- 4. A DIFFERENT query, with NO primary key ----------------
            let later_sql = "SELECT name, email FROM tagtest.users ORDER BY email";
            let later = run(&state, later_sql).await;
            let later_id =
                later.row_identity.as_ref().expect("step 4: expected an identity block");
            assert_eq!(
                later_id.candidates.len(),
                1,
                "step 4: the primary key is absent, so exactly one candidate must \
                 survive; got {:?}",
                later_id.candidates
            );
            let later_unique = keyset(later_id, "unique");
            assert_eq!(later_unique.key_columns, vec!["email"], "step 4 unique columns");
            assert!(
                !later.columns.iter().any(|c| c.name == "id"),
                "step 4: the test is void if the result still carries the primary key"
            );
            // The lookup below crosses the two results, so their table keys must
            // agree. Nothing else checks this.
            assert_eq!(
                later_id.table_key, saved.table_key,
                "step 4: both results must name the same table"
            );

            // --- 5. Load and index, as Swift will ------------------------
            let tags = load_row_tags(&state, CONN.to_string())
                .await
                .expect("step 5: load_row_tags failed");
            assert_eq!(tags.len(), 1, "step 5: one tag was written");
            let index = key_index(&tags);

            // --- 6. THE ASSERTION THIS PHASE EXISTS FOR ------------------
            println!("  matched in: {}", later_sql);
            let mut matched_names: Vec<String> = Vec::new();
            for row in 0..later.row_count {
                let name = value_at(&later, row, "name").unwrap_or_default();
                let email = value_at(&later, row, "email").unwrap_or_default();
                let key = &later_unique.keys[row];
                let hit = index.get(&(
                    later_id.table_key.clone(),
                    later_unique.kind.clone(),
                    key.clone(),
                ));
                println!(
                    "    row {} name={:<4} email={:<8} key={:<12} -> {}",
                    row,
                    name,
                    email,
                    key,
                    match hit {
                        Some(t) => format!("MATCHED tag {} (label {})", t.id, t.label_id),
                        None => "no tag".to_string(),
                    }
                );
                if let Some(tag) = hit {
                    assert_eq!(
                        tag.label_id, label.id,
                        "row {} matched a tag holding the wrong label",
                        row
                    );
                    matched_names.push(name);
                }
            }
            assert_eq!(
                matched_names,
                vec!["Ann".to_string()],
                "THE ROUND TRIP FAILED: a tag set from `SELECT *` must attach to \
                 Ann's row, and ONLY Ann's row, in `SELECT name, email`"
            );
            println!("  result: the tag followed Ann, and no other row.");

            // --- C. The cascade really removes tags ----------------------
            // Through the command layer, so this proves the database-level
            // ON DELETE CASCADE reaches the caller, not just the SQL.
            assert_eq!(
                count_tags_for_label(&state, label.id.clone())
                    .await
                    .expect("count_tags_for_label failed"),
                1,
                "check C: the label must hold exactly the one tag"
            );
            assert!(
                delete_tag_label(&state, label.id.clone())
                    .await
                    .expect("delete_tag_label failed"),
                "check C: deleting a known label must report true"
            );
            let after = load_row_tags(&state, CONN.to_string())
                .await
                .expect("load_row_tags after delete failed");
            assert!(
                after.is_empty(),
                "check C: deleting the label must cascade to its tags; got {:?}",
                after
            );
            println!("  check C: the label delete cascaded; 0 tags remain.");
        });
    }

    // -----------------------------------------------------------------------
    // A. One catalogue read per table, per connection
    // -----------------------------------------------------------------------

    /// The round-trip count cannot be observed from here: nothing counts the
    /// catalogue round trips. So this asserts the OBSERVABLE state the skip
    /// depends on — the entry is cached after the first query, and stays cached
    /// across later ones, which is exactly the condition
    /// `missing_key_cache_oids` tests before it reads.
    #[test]
    #[ignore = "needs a live PostgreSQL with scripts/tagtest-schema.sql loaded"]
    fn the_catalogue_is_cached_after_the_first_query_and_cleared_per_connection() {
        let rt = tokio::runtime::Runtime::new().expect("tokio runtime");
        rt.block_on(async move {
            let Some(pool) = live_pool().await else { return };
            let users_oid = relation_oid(&pool, "users").await;
            let state = live_state(&pool);

            assert!(
                state.get_table_key_info(CONN, users_oid).is_none(),
                "check A: nothing may be cached before the first query"
            );

            let sql = "SELECT * FROM tagtest.users ORDER BY id";
            for attempt in 1..=3 {
                run(&state, sql).await;
                let info = state.get_table_key_info(CONN, users_oid).unwrap_or_else(|| {
                    panic!("check A: no cached entry after query {}", attempt)
                });
                assert_eq!(info.display, "tagtest.users", "check A: cached display");
                assert_eq!(info.candidates.len(), 2, "check A: cached candidates");
            }
            println!("\ncheck A: cached after query 1, still cached after 3.");

            // Per connection: a disconnect must drop it, because an OID means
            // nothing outside the connection that reported it.
            state.clear_key_cache(CONN);
            assert!(
                state.get_table_key_info(CONN, users_oid).is_none(),
                "check A: clear_key_cache must empty the connection's entries"
            );
            println!("check A: clear_key_cache emptied it again.");
        });
    }

    // -----------------------------------------------------------------------
    // B. The error path is loud
    // -----------------------------------------------------------------------

    /// A tag naming a label that does not exist must be REFUSED. A foreign key
    /// guards it, so a silent success here would mean the pragma had been lost
    /// and orphan tags could accumulate, each one invisible in the palette.
    ///
    /// This one needs no server: it lives beside the round trip so that a single
    /// command produces the whole evidence set.
    #[test]
    #[ignore = "part of the live evidence set; needs no server itself"]
    fn a_tag_naming_an_unknown_label_is_refused() {
        let rt = tokio::runtime::Runtime::new().expect("tokio runtime");
        rt.block_on(async move {
            let state = AppState::new(metadata_db());

            let err = upsert_row_tag(
                &state,
                UpsertRowTag {
                    connection_id: CONN.to_string(),
                    label_id: "no-such-label-9f3c".to_string(),
                    note: None,
                    primary_kind: "pk".to_string(),
                    table_key: "oid:16543".to_string(),
                    table_display: "tagtest.users".to_string(),
                    identity_columns: vec!["id".to_string()],
                    identity_values: vec![Some("1".to_string())],
                    keys: vec![RowTagKey {
                        identity_kind: "pk".to_string(),
                        identity_value: "V1:1".to_string(),
                    }],
                },
            )
            .await
            .expect_err("check B: an unknown label must NOT be accepted");

            println!("\ncheck B: {}", err);
            assert!(
                err.contains("Failed to save row tag"),
                "check B: the message must say which operation failed; got {}",
                err
            );
            assert!(
                err.to_uppercase().contains("FOREIGN KEY"),
                "check B: the message must name the constraint; got {}",
                err
            );

            // And nothing was left behind: the write is one transaction.
            let tags = load_row_tags(&state, CONN.to_string()).await.expect("load_row_tags failed");
            assert!(tags.is_empty(), "check B: the refused write must leave nothing; got {:?}", tags);
        });
    }

    // -----------------------------------------------------------------------
    // D. The fingerprint tier still returns a block
    // -----------------------------------------------------------------------

    /// `commands::query` case 3 runs the same query. This asserts it from the
    /// TAG side, because Phase 2's weak tier is built on this exact shape: a
    /// block that is present, names its tables, and reports NO candidate. A
    /// `None` block instead would leave the user interface with nothing to
    /// compare, and an invented candidate would attach tags to the wrong rows.
    #[test]
    #[ignore = "needs a live PostgreSQL with scripts/tagtest-schema.sql loaded"]
    fn a_result_with_no_key_column_still_reports_its_table() {
        let rt = tokio::runtime::Runtime::new().expect("tokio runtime");
        rt.block_on(async move {
            let Some(pool) = live_pool().await else { return };
            let users_oid = relation_oid(&pool, "users").await;
            let state = live_state(&pool);

            let sql = "SELECT name, status FROM tagtest.users";
            let r = run(&state, sql).await;
            let id = r.row_identity.as_ref().expect("check D: a block is still required");
            assert!(
                id.candidates.is_empty(),
                "check D: no key column means no candidate; got {:?}",
                id.candidates
            );
            assert_eq!(
                id.table_keys,
                vec![format!("oid:{}", users_oid)],
                "check D: the block must still name its source table"
            );
            assert_eq!(id.table_display, "tagtest.users", "check D: table_display");
            println!(
                "\ncheck D: {} -> candidates [] , table_keys {:?}, display {}",
                sql, id.table_keys, id.table_display
            );
        });
    }
}
