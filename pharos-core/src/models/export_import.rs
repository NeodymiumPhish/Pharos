use serde::{Deserialize, Serialize};

// The one CSV dialect, shared by export and import.
//
// Every default below is what the app did BEFORE this struct existed, so a
// user who never opens Settings ▸ Export & Import gets byte-identical files:
//
//   delimiter        `Comma`   — `commands/table.rs`, the CSV/TSV export branch
//                                picked `b','` for every format but TSV.
//   custom_delimiter `,`       — unused unless `delimiter` is `Custom`.
//   quote_char       `"`       — `escape_csv_field` wrapped a field in `"` and
//                                doubled an interior `"`.
//   quote_style      `Minimal` — `escape_csv_field` quoted ONLY when the field
//                                held the delimiter, a quote, `\n` or `\r`.
//   null_literal     empty     — the export sheet's NULL popup opened on
//                                "Empty string" (`ExportDataSheet.swift`), and
//                                the importer bound `None` for an empty field.
//   encoding         `Utf8`    — `writeln!` wrote raw UTF-8 with no BOM.
//
// Mirrors `CsvDialect` in `Pharos/Models/Settings.swift`. Both sides use
// camelCase on the wire.

/// The file formats "Export Data…" offers, in the order the popup lists them.
///
/// Lives here rather than beside the export engine because `AppSettings`
/// names it: `data_export.default_format` is the format the sheet opens on.
/// Mirrors `ExportFormat` in `Pharos/Models/Settings.swift`.
#[derive(Debug, Clone, Copy, Default, Serialize, Deserialize, PartialEq, Eq)]
#[serde(rename_all = "camelCase")]
pub enum ExportFormat {
    #[default]
    Csv,
    Tsv,
    Json,
    JsonLines,
    SqlInsert,
    Markdown,
    Xlsx,
}

/// The field separator. `Custom` reads `CsvDialect::custom_delimiter`.
#[derive(Debug, Clone, Copy, Default, Serialize, Deserialize, PartialEq, Eq)]
#[serde(rename_all = "camelCase")]
pub enum CsvDelimiter {
    #[default]
    Comma,
    Semicolon,
    Tab,
    Pipe,
    Custom,
}

/// When a field is wrapped in the quote character.
#[derive(Debug, Clone, Copy, Default, Serialize, Deserialize, PartialEq, Eq)]
#[serde(rename_all = "camelCase")]
pub enum CsvQuoteStyle {
    /// Only when the field holds the delimiter, the quote, `\n` or `\r`.
    #[default]
    Minimal,
    /// Every field, on every row, including the header.
    Always,
    /// Never — the writer escapes nothing, so this only suits data that
    /// cannot hold the delimiter.
    Never,
}

/// How the bytes of the file are encoded.
#[derive(Debug, Clone, Copy, Default, Serialize, Deserialize, PartialEq, Eq)]
#[serde(rename_all = "camelCase")]
pub enum CsvEncoding {
    /// Raw UTF-8, no byte-order mark.
    #[default]
    Utf8,
    /// UTF-8 behind `EF BB BF`, which is what Excel on Windows wants.
    Utf8Bom,
    /// UTF-16 little-endian behind `FF FE`.
    Utf16Le,
    /// ISO-8859-1. A character above U+00FF cannot be written and is
    /// replaced; the export reports how many times that happened.
    Latin1,
}

/// What a failing row does to the rest of a CSV import.
#[derive(Debug, Clone, Copy, Default, Serialize, Deserialize, PartialEq, Eq)]
#[serde(rename_all = "camelCase")]
pub enum ImportErrorPolicy {
    /// Roll the whole import back and report the row that failed. This is
    /// what `commands/table.rs` did before the setting existed.
    #[default]
    Abort,
    /// Roll back just that row (a `SAVEPOINT` per row) and carry on.
    SkipRow,
}

fn default_custom_delimiter() -> String {
    ",".to_string()
}

fn default_quote_char() -> String {
    "\"".to_string()
}

