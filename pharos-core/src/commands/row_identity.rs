use serde::{Deserialize, Serialize};
use std::collections::HashMap;

use crate::models::{KeyCandidate, TableKeyInfo};

/// One column of a query result. `relation_oid` and `relation_attno` are what
/// make a row identity possible: they say which table column this result column
/// came from.
///
/// This struct carries NO `rename_all`, so its JSON keys stay snake_case. Swift
/// mirrors that with explicit CodingKeys.
#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct ColumnDef {
    pub name: String,
    pub data_type: String,
    /// The OID of the source table, from PgColumn::relation_id(). None for an
    /// expression column.
    #[serde(default)]
    pub relation_oid: Option<u32>,
    /// The 1-based attnum in that table, from relation_attribute_no().
    #[serde(default)]
    pub relation_attno: Option<i16>,
}

/// One satisfied key of a result: a kind, the columns it uses, and one key
/// string per row. An empty key string means the row has no identity in this
/// set, for example a NULL from an outer join.
#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct KeySet {
    /// "pk" | "unique"
    pub kind: String,
    pub key_columns: Vec<String>,
    pub keys: Vec<String>,
}

/// The row identity of a result. An empty `candidates` array means the
/// fingerprint tier: Swift then compares row values.
#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct RowIdentity {
    pub table_key: String,
    pub table_display: String,
    /// Every source table in the result, so the weak tier can test the table
    /// overlap even with no candidate.
    pub table_keys: Vec<String>,
    /// At most two entries, strongest first.
    pub candidates: Vec<KeySet>,
}

/// Assemble a result's identity block from catalogue info already in hand.
///
/// Pure by design. The caller does the I/O, so every branch below is reachable
/// from an offline test — which matters because each one is a silent
/// degradation: it produces a weaker identity, never an error.
///
/// `info` is None when the catalogue read failed. The result then keeps its
/// table names and drops to the fingerprint tier.
pub fn assemble_row_identity(
    columns: &[ColumnDef],
    json_rows: &[serde_json::Value],
    primary_oid: u32,
    all_oids: &[u32],
    info: Option<&TableKeyInfo>,
) -> RowIdentity {
    let table_display = info
        .map(|i| i.display.clone())
        // This is user-visible: table_display names the table in the tag
        // popover. Make a missing catalogue entry read as a fallback rather
        // than as a table name, and keep it clearly distinct from table_key's
        // "oid:{n}" form.
        .unwrap_or_else(|| unknown_table_display(primary_oid));

    // Where each of the primary table's columns sits in the result. `or_insert`
    // keeps the FIRST position, so a column selected twice always builds the
    // key from the same place. One map serves both the "is this key complete"
    // test and the key building below, so the two cannot disagree.
    let mut position_of: HashMap<i16, usize> = HashMap::new();
    for (idx, col) in columns.iter().enumerate() {
        if col.relation_oid == Some(primary_oid) {
            if let Some(attno) = col.relation_attno {
                position_of.entry(attno).or_insert(idx);
            }
        }
    }
    let present_attnos: Vec<i16> = position_of.keys().copied().collect();

    let chosen = info.map(|i| choose_candidates(&i.candidates, &present_attnos)).unwrap_or_default();

    let mut candidates: Vec<KeySet> = Vec::with_capacity(chosen.len());
    for cand in chosen {
        // Collecting into Option<Vec<_>> yields None if ANY attnum is missing.
        // choose_candidates only returns candidates whose every attnum is in
        // `present_attnos`, which came from this same map, so a None is
        // unreachable. It stays a guard rather than an index or an expect
        // because the failure it prevents is a SHORT key, and a short key is
        // not a missing key but a wrong one: it would claim that fewer columns
        // are unique than really are, and quietly attach a tag to the wrong row.
        let Some(indices) = cand
            .column_attnums
            .iter()
            .map(|attno| position_of.get(attno).copied())
            .collect::<Option<Vec<usize>>>()
        else {
            continue;
        };

        let key_columns: Vec<String> =
            indices.iter().map(|idx| columns[*idx].name.clone()).collect();

        let keys: Vec<String> = json_rows
            .iter()
            .map(|row| match row.as_array() {
                Some(values) => row_key(values, &indices),
                None => String::new(),
            })
            .collect();

        candidates.push(KeySet {
            kind: if cand.is_primary { "pk".to_string() } else { "unique".to_string() },
            key_columns,
            keys,
        });
    }

    RowIdentity {
        table_key: format!("oid:{}", primary_oid),
        table_display,
        table_keys: all_oids.iter().map(|o| format!("oid:{}", o)).collect(),
        candidates,
    }
}

