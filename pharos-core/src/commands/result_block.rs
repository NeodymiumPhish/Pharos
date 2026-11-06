//! The PRB1 columnar result block: the rows of a result as one byte block,
//! the SAME bytes Swift's `ResultTable` (`Pharos/Models/ResultTable.swift`)
//! reads, so a result crosses the FFI without JSON and without a
//! `serde_json::Value` per cell.
//!
//! Little-endian layout:
//!
//! ```text
//! "PRB1" | u32 version (1) | u32 row_count | u32 column_count
//! per column, each part padded to a multiple of 4 bytes:
//!   u32 byte_length | null bitmap, ceil(rows/8) bytes, bit set = NULL
//!   | u32 offsets[rows + 1] | UTF-8 bytes (byte_length)
//! ```
//!
//! Every cell of a real result is text or NULL (PostgreSQL's text format and
//! DuckDB's `::VARCHAR`), so this is the whole of a result's rows. The JSON
//! form, `[[string|null]]`, is still what history and saved Sessions store:
//! `to_json_rows` writes it and `from_json_rows` reads it.

use serde::de::{DeserializeSeed, SeqAccess, Visitor};
use serde::ser::{SerializeSeq, Serializer};
use serde::Serialize;
use std::fmt;

const MAGIC: &[u8; 4] = b"PRB1";
const VERSION: u32 = 1;

fn padded(n: usize) -> usize {
    (n + 3) & !3
}

/// Builds a block cell by cell, row-major.
pub struct ResultBlockBuilder {
    columns: usize,
    bytes: Vec<Vec<u8>>,
    offsets: Vec<Vec<u32>>,
    nulls: Vec<Vec<u8>>,
    rows: usize,
    column: usize,
}

impl ResultBlockBuilder {
    pub fn new(columns: usize) -> Self {
        ResultBlockBuilder {
            columns,
            bytes: vec![Vec::new(); columns],
            offsets: vec![vec![0]; columns],
            nulls: vec![Vec::new(); columns],
            rows: 0,
            column: 0,
        }
    }

    pub fn column_count(&self) -> usize {
        self.columns
    }

    pub fn row_count(&self) -> usize {
        self.rows
    }

    pub fn reserve_rows(&mut self, n: usize) {
        for c in 0..self.columns {
            self.offsets[c].reserve(n);
            self.nulls[c].reserve(n.div_ceil(8));
        }
    }

    /// The next cell of the current row; `None` is NULL.
    pub fn push(&mut self, cell: Option<&str>) {
        self.push_bytes(cell.map(str::as_bytes));
    }

    /// The next cell as bytes, which must be UTF-8 (the text format is).
    pub fn push_bytes(&mut self, cell: Option<&[u8]>) {
        assert!(self.column < self.columns, "more cells than columns");
        let c = self.column;
        if let Some(bytes) = cell {
            self.bytes[c].extend_from_slice(bytes);
        }
        assert!(self.bytes[c].len() <= u32::MAX as usize, "a column holds more than 4 GB of text");
        self.offsets[c].push(self.bytes[c].len() as u32);
        let (byte, bit) = (self.rows >> 3, self.rows & 7);
        if byte >= self.nulls[c].len() {
            self.nulls[c].push(0);
        }
        if cell.is_none() {
            self.nulls[c][byte] |= 1 << bit;
        }
        self.column += 1;
    }

    /// End the current row; cells it did not fill are NULL.
    pub fn end_row(&mut self) {
        while self.column < self.columns {
            self.push_bytes(None);
        }
        self.column = 0;
        self.rows += 1;
    }

