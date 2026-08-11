use serde::{Deserialize, Serialize};

/// A re-usable label. The palette is global: a label holds no connection id.
#[derive(Debug, Clone, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct TagLabel {
    pub id: String,
    pub name: String,
    /// Index into a fixed colour palette, not a hex string.
    pub color_index: i64,
    pub sort_order: i64,
    pub created_at: String,
}

#[derive(Debug, Clone, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct CreateTagLabel {
    pub name: String,
    pub color_index: i64,
}

#[derive(Debug, Clone, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct UpdateTagLabel {
    pub id: String,
    pub name: Option<String>,
    pub color_index: Option<i64>,
    pub sort_order: Option<i64>,
}

/// One candidate key of a tagged row. A strong tag holds one or two of these.
/// A fingerprint tag holds exactly one.
#[derive(Debug, Clone, PartialEq, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct RowTagKey {
    /// "pk" | "unique" | "fingerprint"
    pub identity_kind: String,
    /// The canonical compare string. See `commands::row_identity::encode_key`.
    pub identity_value: String,
}

#[derive(Debug, Clone, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct RowTag {
    pub id: String,
    pub connection_id: String,
    pub label_id: String,
    pub note: Option<String>,
    /// The strongest kind this tag holds. Display only: it drives the trust
    /// sentence in the popover.
    pub primary_kind: String,
    /// "oid:16543", or "name:public.users" when the result carried no OID.
    pub table_key: String,
    pub table_display: String,
    /// The primary candidate's columns, or every column for a fingerprint tag.
    pub identity_columns: Vec<String>,
    /// The matching values. `None` is a NULL.
    pub identity_values: Vec<Option<String>>,
    pub keys: Vec<RowTagKey>,
    pub created_at: String,
    pub updated_at: String,
}

/// Payload for a tag write. The write is key-set-aware: it replaces any tag
/// that already matches ANY key in `keys`.
#[derive(Debug, Clone, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct UpsertRowTag {
    pub connection_id: String,
    pub label_id: String,
    pub note: Option<String>,
    pub primary_kind: String,
    pub table_key: String,
    pub table_display: String,
    pub identity_columns: Vec<String>,
    pub identity_values: Vec<Option<String>>,
    pub keys: Vec<RowTagKey>,
}

/// One key index of a table, from the catalogue. Cached per connection.
#[derive(Debug, Clone, PartialEq)]
pub struct KeyCandidate {
    /// The key column `attnum`s, in index order. INCLUDE columns are excluded.
    pub columns: Vec<i16>,
    pub is_primary: bool,
    pub all_not_null: bool,
}

/// A cached catalogue entry for one table.
#[derive(Debug, Clone)]
pub struct TableKeyInfo {
    /// "public.users"
    pub display: String,
    pub candidates: Vec<KeyCandidate>,
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn tag_label_serializes_camel_case() {
        let label = TagLabel {
            id: "l1".into(),
            name: "Bad data".into(),
            color_index: 2,
            sort_order: 0,
            created_at: "2026-08-11T00:00:00Z".into(),
        };
        let json = serde_json::to_string(&label).unwrap();
        assert!(json.contains("\"colorIndex\":2"), "got {}", json);
        assert!(json.contains("\"sortOrder\":0"), "got {}", json);
    }

    #[test]
    fn row_tag_round_trips_with_keys_and_null_values() {
        let tag = RowTag {
            id: "t1".into(),
            connection_id: "c1".into(),
            label_id: "l1".into(),
            note: Some("check this".into()),
            primary_kind: "pk".into(),
            table_key: "oid:16543".into(),
            table_display: "public.users".into(),
            identity_columns: vec!["id".into()],
            identity_values: vec![Some("42".into()), None],
            keys: vec![
                RowTagKey { identity_kind: "pk".into(), identity_value: "V2:42".into() },
                RowTagKey { identity_kind: "unique".into(), identity_value: "V9:a@b.co.uk".into() },
            ],
            created_at: "2026-08-11T00:00:00Z".into(),
            updated_at: "2026-08-11T00:00:00Z".into(),
        };
        let json = serde_json::to_string(&tag).unwrap();
        assert!(json.contains("\"identityColumns\""), "got {}", json);
        assert!(json.contains("\"identityKind\":\"unique\""), "got {}", json);

        let back: RowTag = serde_json::from_str(&json).unwrap();
        assert_eq!(back.keys.len(), 2);
        assert_eq!(back.identity_values[1], None);
    }
}