/// Encode one field of a key. The length prefix makes the string
/// self-delimiting, so no separator and no escape is needed, and no value can
/// forge a key. `None` is a NULL.
pub fn encode_field(value: Option<&str>) -> String {
    match value {
        None => "N".to_string(),
        // `len()` on a &str is the UTF-8 byte count, which is the definition.
        Some(v) => format!("V{}:{}", v.len(), v),
    }
}

/// Join encoded fields in key-column order.
pub fn encode_key(values: &[Option<String>]) -> String {
    let mut out = String::new();
    for v in values {
        out.push_str(&encode_field(v.as_deref()));
    }
    out
}

/// The candidates this result satisfies, strongest first, capped at two: the
/// primary key, then the narrowest complete unique index whose columns are all
/// NOT NULL. The primary key's own index never competes for the second slot,
/// because `is_primary` excludes it.
pub fn choose_candidates(candidates: &[KeyCandidate], present_attnos: &[i16]) -> Vec<KeyCandidate> {
    let complete = |c: &KeyCandidate| c.column_attnums.iter().all(|a| present_attnos.contains(a));

    let mut chosen: Vec<KeyCandidate> = Vec::with_capacity(2);

    if let Some(pk) = candidates.iter().find(|c| c.is_primary && complete(c)) {
        chosen.push(pk.clone());
    }

    // Tie-break on the attnums themselves, not just on width. The catalogue
    // query returns rows in planner order, and `min_by_key` keeps the FIRST of
    // several equal minima, so width alone would let two unique indexes of the
    // same width swap places between runs. That is not cosmetic: the chosen
    // index decides the key a tag is STORED under, so a swap means a tag stops
    // matching its own row, silently. Lexicographic order on the attnums makes
    // the same table always yield the same key.
    let narrowest_unique = candidates
        .iter()
        .filter(|c| !c.is_primary && c.all_not_null && complete(c))
        .min_by_key(|c| (c.column_attnums.len(), c.column_attnums.clone()));
    if let Some(u) = narrowest_unique {
        chosen.push(u.clone());
    }

    chosen
}

/// The table that owns the most result columns. A tie goes to the leftmost
/// column's table. `None` when no column has a source table.
pub fn primary_table_oid(column_oids: &[Option<u32>]) -> Option<u32> {
    let mut counts: HashMap<u32, usize> = HashMap::new();
    let mut first_seen: HashMap<u32, usize> = HashMap::new();
    for (i, oid) in column_oids.iter().enumerate() {
        if let Some(oid) = oid {
            *counts.entry(*oid).or_insert(0) += 1;
            first_seen.entry(*oid).or_insert(i);
        }
    }
    counts
        .into_iter()
        // Most columns wins; on a tie the smaller first-seen index wins.
        .min_by_key(|(oid, count)| (std::cmp::Reverse(*count), first_seen[oid]))
        .map(|(oid, _)| oid)
}

/// The `table_display` text for a table whose catalogue entry is missing.
///
/// One source, because two call sites need the SAME bytes: the assembly's
/// fallback, and the negative-cache placeholder in `commands::query`. Swift may
/// come to treat this text as a state, so a drift between the two would be a
/// silent behaviour split.
pub fn unknown_table_display(oid: u32) -> String {
    format!("unknown table (oid {})", oid)
}

/// Build the key of one row from the given column positions.
///
/// Returns an empty string when any key value is NULL or any position is out of
/// range. An empty string is the "no identity" sentinel: such a row cannot hold
/// a tag, and the matcher must never treat it as a hit.
///
/// `row` holds the same JSON values that go to Swift. Every value crossed the
/// wire as PostgreSQL text, so a string or a null is all that can appear.
pub fn row_key(row: &[serde_json::Value], column_indices: &[usize]) -> String {
    let mut values: Vec<Option<String>> = Vec::with_capacity(column_indices.len());
    for idx in column_indices {
        match row.get(*idx) {
            Some(serde_json::Value::String(s)) => values.push(Some(s.clone())),
            Some(serde_json::Value::Null) | None => return String::new(),
            // Defensive: a non-string, non-null value means the text-protocol
            // assumption broke. Refuse to build a key rather than guess.
            Some(_) => return String::new(),
        }
    }
    encode_key(&values)
}