    /// The block, exactly sized. A row left open is ended first.
    pub fn finish(mut self) -> Vec<u8> {
        if self.column != 0 {
            self.end_row();
        }
        let bitmap = self.rows.div_ceil(8);
        let size = 16
            + (0..self.columns)
                .map(|c| 4 + padded(bitmap) + 4 * (self.rows + 1) + padded(self.bytes[c].len()))
                .sum::<usize>();
        let mut out = Vec::with_capacity(size);
        out.extend_from_slice(MAGIC);
        out.extend_from_slice(&VERSION.to_le_bytes());
        out.extend_from_slice(&(self.rows as u32).to_le_bytes());
        out.extend_from_slice(&(self.columns as u32).to_le_bytes());
        for c in 0..self.columns {
            out.extend_from_slice(&(self.bytes[c].len() as u32).to_le_bytes());
            let mut nulls = std::mem::take(&mut self.nulls[c]);
            nulls.resize(padded(bitmap), 0);
            out.extend_from_slice(&nulls);
            for offset in &self.offsets[c] {
                out.extend_from_slice(&offset.to_le_bytes());
            }
            let text = std::mem::take(&mut self.bytes[c]);
            let pad = padded(text.len()) - text.len();
            out.extend_from_slice(&text);
            out.extend(std::iter::repeat(0u8).take(pad));
        }
        debug_assert_eq!(out.len(), size);
        out
    }
}

/// A parsed block, borrowing its bytes.
pub struct ResultBlock<'a> {
    data: &'a [u8],
    rows: usize,
    columns: usize,
    /// Per column: (bitmap at, offsets at, text at).
    parts: Vec<(usize, usize, usize)>,
}

impl<'a> ResultBlock<'a> {
    /// Check the whole block once; every later read is in bounds.
    pub fn parse(data: &'a [u8]) -> Result<Self, String> {
        let u32_at = |at: usize| -> Option<usize> {
            data.get(at..at + 4).map(|b| u32::from_le_bytes([b[0], b[1], b[2], b[3]]) as usize)
        };
        if data.len() < 16 || &data[0..4] != MAGIC {
            return Err("not a PRB1 block".into());
        }
        if u32_at(4) != Some(VERSION as usize) {
            return Err(format!("PRB1 version {:?}", u32_at(4)));
        }
        let rows = u32_at(8).unwrap();
        let columns = u32_at(12).unwrap();
        let bitmap = rows.div_ceil(8);
        let mut at = 16;
        let mut parts = Vec::with_capacity(columns);
        for c in 0..columns {
            let length = u32_at(at).ok_or_else(|| format!("column {} is cut short", c))?;
            at += 4;
            let need = padded(bitmap) + 4 * (rows + 1) + padded(length);
            if data.len() - at < need {
                return Err(format!("column {} is cut short", c));
            }
            let bitmap_at = at;
            at += padded(bitmap);
            let offsets_at = at;
            let mut previous = 0;
            for r in 0..=rows {
                let offset = u32_at(offsets_at + 4 * r).unwrap();
                if (r == 0 && offset != 0) || offset < previous {
                    return Err(format!("column {} offsets are out of order at row {}", c, r));
                }
                previous = offset;
            }
            if previous != length {
                return Err(format!("column {} offsets do not end at its length", c));
            }
            at += 4 * (rows + 1);
            let text_at = at;
            if std::str::from_utf8(&data[text_at..text_at + length]).is_err() {
                return Err(format!("column {} is not UTF-8", c));
            }
            at += padded(length);
            parts.push((bitmap_at, offsets_at, text_at));
        }
        if at != data.len() {
            return Err(format!("{} bytes after the last column", data.len() - at));
        }
        Ok(ResultBlock { data, rows, columns, parts })
    }

    pub fn row_count(&self) -> usize {
        self.rows
    }

    pub fn column_count(&self) -> usize {
        self.columns
    }

