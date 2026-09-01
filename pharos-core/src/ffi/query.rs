use std::os::raw::c_char;

use super::*;

// ---------------------------------------------------------------------------
// Query execution
// ---------------------------------------------------------------------------

/// Format SQL with PostgreSQL conventions. Returns formatted SQL. Caller must free.
#[no_mangle]
pub extern "C" fn pharos_format_sql(sql: *const c_char) -> *mut c_char {
    ffi_sync!({
        let sql_str = match unsafe { c_str_to_option(sql) } {
            Some(s) => s,
            None => return to_c_string(""),
        };
        let options = sqlformat::FormatOptions {
            indent: sqlformat::Indent::Spaces(2),
            uppercase: Some(true),
            lines_between_queries: 2,
            ..Default::default()
        };
        let (masked, tokens, prefix) = mask_variable_tokens(&sql_str);
        let formatted = sqlformat::format(&masked, &sqlformat::QueryParams::None, &options);
        to_c_string(&restore_variable_tokens(&formatted, &tokens, &prefix))
    })
}

// ---------------------------------------------------------------------------
// Query variable tokens vs. the formatter
// ---------------------------------------------------------------------------

/// `sqlformat` knows nothing of Pharos's `{{name}}` variable tokens. It lexes
/// each brace as its own punctuation character and pushes them apart, so
/// `{{example}}` comes back as `{ { example } }` — a form the token regex no
/// longer matches, so the text reaches Postgres verbatim and the server
/// answers `syntax error at or near "{"`.
///
/// The cure is to hide every token behind one identifier-shaped word for the
/// length of the format pass, then put the original text back. The word is a
/// single lexical token, so the formatter carries it through whole and places
/// it exactly where the variable belongs.
///
/// The scan is deliberately wider than `VariableSubstitutor`'s regex: it takes
/// any `{{...}}` pair whose contents hold no brace and no newline, including
/// names that regex rejects. A run that is not a real variable is restored
/// byte for byte, so masking it costs nothing, while leaving it unmasked would
/// mangle text the user typed on purpose.
fn mask_variable_tokens(sql: &str) -> (String, Vec<String>, String) {
    let prefix = unique_placeholder_prefix(sql);
    let mut masked = String::with_capacity(sql.len());
    let mut tokens: Vec<String> = Vec::new();
    let bytes = sql.as_bytes();
    let mut i = 0;

    while i < sql.len() {
        if bytes[i] == b'{' && i + 1 < sql.len() && bytes[i + 1] == b'{' {
            if let Some(end) = token_end(sql, i + 2) {
                masked.push_str(&format!("{}{}q", prefix, tokens.len()));
                tokens.push(sql[i..end].to_string());
                i = end;
                continue;
            }
        }
        // Not a token start: copy this whole character, not this byte, so a
        // multi-byte one stays intact.
        let ch = sql[i..].chars().next().unwrap();
        masked.push(ch);
        i += ch.len_utf8();
    }

    (masked, tokens, prefix)
}

/// End index (exclusive, past the `}}`) of the token whose contents start at
/// `from`, or `None` when the run holds a brace or a newline before it closes.
fn token_end(sql: &str, from: usize) -> Option<usize> {
    let bytes = sql.as_bytes();
    let mut i = from;
    while i < sql.len() {
        match bytes[i] {
            b'}' if i + 1 < sql.len() && bytes[i + 1] == b'}' => return Some(i + 2),
            b'{' | b'}' | b'\n' | b'\r' => return None,
            _ => i += 1,
        }
    }
    None
}

/// A placeholder stem no substring of `sql` already carries, so restoring can
/// never overwrite text the user wrote. Grows by one `z` per collision.
fn unique_placeholder_prefix(sql: &str) -> String {
    let mut prefix = String::from("pharosvartoken");
    while sql.contains(&prefix) {
        prefix.push('z');
    }
    prefix
}

/// Put the original token text back where the placeholders sit.
///
/// The match is case-insensitive: `uppercase: Some(true)` only touches words
/// the formatter holds as reserved, but a future keyword list is not worth a
/// silently broken token, and no real identifier can collide with the stem.
/// Each placeholder ends in `q`, so `...0q` cannot be read out of `...10q`.
fn restore_variable_tokens(sql: &str, tokens: &[String], prefix: &str) -> String {
    let mut out = sql.to_string();
    for (index, original) in tokens.iter().enumerate() {
        let placeholder = format!("{}{}q", prefix, index);
        out = replace_ignore_ascii_case(&out, &placeholder, original);
    }
    out
}

