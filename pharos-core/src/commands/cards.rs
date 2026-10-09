//! Query cards to and from SQL text: a `.sql` file, an old editor tab's text,
//! and the flat text columns kept for search and older app versions.
//!
//! The text form, one card after another, a blank line between:
//!
//! ```sql
//! -- name: Active users
//! -- version: 1 locked
//! -- SELECT * FROM users
//!
//! -- name: Active users
//! -- version: 2
//! SELECT * FROM users WHERE active;
//! ```
//!
//! - `-- name:` names the card. A card without a name has no header line.
//! - `-- version:` appears only when a query has more than one version.
//! - Older locked versions are written as comments, so running the file in
//!   psql runs only the latest version of each query; nothing is lost.
//! - psql meta-command lines and `COPY … FROM STDIN` data are written as they
//!   were read.
//! - A query's notes are a block comment between two `=` border lines, after
//!   the header lines of its latest version:
//!
//! ```sql
//! -- name: Active users
//! /*
//! =====================================================================
//! Users who signed in this month.
//! =====================================================================
//! */
//! SELECT * FROM users WHERE active;
//! ```
//!
//!   A split reads that block back as notes. Other comments before a
//!   statement stay in its SQL; `extract_leading_notes` turns them into notes
//!   when the user asks.
//!
//! Splitting finds statements with `sql_lexer`, and reads the headers from the
//! comments before each one. Every card a serialize writes comes back from a
//! split with the same name, version, lock, SQL and kind.

use serde::{Deserialize, Serialize};
use std::collections::HashMap;

use super::sql_lexer::{ends_in_line_comment, is_blank_or_comment, skip_block_comment, skip_line_comment, split_chunks, ChunkKind};

/// What a card holds. The same strings as Swift's `QueryCardKind`.
#[derive(Debug, Clone, Copy, PartialEq, Eq, Serialize, Deserialize, Default)]
#[serde(rename_all = "camelCase")]
pub enum CardKind {
    #[default]
    Sql,
    PsqlMeta,
    CopyData,
}

/// One card read from text.
#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct SplitCard {
    pub name: Option<String>,
    /// From a `-- version:` line; None when the text had none.
    pub version: Option<u32>,
    pub locked: bool,
    /// The statement without its `;`, with the comments that came before it.
    pub sql: String,
    pub kind: CardKind,
    /// Cards with the same number are versions of one query, in order.
    pub lineage: u32,
    /// 1-based lines of the statement in the text; 0 for a version that was
    /// written as comments.
    pub start_line: u32,
    pub end_line: u32,
    /// The query's notes, from a notes block. Every version of the query has
    /// them. None when the text had no notes block.
    pub notes: Option<String>,
}

/// One card to write.
#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct CardToWrite {
    pub name: Option<String>,
    pub version: u32,
    #[serde(default)]
    pub locked: bool,
    pub sql: String,
    #[serde(default)]
    pub kind: CardKind,
    /// The query this card is a version of. Versions of one query are
    /// consecutive.
    pub lineage_id: String,
    /// The query's notes. Written once, with the query's latest version.
    #[serde(default)]
    pub notes: Option<String>,
}

/// Which cards to write.
#[derive(Debug, Clone, Copy, PartialEq, Eq, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub enum SerializeMode {
    /// Every version: `.sql` files, the workspace and session text.
    All,
    /// The latest version of each query only: a clean script, for a saved
    /// query's text, Spotlight and Shortcuts.
    Latest,
}

// MARK: - Split

