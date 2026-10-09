use std::os::raw::c_char;

use serde::{Deserialize, Serialize};

use super::*;
use crate::commands::cards::{extract_leading_notes, serialize_cards, split_cards, CardToWrite, SerializeMode, SplitCard};

#[derive(Serialize)]
struct SplitResponse {
    cards: Vec<SplitCard>,
}

#[derive(Deserialize)]
struct SerializeRequest {
    cards: Vec<CardToWrite>,
    mode: SerializeMode,
}

#[derive(Serialize)]
struct SerializeResponse {
    text: String,
}

/// Split SQL text into query cards. Returns `{"cards":[…]}` (camelCase card
/// fields). A null pointer is empty text.
#[no_mangle]
pub extern "C" fn pharos_cards_split(text: *const c_char) -> *mut c_char {
    ffi_sync!({
        let text = unsafe { c_str_to_option(text) }.unwrap_or_default();
        to_json_c_string(&SplitResponse { cards: split_cards(&text) })
    })
}

/// Write query cards as SQL text. Takes `{"cards":[…],"mode":"all"|"latest"}`
/// and returns `{"text":"…"}`, or `{"error":"…"}` when the request does not
/// parse.
#[no_mangle]
pub extern "C" fn pharos_cards_serialize(request_json: *const c_char) -> *mut c_char {
    ffi_sync!({
        let json = unsafe { c_str_to_option(request_json) }.unwrap_or_default();
        match serde_json::from_str::<SerializeRequest>(&json) {
            Ok(request) => to_json_c_string(&SerializeResponse { text: serialize_cards(&request.cards, request.mode) }),
            Err(e) => to_json_c_string(&serde_json::json!({ "error": format!("Invalid cards: {}", e) })),
        }
    })
}

#[derive(Serialize)]
struct ExtractNotesResponse {
    /// None when the SQL has no comments to take.
    notes: Option<String>,
    /// The SQL without them; the input when `notes` is None.
    sql: String,
}

/// Take the comments before a card's statement as notes. Returns
/// `{"notes":"…","sql":"…"}`, or `{"notes":null,"sql":<input>}` when no
/// comment comes before a statement. A null pointer is empty text.
#[no_mangle]
pub extern "C" fn pharos_cards_extract_notes(sql: *const c_char) -> *mut c_char {
    ffi_sync!({
        let sql = unsafe { c_str_to_option(sql) }.unwrap_or_default();
        let response = match extract_leading_notes(&sql) {
            Some((notes, rest)) => ExtractNotesResponse { notes: Some(notes), sql: rest },
            None => ExtractNotesResponse { notes: None, sql },
        };
        to_json_c_string(&response)
    })
}

#[cfg(test)]
mod tests {
    use super::*;
    use std::ffi::{CStr, CString};

    fn call(f: extern "C" fn(*const c_char) -> *mut c_char, input: &str) -> serde_json::Value {
        let input = CString::new(input).unwrap();
        let out = f(input.as_ptr());
        let text = unsafe { CStr::from_ptr(out) }.to_str().unwrap().to_string();
        crate::ffi::lifecycle::pharos_free_string(out);
        serde_json::from_str(&text).unwrap()
    }

    #[test]
    fn split_answers_camel_case_cards() {
        let v = call(pharos_cards_split, "-- name: A\nSELECT 1;\n\\set x 1");
        let cards = v["cards"].as_array().unwrap();
        assert_eq!(cards.len(), 2);
        assert_eq!(cards[0]["name"], "A");
        assert_eq!(cards[0]["sql"], "SELECT 1");
        assert_eq!(cards[0]["kind"], "sql");
        assert_eq!(cards[0]["startLine"], 2);
        assert_eq!(cards[1]["kind"], "psqlMeta");
    }

    #[test]
    fn serialize_takes_the_swift_shape() {
        let v = call(
            pharos_cards_serialize,
            r#"{"mode":"all","cards":[{"name":"A","version":1,"locked":true,"sql":"SELECT 1","kind":"sql","lineageId":"q"},
                                      {"name":"A","version":2,"sql":"SELECT 2","lineageId":"q"}]}"#,
        );
        assert_eq!(v["text"], "-- name: A\n-- version: 1 locked\n-- SELECT 1\n\n-- name: A\n-- version: 2\nSELECT 2;\n");
        let notes = call(
            pharos_cards_serialize,
            r#"{"mode":"latest","cards":[{"name":null,"version":1,"sql":"SELECT 1","lineageId":"q","notes":"n"}]}"#,
        );
        assert!(notes["text"].as_str().unwrap().contains("\nn\n"));
        let bad = call(pharos_cards_serialize, "{not json");
        assert!(bad["error"].as_str().unwrap().starts_with("Invalid cards"));
    }

    #[test]
    fn extract_notes_answers_notes_and_sql() {
        let v = call(pharos_cards_extract_notes, "-- why\nSELECT 1");
        assert_eq!(v["notes"], "why");
        assert_eq!(v["sql"], "SELECT 1");
        let none = call(pharos_cards_extract_notes, "SELECT 1");
        assert!(none["notes"].is_null());
        assert_eq!(none["sql"], "SELECT 1");
    }

    #[test]
    fn split_answers_notes() {
        let v = call(pharos_cards_split, "/*\n===\nn\n===\n*/\nSELECT 1;");
        assert_eq!(v["cards"][0]["notes"], "n");
        assert_eq!(v["cards"][0]["sql"], "SELECT 1");
    }
}
