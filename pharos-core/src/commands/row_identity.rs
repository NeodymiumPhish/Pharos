use std::collections::HashMap;

use crate::models::KeyCandidate;

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

    let narrowest_unique = candidates
        .iter()
        .filter(|c| !c.is_primary && c.all_not_null && complete(c))
        .min_by_key(|c| c.column_attnums.len());
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