/// The cards in `text`. A UTF-8 byte order mark is dropped.
pub fn split_cards(text: &str) -> Vec<SplitCard> {
    let text = text.strip_prefix('\u{feff}').unwrap_or(text);
    let line_of = LineIndex::new(text);
    let mut cards: Vec<SplitCard> = Vec::new();

    for chunk in split_chunks(text) {
        let leading = chunk.leading(text);
        let lines: Vec<&str> = leading.split('\n').collect();
        // A `-- name:` line inside a block comment (a notes block, say) is
        // text of that comment, not a header.
        let outside = lines_outside_block_comments(leading);
        let headers: Vec<usize> = lines
            .iter()
            .enumerate()
            .filter(|(i, l)| outside[*i] && header_name(l).is_some())
            .map(|(i, _)| i)
            .collect();

        // Comments before the first header are a card of their own: they are
        // not this statement's (a header stands between).
        let first_header = headers.first().copied().unwrap_or(lines.len());
        if !headers.is_empty() {
            let notes = trim_blank_lines(&lines[..first_header]);
            if !notes.is_empty() {
                cards.push(card(None, None, false, notes, CardKind::Sql, 0, 0));
            }
        }

        // Every header but the last opens a version written as comments.
        for (k, &h) in headers.iter().enumerate().take(headers.len().saturating_sub(1)) {
            let next = headers[k + 1];
            let name = header_name(lines[h]).flatten();
            let (version, mut body_from) = (version_line(lines.get(h + 1).copied().unwrap_or("")), h + 1);
            if version.is_some() {
                body_from += 1;
            }
            let sql: Vec<String> = lines[body_from.min(next)..next].iter().map(|l| uncomment(l)).collect();
            let sql_refs: Vec<&str> = sql.iter().map(String::as_str).collect();
            cards.push(card(name, version.map(|v| v.0), true, trim_blank_lines(&sql_refs), CardKind::Sql, 0, 0));
        }

        // The last header, if any, is this statement's.
        let (name, version, locked, prefix_from) = match headers.last() {
            Some(&h) => {
                let v = version_line(lines.get(h + 1).copied().unwrap_or(""));
                (header_name(lines[h]).flatten(), v.map(|v| v.0), v.map(|v| v.1).unwrap_or(false), h + 1 + v.map_or(0, |_| 1))
            }
            None => (None, None, false, 0),
        };
        // The statement keeps its own spacing: from the first line after the
        // header to the end of the statement, as the text had it.
        let prefix_offset: usize = lines.iter().take(prefix_from.min(lines.len())).map(|l| l.len() + 1).sum();
        let from = (chunk.start + prefix_offset).min(chunk.body.end);
        let (kind, statement) = match chunk.kind {
            ChunkKind::PsqlMeta => (CardKind::PsqlMeta, text[from..chunk.body.end].to_string()),
            ChunkKind::CopyData => (CardKind::CopyData, format!("{};{}", &text[from..chunk.body.end], chunk.trailing(text))),
            ChunkKind::Statement => (CardKind::Sql, format!("{}{}", &text[from..chunk.body.end], chunk.trailing(text))),
        };
        let mut sql = statement.trim().to_string();
        let mut notes = None;
        if kind == CardKind::Sql {
            if let Some((n, rest)) = read_notes_block(&sql) {
                notes = Some(n);
                sql = rest;
            }
        }
        if sql.trim().is_empty() && name.is_none() && notes.is_none() {
            continue; // a lone `;`
        }
        let start_line = line_of.line(chunk.body.start);
        let end_line = line_of.line(chunk.body.end.max(chunk.body.start));
        let mut c = card(name, version, locked, sql, kind, start_line, end_line);
        c.notes = notes;
        cards.push(c);
    }

    assign_lineages(&mut cards);
    share_notes(&mut cards);
    cards
}

fn card(name: Option<String>, version: Option<u32>, locked: bool, sql: String, kind: CardKind,
        start_line: u32, end_line: u32) -> SplitCard {
    SplitCard { name, version, locked, sql, kind, lineage: 0, start_line, end_line, notes: None }
}

/// Notes belong to the query: give every version the notes its query was
/// written with (only the latest version carries the block).
fn share_notes(cards: &mut [SplitCard]) {
    let mut by_lineage: HashMap<u32, String> = HashMap::new();
    for c in cards.iter() {
        if let Some(n) = &c.notes {
            by_lineage.entry(c.lineage).or_insert_with(|| n.clone());
        }
    }
    for c in cards.iter_mut() {
        if c.notes.is_none() {
            c.notes = by_lineage.get(&c.lineage).cloned();
        }
    }
}

/// Consecutive cards with the same name and rising version numbers are
/// versions of one query. Any other card starts a query of its own.
fn assign_lineages(cards: &mut [SplitCard]) {
    let mut lineage = 0u32;
    for i in 0..cards.len() {
        let joins = i > 0 && {
            let (prev, cur) = (&cards[i - 1], &cards[i]);
            matches!((prev.version, cur.version), (Some(p), Some(c)) if c > p) && prev.name == cur.name
        };
        if i > 0 && !joins {
            lineage += 1;
        }
        cards[i].lineage = lineage;
    }
}

/// For each line of `text` (comments and whitespace only), whether it starts
/// outside every block comment.
fn lines_outside_block_comments(text: &str) -> Vec<bool> {
    let b = text.as_bytes();
    let n = b.len();
    // Byte ranges covered by block comments.
    let mut blocks: Vec<(usize, usize)> = Vec::new();
    let mut i = 0usize;
    while i < n {
        if b[i] == b'-' && i + 1 < n && b[i + 1] == b'-' {
            i = skip_line_comment(b, i);
        } else if b[i] == b'/' && i + 1 < n && b[i + 1] == b'*' {
            let end = skip_block_comment(b, i);
            blocks.push((i, end));
            i = end;
        } else {
            i += 1;
        }
    }
    let mut out = Vec::new();
    let mut start = 0usize;
    for line in text.split('\n') {
        out.push(!blocks.iter().any(|&(s, e)| start > s && start < e));
        start += line.len() + 1;
    }
    out
}

