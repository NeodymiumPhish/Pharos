//! Where one SQL statement ends and the next begins, in text a user wrote.
//!
//! One scanner for every place that has to know: splitting a `.sql` file or an
//! old editor tab into query cards (`cards.rs`), and refusing a script where a
//! single statement is expected (`query::explain_statement`).
//!
//! A `;` ends a statement only in ordinary SQL text. It does not end one:
//! - inside a string (`'…'`, `E'…'` with backslash escapes), a quoted
//!   identifier, a comment (`--`, nested `/* */`) or a dollar-quoted body;
//! - inside parentheses (`CREATE RULE … DO (INSERT …; UPDATE …)`);
//! - inside the `BEGIN ATOMIC … END` body of a `CREATE FUNCTION` or
//!   `CREATE PROCEDURE` (counted the way psql counts it);
//! - inside a `{{name}}` variable token.
//!
//! Two things in a psql script are not SQL and get pieces of their own: a
//! backslash meta-command (`\set x 1`, `\gx`), which runs to the end of its
//! line, and the data lines after `COPY … FROM STDIN;`, which run to a line
//! that is exactly `\.`.
//!
//! Byte offsets throughout; every boundary is on an ASCII byte, so slicing the
//! original `&str` at them is always valid UTF-8.

use std::ops::Range;

/// What a piece of text is.
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum ChunkKind {
    /// An SQL statement, possibly with no body (a comment-only piece).
    Statement,
    /// A psql backslash meta-command line.
    PsqlMeta,
    /// `COPY … FROM STDIN;` and its data lines up to `\.`.
    CopyData,
}

/// One statement of the text, with the comments and blank lines before it.
#[derive(Debug, Clone, PartialEq, Eq)]
pub struct Chunk {
    /// Where the piece starts: just after the previous piece.
    pub start: usize,
    /// The statement itself: from its first non-comment byte to just before
    /// its `;`. Empty (and at the end of the leading comments) for a piece
    /// that holds only comments.
    pub body: Range<usize>,
    /// What follows the `;` and belongs to the statement: a comment on the
    /// same line (with the spaces before it), or COPY data. Empty for most.
    pub tail: Range<usize>,
    /// Just past the piece. Whitespace after the last statement of the text
    /// is in it too.
    pub end: usize,
    pub kind: ChunkKind,
    /// The statement ended with a `;` (or is a meta line / COPY data).
    pub terminated: bool,
}

impl Chunk {
    /// The comments and whitespace before the statement.
    pub fn leading<'a>(&self, text: &'a str) -> &'a str {
        &text[self.start..self.body.start]
    }

    /// The statement, without its `;`.
    pub fn body<'a>(&self, text: &'a str) -> &'a str {
        &text[self.body.clone()]
    }

    /// What follows the statement's `;` and belongs to it: a same-line
    /// comment, or COPY data.
    pub fn trailing<'a>(&self, text: &'a str) -> &'a str {
        &text[self.tail.clone()]
    }
}