fn replace_ignore_ascii_case(haystack: &str, needle: &str, replacement: &str) -> String {
    let lower_haystack = haystack.to_ascii_lowercase();
    let lower_needle = needle.to_ascii_lowercase();
    let mut out = String::with_capacity(haystack.len());
    let mut cursor = 0;
    while let Some(hit) = lower_haystack[cursor..].find(&lower_needle) {
        let start = cursor + hit;
        out.push_str(&haystack[cursor..start]);
        out.push_str(replacement);
        cursor = start + needle.len();
    }
    out.push_str(&haystack[cursor..]);
    out
}

/// Execute a SQL query. Returns JSON QueryResult via callback.
#[no_mangle]
pub extern "C" fn pharos_execute_query(
    connection_id: *const c_char,
    sql: *const c_char,
    query_id: *const c_char,
    limit: i32,
    schema: *const c_char,
    source: *const c_char,
    callback: AsyncCallback,
    context: *mut std::ffi::c_void,
) {
    let state = app_state();
    let conn_id = unsafe { c_str_to_string(connection_id) };
    let sql_str = unsafe { c_str_to_string(sql) };
    let qid = unsafe { c_str_to_option(query_id) };
    let schema_str = unsafe { c_str_to_option(schema) };
    let source_str = unsafe { c_str_to_option(source) };
    let lim = if limit > 0 { Some(limit as u32) } else { None };

    let ctx = context as usize;
    ffi_spawn!(callback, context, async move {

        match crate::commands::execute_query(conn_id, sql_str, qid, lim, schema_str, source_str, state).await {
            Ok(result) => {
                let json = serde_json::to_string(&result).unwrap_or_default();
                callback_ok(callback, ctx, &json);
            }
            Err(e) => callback_err(callback, ctx, &e),
        }
    });
}

/// Execute a statement (INSERT/UPDATE/DELETE). Returns JSON ExecuteResult via callback.
#[no_mangle]
pub extern "C" fn pharos_execute_statement(
    connection_id: *const c_char,
    sql: *const c_char,
    schema: *const c_char,
    callback: AsyncCallback,
    context: *mut std::ffi::c_void,
) {
    let state = app_state();
    let conn_id = unsafe { c_str_to_string(connection_id) };
    let sql_str = unsafe { c_str_to_string(sql) };
    let schema_str = unsafe { c_str_to_option(schema) };

    let ctx = context as usize;
    ffi_spawn!(callback, context, async move {

        match crate::commands::execute_statement(conn_id, sql_str, schema_str, state).await {
            Ok(result) => {
                let json = serde_json::to_string(&result).unwrap_or_default();
                callback_ok(callback, ctx, &json);
            }
            Err(e) => callback_err(callback, ctx, &e),
        }
    });
}

/// Fetch more rows. Returns JSON QueryResult via callback.
#[no_mangle]
pub extern "C" fn pharos_fetch_more_rows(
    connection_id: *const c_char,
    sql: *const c_char,
    limit: i64,
    offset: i64,
    schema: *const c_char,
    callback: AsyncCallback,
    context: *mut std::ffi::c_void,
) {
    let state = app_state();
    let conn_id = unsafe { c_str_to_string(connection_id) };
    let sql_str = unsafe { c_str_to_string(sql) };
    let schema_str = unsafe { c_str_to_option(schema) };

    let ctx = context as usize;
    ffi_spawn!(callback, context, async move {

        match crate::commands::fetch_more_rows(conn_id, sql_str, limit, offset, schema_str, state).await {
            Ok(result) => {
                let json = serde_json::to_string(&result).unwrap_or_default();
                callback_ok(callback, ctx, &json);
            }
            Err(e) => callback_err(callback, ctx, &e),
        }
    });
}

/// Cancel a running query. Returns immediately (synchronous).
#[no_mangle]
pub extern "C" fn pharos_cancel_query(
    connection_id: *const c_char,
    query_id: *const c_char,
    callback: AsyncCallback,
    context: *mut std::ffi::c_void,
) {
    let state = app_state();
    let conn_id = unsafe { c_str_to_string(connection_id) };
    let qid = unsafe { c_str_to_string(query_id) };

    let ctx = context as usize;
    ffi_spawn!(callback, context, async move {

        match crate::commands::cancel_query(conn_id, qid, state).await {
            Ok(cancelled) => callback_ok(callback, ctx, if cancelled { "true" } else { "false" }),
            Err(e) => callback_err(callback, ctx, &e),
        }
    });
}