/// Tests for the whole-block assembly.
///
/// These cover what only an ignored live test reached before. Every path here is
/// a SILENT degradation: a wrong answer produces a weaker identity or a wrong
/// key, never an error, so nothing else would report the fault.
#[cfg(test)]
mod assemble_tests {
    use super::*;
    use crate::models::{KeyCandidate, TableKeyInfo};

    const USERS: u32 = 609999;

    fn col(name: &str, oid: Option<u32>, attno: Option<i16>) -> ColumnDef {
        ColumnDef {
            name: name.to_string(),
            data_type: "TEXT".to_string(),
            relation_oid: oid,
            relation_attno: attno,
        }
    }

    /// `tagtest.users`: a primary key on id (attnum 1) and a unique key on
    /// email (attnum 2).
    fn users_info() -> TableKeyInfo {
        TableKeyInfo {
            display: "tagtest.users".to_string(),
            candidates: vec![
                KeyCandidate { column_attnums: vec![1], is_primary: true, all_not_null: true },
                KeyCandidate { column_attnums: vec![2], is_primary: false, all_not_null: true },
            ],
        }
    }

    /// The four columns of `SELECT * FROM tagtest.users`.
    fn users_columns() -> Vec<ColumnDef> {
        vec![
            col("id", Some(USERS), Some(1)),
            col("email", Some(USERS), Some(2)),
            col("name", Some(USERS), Some(3)),
            col("status", Some(USERS), Some(4)),
        ]
    }

    fn row(values: &[serde_json::Value]) -> serde_json::Value {
        serde_json::Value::Array(values.to_vec())
    }

    fn s(v: &str) -> serde_json::Value {
        serde_json::Value::String(v.to_string())
    }

