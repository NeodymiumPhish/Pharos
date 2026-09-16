use serde::{Deserialize, Serialize};

/// One app-wide query variable: a `{{name}}` token and the value it stands for.
///
/// Variables are GLOBAL, exactly like tags: one list for every window, tab and
/// connection, persisted in the metadata store so the values survive a
/// relaunch. There is no connection key and no per-tab copy.
///
/// The JSON keys are `id`, `name`, `value` and `type` — the Swift
/// `QueryVariable.CodingKeys` verbatim, because `JSONDecoder.pharos` applies no
/// key strategy. `kind` is renamed to `type` only in the JSON; `type` is a
/// keyword in Rust.
///
/// `kind` is an opaque STRING here, never an enum: Swift is the only producer
/// and its decoder maps an unknown type to `literal` rather than failing.
/// An enum on this side would reject a type written by a newer build and drop
/// the whole list on load.
///
/// `id` is Swift's `UUID` as its string form; Rust never parses it.
#[derive(Debug, Clone, Serialize, Deserialize, PartialEq, Eq)]
pub struct QueryVariable {
    pub id: String,
    pub name: String,
    #[serde(default)]
    pub value: String,
    #[serde(rename = "type", default = "default_kind")]
    pub kind: String,
}

fn default_kind() -> String {
    "literal".to_string()
}