/// `-- name: X` (any case and spacing) gives Some(Some(X)); `-- name:` alone
/// gives Some(None); any other line None.
fn header_name(line: &str) -> Option<Option<String>> {
    let rest = line.trim().strip_prefix("--")?.trim_start();
    if rest.len() < 5 || !rest[..5].eq_ignore_ascii_case("name:") {
        return None;
    }
    let name = rest[5..].trim();
    Some(if name.is_empty() { None } else { Some(name.to_string()) })
}

/// `-- version: 2` or `-- version: 2 locked`.
fn version_line(line: &str) -> Option<(u32, bool)> {
    let rest = line.trim().strip_prefix("--")?.trim_start();
    if rest.len() < 8 || !rest[..8].eq_ignore_ascii_case("version:") {
        return None;
    }
    let mut words = rest[8..].split_whitespace();
    let number = words.next()?.parse::<u32>().ok()?;
    let locked = words.next().is_some_and(|w| w.eq_ignore_ascii_case("locked"));
    Some((number, locked))
}

/// A line of a version written as comments, back to SQL: `-- x` → `x`,
/// `--` → empty.
fn uncomment(line: &str) -> String {
    let trimmed = line.trim_end_matches('\r');
    match trimmed.strip_prefix("--") {
        Some(rest) => rest.strip_prefix(' ').unwrap_or(rest).to_string(),
        None => trimmed.to_string(),
    }
}

/// The lines joined, without blank lines at either end.
fn trim_blank_lines(lines: &[&str]) -> String {
    let first = lines.iter().position(|l| !l.trim().is_empty());
    let last = lines.iter().rposition(|l| !l.trim().is_empty());
    match (first, last) {
        (Some(a), Some(b)) => lines[a..=b].join("\n"),
        _ => String::new(),
    }
}

/// 1-based line numbers of byte offsets.
struct LineIndex {
    starts: Vec<usize>,
}

impl LineIndex {
    fn new(text: &str) -> LineIndex {
        let mut starts = vec![0];
        starts.extend(text.bytes().enumerate().filter(|(_, b)| *b == b'\n').map(|(i, _)| i + 1));
        LineIndex { starts }
    }

    fn line(&self, offset: usize) -> u32 {
        (self.starts.partition_point(|&s| s <= offset)) as u32
    }
}

// MARK: - Serialize

/// `cards` as SQL text.
pub fn serialize_cards(cards: &[CardToWrite], mode: SerializeMode) -> String {
    let mut last_of: HashMap<&str, usize> = HashMap::new();
    let mut count_of: HashMap<&str, usize> = HashMap::new();
    for (i, c) in cards.iter().enumerate() {
        last_of.insert(c.lineage_id.as_str(), i);
        *count_of.entry(c.lineage_id.as_str()).or_insert(0) += 1;
    }

    let mut blocks: Vec<String> = Vec::new();
    for (i, c) in cards.iter().enumerate() {
        let is_last = last_of[c.lineage_id.as_str()] == i;
        if mode == SerializeMode::Latest && !is_last {
            continue;
        }
        let versioned = mode == SerializeMode::All && count_of[c.lineage_id.as_str()] > 1;
        let name = c.name.as_deref().map(flatten_name).filter(|n| !n.is_empty());
        let mut lines: Vec<String> = Vec::new();

        if mode == SerializeMode::All && c.locked && !is_last {
            lines.push(format!("-- name: {}", name.unwrap_or_default()).trim_end().to_string());
            lines.push(format!("-- version: {} locked", c.version));
            for line in c.sql.trim_end().split('\n') {
                lines.push(if line.is_empty() { "--".to_string() } else { format!("-- {}", line) });
            }
            blocks.push(lines.join("\n"));
            continue;
        }

        if name.is_some() || versioned {
            lines.push(format!("-- name: {}", name.unwrap_or_default()).trim_end().to_string());
        }
        if versioned {
            lines.push(format!("-- version: {}{}", c.version, if c.locked { " locked" } else { "" }));
        }
        if is_last && c.kind == CardKind::Sql {
            if let Some(block) = c.notes.as_deref().and_then(notes_block) {
                lines.push(block);
            }
        }
        let sql = c.sql.trim_end();
        match c.kind {
            CardKind::PsqlMeta | CardKind::CopyData => lines.push(sql.to_string()),
            CardKind::Sql if is_blank_or_comment(sql) || ends_in_line_comment(sql) => {
                // A `;` on the same line would be inside the comment.
                if !sql.is_empty() {
                    lines.push(sql.to_string());
                }
                lines.push(";".to_string());
            }
            CardKind::Sql if sql.ends_with(';') => lines.push(sql.to_string()),
            CardKind::Sql => lines.push(format!("{};", sql)),
        }
        blocks.push(lines.join("\n"));
    }

    if blocks.is_empty() {
        return String::new();
    }
    blocks.join("\n\n") + "\n"
}

/// A name on one line, trimmed.
fn flatten_name(name: &str) -> String {
    name.split_whitespace().collect::<Vec<_>>().join(" ")
}

// MARK: - Notes