    fn keyset<'a>(id: &'a RowIdentity, kind: &str) -> &'a KeySet {
        id.candidates
            .iter()
            .find(|c| c.kind == kind)
            .unwrap_or_else(|| panic!("no `{}` candidate; got {:?}", kind, id.candidates))
    }

    /// The catalogue read failed, so there is no info. The block must still name
    /// the table, and must not pass an OID off as a table name: table_display
    /// goes straight into the tag popover.
    #[test]
    fn a_missing_catalogue_entry_still_names_the_table() {
        let id = assemble_row_identity(&users_columns(), &[], USERS, &[USERS], None);
        // Compare against the helper, not a literal: the point is that both
        // call sites agree, not that the wording is any particular string.
        assert_eq!(id.table_display, unknown_table_display(609999));
        assert_eq!(id.table_key, "oid:609999");
        // No info means no candidate can be judged complete, so this is the
        // fingerprint tier rather than a guess.
        assert!(id.candidates.is_empty(), "got {:?}", id.candidates);
    }

    /// `is_primary` must map to "pk" and everything else to "unique". Swift
    /// reads this string to decide which key is the stronger, so a swap would
    /// silently store tags under the weaker key.
    #[test]
    fn the_kind_names_the_key_type() {
        let rows = vec![row(&[s("1"), s("a@b.co"), s("Ann"), s("active")])];
        let id =
            assemble_row_identity(&users_columns(), &rows, USERS, &[USERS], Some(&users_info()));
        assert_eq!(id.candidates.len(), 2, "got {:?}", id.candidates);
        // Assert the kind of each candidate by the columns it uses, so a swapped
        // mapping cannot pass. Finding by kind alone would not discriminate.
        let by_id = id
            .candidates
            .iter()
            .find(|c| c.key_columns == ["id"])
            .expect("no candidate on id");
        assert_eq!(by_id.kind, "pk", "the primary key must be `pk`");
        let by_email = id
            .candidates
            .iter()
            .find(|c| c.key_columns == ["email"])
            .expect("no candidate on email");
        assert_eq!(by_email.kind, "unique", "a non-primary key must be `unique`");
        // Strongest first.
        assert_eq!(id.candidates[0].kind, "pk");
    }

    /// key_columns must hold the RESULT's column names, and keys must hold one
    /// entry per row in row order.
    #[test]
    fn builds_one_key_per_row_from_the_named_columns() {
        let rows = vec![
            row(&[s("1"), s("a@b.co"), s("Ann"), s("active")]),
            row(&[s("2"), s("c@d.co"), s("Bob"), s("active")]),
            row(&[s("3"), s("e@f.co"), s("Cal"), s("closed")]),
        ];
        let id =
            assemble_row_identity(&users_columns(), &rows, USERS, &[USERS], Some(&users_info()));
        let pk = keyset(&id, "pk");
        assert_eq!(pk.key_columns, vec!["id"]);
        assert_eq!(pk.keys, vec!["V1:1", "V1:2", "V1:3"]);
        let uq = keyset(&id, "unique");
        assert_eq!(uq.key_columns, vec!["email"]);
        assert_eq!(uq.keys, vec!["V6:a@b.co", "V6:c@d.co", "V6:e@f.co"]);
    }

    /// A compound key must read its columns in KEY order, not in result order.
    /// The result below puts team_id first, so a key built in result order would
    /// silently swap the two halves and never match a stored tag.
    #[test]
    fn a_compound_key_keeps_key_order_not_result_order() {
        let columns = vec![col("team_id", Some(10), Some(2)), col("user_id", Some(10), Some(1))];
        let info = TableKeyInfo {
            display: "tagtest.memberships".to_string(),
            candidates: vec![KeyCandidate {
                column_attnums: vec![1, 2],
                is_primary: true,
                all_not_null: true,
            }],
        };
        let rows = vec![row(&[s("10"), s("1")])];
        let id = assemble_row_identity(&columns, &rows, 10, &[10], Some(&info));
        let pk = keyset(&id, "pk");
        assert_eq!(pk.key_columns, vec!["user_id", "team_id"]);
        assert_eq!(pk.keys, vec!["V1:1V2:10"]);
    }

    /// The NULL sentinel. An outer join leaves the key columns NULL, and such a
    /// row must get an EMPTY key. It must not get a key built from "NULL", which
    /// every unmatched row would share, so one tag would appear on all of them.
    #[test]
    fn a_null_key_value_gives_that_row_an_empty_key() {
        let rows = vec![
            row(&[s("1"), s("a@b.co"), s("Ann"), s("active")]),
            row(&[
                serde_json::Value::Null,
                serde_json::Value::Null,
                s("Cal"),
                serde_json::Value::Null,
            ]),
        ];
        let id =
            assemble_row_identity(&users_columns(), &rows, USERS, &[USERS], Some(&users_info()));
        let pk = keyset(&id, "pk");
        assert_eq!(pk.keys, vec!["V1:1", ""], "the unmatched row must have an empty key");
    }

    /// table_keys carries every source table, in the order the OIDs arrive, so
    /// the fingerprint tier can test the table overlap with no candidate.
    #[test]
    fn table_keys_lists_every_source_table() {
        let columns = vec![col("name", Some(USERS), Some(3)), col("role", Some(610009), Some(3))];
        let id = assemble_row_identity(&columns, &[], USERS, &[USERS, 610009], None);
        assert_eq!(id.table_keys, vec!["oid:609999", "oid:610009"]);
        // table_key names the primary table only, and is one of table_keys.
        assert_eq!(id.table_key, "oid:609999");
    }

    /// A candidate whose columns are not all in the result must not appear. Here
    /// the primary key column is absent, so only the natural key survives — the
    /// case the whole feature exists for.
    #[test]
    fn an_incomplete_candidate_is_dropped() {
        let columns = vec![col("name", Some(USERS), Some(3)), col("email", Some(USERS), Some(2))];
        let rows = vec![row(&[s("Ann"), s("a@b.co")])];
        let id = assemble_row_identity(&columns, &rows, USERS, &[USERS], Some(&users_info()));
        assert_eq!(id.candidates.len(), 1, "got {:?}", id.candidates);
        let uq = keyset(&id, "unique");
        assert_eq!(uq.key_columns, vec!["email"]);
        assert_eq!(uq.keys, vec!["V6:a@b.co"]);
    }

    /// A column belonging to another table must not satisfy the primary table's
    /// key. Without the OID test, `email` below would answer for attnum 2 and
    /// build a key from a different table's value.
    #[test]
    fn a_column_from_another_table_cannot_satisfy_the_key() {
        let columns = vec![
            col("name", Some(USERS), Some(3)),
            // attnum 2 of a DIFFERENT table.
            col("email", Some(999), Some(2)),
        ];
        let rows = vec![row(&[s("Ann"), s("wrong@table.co")])];
        let id = assemble_row_identity(&columns, &rows, USERS, &[USERS, 999], Some(&users_info()));
        assert!(id.candidates.is_empty(), "got {:?}", id.candidates);
    }

    /// `SELECT id, id FROM users` repeats one column. The key must come from the
    /// FIRST position, deterministically: the two columns hold the same value
    /// today, but a stable choice is what keeps a key reproducible.
    #[test]
    fn a_repeated_column_builds_the_key_from_its_first_position() {
        let columns = vec![
            col("id", Some(USERS), Some(1)),
            col("id_again", Some(USERS), Some(1)),
            col("email", Some(USERS), Some(2)),
        ];
        let rows = vec![row(&[s("1"), s("1"), s("a@b.co")])];
        let id = assemble_row_identity(&columns, &rows, USERS, &[USERS], Some(&users_info()));
        assert_eq!(keyset(&id, "pk").key_columns, vec!["id"]);
    }

    /// A result with no rows still reports its table and its candidates, with an
    /// empty key list in each. Nothing may panic on the empty row set.
    #[test]
    fn no_rows_gives_candidates_with_no_keys() {
        let id =
            assemble_row_identity(&users_columns(), &[], USERS, &[USERS], Some(&users_info()));
        assert_eq!(id.candidates.len(), 2);
        assert!(keyset(&id, "pk").keys.is_empty());
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::models::KeyCandidate;

    fn pk(cols: &[i16]) -> KeyCandidate {
        KeyCandidate { column_attnums: cols.to_vec(), is_primary: true, all_not_null: true }
    }
    fn uniq(cols: &[i16], all_not_null: bool) -> KeyCandidate {
        KeyCandidate { column_attnums: cols.to_vec(), is_primary: false, all_not_null }
    }

    // --- encode_field / encode_key ---

    #[test]
    fn encodes_null_as_n() {
        assert_eq!(encode_field(None), "N");
    }

    #[test]
    fn encodes_value_with_byte_length() {
        assert_eq!(encode_field(Some("42")), "V2:42");
    }

    #[test]
    fn length_prefix_counts_bytes_not_characters() {
        // "é" is two bytes in UTF-8.
        assert_eq!(encode_field(Some("é")), "V2:é");
    }

    #[test]
    fn separator_inside_a_value_cannot_forge_a_key() {
        // Two different rows whose values differ only by where a separator
        // falls must encode differently.
        let a = encode_key(&[Some("a:b".to_string()), Some("c".to_string())]);
        let b = encode_key(&[Some("a".to_string()), Some("b:c".to_string())]);
        // Pin the exact output. assert_ne! alone is satisfied by almost any
        // encoding, including a broken one.
        assert_eq!(a, "V3:a:bV1:c");
        assert_eq!(b, "V1:aV3:b:c");
        assert_ne!(a, b);
    }

    #[test]
    fn encode_key_joins_fields_in_order() {
        let k = encode_key(&[Some("7".to_string()), None, Some("x".to_string())]);
        assert_eq!(k, "V1:7NV1:x");
    }

    // --- choose_candidates ---

    #[test]
    fn picks_the_primary_key_when_every_column_is_present() {
        let cands = vec![pk(&[1]), uniq(&[3], true)];
        let chosen = choose_candidates(&cands, &[1, 2, 3]);
        assert_eq!(chosen.len(), 2);
        assert!(chosen[0].is_primary, "the primary key must come first");
    }

    #[test]
    fn skips_the_primary_key_when_a_column_is_missing() {
        let cands = vec![pk(&[1, 2]), uniq(&[3], true)];
        let chosen = choose_candidates(&cands, &[2, 3]);
        assert_eq!(chosen.len(), 1);
        assert!(!chosen[0].is_primary);
    }

    #[test]
    fn caps_the_set_at_two() {
        let cands = vec![pk(&[1]), uniq(&[2], true), uniq(&[3], true)];
        let chosen = choose_candidates(&cands, &[1, 2, 3]);
        assert_eq!(chosen.len(), 2);
        // Say WHICH two: the primary key must survive the cap, and the second
        // slot must hold the first satisfied unique index.
        assert!(chosen[0].is_primary);
        assert_eq!(chosen[1].column_attnums, vec![2]);
    }

    #[test]
    fn picks_the_narrowest_unique_index() {
        let cands = vec![uniq(&[2, 3], true), uniq(&[4], true)];
        let chosen = choose_candidates(&cands, &[2, 3, 4]);
        assert_eq!(chosen.len(), 1);
        assert_eq!(chosen[0].column_attnums, vec![4]);
    }

    /// The catalogue query has no guaranteed row order, and `min_by_key` keeps
    /// the first of several equal minima. Two unique indexes of the same width
    /// must therefore not depend on the order they arrive in: the chosen index
    /// decides the key a tag is stored under, so a swap between runs would make
    /// a tag stop matching its own row, with nothing to report.
    #[test]
    fn a_width_tie_resolves_the_same_way_whatever_the_row_order() {
        let a = vec![uniq(&[2], true), uniq(&[5], true)];
        let b = vec![uniq(&[5], true), uniq(&[2], true)];
        let pick_a = choose_candidates(&a, &[2, 5]);
        let pick_b = choose_candidates(&b, &[2, 5]);
        assert_eq!(pick_a.len(), 1);
        assert_eq!(pick_a[0].column_attnums, pick_b[0].column_attnums);
        // And it is the lower attnum, not merely "whichever came first".
        assert_eq!(pick_a[0].column_attnums, vec![2]);
    }

    /// The same rule for a compound tie: equal width, so the attnums decide.
    #[test]
    fn a_compound_width_tie_also_resolves_by_attnums() {
        let a = vec![uniq(&[3, 4], true), uniq(&[1, 9], true)];
        let b = vec![uniq(&[1, 9], true), uniq(&[3, 4], true)];
        assert_eq!(choose_candidates(&a, &[1, 3, 4, 9])[0].column_attnums, vec![1, 9]);
        assert_eq!(choose_candidates(&b, &[1, 3, 4, 9])[0].column_attnums, vec![1, 9]);
    }

    #[test]
    fn rejects_a_nullable_unique_index() {
        let cands = vec![uniq(&[2], false)];
        let chosen = choose_candidates(&cands, &[2]);
        assert!(chosen.is_empty());
    }

    #[test]
    fn returns_nothing_when_no_candidate_is_complete() {
        let cands = vec![pk(&[1]), uniq(&[9], true)];
        let chosen = choose_candidates(&cands, &[2, 3]);
        assert!(chosen.is_empty());
    }

    // --- primary_table_oid ---

    #[test]
    fn primary_table_is_the_one_with_the_most_columns() {
        let oids = vec![Some(10), Some(20), Some(20), None];
        assert_eq!(primary_table_oid(&oids), Some(20));
    }

    #[test]
    fn a_tie_goes_to_the_leftmost_table() {
        // Put the HIGHER oid on the left. With 30 before 40, "leftmost wins"
        // and "lowest oid wins" give the same answer, so that ordering cannot
        // tell the two rules apart. Only leftmost gives 40 here.
        assert_eq!(primary_table_oid(&[Some(40), Some(30)]), Some(40));
        assert_eq!(primary_table_oid(&[Some(30), Some(40)]), Some(30));
    }

    #[test]
    fn no_source_table_means_no_primary_table() {
        assert_eq!(primary_table_oid(&[None, None]), None);
    }

    // --- row_key ---

    #[test]
    fn row_key_reads_the_named_column_positions() {
        let row = vec![
            serde_json::Value::String("42".into()),
            serde_json::Value::String("a@b.co".into()),
        ];
        assert_eq!(row_key(&row, &[0]), "V2:42");
        assert_eq!(row_key(&row, &[0, 1]), "V2:42V6:a@b.co");
    }

    #[test]
    fn a_null_key_value_yields_an_empty_key() {
        let row = vec![serde_json::Value::Null];
        assert_eq!(row_key(&row, &[0]), "");
    }

    #[test]
    fn a_missing_column_index_yields_an_empty_key() {
        let row = vec![serde_json::Value::String("42".into())];
        assert_eq!(row_key(&row, &[5]), "");
    }

    /// Every value crosses the FFI as PostgreSQL text, so a number or a bool
    /// here means that assumption broke. Refuse to build a key rather than
    /// guess at its text form: a guess would produce a key that no later query
    /// can reproduce.
    #[test]
    fn a_non_string_value_yields_an_empty_key() {
        let row = vec![serde_json::json!(42), serde_json::json!(true)];
        assert_eq!(row_key(&row, &[0]), "");
        assert_eq!(row_key(&row, &[1]), "");
    }
}
