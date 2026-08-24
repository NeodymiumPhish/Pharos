use serde::{Deserialize, Serialize};

/// One condition of a rule. `column` is PROVENANCE — the matcher never reads
/// it. `value` is the normalized form Swift produced; `display` is the text as
/// it was captured, for the Inspector.
///
/// `kind` and `operand2` are plain optional STRINGS here, never an enum. Rust
/// does not interpret them — Swift is the only producer, exactly as it already
/// is for `tuple_key`.
///
/// An enum would reject a kind written by a newer build, and `read_tag_tuples`
/// decodes the blob with `unwrap_or_default()`, so one rejected variant loads
/// the rule with an EMPTY condition list that the next save writes back. That
/// destroys the rule silently, with no error anywhere.
///
/// `#[serde(default)]` covers an ABSENT key, which is what an old stored blob
/// has. It does nothing about an unknown VALUE; keeping the type as `String` is
/// what covers that.
#[derive(Debug, Clone, PartialEq, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct TagCondition {
    pub column: String,
    /// "address" | "text" | "numeric" | "temporal" | "uuid" | "type:<name>"
    pub family: String,
    #[serde(default)]
    pub kind: Option<String>,
    pub value: String,
    #[serde(default)]
    pub operand2: Option<String>,
    pub display: String,
}

/// One tagged origin row.
#[derive(Debug, Clone, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct TagRule {
    pub id: String,
    pub conditions: Vec<TagCondition>,
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
    pub rules: Vec<TagRule>,
}

/// A tuple as Swift sends it. The id and the timestamp are minted here.
#[derive(Debug, Clone, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct NewTagRule {
    pub conditions: Vec<TagCondition>,
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
    pub rules: Vec<NewTagRule>,
}

#[derive(Debug, Clone, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct AddTagRules {
    pub tag_id: String,
    pub rules: Vec<NewTagRule>,
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
          "rules":[{"conditions":[{"column":"md5","family":"text","value":"d41d8c",
          "display":"D41D8C"}],"tupleKey":"K4:textV6:d41d8c",
          "originConnection":"c1","originTable":"public.certs"}]}"#;
        let create: CreateTag = serde_json::from_str(json).unwrap();
        assert_eq!(create.color_index, 2);
        assert_eq!(create.note.as_deref(), Some("may sprint"));
        assert_eq!(create.rules[0].tuple_key, "K4:textV6:d41d8c");
        assert_eq!(create.rules[0].origin_table, "public.certs");
        assert_eq!(create.rules[0].conditions[0].display, "D41D8C");
    }

    #[test]
    fn add_and_update_payloads_decode_swift_camel_case() {
        let add: AddTagRules = serde_json::from_str(
            r#"{"tagId":"t1","rules":[{"conditions":[],"tupleKey":"k","originConnection":"c",
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

    /// A SPARSE document pins the defaults and nothing more. A FULL literal
    /// document is what pins the key names — serde reports a mis-cased optional
    /// as `None`, indistinguishable from the caller omitting it.
    #[test]
    fn condition_decodes_sparse_and_full_documents() {
        let sparse: TagCondition = serde_json::from_str(
            r#"{"column":"host","family":"text","value":"abc","display":"ABC"}"#,
        )
        .unwrap();
        assert_eq!(sparse.kind, None);
        assert_eq!(sparse.operand2, None);

        let full: TagCondition = serde_json::from_str(
            r#"{"column":"port","family":"numeric","kind":"between","value":"1000",
                "operand2":"2000","display":"1000 .. 2000"}"#,
        )
        .unwrap();
        assert_eq!(full.kind.as_deref(), Some("between"));
        assert_eq!(full.operand2.as_deref(), Some("2000"));
        assert_eq!(full.family, "numeric");
        assert_eq!(full.display, "1000 .. 2000");
    }

    /// An unknown kind must round-trip verbatim. This is the test that protects
    /// a rule written by a newer build from being destroyed by an older one.
    #[test]
    fn unknown_kind_round_trips_verbatim() {
        let decoded: TagCondition = serde_json::from_str(
            r#"{"column":"h","family":"text","kind":"startsWith","value":"a","display":"a"}"#,
        )
        .unwrap();
        assert_eq!(decoded.kind.as_deref(), Some("startsWith"));
        let json = serde_json::to_string(&decoded).unwrap();
        assert!(json.contains(r#""kind":"startsWith""#), "got {}", json);
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
            rules: vec![TagRule {
                id: "u1".into(),
                conditions: vec![TagCondition {
                    column: "md5".into(),
                    family: "text".into(),
                    kind: None,
                    value: "d41d8c".into(),
                    operand2: None,
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