/// Split `text` into its statements. Every byte belongs to exactly one piece,
/// in order: the pieces' `start..end` ranges tile the text. A comment-only
/// tail is a piece of its own, so it is never lost.
pub fn split_chunks(text: &str) -> Vec<Chunk> {
    let b = text.as_bytes();
    let n = b.len();
    let mut out = Vec::new();
    let mut st = Scan::new(0);
    let mut i = 0usize;

    while i < n {
        let c = b[i];
        if c.is_ascii_whitespace() {
            i += 1;
            continue;
        }
        if c == b'-' && i + 1 < n && b[i + 1] == b'-' {
            i = skip_line_comment(b, i);
            continue;
        }
        if c == b'/' && i + 1 < n && b[i + 1] == b'*' {
            i = skip_block_comment(b, i);
            continue;
        }
        if c == b'\\' {
            // A psql meta-command ends the statement before it, then runs to
            // the end of its line.
            if let Some(body_start) = st.body_start {
                out.push(Chunk {
                    start: st.start,
                    body: body_start..trim_end(b, body_start, i),
                    tail: i..i,
                    end: i,
                    kind: ChunkKind::Statement,
                    terminated: false,
                });
                st = Scan::new(i);
            }
            let line_end = line_end(b, i);
            out.push(Chunk {
                start: st.start, body: i..line_end, tail: line_end..line_end, end: line_end,
                kind: ChunkKind::PsqlMeta, terminated: true,
            });
            st = Scan::new(line_end);
            i = line_end;
            continue;
        }

        if st.body_start.is_none() {
            st.body_start = Some(i);
        }
        match c {
            b'\'' => i = skip_single_quoted(b, i),
            b'"' => i = skip_double_quoted(b, i),
            b'$' => match dollar_tag_end(b, i) {
                Some(open_end) => i = skip_dollar_quoted(b, i, open_end),
                None => i += 1,
            },
            b'{' if i + 1 < n && b[i + 1] == b'{' => match variable_token_end(text, i + 2) {
                Some(end) => i = end,
                None => i += 1,
            },
            b'(' => {
                st.paren_depth += 1;
                i += 1;
            }
            b')' => {
                st.paren_depth = st.paren_depth.saturating_sub(1);
                i += 1;
            }
            b';' if st.paren_depth == 0 && st.begin_depth == 0 => {
                let body_start = st.body_start.unwrap_or(i);
                let body_end = trim_end(b, body_start, i);
                let mut end = same_line_comment_end(b, i + 1);
                let mut kind = ChunkKind::Statement;
                if is_copy_from_stdin(&text[body_start..body_end]) {
                    kind = ChunkKind::CopyData;
                    end = copy_data_end(b, end);
                }
                out.push(Chunk { start: st.start, body: body_start..body_end, tail: (i + 1)..end, end, kind, terminated: true });
                st = Scan::new(end);
                i = end;
            }
            c if is_ident_start(c) => {
                let word_end = ident_end(b, i);
                st.word(&text[i..word_end]);
                i = word_end;
            }
            _ => i += 1,
        }
    }

    if let Some(body_start) = st.body_start {
        let body_end = trim_end(b, body_start, n);
        out.push(Chunk {
            start: st.start,
            body: body_start..body_end,
            tail: body_end..body_end,
            end: n,
            kind: ChunkKind::Statement,
            terminated: false,
        });
    } else if st.start < n && !text[st.start..].trim().is_empty() {
        // Comments after the last statement: a piece of their own.
        out.push(Chunk { start: st.start, body: n..n, tail: n..n, end: n, kind: ChunkKind::Statement, terminated: false });
    } else if st.start < n {
        // Only whitespace after the last statement: it goes with that one.
        if let Some(last) = out.last_mut() {
            last.end = n;
        }
    }
    out
}

/// Byte offsets of the `;` characters that end statements.
pub fn top_level_semicolons(sql: &str) -> Vec<usize> {
    split_chunks(sql)
        .into_iter()
        .filter(|c| c.kind != ChunkKind::PsqlMeta && c.terminated)
        .map(|c| semicolon_after(sql.as_bytes(), c.body.end))
        .collect()
}

/// True when the text holds nothing but whitespace and comments.
pub fn is_blank_or_comment(sql: &str) -> bool {
    let b = sql.as_bytes();
    let n = b.len();
    let mut i = 0usize;
    while i < n {
        match b[i] {
            b'-' if i + 1 < n && b[i + 1] == b'-' => i = skip_line_comment(b, i),
            b'/' if i + 1 < n && b[i + 1] == b'*' => i = skip_block_comment(b, i),
            c if c.is_ascii_whitespace() => i += 1,
            _ => return false,
        }
    }
    true
}

/// True when `sql` ends inside a `--` comment, so a `;` appended on the same
/// line would be commented out.
pub fn ends_in_line_comment(sql: &str) -> bool {
    let b = sql.as_bytes();
    let n = b.len();
    let mut i = 0usize;
    let mut in_comment = false;
    while i < n {
        in_comment = false;
        match b[i] {
            b'\'' => i = skip_single_quoted(b, i),
            b'"' => i = skip_double_quoted(b, i),
            b'$' => match dollar_tag_end(b, i) {
                Some(open_end) => i = skip_dollar_quoted(b, i, open_end),
                None => i += 1,
            },
            b'-' if i + 1 < n && b[i + 1] == b'-' => {
                i = skip_line_comment(b, i);
                in_comment = i >= n;
            }
            b'/' if i + 1 < n && b[i + 1] == b'*' => i = skip_block_comment(b, i),
            _ => i += 1,
        }
    }
    in_comment
}