/// The shape of a CSV file: what separates fields, what quotes them, what a
/// NULL looks like and how the bytes are encoded.
#[derive(Debug, Clone, Serialize, Deserialize, PartialEq, Eq)]
#[serde(rename_all = "camelCase")]
pub struct CsvDialect {
    #[serde(default)]
    pub delimiter: CsvDelimiter,
    /// The separator when `delimiter` is `Custom`. Only its first byte is
    /// used, and a non-ASCII or empty value falls back to a comma.
    #[serde(default = "default_custom_delimiter")]
    pub custom_delimiter: String,
    /// The quote character. Only its first byte is used; a non-ASCII or empty
    /// value falls back to `"`.
    #[serde(default = "default_quote_char")]
    pub quote_char: String,
    #[serde(default)]
    pub quote_style: CsvQuoteStyle,
    /// What a NULL is written as, and what an imported field must equal to
    /// become a real NULL. Empty is the historical behaviour.
    #[serde(default)]
    pub null_literal: String,
    #[serde(default)]
    pub encoding: CsvEncoding,
}

impl Default for CsvDialect {
    fn default() -> Self {
        CsvDialect {
            delimiter: CsvDelimiter::Comma,
            custom_delimiter: default_custom_delimiter(),
            quote_char: default_quote_char(),
            quote_style: CsvQuoteStyle::Minimal,
            null_literal: String::new(),
            encoding: CsvEncoding::Utf8,
        }
    }
}

impl CsvDialect {
    /// The separator byte. A `Custom` value that is empty or not a single
    /// ASCII byte falls back to a comma rather than failing the export: the
    /// user asked for a file, not for a lecture about their delimiter.
    pub fn delimiter_byte(&self) -> u8 {
        match self.delimiter {
            CsvDelimiter::Comma => b',',
            CsvDelimiter::Semicolon => b';',
            CsvDelimiter::Tab => b'\t',
            CsvDelimiter::Pipe => b'|',
            CsvDelimiter::Custom => first_ascii_byte(&self.custom_delimiter).unwrap_or(b','),
        }
    }

    /// The quote byte, `"` when the setting is empty or not one ASCII byte.
    pub fn quote_byte(&self) -> u8 {
        first_ascii_byte(&self.quote_char).unwrap_or(b'"')
    }
}

/// The first byte of `value`, if `value` is exactly one ASCII character.
fn first_ascii_byte(value: &str) -> Option<u8> {
    let mut chars = value.chars();
    let first = chars.next()?;
    if chars.next().is_some() || !first.is_ascii() {
        return None;
    }
    Some(first as u8)
}

/// Encode `text` for `encoding`, counting characters Latin-1 cannot carry.
///
/// Called per batch, never per file, so it must be safe to split a document
/// at a record boundary: UTF-8 and UTF-16 code units are whole within a
/// batch, and the byte-order mark is written once, by the caller.
pub fn encode_csv_chunk(text: &str, encoding: CsvEncoding, substitutions: &mut u64) -> Vec<u8> {
    match encoding {
        CsvEncoding::Utf8 | CsvEncoding::Utf8Bom => text.as_bytes().to_vec(),
        CsvEncoding::Utf16Le => {
            let mut out = Vec::with_capacity(text.len() * 2);
            for unit in text.encode_utf16() {
                out.extend_from_slice(&unit.to_le_bytes());
            }
            out
        }
        CsvEncoding::Latin1 => {
            let mut out = Vec::with_capacity(text.len());
            for ch in text.chars() {
                let code = ch as u32;
                if code <= 0xFF {
                    out.push(code as u8);
                } else {
                    out.push(b'?');
                    *substitutions += 1;
                }
            }
            out
        }
    }
}

/// The bytes that open a file in `encoding`, if any.
pub fn encoding_bom(encoding: CsvEncoding) -> &'static [u8] {
    match encoding {
        CsvEncoding::Utf8 => &[],
        CsvEncoding::Utf8Bom => &[0xEF, 0xBB, 0xBF],
        CsvEncoding::Utf16Le => &[0xFF, 0xFE],
        CsvEncoding::Latin1 => &[],
    }
}