    /// The cell, `None` for NULL or a column past the last one.
    pub fn cell(&self, row: usize, column: usize) -> Option<&'a str> {
        assert!(row < self.rows, "row {} out of range", row);
        let &(bitmap_at, offsets_at, text_at) = self.parts.get(column)?;
        if self.data[bitmap_at + (row >> 3)] & (1 << (row & 7)) != 0 {
            return None;
        }
        let read = |at: usize| u32::from_le_bytes(self.data[at..at + 4].try_into().unwrap()) as usize;
        let start = read(offsets_at + 4 * row);
        let end = read(offsets_at + 4 * row + 4);
        // `parse` checked each column's text is UTF-8, and offsets fall on
        // the cell boundaries the builder wrote; a cut inside a character
        // would fail here rather than read garbage.
        std::str::from_utf8(&self.data[text_at + start..text_at + end]).ok()
    }
}

/// The rows as JSON `[[string|null]]`, byte for byte what serializing the
/// same cells as `serde_json::Value` strings and nulls gives.
pub struct JsonRows<'b, 'a>(pub &'b ResultBlock<'a>);

impl Serialize for JsonRows<'_, '_> {
    fn serialize<S: Serializer>(&self, serializer: S) -> Result<S::Ok, S::Error> {
        let block = self.0;
        let mut rows = serializer.serialize_seq(Some(block.rows))?;
        for r in 0..block.rows {
            rows.serialize_element(&JsonRow(block, r))?;
        }
        rows.end()
    }
}

struct JsonRow<'b, 'a>(&'b ResultBlock<'a>, usize);

impl Serialize for JsonRow<'_, '_> {
    fn serialize<S: Serializer>(&self, serializer: S) -> Result<S::Ok, S::Error> {
        let (block, r) = (self.0, self.1);
        let mut cells = serializer.serialize_seq(Some(block.columns))?;
        for c in 0..block.columns {
            cells.serialize_element(&block.cell(r, c))?;
        }
        cells.end()
    }
}

/// A result's rows, held as one PRB1 block in place of a `serde_json::Value`
/// per cell (a 32-byte enum plus a heap String each). Serializes as JSON
/// `[[string|null]]`, byte for byte what the `Value` rows wrote, so the FFI
/// and the stored history are unchanged; `block()` is the binary form.
#[derive(Clone, PartialEq)]
pub struct Rows {
    block: Vec<u8>,
    rows: usize,
    columns: usize,
}

impl Rows {
    /// No rows and no columns.
    pub fn empty() -> Rows {
        Rows::from_builder(ResultBlockBuilder::new(0))
    }

    pub fn from_builder(builder: ResultBlockBuilder) -> Rows {
        let (rows, columns) = (builder.row_count(), builder.column_count());
        let block = builder.finish();
        Rows { block, rows, columns }
    }

    /// Wrap a block written elsewhere (Swift), checked once.
    pub fn from_block(block: Vec<u8>) -> Result<Rows, String> {
        let parsed = ResultBlock::parse(&block)?;
        let (rows, columns) = (parsed.row_count(), parsed.column_count());
        Ok(Rows { block, rows, columns })
    }

    pub fn len(&self) -> usize {
        self.rows
    }

    pub fn is_empty(&self) -> bool {
        self.rows == 0
    }

    pub fn column_count(&self) -> usize {
        self.columns
    }

    pub fn block(&self) -> &[u8] {
        &self.block
    }

    pub fn into_block(self) -> Vec<u8> {
        self.block
    }

    /// A reader over the block. The block was checked when this was made.
    pub fn reader(&self) -> ResultBlock<'_> {
        ResultBlock::parse(&self.block).expect("a Rows block is checked when it is made")
    }

    /// One cell, owned. For tests and one-off reads; scans use `reader()`.
    pub fn cell(&self, row: usize, column: usize) -> Option<String> {
        self.reader().cell(row, column).map(str::to_owned)
    }

    /// Every row as JSON values, the pre-block shape. For tests.
    pub fn to_values(&self) -> Vec<serde_json::Value> {
        let reader = self.reader();
        (0..self.rows)
            .map(|r| {
                serde_json::Value::Array(
                    (0..self.columns)
                        .map(|c| reader.cell(r, c).map_or(serde_json::Value::Null, |s| s.into()))
                        .collect(),
                )
            })
            .collect()
    }

    /// Every row as text cells. For callers that hand rows on in batches.
    pub fn to_cells(&self) -> Vec<Vec<Option<String>>> {
        let reader = self.reader();
        (0..self.rows)
            .map(|r| (0..self.columns).map(|c| reader.cell(r, c).map(str::to_owned)).collect())
            .collect()
    }
}