// MARK: - Statement state

/// What the scanner knows about the statement it is in.
struct Scan {
    start: usize,
    body_start: Option<usize>,
    paren_depth: u32,
    /// Open `BEGIN` / `CASE` in a `CREATE FUNCTION|PROCEDURE … BEGIN ATOMIC`.
    begin_depth: u32,
    /// The statement's first words, lowercased, up to four: enough to see
    /// `create [or replace] function|procedure`.
    words: Vec<String>,
    word_count: usize,
}

impl Scan {
    fn new(start: usize) -> Scan {
        Scan { start, body_start: None, paren_depth: 0, begin_depth: 0, words: Vec::new(), word_count: 0 }
    }

    /// psql's rule (psqlscan.l): only in a CREATE FUNCTION or PROCEDURE, a
    /// `BEGIN` or `CASE` after the first word opens a block, and `END` closes
    /// one. A routine body in `$$` never reaches here: it is skipped whole.
    fn word(&mut self, word: &str) {
        self.word_count += 1;
        let lower = word.to_ascii_lowercase();
        if self.words.len() < 4 {
            self.words.push(lower.clone());
        }
        if !self.is_routine() {
            return;
        }
        match lower.as_str() {
            "begin" | "case" if self.word_count > 1 => self.begin_depth += 1,
            "end" if self.begin_depth > 0 => self.begin_depth -= 1,
            _ => {}
        }
    }

    fn is_routine(&self) -> bool {
        let w = &self.words;
        let kind = |s: &String| s == "function" || s == "procedure";
        match w.as_slice() {
            [c, k, ..] if c == "create" && kind(k) => true,
            [c, o, r, k, ..] if c == "create" && o == "or" && r == "replace" && kind(k) => true,
            _ => false,
        }
    }
}

// MARK: - Byte helpers

/// Index just past the closing quote of the single-quoted literal at `start`.
///
/// `''` is the doubled-quote escape. A backslash escapes the next character
/// only in an `E'…'` string, which is why the `E` prefix is detected here
/// rather than every backslash being treated as an escape — in a standard
/// string (`standard_conforming_strings` is on by default) a backslash is an
/// ordinary character and must not swallow a closing quote.
pub(crate) fn skip_single_quoted(b: &[u8], start: usize) -> usize {
    let n = b.len();
    let escapes = start > 0
        && (b[start - 1] == b'E' || b[start - 1] == b'e')
        && (start < 2 || !is_ident_byte(b[start - 2]));
    let mut i = start + 1;
    while i < n {
        match b[i] {
            b'\\' if escapes && i + 1 < n => i += 2,
            b'\'' if i + 1 < n && b[i + 1] == b'\'' => i += 2,
            b'\'' => return i + 1,
            _ => i += 1,
        }
    }
    n
}

/// Index just past the closing quote of the quoted identifier at `start`.
/// `""` is the doubled-quote escape.
pub(crate) fn skip_double_quoted(b: &[u8], start: usize) -> usize {
    let n = b.len();
    let mut i = start + 1;
    while i < n {
        match b[i] {
            b'"' if i + 1 < n && b[i + 1] == b'"' => i += 2,
            b'"' => return i + 1,
            _ => i += 1,
        }
    }
    n
}

pub(crate) fn skip_line_comment(b: &[u8], start: usize) -> usize {
    let n = b.len();
    let mut i = start + 2;
    while i < n && b[i] != b'\n' {
        i += 1;
    }
    i
}

