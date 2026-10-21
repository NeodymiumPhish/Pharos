//! Remove passwords and secret keys from SQL text before query history
//! stores it.
//!
//! History records what ran without asking, so it must not keep
//! `ALTER ROLE ana PASSWORD 'hunter2'`, `CREATE SECRET (TYPE s3, SECRET '…')`
//! or `ATTACH 'host=db password=…'`. Saved Sessions and the editor keep the
//! text exactly as written: those are documents the user chose to keep.
//!
//! Three rules, each replacing only the secret with `********`:
//! 1. A string literal right after the word `PASSWORD` (`CREATE/ALTER
//!    ROLE|USER … [ENCRYPTED] PASSWORD '…'`, `CREATE USER MAPPING … OPTIONS
//!    (password '…')`, a DuckDB secret's `PASSWORD '…'`).
//! 2. In `CREATE [OR REPLACE] [PERSISTENT|TEMPORARY] SECRET …`: the literal
//!    after a key that holds a secret (`SECRET`, `TOKEN`, `SESSION_TOKEN`,
//!    `ACCOUNT_KEY`, `CLIENT_SECRET`, `CONNECTION_STRING`, `URI`,
//!    `SSLPASSWORD`, `OAUTH_CLIENT_SECRET`). `KEY_ID` is an id and stays.
//! 3. Inside any string literal or dollar-quoted body: a libpq
//!    `…password=<value>` and the password of a URI `scheme://user:<pw>@`.
//! 4. DuckDB's older settings form, `SET [GLOBAL|SESSION|LOCAL]
//!    s3_secret_access_key = '…'` (and the other secret settings in
//!    `SECRET_SETTINGS`): the value literal.
//!
//! The scanner uses `sql_lexer`'s quoting rules, so text in a comment or a
//! quoted identifier is never taken for a literal, and a column named
//! `password` stays as it is.

use std::borrow::Cow;
use std::ops::Range;

use super::sql_lexer::{dollar_tag_end, is_ident_byte, skip_block_comment, skip_dollar_quoted, skip_double_quoted,
                       skip_line_comment, skip_single_quoted};

/// What a removed secret reads as.
pub const MASK: &str = "********";

/// Keys of a DuckDB `CREATE SECRET` whose value is secret (rule 2).
const SECRET_KEYS: [&str; 10] = [
    "password", "secret", "token", "session_token", "account_key", "client_secret", "connection_string", "uri",
    "sslpassword", "oauth_client_secret",
];

/// DuckDB settings whose value is a secret (rule 4).
const SECRET_SETTINGS: [&str; 5] = [
    "s3_secret_access_key", "s3_session_token", "azure_storage_connection_string", "hf_token", "gcs_secret",
];

#[derive(Debug, Clone, PartialEq)]
enum Tok {
    Word(Range<usize>),
    /// A single-quoted literal: the whole token, and its content.
    Str { content: Range<usize> },
    /// A dollar-quoted body: its content between the tags.
    Dollar { content: Range<usize> },
    Semi,
    Other,
}

fn tokens(sql: &str) -> Vec<Tok> {
    let b = sql.as_bytes();
    let n = b.len();
    let mut out = Vec::new();
    let mut i = 0;
    while i < n {
        let c = b[i];
        if c.is_ascii_whitespace() {
            i += 1;
        } else if c == b'-' && i + 1 < n && b[i + 1] == b'-' {
            i = skip_line_comment(b, i);
        } else if c == b'/' && i + 1 < n && b[i + 1] == b'*' {
            i = skip_block_comment(b, i);
        } else if c == b'\'' {
            // `E'…'`: the E was read as a word just before; it is the prefix.
            if let Some(Tok::Word(w)) = out.last() {
                if w.end == i && w.len() == 1 && (b[w.start] == b'E' || b[w.start] == b'e') {
                    out.pop();
                }
            }
            let end = skip_single_quoted(b, i);
            let closed = end <= n && end > i + 1 && b[end - 1] == b'\'';
            out.push(Tok::Str { content: (i + 1)..(if closed { end - 1 } else { end }) });
            i = end;
        } else if c == b'"' {
            i = skip_double_quoted(b, i);
            out.push(Tok::Other);
        } else if c == b'$' {
            match dollar_tag_end(b, i) {
                Some(open_end) => {
                    let end = skip_dollar_quoted(b, i, open_end);
                    let tag_len = open_end - i;
                    let content_end = if end >= open_end + tag_len { end - tag_len } else { end };
                    out.push(Tok::Dollar { content: open_end..content_end.max(open_end) });
                    i = end;
                }
                None => {
                    out.push(Tok::Other);
                    i += 1;
                }
            }
        } else if c.is_ascii_alphabetic() || c == b'_' {
            let start = i;
            while i < n && is_ident_byte(b[i]) {
                i += 1;
            }
            out.push(Tok::Word(start..i));
        } else if c == b';' {
            out.push(Tok::Semi);
            i += 1;
        } else {
            // A UTF-8 lead byte and its continuation bytes are one "other".
            i += 1;
            while i < n && (b[i] & 0xC0) == 0x80 {
                i += 1;
            }
            out.push(Tok::Other);
        }
    }
    out
}