/// The top and bottom line of a notes block.
pub const NOTES_BORDER: &str = "=====================================================================";

/// True for a line of 3 or more `=` and nothing else (spaces aside).
fn is_border(line: &str) -> bool {
    let t = line.trim();
    t.len() >= 3 && t.bytes().all(|b| b == b'=')
}

/// `notes` as the block comment the text form writes, or None when they are
/// blank. `/*` and `*/` inside are broken up (`/ *`, `* /`): PostgreSQL nests
/// block comments, so an unbalanced one would comment out the statement.
fn notes_block(notes: &str) -> Option<String> {
    let text = notes.replace("\r\n", "\n").replace('\r', "\n").replace("/*", "/ *").replace("*/", "* /");
    let lines: Vec<&str> = text.split('\n').map(str::trim_end).collect();
    let body = trim_blank_lines(&lines);
    if body.is_empty() {
        return None;
    }
    Some(format!("/*\n{}\n{}\n{}\n*/", NOTES_BORDER, body, NOTES_BORDER))
}

/// A notes block at the very start of `sql`: the notes and the SQL after the
/// block. The block is a block comment whose first and last non-blank lines
/// are `=` borders; anything else is an ordinary comment and stays in the SQL.
fn read_notes_block(sql: &str) -> Option<(String, String)> {
    if !sql.starts_with("/*") {
        return None;
    }
    let end = skip_block_comment(sql.as_bytes(), 0);
    if end < 4 || !sql[..end].ends_with("*/") {
        return None; // never closed
    }
    let inner = &sql[2..end - 2];
    let lines: Vec<&str> = inner.split('\n').map(|l| l.trim_end_matches('\r')).collect();
    let first = lines.iter().position(|l| !l.trim().is_empty())?;
    let last = lines.iter().rposition(|l| !l.trim().is_empty())?;
    if first == last || !is_border(lines[first]) || !is_border(lines[last]) {
        return None;
    }
    let notes = trim_blank_lines(&lines[first + 1..last]);
    Some((notes, sql[end..].trim_start().to_string()))
}

/// The comments before the first token of `sql` as notes, and the SQL from
/// that token on. Comment marks are removed: `--` (and one space after it),
/// `/*`, `*/`, and a ` * ` gutter when every line of a block has one. Border
/// lines of `=`, and `-- name:` / `-- version:` lines, are dropped.
///
/// None when no comment comes before a statement, when the text is nothing
/// but comments, or when the comments hold nothing but borders.
pub fn extract_leading_notes(sql: &str) -> Option<(String, String)> {
    let b = sql.as_bytes();
    let n = b.len();
    let mut out: Vec<String> = Vec::new();
    let mut i = 0usize;
    // Newlines since the last comment ended: two or more is a blank line,
    // which separates paragraphs in the notes too.
    let mut newlines = 0usize;
    let mut saw_comment = false;

    while i < n {
        match b[i] {
            b'-' if i + 1 < n && b[i + 1] == b'-' => {
                if saw_comment && newlines >= 2 {
                    out.push(String::new());
                }
                let end = skip_line_comment(b, i);
                let raw = &sql[i..end];
                if header_name(raw).is_none() && version_line(raw).is_none() {
                    let text = &sql[i + 2..end];
                    out.push(text.strip_prefix(' ').unwrap_or(text).trim_end().to_string());
                }
                saw_comment = true;
                newlines = 0;
                i = end;
            }
            b'/' if i + 1 < n && b[i + 1] == b'*' => {
                let end = skip_block_comment(b, i);
                if !sql[i..end].ends_with("*/") || end - i < 4 {
                    return None; // never closed: the rest is all comment
                }
                if saw_comment && newlines >= 2 {
                    out.push(String::new());
                }
                out.extend(block_lines(&sql[i + 2..end - 2]));
                saw_comment = true;
                newlines = 0;
                i = end;
            }
            b'\n' => {
                newlines += 1;
                i += 1;
            }
            c if c.is_ascii_whitespace() => i += 1,
            _ => break,
        }
    }

    if !saw_comment || sql[i..].trim().is_empty() {
        return None;
    }
    let mut lines: Vec<&str> = Vec::new();
    for line in out.iter().filter(|l| !is_border(l)).map(String::as_str) {
        // One blank line between paragraphs, however many the text had.
        if line.trim().is_empty() && lines.last().is_some_and(|l| l.trim().is_empty()) {
            continue;
        }
        lines.push(line);
    }
    let notes = trim_blank_lines(&lines);
    if notes.is_empty() {
        return None;
    }
    Some((notes, sql[i..].to_string()))
}

