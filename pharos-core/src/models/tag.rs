use serde::{Deserialize, Serialize};

/// One captured value. `column` is PROVENANCE — the matcher never reads it.
/// `value` is the normalized form Swift produced; `display` is the text as it
/// was captured, for the Inspector.
#[derive(Debug, Clone, PartialEq, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct TaggedValue {
    pub column: String,
    /// "address" | "text" | "numeric" | "temporal" | "uuid" | "type:<name>"
    pub family: String,
    pub value: String,
    pub display: String,
}

/// One tagged origin row.
#[derive(Debug, Clone, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct TagTuple {
    pub id: String,
    pub values: Vec<TaggedValue>,
    pub tuple_key: String,
    pub origin_connection: String,
    pub origin_table: String,
    pub created_at: String,
}

/// A named indicator set.
#[derive(Debug, Clone, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct Tag {
    pub id: String,
    pub name: String,
    /// Index into a fixed palette, not a hex string.
    pub color_index: i64,
    pub note: Option<String>,
    pub created_at: String,
    pub updated_at: String,
    pub tuples: Vec<TagTuple>,
}

/// A tuple as Swift sends it. The id and the timestamp are minted here.
#[derive(Debug, Clone, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct NewTagTuple {
    pub values: Vec<TaggedValue>,
    pub tuple_key: String,
    pub origin_connection: String,
    pub origin_table: String,
}

#[derive(Debug, Clone, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct CreateTag {
    pub name: String,
    pub color_index: i64,
    pub note: Option<String>,
    pub tuples: Vec<NewTagTuple>,
}

#[derive(Debug, Clone, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct AddTagTuples {
    pub tag_id: String,
    pub tuples: Vec<NewTagTuple>,
}

/// A nil field is left as it is. A note therefore cannot be CLEARED through
/// this payload, only replaced — the Phase 5 manage sheet writes an empty
/// string for "no note".
#[derive(Debug, Clone, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct UpdateTag {
    pub id: String,
    pub name: Option<String>,
    pub color_index: Option<i64>,
    pub note: Option<String>,
}

#[cfg(test)]
mod tests {
    use super::*;

    /// Rust only DEserializes the write payloads: Swift writes them. A round
    /// trip would pass with `rename_all` removed — both sides would agree with
    /// each other and disagree with Swift — so decode a literal camelCase
    /// document, exactly as Swift sends it, with EVERY optional key present.
    #[test]
    fn create_tag_decodes_swift_camel_case() {
        let json = r#"{"name":"Suspect infra","colorIndex":2,"note":"may sprint",
          "tuples":[{"values":[{"column":"md5","family":"text","value":"d41d8c",
          "display":"D41D8C"}],"tupleKey":"K4:textV6:d41d8c",
          "originConnection":"c1","originTable":"public.certs"}]}"#;
        let create: CreateTag = serde_json::from_str(json).unwrap();
        assert_eq!(create.color_index, 2);
        assert_eq!(create.note.as_deref(), Some("may sprint"));
        assert_eq!(create.tuples[0].tuple_key, "K4:textV6:d41d8c");
        assert_eq!(create.tuples[0].origin_table, "public.certs");
        assert_eq!(create.tuples[0].values[0].display, "D41D8C");
    }

    #[test]
    fn add_and_update_payloads_decode_swift_camel_case() {
        let add: AddTagTuples = serde_json::from_str(
            r#"{"tagId":"t1","tuples":[{"values":[],"tupleKey":"k","originConnection":"c",
               "originTable":"t"}]}"#,
        )
        .unwrap();
        assert_eq!(add.tag_id, "t1");

        let full: UpdateTag =
            serde_json::from_str(r#"{"id":"t1","name":"Renamed","colorIndex":4,"note":"n"}"#)
                .unwrap();
        assert_eq!(full.name.as_deref(), Some("Renamed"));
        assert_eq!(full.color_index, Some(4));

        let sparse: UpdateTag = serde_json::from_str(r#"{"id":"t1"}"#).unwrap();
        assert_eq!(sparse.name, None);
    }

    #[test]
    fn tag_serializes_camel_case() {
        let tag = Tag {
            id: "t1".into(),
            name: "Suspect infra".into(),
            color_index: 2,
            note: None,
            created_at: "2026-08-13T00:00:00Z".into(),
            updated_at: "2026-08-13T00:00:00Z".into(),
            tuples: vec![TagTuple {
                id: "u1".into(),
                values: vec![TaggedValue {
                    column: "md5".into(),
                    family: "text".into(),
                    value: "d41d8c".into(),
                    display: "D41D8C".into(),
                }],
                tuple_key: "K4:textV6:d41d8c".into(),
                origin_connection: "c1".into(),
                origin_table: "public.certs".into(),
                created_at: "2026-08-13T00:00:00Z".into(),
            }],
        };
        let json = serde_json::to_string(&tag).unwrap();
        assert!(json.contains("\"colorIndex\":2"), "got {}", json);
        assert!(json.contains("\"tupleKey\""), "got {}", json);
        assert!(json.contains("\"originConnection\""), "got {}", json);
    }
}