/// Byte ranges to replace with `MASK`, in order.
fn secret_ranges(sql: &str) -> Vec<Range<usize>> {
    let toks = tokens(sql);
    let word = |r: &Range<usize>| sql[r.clone()].to_ascii_lowercase();
    let mut out = Vec::new();
    let mut statement_start = 0usize;
    let mut in_create_secret = false;
    let mut in_set_secret = false;

    for (k, tok) in toks.iter().enumerate() {
        match tok {
            Tok::Semi => {
                statement_start = k + 1;
                in_create_secret = false;
                in_set_secret = false;
            }
            Tok::Word(_) if k == statement_start => {
                in_create_secret = is_create_secret(&toks[k..], sql);
                in_set_secret = is_set_secret(&toks[k..], sql);
            }
            Tok::Str { content } | Tok::Dollar { content } => {
                let key = match k.checked_sub(1).map(|p| &toks[p]) {
                    Some(Tok::Word(w)) => Some(word(w)),
                    _ => None,
                };
                let whole = matches!(tok, Tok::Str { .. })
                    && (in_set_secret
                        || key.as_deref().is_some_and(|key| key == "password" || (in_create_secret && SECRET_KEYS.contains(&key))));
                in_set_secret = false;
                if whole {
                    if !content.is_empty() {
                        out.push(content.clone());
                    }
                } else {
                    out.extend(in_literal(sql, content.clone()));
                }
            }
            _ => {}
        }
    }
    out
}

/// `SET [GLOBAL | SESSION | LOCAL] <secret setting>`, at a statement's start.
fn is_set_secret(toks: &[Tok], sql: &str) -> bool {
    let words: Vec<String> = toks
        .iter()
        .take(3)
        .map(|t| match t { Tok::Word(r) => sql[r.clone()].to_ascii_lowercase(), _ => String::new() })
        .collect();
    if words.first().map(String::as_str) != Some("set") {
        return false;
    }
    let name = match words.get(1).map(String::as_str) {
        Some("global") | Some("session") | Some("local") => words.get(2),
        _ => words.get(1),
    };
    name.is_some_and(|n| SECRET_SETTINGS.contains(&n.as_str()))
}

/// `CREATE [OR REPLACE] [PERSISTENT | TEMPORARY] SECRET`, at a statement's start.
fn is_create_secret(toks: &[Tok], sql: &str) -> bool {
    let mut words = toks.iter().map_while(|t| match t {
        Tok::Word(r) => Some(sql[r.clone()].to_ascii_lowercase()),
        _ => None,
    });
    if words.next().as_deref() != Some("create") {
        return false;
    }
    for w in words.take(4) {
        match w.as_str() {
            "secret" => return true,
            "or" | "replace" | "persistent" | "temporary" | "temp" => continue,
            _ => return false,
        }
    }
    false
}

/// Whether `statement` stores a DuckDB secret outside memory:
/// `CREATE … PERSISTENT SECRET …` or `CREATE … SECRET [name] IN <storage>`
/// with a storage other than `memory`. Pharos refuses both
/// (`db::duckdb::exec`): DuckDB writes such a secret to disk in plain text.
pub(crate) fn creates_stored_secret(statement: &str) -> bool {
    let toks = tokens(statement);
    let words: Vec<String> = toks
        .iter()
        .map_while(|t| match t {
            Tok::Word(r) => Some(statement[r.clone()].to_ascii_lowercase()),
            _ => None,
        })
        .collect();
    if !is_create_secret(&toks, statement) {
        return false;
    }
    let secret_at = words.iter().position(|w| w == "secret").unwrap_or(0);
    if words[..secret_at].iter().any(|w| w == "persistent") {
        return true;
    }
    match words[secret_at..].iter().position(|w| w == "in") {
        Some(i) => words.get(secret_at + i + 1).is_some_and(|storage| storage != "memory"),
        None => false,
    }
}