impl fmt::Debug for Rows {
    fn fmt(&self, f: &mut fmt::Formatter<'_>) -> fmt::Result {
        if self.rows <= 20 {
            write!(f, "Rows{:?}", self.to_values())
        } else {
            write!(f, "Rows({} x {}, {} bytes)", self.rows, self.columns, self.block.len())
        }
    }
}

/// Tests compare rows with `vec![json!([...])]`.
impl PartialEq<Vec<serde_json::Value>> for Rows {
    fn eq(&self, other: &Vec<serde_json::Value>) -> bool {
        &self.to_values() == other
    }
}

impl Serialize for Rows {
    fn serialize<S: Serializer>(&self, serializer: S) -> Result<S::Ok, S::Error> {
        JsonRows(&self.reader()).serialize(serializer)
    }
}

impl<'de> serde::Deserialize<'de> for Rows {
    fn deserialize<D: serde::Deserializer<'de>>(d: D) -> Result<Rows, D::Error> {
        let builder = RowsSeed.deserialize(d)?;
        Ok(Rows::from_builder(builder.unwrap_or_else(|| ResultBlockBuilder::new(0))))
    }
}

/// The cells row identity reads: a JSON row list (tests, stored rows) or a
/// block. `None` for NULL, a missing cell or a non-text value.
pub trait KeyCells {
    fn row_count(&self) -> usize;
    fn text(&self, row: usize, column: usize) -> Option<&str>;
}

impl KeyCells for [serde_json::Value] {
    fn row_count(&self) -> usize {
        self.len()
    }
    fn text(&self, row: usize, column: usize) -> Option<&str> {
        self[row].as_array().and_then(|cells| cells.get(column)).and_then(serde_json::Value::as_str)
    }
}

impl KeyCells for Vec<serde_json::Value> {
    fn row_count(&self) -> usize {
        self.len()
    }
    fn text(&self, row: usize, column: usize) -> Option<&str> {
        self.as_slice().text(row, column)
    }
}

impl KeyCells for ResultBlock<'_> {
    fn row_count(&self) -> usize {
        self.rows
    }
    fn text(&self, row: usize, column: usize) -> Option<&str> {
        self.cell(row, column)
    }
}

/// The JSON rows of a block.
pub fn to_json_rows(block: &[u8]) -> Result<String, String> {
    let parsed = ResultBlock::parse(block)?;
    serde_json::to_string(&JsonRows(&parsed)).map_err(|e| e.to_string())
}

/// A block from stored JSON rows `[[string|null]]`, streamed into the builder
/// (no array per row). The first row sets the column count; a later short row
/// is padded with NULL, a longer one is an error.
pub fn from_json_rows(json: &str) -> Result<Vec<u8>, String> {
    let mut de = serde_json::Deserializer::from_str(json);
    let builder = RowsSeed.deserialize(&mut de).map_err(|e| e.to_string())?;
    de.end().map_err(|e| e.to_string())?;
    Ok(builder.unwrap_or_else(|| ResultBlockBuilder::new(0)).finish())
}

struct RowsSeed;

impl<'de> DeserializeSeed<'de> for RowsSeed {
    type Value = Option<ResultBlockBuilder>;
    fn deserialize<D: serde::Deserializer<'de>>(self, d: D) -> Result<Self::Value, D::Error> {
        d.deserialize_seq(RowsVisitor)
    }
}

struct RowsVisitor;