/// The lines inside a block comment (without `/*` and `*/`): a ` * ` gutter
/// removed when every line after the first has one, then the common
/// indentation removed, trailing spaces trimmed.
fn block_lines(inner: &str) -> Vec<String> {
    let mut lines: Vec<String> = inner.split('\n').map(|l| l.trim_end_matches('\r').to_string()).collect();
    if let Some(first) = lines.first_mut() {
        // The text after `/*`; a `/**` opener leaves only stars, which go.
        let t = first.trim();
        *first = if t.bytes().all(|b| b == b'*') { String::new() } else { first.trim_start().to_string() };
    }
    let rest_marked = lines.len() > 1
        && lines[1..].iter().filter(|l| !l.trim().is_empty()).all(|l| l.trim_start().starts_with('*'))
        && lines[1..].iter().any(|l| !l.trim().is_empty());
    if rest_marked {
        for l in lines[1..].iter_mut() {
            if let Some(after) = l.trim_start().strip_prefix('*') {
                *l = after.strip_prefix(' ').unwrap_or(after).to_string();
            }
        }
    }
    // ASCII spaces and tabs only: those are one byte each, so the slice
    // below always cuts between characters.
    let indent = lines[1..]
        .iter()
        .filter(|l| !l.trim().is_empty())
        .map(|l| l.len() - l.trim_start_matches([' ', '\t']).len())
        .min()
        .unwrap_or(0);
    lines
        .iter()
        .enumerate()
        .map(|(k, l)| {
            let l = if k > 0 && l.len() >= indent && !l.trim().is_empty() { &l[indent..] } else { l.as_str() };
            l.trim_end().to_string()
        })
        .collect()
}

#[cfg(test)]
mod tests {
    use super::*;

    fn w(name: Option<&str>, version: u32, locked: bool, sql: &str, lineage: &str) -> CardToWrite {
        CardToWrite { name: name.map(str::to_string), version, locked, sql: sql.to_string(), kind: CardKind::Sql, lineage_id: lineage.to_string(), notes: None }
    }

    fn meta(sql: &str, kind: CardKind, lineage: &str) -> CardToWrite {
        CardToWrite { name: None, version: 1, locked: false, sql: sql.to_string(), kind, lineage_id: lineage.to_string(), notes: None }
    }

    /// What a split card must match of the card it was written from.
    fn same(read: &SplitCard, written: &CardToWrite, versioned: bool) -> bool {
        read.name == written.name
            && read.sql == written.sql
            && read.kind == written.kind
            && read.locked == (versioned && written.locked)
            && read.version == if versioned { Some(written.version) } else { None }
            && read.notes.as_deref().unwrap_or("") == written.notes.as_deref().unwrap_or("").trim()
    }

    /// split(serialize(cards)) gives the cards back, lineages included.
    fn round_trip(cards: &[CardToWrite]) {
        let text = serialize_cards(cards, SerializeMode::All);
        let read = split_cards(&text);
        assert_eq!(read.len(), cards.len(), "card count after a round trip of:\n{}\n{:#?}", text, read);
        let mut counts: HashMap<&str, usize> = HashMap::new();
        for c in cards {
            *counts.entry(c.lineage_id.as_str()).or_insert(0) += 1;
        }
        for (i, (r, c)) in read.iter().zip(cards).enumerate() {
            assert!(same(r, c, counts[c.lineage_id.as_str()] > 1), "card {} after a round trip of:\n{}\nread {:#?}\nwrote {:#?}", i, text, r, c);
        }
        for i in 1..cards.len() {
            assert_eq!(
                read[i].lineage == read[i - 1].lineage,
                cards[i].lineage_id == cards[i - 1].lineage_id,
                "lineage of card {} after a round trip of:\n{}", i, text
            );
        }
    }

    #[test]
    fn the_documented_form() {
        let cards = vec![
            w(Some("Active users"), 1, true, "SELECT * FROM users", "a"),
            w(Some("Active users"), 2, false, "SELECT * FROM users WHERE active", "a"),
        ];
        assert_eq!(
            serialize_cards(&cards, SerializeMode::All),
            "-- name: Active users\n-- version: 1 locked\n-- SELECT * FROM users\n\n-- name: Active users\n-- version: 2\nSELECT * FROM users WHERE active;\n"
        );
        assert_eq!(serialize_cards(&cards, SerializeMode::Latest), "-- name: Active users\nSELECT * FROM users WHERE active;\n");
        round_trip(&cards);
    }