/// PostgreSQL nests block comments, so the depth is counted rather than
/// stopping at the first `*/`.
pub(crate) fn skip_block_comment(b: &[u8], start: usize) -> usize {
    let n = b.len();
    let mut depth = 1usize;
    let mut i = start + 2;
    while i < n {
        if i + 1 < n && b[i] == b'/' && b[i + 1] == b'*' {
            depth += 1;
            i += 2;
        } else if i + 1 < n && b[i] == b'*' && b[i + 1] == b'/' {
            depth -= 1;
            i += 2;
            if depth == 0 {
                return i;
            }
        } else {
            i += 1;
        }
    }
    n
}

pub(crate) fn is_ident_byte(c: u8) -> bool {
    c.is_ascii_alphanumeric() || c == b'_'
}

fn is_ident_start(c: u8) -> bool {
    c.is_ascii_alphabetic() || c == b'_'
}

fn ident_end(b: &[u8], start: usize) -> usize {
    let mut i = start;
    while i < b.len() && (is_ident_byte(b[i]) || b[i] == b'$') {
        i += 1;
    }
    i
}

/// Index just past the opening `$tag$` at `start`, or `None` when this `$` does
/// not open a dollar-quoted body. `$1` (a positional parameter) has no closing
/// `$`, and `$2x$` is not a tag because a tag may not start with a digit.
pub(crate) fn dollar_tag_end(b: &[u8], start: usize) -> Option<usize> {
    let n = b.len();
    let mut i = start + 1;
    while i < n && b[i] != b'$' {
        if !is_ident_byte(b[i]) {
            return None;
        }
        i += 1;
    }
    if i >= n {
        return None;
    }
    if i > start + 1 && b[start + 1].is_ascii_digit() {
        return None;
    }
    Some(i + 1)
}

/// Index just past the closing `$tag$` of the body opened at `start`.
pub(crate) fn skip_dollar_quoted(b: &[u8], start: usize, open_end: usize) -> usize {
    let tag = &b[start..open_end];
    let n = b.len();
    let mut i = open_end;
    while i + tag.len() <= n {
        if &b[i..i + tag.len()] == tag {
            return i + tag.len();
        }
        i += 1;
    }
    n
}