/// Validate SQL syntax. Returns JSON ValidationResult via callback.
#[no_mangle]
pub extern "C" fn pharos_validate_sql(
    connection_id: *const c_char,
    sql: *const c_char,
    schema: *const c_char,
    callback: AsyncCallback,
    context: *mut std::ffi::c_void,
) {
    let state = app_state();
    let conn_id = unsafe { c_str_to_string(connection_id) };
    let sql_str = unsafe { c_str_to_string(sql) };
    let schema_str = unsafe { c_str_to_option(schema) };

    let ctx = context as usize;
    ffi_spawn!(callback, context, async move {

        match crate::commands::validate_sql(conn_id, sql_str, schema_str, state).await {
            Ok(result) => {
                let json = serde_json::to_string(&result).unwrap_or_default();
                callback_ok(callback, ctx, &json);
            }
            Err(e) => callback_err(callback, ctx, &e),
        }
    });
}

#[cfg(test)]
mod variable_token_tests {
    use super::*;

    /// The same options `pharos_format_sql` uses, so a test failure means the
    /// button is broken and not that the test drifted.
    fn format(sql: &str) -> String {
        let options = sqlformat::FormatOptions {
            indent: sqlformat::Indent::Spaces(2),
            uppercase: Some(true),
            lines_between_queries: 2,
            ..Default::default()
        };
        let (masked, tokens, prefix) = mask_variable_tokens(sql);
        let formatted = sqlformat::format(&masked, &sqlformat::QueryParams::None, &options);
        restore_variable_tokens(&formatted, &tokens, &prefix)
    }

    #[test]
    fn token_survives_the_format_pass() {
        let out = format("select * from t where id = {{example_variable}}");
        assert!(out.contains("{{example_variable}}"), "got: {out}");
        assert!(!out.contains("{ {"), "got: {out}");
    }

    #[test]
    fn inner_whitespace_is_kept_byte_for_byte() {
        let out = format("select * from t where id = {{ spaced }}");
        assert!(out.contains("{{ spaced }}"), "got: {out}");
    }

    #[test]
    fn several_tokens_keep_their_own_names() {
        let out = format("select * from t where a = {{one}} and b = {{two}} and c = {{one}}");
        assert_eq!(out.matches("{{one}}").count(), 2, "got: {out}");
        assert_eq!(out.matches("{{two}}").count(), 1, "got: {out}");
    }

    /// Ten or more tokens: `...0q` must not be read out of `...10q`.
    #[test]
    fn a_two_digit_index_does_not_swallow_a_one_digit_one() {
        let names: Vec<String> = (0..12).map(|i| format!("{{{{v{i}}}}}")).collect();
        let sql = format!("select {} from t", names.join(", "));
        let out = format(&sql);
        for (i, name) in names.iter().enumerate() {
            assert!(out.contains(name), "token {i} lost, got: {out}");
        }
    }

    /// A leading digit is legal in a Pharos token name, and the formatter must
    /// not treat the placeholder as a number.
    #[test]
    fn a_name_starting_with_a_digit_survives() {
        let out = format("select * from t where n = {{185_domains}}");
        assert!(out.contains("{{185_domains}}"), "got: {out}");
    }

    #[test]
    fn a_token_inside_a_string_literal_is_left_as_typed() {
        let out = format("select * from t where s = '{{name}}'");
        assert!(out.contains("'{{name}}'"), "got: {out}");
    }

    #[test]
    fn an_unclosed_brace_run_is_not_masked() {
        let (masked, tokens, _) = mask_variable_tokens("select {{ from t");
        assert!(tokens.is_empty());
        assert_eq!(masked, "select {{ from t");
    }

    #[test]
    fn sql_already_holding_the_stem_gets_a_longer_one() {
        let sql = "select pharosvartoken0q, {{v}} from t";
        let (masked, tokens, prefix) = mask_variable_tokens(sql);
        assert_ne!(prefix, "pharosvartoken");
        assert_eq!(restore_variable_tokens(&masked, &tokens, &prefix), sql);
    }

    #[test]
    fn sql_without_tokens_is_untouched_by_the_mask() {
        let sql = "select 1";
        let (masked, tokens, _) = mask_variable_tokens(sql);
        assert_eq!(masked, sql);
        assert!(tokens.is_empty());
    }

    #[test]
    fn multibyte_text_is_not_split() {
        let sql = "select '日本語' from t where id = {{v}}";
        let (masked, tokens, prefix) = mask_variable_tokens(sql);
        assert_eq!(restore_variable_tokens(&masked, &tokens, &prefix), sql);
    }
}