    #[test]
    fn round_trips() {
        round_trip(&[w(None, 1, false, "SELECT 1", "x")]);
        round_trip(&[w(Some("A"), 1, false, "SELECT 1", "a"), w(None, 1, false, "SELECT 2", "b"), w(Some("A"), 1, false, "SELECT 3", "c")]);
        // Several locked versions, a multi-line one, a blank line inside one.
        round_trip(&[
            w(Some("Q"), 1, true, "SELECT a\nFROM t", "q"),
            w(Some("Q"), 2, true, "SELECT a\n\nFROM t\nWHERE x", "q"),
            w(Some("Q"), 3, false, "SELECT b FROM t", "q"),
            w(None, 1, false, "SELECT 'other'", "o"),
        ]);
        // Every version locked: the last is written live, locked.
        round_trip(&[w(Some("L"), 1, true, "SELECT 1", "l"), w(Some("L"), 2, true, "SELECT 2", "l")]);
        // Unnamed versions.
        round_trip(&[w(None, 1, true, "SELECT 1", "u"), w(None, 2, false, "SELECT 2", "u")]);
        // A card ending in a line comment, one with leading comments, a
        // comment-only notes card, quoted semicolons, a variable token.
        round_trip(&[
            w(Some("C"), 1, false, "SELECT 1 -- note;", "c"),
            w(None, 1, false, "-- monthly totals\nSELECT sum(x) FROM t", "d"),
            w(None, 1, false, "-- just notes\n-- more notes", "n"),
            w(Some("S"), 1, false, "SELECT ';', $$a;b$$, {{v;w}}", "s"),
        ]);
        // psql meta and COPY data are kept as they are.
        round_trip(&[
            meta("\\set x 1", CardKind::PsqlMeta, "m"),
            w(None, 1, false, "SELECT :x", "y"),
            meta("COPY t (a) FROM stdin;\n1\n2\n\\.", CardKind::CopyData, "cp"),
            w(Some("After"), 1, false, "SELECT 2", "z"),
        ]);
        // A BEGIN ATOMIC body.
        round_trip(&[w(Some("F"), 1, false, "CREATE FUNCTION f() RETURNS int LANGUAGE sql\nBEGIN ATOMIC\n  SELECT 1;\nEND", "f")]);
    }

    #[test]
    fn plain_text_splits_into_cards() {
        let text = "-- report.sql\n\nSELECT 1;\nSELECT 2; -- why\n\n/* c */ SELECT 3";
        let cards = split_cards(text);
        let sql: Vec<&str> = cards.iter().map(|c| c.sql.as_str()).collect();
        assert_eq!(sql, vec!["-- report.sql\n\nSELECT 1", "SELECT 2 -- why", "/* c */ SELECT 3"]);
        assert!(cards.iter().all(|c| c.name.is_none() && c.version.is_none() && !c.locked));
        assert_eq!(cards.iter().map(|c| c.lineage).collect::<Vec<_>>(), vec![0, 1, 2]);
        assert_eq!((cards[0].start_line, cards[0].end_line), (3, 3));
        assert_eq!((cards[2].start_line, cards[2].end_line), (6, 6));
    }

    #[test]
    fn headers_are_read_in_any_case_and_spacing() {
        let cards = split_cards("--NAME:  Totals \n--  Version: 3   LOCKED\nSELECT 1;");
        assert_eq!(cards[0].name.as_deref(), Some("Totals"));
        assert_eq!((cards[0].version, cards[0].locked), (Some(3), true));
        assert_eq!(cards[0].sql, "SELECT 1");
    }

    #[test]
    fn comments_before_a_header_are_a_card_of_their_own() {
        let cards = split_cards("-- exported by Pharos\n\n-- name: A\nSELECT 1;");
        assert_eq!(cards.len(), 2);
        assert_eq!(cards[0].sql, "-- exported by Pharos");
        assert_eq!(cards[1].name.as_deref(), Some("A"));
        assert_eq!(cards[1].sql, "SELECT 1");
    }

    #[test]
    fn same_names_without_versions_are_separate_queries() {
        let cards = split_cards("-- name: A\nSELECT 1;\n-- name: A\nSELECT 2;");
        assert_ne!(cards[0].lineage, cards[1].lineage);
    }

    #[test]
    fn names_are_flattened_to_one_line() {
        let text = serialize_cards(&[w(Some("  two\nlines  "), 1, false, "SELECT 1", "a")], SerializeMode::All);
        assert_eq!(text, "-- name: two lines\nSELECT 1;\n");
    }

    #[test]
    fn a_byte_order_mark_is_dropped_and_crlf_kept() {
        let cards = split_cards("\u{feff}SELECT 1;\r\nSELECT\r\n 2;");
        assert_eq!(cards.len(), 2);
        assert_eq!(cards[0].sql, "SELECT 1");
        assert_eq!(cards[1].sql, "SELECT\r\n 2");
    }

    #[test]
    fn nothing_but_whitespace_is_no_cards() {
        assert!(split_cards("  \n ; \n").is_empty());
        assert_eq!(serialize_cards(&[], SerializeMode::All), "");
    }

    #[test]
    fn serialize_loses_no_text() {
        // serialize(split(text)) keeps every non-blank character of the text,
        // header-free text included.
        let text = "-- top\nSELECT 'a;b' FROM t; -- tail\n\\set v 1\nCOPY t FROM STDIN;\n1\n\\.\n/* end */";
        let cards: Vec<CardToWrite> = split_cards(text)
            .into_iter()
            .enumerate()
            .map(|(i, c)| CardToWrite { name: c.name, version: 1, locked: false, sql: c.sql, kind: c.kind, lineage_id: i.to_string(), notes: c.notes })
            .collect();
        let back = serialize_cards(&cards, SerializeMode::All);
        let keep = |s: &str| s.chars().filter(|c| !c.is_whitespace() && *c != ';').collect::<String>();
        assert_eq!(keep(&back), keep(text), "text after a serialize:\n{}", back);
    }