/// End index (exclusive, past the `}}`) of the `{{name}}` token whose contents
/// start at `from`, or `None` when the run holds a brace or a newline before
/// it closes — then it is not a token.
pub(crate) fn variable_token_end(sql: &str, from: usize) -> Option<usize> {
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

/// `end`, moved back over whitespace, but never before `start`.
fn trim_end(b: &[u8], start: usize, end: usize) -> usize {
    let mut e = end;
    while e > start && b[e - 1].is_ascii_whitespace() {
        e -= 1;
    }
    e
}

/// The `;` at or after `from` (the statement's body end).
fn semicolon_after(b: &[u8], from: usize) -> usize {
    let mut i = from;
    while i < b.len() && b[i] != b';' {
        i += 1;
    }
    i
}

/// Index of the newline that ends the line at `from`, or the text's end.
fn line_end(b: &[u8], from: usize) -> usize {
    let mut i = from;
    while i < b.len() && b[i] != b'\n' {
        i += 1;
    }
    i
}

/// After a statement's `;`: past spaces and a `--` comment on the same line,
/// if there is one. Otherwise `from` itself.
fn same_line_comment_end(b: &[u8], from: usize) -> usize {
    let mut i = from;
    while i < b.len() && (b[i] == b' ' || b[i] == b'\t') {
        i += 1;
    }
    if i + 1 < b.len() && b[i] == b'-' && b[i + 1] == b'-' {
        skip_line_comment(b, i)
    } else {
        from
    }
}

/// `COPY … FROM STDIN` (any case, any spacing): its data follows in the text.
fn is_copy_from_stdin(body: &str) -> bool {
    let words: Vec<String> = body
        .split(|c: char| c.is_whitespace() || c == '(' || c == ')')
        .filter(|w| !w.is_empty())
        .map(|w| w.to_ascii_lowercase())
        .collect();
    words.first().map(String::as_str) == Some("copy")
        && words.windows(2).any(|w| w[0] == "from" && w[1] == "stdin")
}

/// Past the `\.` line that ends COPY data starting after `from`, or the
/// text's end when there is none.
fn copy_data_end(b: &[u8], from: usize) -> usize {
    let mut i = line_end(b, from);
    while i < b.len() {
        let start = i + 1;
        let end = line_end(b, start);
        let line = &b[start..end];
        let line = line.strip_suffix(b"\r").unwrap_or(line);
        if line == b"\\." {
            return end;
        }
        i = end;
    }
    b.len()
}

#[cfg(test)]
mod tests {
    use super::*;

    /// The bodies of the statement pieces.
    fn bodies(text: &str) -> Vec<&str> {
        split_chunks(text).iter().map(|c| c.body(text)).collect()
    }

    fn tiles(text: &str) {
        let chunks = split_chunks(text);
        let mut at = 0;
        for c in &chunks {
            assert_eq!(c.start, at, "pieces tile the text: {:?}", chunks);
            assert!(c.start <= c.body.start && c.body.start <= c.body.end && c.body.end <= c.end);
            at = c.end;
        }
        assert_eq!(at, text.len(), "pieces reach the end: {:?}", chunks);
    }

    #[test]
    fn splits_on_top_level_semicolons_only() {
        let text = "SELECT 'a;b' -- c;\nFROM t;\nSELECT \"x;y\", $$p;q$$, $tag$r;s$tag$ /* u; /* v; */ w; */;";
        assert_eq!(bodies(text), vec!["SELECT 'a;b' -- c;\nFROM t", "SELECT \"x;y\", $$p;q$$, $tag$r;s$tag$ /* u; /* v; */ w; */"]);
        tiles(text);
    }

    #[test]
    fn leading_comments_and_blank_lines_are_not_the_body() {
        let text = "\n-- totals\n/* by month */\nSELECT 1;\n\n  SELECT 2";
        let chunks = split_chunks(text);
        assert_eq!(chunks.len(), 2);
        assert_eq!(chunks[0].leading(text), "\n-- totals\n/* by month */\n");
        assert_eq!(chunks[0].body(text), "SELECT 1");
        assert!(chunks[0].terminated);
        assert_eq!(chunks[1].body(text), "SELECT 2");
        assert!(!chunks[1].terminated, "the last statement may have no semicolon");
        tiles(text);
    }

    #[test]
    fn parentheses_hold_semicolons() {
        let text = "CREATE RULE r AS ON INSERT TO t DO ALSO (INSERT INTO a VALUES (1); UPDATE b SET x = 1);\nSELECT 1;";
        assert_eq!(bodies(text).len(), 2);
        assert!(bodies(text)[0].ends_with("SET x = 1)"));
    }

    #[test]
    fn begin_atomic_bodies_hold_semicolons() {
        let text = "CREATE OR REPLACE FUNCTION f(x int) RETURNS int LANGUAGE sql\nBEGIN ATOMIC\n  SELECT CASE WHEN x > 0 THEN 1 ELSE 0 END;\n  SELECT x;\nEND;\nSELECT f(1);";
        let b = bodies(text);
        assert_eq!(b.len(), 2, "{:?}", b);
        assert!(b[0].ends_with("END"));
        assert_eq!(b[1], "SELECT f(1)");
        // Outside a routine, BEGIN is a statement of its own.
        assert_eq!(bodies("BEGIN; UPDATE t SET x = 1; COMMIT;"), vec!["BEGIN", "UPDATE t SET x = 1", "COMMIT"]);
        let proc = "create procedure p() begin atomic insert into t values (1); end; call p();";
        assert_eq!(bodies(proc).len(), 2);
    }

    #[test]
    fn variable_tokens_are_opaque() {
        assert_eq!(bodies("SELECT {{a;b}}; SELECT 2"), vec!["SELECT {{a;b}}", "SELECT 2"]);
        // A run with a newline is not a token, so its semicolon splits.
        assert_eq!(bodies("SELECT {{a;\n}}").len(), 2);
    }

    #[test]
    fn psql_meta_commands_are_pieces_of_their_own() {
        let text = "\\set x 1\nSELECT :x;\nSELECT 2 \\gx\n\\echo done";
        let chunks = split_chunks(text);
        let kinds: Vec<ChunkKind> = chunks.iter().map(|c| c.kind).collect();
        assert_eq!(
            kinds,
            vec![ChunkKind::PsqlMeta, ChunkKind::Statement, ChunkKind::Statement, ChunkKind::PsqlMeta, ChunkKind::PsqlMeta]
        );
        assert_eq!(chunks[0].body(text), "\\set x 1");
        assert_eq!(chunks[2].body(text), "SELECT 2");
        assert_eq!(chunks[3].body(text), "\\gx");
        assert_eq!(chunks[4].body(text), "\\echo done");
        tiles(text);
        // A backslash inside a literal or an E-string is not a meta-command.
        assert_eq!(bodies("SELECT '\\n', E'\\';'; SELECT 2"), vec!["SELECT '\\n', E'\\';'", "SELECT 2"]);
    }

    #[test]
    fn copy_from_stdin_keeps_its_data() {
        let text = "COPY t (a, b) FROM stdin;\n1\t'x;y'\n2\t;\n\\.\nSELECT 1;";
        let chunks = split_chunks(text);
        assert_eq!(chunks.len(), 2, "{:?}", chunks);
        assert_eq!(chunks[0].kind, ChunkKind::CopyData);
        assert_eq!(chunks[0].body(text), "COPY t (a, b) FROM stdin");
        assert_eq!(chunks[0].trailing(text), "\n1\t'x;y'\n2\t;\n\\.");
        assert_eq!(chunks[1].body(text), "SELECT 1");
        tiles(text);
        // No terminator: the data runs to the end, nothing is lost.
        let open = "COPY t FROM STDIN;\n1\n2";
        assert_eq!(split_chunks(open).len(), 1);
        tiles(open);
        // COPY to a file is a plain statement.
        assert_eq!(split_chunks("COPY t TO '/tmp/x'; SELECT 1;")[0].kind, ChunkKind::Statement);
    }

    #[test]
    fn same_line_comment_after_the_semicolon_goes_with_the_statement() {
        let text = "SELECT 1; -- why\nSELECT 2;";
        let chunks = split_chunks(text);
        assert_eq!(chunks[0].trailing(text), " -- why");
        assert_eq!(chunks[1].leading(text), "\n");
    }

    #[test]
    fn a_comment_only_tail_is_kept() {
        let text = "SELECT 1;\n-- the end\n";
        let chunks = split_chunks(text);
        assert_eq!(chunks.len(), 2);
        assert!(chunks[1].body.is_empty());
        assert_eq!(chunks[1].leading(text), "\n-- the end\n");
        tiles(text);
        // Whitespace only after the last statement joins it.
        assert_eq!(split_chunks("SELECT 1;\n\n").len(), 1);
        tiles("SELECT 1;\n\n");
    }

    #[test]
    fn an_unterminated_literal_runs_to_the_end() {
        let text = "SELECT 1; SELECT 'open; SELECT 2;";
        assert_eq!(bodies(text), vec!["SELECT 1", "SELECT 'open; SELECT 2;"]);
        tiles(text);
    }

    #[test]
    fn helpers() {
        assert_eq!(top_level_semicolons("select 1; select ';'; -- ;"), vec![8, 20]);
        assert!(is_blank_or_comment("  -- x\n /* y */ "));
        assert!(!is_blank_or_comment("-- x\nselect 1"));
        assert!(ends_in_line_comment("SELECT 1 -- note"));
        assert!(!ends_in_line_comment("SELECT '--' -- x\nFROM t"));
        assert!(!ends_in_line_comment("SELECT 1 /* -- */"));
        assert_eq!(variable_token_end("{{abc}} x", 2), Some(7));
        assert_eq!(variable_token_end("{{a\n}}", 2), None);
    }

    #[test]
    fn multibyte_text_splits_on_character_boundaries() {
        let text = "SELECT 'café;'; -- naïve ;\nSELECT 'ü'";
        assert_eq!(bodies(text), vec!["SELECT 'café;'", "SELECT 'ü'"]);
        tiles(text);
    }
}