/// Decode a whole CSV file's bytes into text, honouring a byte-order mark
/// first and `encoding` only when no mark says otherwise.
///
/// A mark WINS: a file that opens `FF FE` is UTF-16LE whatever the setting
/// says, so a user who exported as UTF-16LE and imports the file back does
/// not have to change the setting twice.
pub fn decode_csv_bytes(bytes: &[u8], encoding: CsvEncoding) -> Result<String, String> {
    if bytes.starts_with(&[0xEF, 0xBB, 0xBF]) {
        return String::from_utf8(bytes[3..].to_vec())
            .map_err(|e| format!("File is not valid UTF-8: {}", e));
    }
    if bytes.starts_with(&[0xFF, 0xFE]) {
        return decode_utf16_le(&bytes[2..]);
    }
    match encoding {
        CsvEncoding::Utf16Le => decode_utf16_le(bytes),
        CsvEncoding::Latin1 => Ok(bytes.iter().map(|b| *b as char).collect()),
        CsvEncoding::Utf8 | CsvEncoding::Utf8Bom => String::from_utf8(bytes.to_vec())
            .map_err(|e| format!("File is not valid UTF-8: {}", e)),
    }
}

fn decode_utf16_le(bytes: &[u8]) -> Result<String, String> {
    if bytes.len() % 2 != 0 {
        return Err("File is not valid UTF-16LE: odd number of bytes".to_string());
    }
    let units: Vec<u16> = bytes
        .chunks_exact(2)
        .map(|pair| u16::from_le_bytes([pair[0], pair[1]]))
        .collect();
    String::from_utf16(&units).map_err(|e| format!("File is not valid UTF-16LE: {}", e))
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn default_dialect_is_todays_behaviour() {
        let dialect = CsvDialect::default();
        assert_eq!(dialect.delimiter_byte(), b',');
        assert_eq!(dialect.quote_byte(), b'"');
        assert_eq!(dialect.quote_style, CsvQuoteStyle::Minimal);
        assert_eq!(dialect.null_literal, "");
        assert_eq!(dialect.encoding, CsvEncoding::Utf8);
        assert!(encoding_bom(dialect.encoding).is_empty());
    }

    #[test]
    fn custom_delimiter_falls_back_when_unusable() {
        let mut dialect = CsvDialect {
            delimiter: CsvDelimiter::Custom,
            custom_delimiter: "~".to_string(),
            ..CsvDialect::default()
        };
        assert_eq!(dialect.delimiter_byte(), b'~');
        dialect.custom_delimiter = String::new();
        assert_eq!(dialect.delimiter_byte(), b',');
        dialect.custom_delimiter = "ab".to_string();
        assert_eq!(dialect.delimiter_byte(), b',');
        dialect.custom_delimiter = "£".to_string();
        assert_eq!(dialect.delimiter_byte(), b',');
    }

    #[test]
    fn utf16le_encodes_two_bytes_per_unit() {
        let mut subs = 0;
        let bytes = encode_csv_chunk("aé", CsvEncoding::Utf16Le, &mut subs);
        assert_eq!(bytes, vec![0x61, 0x00, 0xE9, 0x00]);
        assert_eq!(subs, 0);
    }

    #[test]
    fn latin1_substitutes_and_counts() {
        let mut subs = 0;
        let bytes = encode_csv_chunk("aé€b", CsvEncoding::Latin1, &mut subs);
        assert_eq!(bytes, vec![b'a', 0xE9, b'?', b'b']);
        assert_eq!(subs, 1);
    }

    #[test]
    fn decode_prefers_the_byte_order_mark() {
        let utf8_bom = [0xEF, 0xBB, 0xBF, b'a', b',', b'b'];
        assert_eq!(decode_csv_bytes(&utf8_bom, CsvEncoding::Latin1).unwrap(), "a,b");
        let utf16 = [0xFF, 0xFE, 0x61, 0x00, 0x2C, 0x00, 0x62, 0x00];
        assert_eq!(decode_csv_bytes(&utf16, CsvEncoding::Utf8).unwrap(), "a,b");
    }

    #[test]
    fn latin1_round_trips_through_decode() {
        let mut subs = 0;
        let bytes = encode_csv_chunk("café", CsvEncoding::Latin1, &mut subs);
        assert_eq!(decode_csv_bytes(&bytes, CsvEncoding::Latin1).unwrap(), "café");
    }
}