    fn with_notes(mut c: CardToWrite, notes: &str) -> CardToWrite {
        c.notes = Some(notes.to_string());
        c
    }

    #[test]
    fn notes_are_written_as_a_bordered_block_under_the_name() {
        let cards = vec![with_notes(w(Some("New JA4T Fingerprints"), 1, false, "WITH params AS (SELECT 1)\nSELECT * FROM params", "a"),
                                    "Q8. NEW TCP CLIENT FINGERPRINTS\nCompare first_seen with Q2.")];
        let border = "=".repeat(69);
        assert_eq!(NOTES_BORDER, border);
        assert_eq!(
            serialize_cards(&cards, SerializeMode::All),
            format!("-- name: New JA4T Fingerprints\n/*\n{b}\nQ8. NEW TCP CLIENT FINGERPRINTS\nCompare first_seen with Q2.\n{b}\n*/\nWITH params AS (SELECT 1)\nSELECT * FROM params;\n", b = border)
        );
        let read = split_cards(&serialize_cards(&cards, SerializeMode::All));
        assert_eq!(read.len(), 1);
        assert_eq!(read[0].notes.as_deref(), Some("Q8. NEW TCP CLIENT FINGERPRINTS\nCompare first_seen with Q2."));
        assert_eq!(read[0].sql, "WITH params AS (SELECT 1)\nSELECT * FROM params");
        assert_eq!(read[0].start_line, 8);
    }

    #[test]
    fn notes_round_trip() {
        // A name, no name, blank notes (none written), notes with blank lines.
        round_trip(&[
            with_notes(w(Some("A"), 1, false, "SELECT 1", "a"), "one\n\n  two"),
            with_notes(w(None, 1, false, "SELECT 2", "b"), "unnamed"),
            with_notes(w(None, 1, false, "SELECT 3", "c"), "  \n"),
            with_notes(w(Some("Empty"), 1, false, "", "d"), "only notes"),
            with_notes(w(None, 1, false, "-- just a comment", "e"), "and notes"),
        ]);
        // Versions: the notes are written once, with the latest, and come
        // back on every version.
        let q = |v, locked, sql| with_notes(w(Some("Q"), v, locked, sql, "q"), "about Q");
        let cards = vec![q(1, true, "SELECT 1"), q(2, true, "SELECT 2"), q(3, false, "SELECT 3")];
        let text = serialize_cards(&cards, SerializeMode::All);
        assert_eq!(text.matches("about Q").count(), 1, "{}", text);
        assert!(text.find("about Q").unwrap() > text.find("-- version: 3").unwrap(), "{}", text);
        round_trip(&cards);
        let latest = serialize_cards(&cards, SerializeMode::Latest);
        assert_eq!(latest, format!("-- name: Q\n/*\n{b}\nabout Q\n{b}\n*/\nSELECT 3;\n", b = NOTES_BORDER));
    }

    #[test]
    fn comment_marks_in_notes_cannot_close_the_block() {
        let cards = vec![with_notes(w(None, 1, false, "SELECT 1", "a"), "see /* here */ and */ there")];
        let text = serialize_cards(&cards, SerializeMode::All);
        assert!(text.contains("see / * here * / and * / there"), "{}", text);
        let read = split_cards(&text);
        assert_eq!(read.len(), 1);
        assert_eq!(read[0].sql, "SELECT 1");
        assert_eq!(read[0].notes.as_deref(), Some("see / * here * / and * / there"));
    }

    #[test]
    fn only_a_bordered_block_is_read_as_notes() {
        let cards = split_cards("/* just a comment */\nSELECT 1;\n/*\n===\nx\n*/\nSELECT 2;");
        assert_eq!(cards[0].notes, None);
        assert_eq!(cards[0].sql, "/* just a comment */\nSELECT 1");
        assert_eq!(cards[1].notes, None, "one border only");
        // Borders of any length of 3 or more are accepted.
        let cards = split_cards("-- name: N\n/*\n  ===\nhello\n=====\n*/\nSELECT 1;");
        assert_eq!(cards[0].notes.as_deref(), Some("hello"));
        assert_eq!(cards[0].sql, "SELECT 1");
    }

    #[test]
    fn leading_line_comments_become_notes() {
        let border = format!("-- {}", "=".repeat(73));
        let sql = format!(
            "{b}\n-- Q8. NEW TCP CLIENT FINGERPRINTS (JA4T) FROM THE HONEYPOT\n-- The honeypot OS normally makes one or few JA4T values.\n{b}\nWITH params AS (\n    SELECT 1 -- CHANGE: honeypot IP\n)\nSELECT * FROM params",
            b = border
        );
        let (notes, rest) = extract_leading_notes(&sql).unwrap();
        assert_eq!(notes, "Q8. NEW TCP CLIENT FINGERPRINTS (JA4T) FROM THE HONEYPOT\nThe honeypot OS normally makes one or few JA4T values.");
        assert_eq!(rest, "WITH params AS (\n    SELECT 1 -- CHANGE: honeypot IP\n)\nSELECT * FROM params");
    }