/// Rule 3 inside one literal's content: `…password=<value>` and
/// `scheme://user:<pw>@`.
fn in_literal(sql: &str, content: Range<usize>) -> Vec<Range<usize>> {
    let text = &sql[content.clone()];
    let lower = text.to_ascii_lowercase();
    let b = text.as_bytes();
    let mut out = Vec::new();

    let mut from = 0;
    while let Some(at) = lower[from..].find("password") {
        let mut i = from + at + "password".len();
        while i < b.len() && b[i] == b' ' {
            i += 1;
        }
        if i < b.len() && b[i] == b'=' {
            i += 1;
            while i < b.len() && b[i] == b' ' {
                i += 1;
            }
            let start = i;
            if text[i..].starts_with("''") {
                // A quoted conninfo value, its quotes doubled inside the SQL literal.
                let value_start = i + 2;
                let end = text[value_start..].find("''").map(|e| value_start + e).unwrap_or(b.len());
                if end > value_start {
                    out.push((content.start + value_start)..(content.start + end));
                }
                i = (end + 2).min(b.len());
            } else {
                while i < b.len() && !b[i].is_ascii_whitespace() && !matches!(b[i], b'\'' | b'&' | b';' | b'"') {
                    i += 1;
                }
                if i > start {
                    out.push((content.start + start)..(content.start + i));
                }
            }
        }
        from = i.max(from + at + 1);
    }

    let mut from = 0;
    while let Some(at) = text[from..].find("://") {
        let auth_start = from + at + 3;
        let auth_end = text[auth_start..]
            .find(|c: char| c == '/' || c == '?' || c == '#' || c.is_whitespace() || c == '\'')
            .map(|e| auth_start + e)
            .unwrap_or(text.len());
        if let Some(at_sign) = text[auth_start..auth_end].rfind('@') {
            let userinfo = &text[auth_start..auth_start + at_sign];
            if let Some(colon) = userinfo.find(':') {
                let pw = (auth_start + colon + 1)..(auth_start + at_sign);
                if !pw.is_empty() {
                    out.push((content.start + pw.start)..(content.start + pw.end));
                }
            }
        }
        from = auth_end.max(auth_start);
    }
    out
}

/// `sql` with every password and secret key replaced by `********`.
/// Borrowed when there is nothing to replace (most SQL).
pub fn redact_secrets(sql: &str) -> Cow<'_, str> {
    let lower = sql.to_ascii_lowercase();
    if !["password", "secret", "token", "key", "uri", "://"].iter().any(|w| lower.contains(w)) {
        return Cow::Borrowed(sql);
    }
    let mut ranges: Vec<Range<usize>> = secret_ranges(sql).into_iter().filter(|r| &sql[r.clone()] != MASK).collect();
    if ranges.is_empty() {
        return Cow::Borrowed(sql);
    }
    ranges.sort_by_key(|r| r.start);
    let mut out = String::with_capacity(sql.len());
    let mut at = 0;
    for r in ranges {
        if r.start < at {
            continue; // overlapping (rule 1 and rule 3 on one literal)
        }
        out.push_str(&sql[at..r.start]);
        out.push_str(MASK);
        at = r.end;
    }
    out.push_str(&sql[at..]);
    Cow::Owned(out)
}

/// `redact_secrets` for an optional field.
pub fn redact_opt(text: Option<&str>) -> Option<Cow<'_, str>> {
    text.map(redact_secrets)
}

#[cfg(test)]
mod tests {
    use super::*;

    fn r(sql: &str) -> String {
        redact_secrets(sql).into_owned()
    }

    #[test]
    fn rule_1_password_literals() {
        assert_eq!(r("ALTER ROLE ana PASSWORD 'hunter2'"), "ALTER ROLE ana PASSWORD '********'");
        assert_eq!(r("create user bo with encrypted password 'md5abc' valid until 'infinity'"),
                   "create user bo with encrypted password '********' valid until 'infinity'");
        assert_eq!(r("CREATE USER MAPPING FOR me SERVER s OPTIONS (user 'u', password 'p''q')"),
                   "CREATE USER MAPPING FOR me SERVER s OPTIONS (user 'u', password '********')");
        assert_eq!(r("ALTER ROLE ana PASSWORD E'it\\'s'"), "ALTER ROLE ana PASSWORD E'********'");
        assert_eq!(r("ALTER ROLE ana PASSWORD NULL"), "ALTER ROLE ana PASSWORD NULL");
    }