impl<'de> Visitor<'de> for RowsVisitor {
    type Value = Option<ResultBlockBuilder>;
    fn expecting(&self, f: &mut fmt::Formatter) -> fmt::Result {
        f.write_str("an array of rows")
    }
    fn visit_seq<A: SeqAccess<'de>>(self, mut seq: A) -> Result<Self::Value, A::Error> {
        // The first row is read whole to learn the column count.
        let Some(first) = seq.next_element::<Vec<Option<std::borrow::Cow<'de, str>>>>()? else {
            return Ok(None);
        };
        let mut builder = ResultBlockBuilder::new(first.len());
        if let Some(n) = seq.size_hint() {
            builder.reserve_rows(n + 1);
        }
        for cell in &first {
            builder.push(cell.as_deref());
        }
        builder.end_row();
        while seq.next_element_seed(RowSeed(&mut builder))?.is_some() {}
        Ok(Some(builder))
    }
}

struct RowSeed<'b>(&'b mut ResultBlockBuilder);

impl<'de> DeserializeSeed<'de> for RowSeed<'_> {
    type Value = ();
    fn deserialize<D: serde::Deserializer<'de>>(self, d: D) -> Result<(), D::Error> {
        d.deserialize_seq(self)
    }
}

impl<'de> Visitor<'de> for RowSeed<'_> {
    type Value = ();
    fn expecting(&self, f: &mut fmt::Formatter) -> fmt::Result {
        f.write_str("a row of text cells")
    }
    fn visit_seq<A: SeqAccess<'de>>(self, mut seq: A) -> Result<(), A::Error> {
        let builder = self.0;
        let mut n = 0;
        while let Some(cell) = seq.next_element::<Option<std::borrow::Cow<'de, str>>>()? {
            if n == builder.column_count() {
                return Err(serde::de::Error::custom("a row has more cells than the first row"));
            }
            builder.push(cell.as_deref());
            n += 1;
        }
        builder.end_row();
        Ok(())
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    fn sample() -> Vec<Vec<Option<&'static str>>> {
        vec![
            vec![Some("1"), Some("alpha"), None, Some("")],
            vec![Some("2"), None, Some("ünïcødé ✓ 🐘"), Some("x")],
            vec![Some("3"), Some("a\u{0}b"), Some("\t\n\"\\"), None],
        ]
    }

    fn build(rows: &[Vec<Option<&str>>]) -> Vec<u8> {
        let mut b = ResultBlockBuilder::new(rows.iter().map(Vec::len).max().unwrap_or(0));
        for row in rows {
            for cell in row {
                b.push(*cell);
            }
            b.end_row();
        }
        b.finish()
    }

    /// The JSON the pre-block code wrote for the same cells.
    fn value_json(rows: &[Vec<Option<&str>>]) -> String {
        let values: Vec<serde_json::Value> = rows
            .iter()
            .map(|r| {
                serde_json::Value::Array(
                    r.iter()
                        .map(|c| c.map_or(serde_json::Value::Null, |s| serde_json::Value::String(s.into())))
                        .collect(),
                )
            })
            .collect();
        serde_json::to_string(&values).unwrap()
    }

    #[test]
    fn a_block_reads_back_cell_for_cell() {
        let rows = sample();
        let block = build(&rows);
        let parsed = ResultBlock::parse(&block).unwrap();
        assert_eq!((parsed.row_count(), parsed.column_count()), (3, 4));
        for (r, row) in rows.iter().enumerate() {
            for (c, cell) in row.iter().enumerate() {
                assert_eq!(parsed.cell(r, c), *cell, "cell {},{}", r, c);
            }
        }
        assert_eq!(parsed.cell(0, 9), None, "a column past the last reads as NULL");
    }

    #[test]
    fn json_rows_are_byte_for_byte_the_value_json() {
        let rows = sample();
        assert_eq!(to_json_rows(&build(&rows)).unwrap(), value_json(&rows));
        assert_eq!(to_json_rows(&build(&[])).unwrap(), "[]");
    }

    #[test]
    fn stored_json_becomes_the_same_block() {
        let rows = sample();
        let block = build(&rows);
        assert_eq!(from_json_rows(&value_json(&rows)).unwrap(), block);
        assert_eq!(from_json_rows("[]").unwrap(), build(&[]));
        // A short row is padded with NULL; a longer row is refused.
        let padded = from_json_rows(r#"[["a","b"],["c"]]"#).unwrap();
        assert_eq!(ResultBlock::parse(&padded).unwrap().cell(1, 1), None);
        assert!(from_json_rows(r#"[["a"],["b","c"]]"#).is_err());
        assert!(from_json_rows(r#"[[1]]"#).is_err(), "every real cell is text");
    }

    /// The Swift reader checks the same bytes: these are the layout rules
    /// both sides rely on, including the 4-byte padding at every size.
    #[test]
    fn padding_and_size_rules_hold_at_every_edge() {
        for n in 0..=17usize {
            let rows: Vec<Vec<Option<String>>> = (0..n)
                .map(|i| vec![Some("x".repeat(i % 10)), if i % 3 == 0 { None } else { Some("y".into()) }])
                .collect();
            let borrowed: Vec<Vec<Option<&str>>> =
                rows.iter().map(|r| r.iter().map(|c| c.as_deref()).collect()).collect();
            let block = build(&borrowed);
            assert_eq!(block.len() % 4, 0, "{} rows", n);
            let parsed = ResultBlock::parse(&block).unwrap();
            for (r, row) in borrowed.iter().enumerate() {
                for (c, cell) in row.iter().enumerate() {
                    assert_eq!(parsed.cell(r, c), *cell);
                }
            }
        }
    }

    #[test]
    fn a_bad_block_is_an_error() {
        let block = build(&sample());
        assert!(ResultBlock::parse(&[]).is_err());
        let mut b = block.clone();
        b[0] = b'X';
        assert!(ResultBlock::parse(&b).is_err(), "magic");
        let mut b = block.clone();
        b[4] = 2;
        assert!(ResultBlock::parse(&b).is_err(), "version");
        assert!(ResultBlock::parse(&block[..block.len() - 4]).is_err(), "cut short");
        let mut b = block.clone();
        b.extend_from_slice(&[0, 0, 0, 0]);
        assert!(ResultBlock::parse(&b).is_err(), "trailing bytes");
        let mut b = block.clone();
        b[16 + 4 + 4 + 4] = 0xFF;
        assert!(ResultBlock::parse(&b).is_err(), "offsets out of order");
    }

    /// The exact bytes of a tiny block, so a change to the layout on one side
    /// shows here. The Swift harness pins the same bytes
    /// (`PharosTests/ResultTableTests.swift`, "the reference block").
    #[test]
    fn the_reference_block_bytes() {
        let block = build(&[vec![Some("ab"), None], vec![Some(""), Some("é")]]);
        let expected: Vec<u8> = [
            &b"PRB1"[..], &1u32.to_le_bytes(), &2u32.to_le_bytes(), &2u32.to_le_bytes(),
            // column 0: length 2, bitmap 0b00 padded, offsets 0,2,2, "ab" padded
            &2u32.to_le_bytes(), &[0, 0, 0, 0], &0u32.to_le_bytes(), &2u32.to_le_bytes(), &2u32.to_le_bytes(), &[b'a', b'b', 0, 0],
            // column 1: length 2 ("é"), bitmap 0b01 (row 0 NULL), offsets 0,0,2, "é" padded
            &2u32.to_le_bytes(), &[1, 0, 0, 0], &0u32.to_le_bytes(), &0u32.to_le_bytes(), &2u32.to_le_bytes(), &[0xC3, 0xA9, 0, 0],
        ]
        .concat();
        assert_eq!(block, expected);
    }
}