    #[test]
    fn leading_block_comments_become_notes() {
        // Pharos's own block.
        let sql = format!("/*\n{b}\nline one\n  indented\n{b}\n*/\nSELECT 1", b = NOTES_BORDER);
        assert_eq!(extract_leading_notes(&sql), Some(("line one\n  indented".to_string(), "SELECT 1".to_string())));
        // A gutter of ` * `.
        let sql = "/**\n * First.\n *\n * Second.\n */\nSELECT 1";
        assert_eq!(extract_leading_notes(sql), Some(("First.\n\nSecond.".to_string(), "SELECT 1".to_string())));
        // One line, and nested comments kept as text.
        assert_eq!(extract_leading_notes("/* a /* b */ c */ SELECT 1"), Some(("a /* b */ c".to_string(), "SELECT 1".to_string())));
        // Indented block lines lose their common indentation.
        assert_eq!(extract_leading_notes("/*\n    a\n      b\n*/\nSELECT 1"), Some(("a\n  b".to_string(), "SELECT 1".to_string())));
    }

    #[test]
    fn mixed_comments_keep_their_paragraphs() {
        let sql = "-- name: Ignored\n-- version: 2\n-- first\n\n\n/* second */\n-- third\nSELECT 1";
        assert_eq!(extract_leading_notes(sql), Some(("first\n\nsecond\nthird".to_string(), "SELECT 1".to_string())));
        let crlf = "-- one\r\n-- two\r\nSELECT 1";
        assert_eq!(extract_leading_notes(crlf), Some(("one\ntwo".to_string(), "SELECT 1".to_string())));
    }

    #[test]
    fn header_lines_inside_notes_stay_notes() {
        let notes = "Cols:\n-- name: customer\n-- version: 2\n  --NAME: x";
        let cards = vec![with_notes(w(Some("Q"), 1, false, "SELECT 1", "q"), notes), w(Some("R"), 1, false, "SELECT 2", "r")];
        round_trip(&cards);
        let read = split_cards(&serialize_cards(&cards, SerializeMode::All));
        assert_eq!(read[0].notes.as_deref(), Some(notes));
        assert_eq!(read[0].name.as_deref(), Some("Q"));
        // A header after a closed block comment is still a header.
        let cards = split_cards("/* c */\n-- name: A\nSELECT 1;");
        assert_eq!(cards.last().unwrap().name.as_deref(), Some("A"));
    }

    #[test]
    fn unicode_indentation_does_not_panic() {
        let sql = "/*\n\u{a0}a\n b\n*/\nSELECT 1";
        let (notes, rest) = extract_leading_notes(sql).unwrap();
        assert_eq!(rest, "SELECT 1");
        assert!(notes.contains('a') && notes.contains('b'), "{:?}", notes);
    }

    #[test]
    fn no_leading_comment_is_no_notes() {
        assert_eq!(extract_leading_notes("SELECT 1 -- trailing"), None);
        assert_eq!(extract_leading_notes("  \n SELECT 1"), None);
        assert_eq!(extract_leading_notes("-- only a comment\n/* and another */"), None, "comment-only");
        assert_eq!(extract_leading_notes("/* never closed\nSELECT 1"), None);
        assert_eq!(extract_leading_notes("-- =====\n-- =====\nSELECT 1"), None, "nothing but borders");
        assert_eq!(extract_leading_notes(""), None);
    }

    #[test]
    fn shared_cases() {
        #[derive(Deserialize)]
        struct Case {
            name: String,
            text: String,
            cards: Vec<Expected>,
        }
        #[derive(Deserialize)]
        #[serde(rename_all = "camelCase")]
        struct Expected {
            name: Option<String>,
            #[serde(default)]
            version: Option<u32>,
            #[serde(default)]
            locked: bool,
            sql: String,
            #[serde(default)]
            kind: CardKind,
            lineage: u32,
        }
        let cases: Vec<Case> = serde_json::from_str(include_str!("testdata/card_split_cases.json")).expect("case file parses");
        assert!(!cases.is_empty());
        for case in cases {
            let got = split_cards(&case.text);
            assert_eq!(got.len(), case.cards.len(), "{}: card count, got {:#?}", case.name, got);
            for (g, e) in got.iter().zip(&case.cards) {
                assert_eq!(
                    (&g.name, g.version, g.locked, g.sql.as_str(), g.kind, g.lineage),
                    (&e.name, e.version, e.locked, e.sql.as_str(), e.kind, e.lineage),
                    "{}", case.name
                );
            }
        }
    }
}