    #[test]
    fn rule_2_duckdb_secrets() {
        assert_eq!(
            r("CREATE OR REPLACE PERSISTENT SECRET s3x (TYPE s3, KEY_ID 'AKIA1', SECRET 'abc/def', REGION 'eu-west-1')"),
            "CREATE OR REPLACE PERSISTENT SECRET s3x (TYPE s3, KEY_ID 'AKIA1', SECRET '********', REGION 'eu-west-1')"
        );
        assert_eq!(r("create secret (type gcs, token 't0k')"), "create secret (type gcs, token '********')");
        // Rule 4: DuckDB's older SET form.
        assert_eq!(r("SET s3_secret_access_key = 'abc'; SET s3_access_key_id = 'AKIA'"),
                   "SET s3_secret_access_key = '********'; SET s3_access_key_id = 'AKIA'");
        assert_eq!(r("set global S3_SESSION_TOKEN to 'tok'"), "set global S3_SESSION_TOKEN to '********'");
        assert_eq!(r("SET search_path = 'main'"), "SET search_path = 'main'");
        assert_eq!(r("CREATE SECRET pg (TYPE postgres, HOST 'h', PASSWORD 'pw')"),
                   "CREATE SECRET pg (TYPE postgres, HOST 'h', PASSWORD '********')");
        assert_eq!(r("CREATE SECRET a (TYPE azure, CONNECTION_STRING 'AccountKey=zz')"),
                   "CREATE SECRET a (TYPE azure, CONNECTION_STRING '********')");
        // Outside CREATE SECRET a word "secret" is just a word.
        assert_eq!(r("SELECT secret 'x'"), "SELECT secret 'x'");
        // Each statement on its own.
        assert_eq!(r("CREATE SECRET a (TYPE s3, SECRET 'k'); SELECT 'token'"),
                   "CREATE SECRET a (TYPE s3, SECRET '********'); SELECT 'token'");
    }

    #[test]
    fn rule_3_inside_literals() {
        assert_eq!(r("ATTACH 'host=db port=5432 password=s3cr3t dbname=x' AS pg (TYPE postgres)"),
                   "ATTACH 'host=db port=5432 password=******** dbname=x' AS pg (TYPE postgres)");
        assert_eq!(r("SELECT dblink_connect('dbname=x password = ''a b'' user=u')"),
                   "SELECT dblink_connect('dbname=x password = ''********'' user=u')");
        assert_eq!(r("ATTACH 'postgresql://ana:pa:ss@db.example.com:5432/sales' AS pg (TYPE postgres)"),
                   "ATTACH 'postgresql://ana:********@db.example.com:5432/sales' AS pg (TYPE postgres)");
        assert_eq!(r("SELECT * FROM read_csv('https://example.com/data.csv')"),
                   "SELECT * FROM read_csv('https://example.com/data.csv')");
        assert_eq!(r("SELECT 'sslpassword=x'"), "SELECT 'sslpassword=********'");
        assert_eq!(r("DO $$ BEGIN PERFORM dblink_connect('password=abc'); END $$"),
                   "DO $$ BEGIN PERFORM dblink_connect('password=********'); END $$");
    }

    #[test]
    fn stored_secrets_are_recognised() {
        for sql in [
            "CREATE PERSISTENT SECRET s (TYPE s3, KEY_ID 'k', SECRET 'v')",
            "create or replace persistent secret (type s3)",
            "CREATE SECRET s IN local_file (TYPE s3)",
            "CREATE SECRET IN local_file (TYPE s3)",
        ] {
            assert!(creates_stored_secret(sql), "{sql}");
        }
        for sql in [
            "CREATE SECRET s (TYPE s3, SECRET 'v')",
            "CREATE TEMPORARY SECRET s (TYPE s3)",
            "CREATE SECRET s IN memory (TYPE s3)",
            "CREATE TABLE persistent (x INT)",
            "SELECT 'CREATE PERSISTENT SECRET'",
            "-- CREATE PERSISTENT SECRET\nSELECT 1",
        ] {
            assert!(!creates_stored_secret(sql), "{sql}");
        }
    }

    #[test]
    fn what_stays() {
        for sql in [
            "SELECT password FROM users WHERE password = 'x'",
            "-- ALTER ROLE ana PASSWORD 'commented'\nSELECT 1",
            "/* password 'x' */ SELECT 1",
            "SELECT \"password\" 'not after a keyword'",
            "SELECT 'no secrets here', key_id FROM t",
        ] {
            assert_eq!(r(sql), sql, "{sql}");
        }
        assert!(matches!(redact_secrets("SELECT 1"), Cow::Borrowed(_)));
        assert!(matches!(redact_secrets("SELECT password FROM users"), Cow::Borrowed(_)));
    }

    #[test]
    fn redaction_is_idempotent_and_keeps_utf8() {
        for sql in [
            "ALTER ROLE ana PASSWORD 'hunter2'",
            "ATTACH 'host=é password=ü€' AS x",
            "CREATE SECRET (TYPE s3, SECRET 'ünïcode')",
            "SELECT 'unterminated password='abc",
        ] {
            let once = r(sql);
            assert_eq!(r(&once), once, "{sql}");
            assert!(matches!(redact_secrets(&once), Cow::Borrowed(_)), "{once}");
        }
        assert_eq!(r("ATTACH 'host=é password=ü€' AS x"), "ATTACH 'host=é password=********' AS x");
    }
}
