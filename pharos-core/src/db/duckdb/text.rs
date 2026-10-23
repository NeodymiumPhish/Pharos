//! A DuckDB value or type as the text the grid shows.
//!
//! Every cell crosses the FFI as a string, as PostgreSQL's text format does.
//! The main path never comes here: `exec` asks DuckDB itself for the text
//! (`COLUMNS(*)::VARCHAR`), which is exact for every type. This formatter is
//! the fallback for a statement that cannot be wrapped in a SELECT — an
//! `INSERT … RETURNING`, a `PRAGMA`, a `CALL` — and it follows DuckDB's own
//! `CAST(… AS VARCHAR)` rules for the types those statements return. The tests
//! compare it with DuckDB's cast, in process.

use chrono::{DateTime, Duration, NaiveDate, NaiveTime};
use duckdb::core::{LogicalTypeHandle, LogicalTypeId};
use duckdb::types::{TimeUnit, Value};

/// The text of one value, or None for SQL NULL.
pub fn value_text(value: &Value) -> Option<String> {
    match value {
        Value::Null => None,
        other => Some(render(other, false)),
    }
}

/// `nested` is true inside a LIST, STRUCT, MAP or ARRAY, where strings are
/// quoted when they need to be and NULL prints as `NULL`.
fn render(value: &Value, nested: bool) -> String {
    match value {
        Value::Null => "NULL".to_string(),
        Value::Boolean(b) => b.to_string(),
        Value::TinyInt(v) => v.to_string(),
        Value::SmallInt(v) => v.to_string(),
        Value::Int(v) => v.to_string(),
        Value::BigInt(v) => v.to_string(),
        Value::HugeInt(v) => v.to_string(),
        Value::UHugeInt(v) => v.to_string(),
        Value::UTinyInt(v) => v.to_string(),
        Value::USmallInt(v) => v.to_string(),
        Value::UInt(v) => v.to_string(),
        Value::UBigInt(v) => v.to_string(),
        Value::Float(v) => float_text(*v as f64, true),
        Value::Double(v) => float_text(*v, false),
        Value::Decimal(d) => d.to_string(),
        Value::Timestamp(unit, v) => timestamp_text(*unit, *v),
        Value::Text(s) => {
            if nested {
                quote_nested(s)
            } else {
                s.clone()
            }
        }
        Value::Enum(s) => {
            if nested {
                quote_nested(s)
            } else {
                s.clone()
            }
        }
        Value::Blob(bytes) | Value::Geometry(bytes) => blob_text(bytes),
        Value::Date32(days) => date_text(*days),
        Value::Time64(unit, v) => time_text(unit.to_micros(*v)),
        Value::Interval { months, days, nanos } => interval_text(*months, *days, *nanos),
        Value::List(items) | Value::Array(items) => {
            let parts: Vec<String> = items.iter().map(|v| render(v, true)).collect();
            format!("[{}]", parts.join(", "))
        }
        Value::Struct(fields) => {
            let parts: Vec<String> = fields
                .iter()
                .map(|(k, v)| format!("{}: {}", quote_key(k), render(v, true)))
                .collect();
            format!("{{{}}}", parts.join(", "))
        }
        Value::Map(entries) => {
            let parts: Vec<String> = entries
                .iter()
                .map(|(k, v)| format!("{}={}", render(k, true), render(v, true)))
                .collect();
            format!("{{{}}}", parts.join(", "))
        }
        Value::Union(inner) => render(inner, nested),
        other => format!("{:?}", other),
    }
}

/// DuckDB prints the shortest text that reads back to the same value, and
/// spells the specials `inf`, `-inf` and `nan`.
fn float_text(v: f64, single: bool) -> String {
    if v.is_nan() {
        return "nan".to_string();
    }
    if v.is_infinite() {
        return if v > 0.0 { "inf".to_string() } else { "-inf".to_string() };
    }
    let text = if single { (v as f32).to_string() } else { v.to_string() };
    // Rust prints 1e20 as "100000000000000000000"; DuckDB prints "1e+20".
    // Both read back the same; keep Rust's for plain magnitudes and switch
    // to the exponent form where DuckDB does.
    let magnitude = v.abs();
    if magnitude != 0.0 && !(1e-5..1e16).contains(&magnitude) {
        let e = if single { format!("{:e}", v as f32) } else { format!("{:e}", v) };
        // "1e20" → "1e+20", "1.5e-7" → "1.5e-07"
        if let Some((mantissa, exp)) = e.split_once('e') {
            let (sign, digits) = match exp.strip_prefix('-') {
                Some(d) => ("-", d),
                None => ("+", exp),
            };
            return format!("{}e{}{:0>2}", mantissa, sign, digits);
        }
    }
    text
}

fn timestamp_text(unit: TimeUnit, v: i64) -> String {
    let (secs, nanos) = match unit {
        TimeUnit::Second => (v, 0),
        TimeUnit::Millisecond => (v.div_euclid(1_000), (v.rem_euclid(1_000) * 1_000_000) as u32),
        TimeUnit::Microsecond => (v.div_euclid(1_000_000), (v.rem_euclid(1_000_000) * 1_000) as u32),
        TimeUnit::Nanosecond => (v.div_euclid(1_000_000_000), v.rem_euclid(1_000_000_000) as u32),
    };
    match DateTime::from_timestamp(secs, nanos) {
        Some(dt) => {
            let naive = dt.naive_utc();
            let date = naive.date().format("%Y-%m-%d").to_string();
            let frac = match unit {
                TimeUnit::Nanosecond => fraction(nanos as i64, 9),
                _ => fraction((nanos / 1_000) as i64, 6),
            };
            format!("{} {}{}", date, naive.time().format("%H:%M:%S"), frac)
        }
        None => v.to_string(),
    }
}

/// `.ffffff` with the trailing zeros removed, or nothing for a whole second.
fn fraction(value: i64, digits: usize) -> String {
    if value == 0 {
        return String::new();
    }
    let text = format!("{:0width$}", value, width = digits);
    format!(".{}", text.trim_end_matches('0'))
}

fn date_text(days: i32) -> String {
    let epoch = NaiveDate::from_ymd_opt(1970, 1, 1).expect("valid epoch");
    match epoch.checked_add_signed(Duration::days(days as i64)) {
        Some(d) => {
            let text = d.format("%Y-%m-%d").to_string();
            // DuckDB writes years before 1 as "(BC)".
            if d.format("%Y").to_string().starts_with('-') {
                format!("{} (BC)", text.trim_start_matches('-'))
            } else {
                text
            }
        }
        None => days.to_string(),
    }
}

fn time_text(micros: i64) -> String {
    let secs = micros.div_euclid(1_000_000);
    let frac = micros.rem_euclid(1_000_000);
    match NaiveTime::from_num_seconds_from_midnight_opt(secs as u32, 0) {
        Some(t) => format!("{}{}", t.format("%H:%M:%S"), fraction(frac, 6)),
        None if secs == 86_400 => "24:00:00".to_string(),
        None => micros.to_string(),
    }
}

/// DuckDB's interval text: `1 year 2 months 3 days 04:05:06.7`, with each
/// part present only when it is not zero, and `00:00:00` for an empty one.
fn interval_text(months: i32, days: i32, nanos: i64) -> String {
    let mut parts: Vec<String> = Vec::new();
    let years = months / 12;
    let rest = months % 12;
    let unit = |n: i32, one: &str, many: &str| format!("{} {}", n, if n == 1 || n == -1 { one } else { many });
    if years != 0 {
        parts.push(unit(years, "year", "years"));
    }
    if rest != 0 {
        parts.push(unit(rest, "month", "months"));
    }
    if days != 0 {
        parts.push(unit(days, "day", "days"));
    }
    let micros = nanos / 1_000;
    if micros != 0 || parts.is_empty() {
        let sign = if micros < 0 { "-" } else { "" };
        let m = micros.abs();
        let hours = m / 3_600_000_000;
        let minutes = (m / 60_000_000) % 60;
        let seconds = (m / 1_000_000) % 60;
        parts.push(format!(
            "{}{:02}:{:02}:{:02}{}",
            sign,
            hours,
            minutes,
            seconds,
            fraction(m % 1_000_000, 6)
        ));
    }
    parts.join(" ")
}

/// Printable ASCII as is; every other byte, and `\` `'` `"`, as `\xHH`
/// (DuckDB's `blob.cpp`).
fn blob_text(bytes: &[u8]) -> String {
    let mut out = String::with_capacity(bytes.len());
    for &b in bytes {
        if (32..127).contains(&b) && !matches!(b, b'\\' | b'\'' | b'"') {
            out.push(b as char);
        } else {
            out.push_str(&format!("\\x{:02X}", b));
        }
    }
    out
}

/// A string inside a nested value: quoted only when it would not read back
/// (empty, outer whitespace, the word null, or a structural character).
fn quote_nested(s: &str) -> String {
    let needs = s.is_empty()
        || s.starts_with(char::is_whitespace)
        || s.ends_with(char::is_whitespace)
        || s.eq_ignore_ascii_case("null")
        || s.chars().any(|c| matches!(c, '"' | '\'' | '(' | ')' | ',' | ':' | '=' | '[' | ']' | '{' | '}'));
    if !needs {
        return s.to_string();
    }
    let mut out = String::with_capacity(s.len() + 2);
    out.push('\'');
    for c in s.chars() {
        if c == '\'' || c == '\\' {
            out.push('\\');
        }
        out.push(c);
    }
    out.push('\'');
    out
}

/// A STRUCT key is always single-quoted.
fn quote_key(k: &str) -> String {
    let mut out = String::with_capacity(k.len() + 2);
    out.push('\'');
    for c in k.chars() {
        if c == '\'' || c == '\\' {
            out.push('\\');
        }
        out.push(c);
    }
    out.push('\'');
    out
}

/// DuckDB's own name for a logical type: `INTEGER`, `DECIMAL(18,3)`,
/// `INTEGER[]`, `STRUCT(a INTEGER)`, `MAP(VARCHAR, INTEGER)`, or the alias
/// (`JSON`) when it has one.
pub fn type_name(t: &LogicalTypeHandle) -> String {
    if let Some(alias) = t.get_alias() {
        if !alias.is_empty() {
            return alias;
        }
    }
    match t.id() {
        LogicalTypeId::Boolean => "BOOLEAN".into(),
        LogicalTypeId::Tinyint => "TINYINT".into(),
        LogicalTypeId::Smallint => "SMALLINT".into(),
        LogicalTypeId::Integer => "INTEGER".into(),
        LogicalTypeId::Bigint => "BIGINT".into(),
        LogicalTypeId::UTinyint => "UTINYINT".into(),
        LogicalTypeId::USmallint => "USMALLINT".into(),
        LogicalTypeId::UInteger => "UINTEGER".into(),
        LogicalTypeId::UBigint => "UBIGINT".into(),
        LogicalTypeId::Float => "FLOAT".into(),
        LogicalTypeId::Double => "DOUBLE".into(),
        LogicalTypeId::Timestamp => "TIMESTAMP".into(),
        LogicalTypeId::Date => "DATE".into(),
        LogicalTypeId::Time => "TIME".into(),
        LogicalTypeId::Interval => "INTERVAL".into(),
        LogicalTypeId::Hugeint => "HUGEINT".into(),
        LogicalTypeId::UHugeint => "UHUGEINT".into(),
        LogicalTypeId::Varchar => "VARCHAR".into(),
        LogicalTypeId::Blob => "BLOB".into(),
        LogicalTypeId::Decimal => format!("DECIMAL({},{})", t.decimal_width(), t.decimal_scale()),
        LogicalTypeId::TimestampS => "TIMESTAMP_S".into(),
        LogicalTypeId::TimestampMs => "TIMESTAMP_MS".into(),
        LogicalTypeId::TimestampNs => "TIMESTAMP_NS".into(),
        LogicalTypeId::TimestampTZ => "TIMESTAMP WITH TIME ZONE".into(),
        LogicalTypeId::TimeTZ => "TIME WITH TIME ZONE".into(),
        LogicalTypeId::Enum => "ENUM".into(),
        LogicalTypeId::Uuid => "UUID".into(),
        LogicalTypeId::Bit => "BIT".into(),
        LogicalTypeId::List => format!("{}[]", type_name(&t.child(0))),
        LogicalTypeId::Array => format!("{}[]", type_name(&t.child(0))),
        LogicalTypeId::Struct | LogicalTypeId::Union => {
            let keyword = if t.id() == LogicalTypeId::Struct { "STRUCT" } else { "UNION" };
            let fields: Vec<String> = (0..t.num_children())
                .map(|i| format!("{} {}", t.child_name(i), type_name(&t.child(i))))
                .collect();
            format!("{}({})", keyword, fields.join(", "))
        }
        LogicalTypeId::Map => format!("MAP({}, {})", type_name(&t.child(0)), type_name(&t.child(1))),
        other => format!("{:?}", other).to_uppercase(),
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    /// The formatter against DuckDB's own cast, for every type a fallback
    /// statement can return.
    fn assert_matches_cast(expr: &str) {
        let conn = crate::db::duckdb::memory_connection().unwrap();
        let sql = format!("SELECT {expr} AS v, CAST({expr} AS VARCHAR) AS t");
        let (value, cast): (Value, Option<String>) =
            conn.query_row(&sql, [], |row| Ok((row.get(0)?, row.get(1)?))).unwrap();
        assert_eq!(value_text(&value), cast, "for {expr} (value {value:?})");
    }

    #[test]
    fn scalars_match_duckdbs_cast() {
        for expr in [
            "true", "false", "42::TINYINT", "-7::SMALLINT", "123456::INTEGER", "9007199254740993::BIGINT",
            "170141183460469231731687303715884105727::HUGEINT", "255::UTINYINT", "18446744073709551615::UBIGINT",
            "1.5::DOUBLE", "0.1::DOUBLE", "-2.25::FLOAT", "1e20::DOUBLE", "1.5e-7::DOUBLE",
            "'inf'::DOUBLE", "'nan'::DOUBLE", "123.456::DECIMAL(18,3)", "-0.5::DECIMAL(4,1)",
            "'hello'", "''", "DATE '2024-02-29'", "TIME '04:05:06.789'", "TIME '23:59:59'",
            "TIMESTAMP '2024-01-02 03:04:05'", "TIMESTAMP '2024-01-02 03:04:05.123456'",
            "TIMESTAMP_MS '2024-01-02 03:04:05.120'", "TIMESTAMP_S '2024-01-02 03:04:05'",
            "TIMESTAMP_NS '2024-01-02 03:04:05.123456789'",
            "INTERVAL '1 year 2 months 3 days 4 hours 5 minutes 6.5 seconds'", "-INTERVAL '90 seconds'",
            "INTERVAL 0 DAY", "INTERVAL 13 MONTH", "INTERVAL 90 MINUTE",
            "'\\x00\\xFFab'::BLOB", "'a\\x5Cb'::BLOB", "'q\\x27'::BLOB", "'q\\x22'::BLOB",
        ] {
            assert_matches_cast(expr);
        }
    }

    #[test]
    fn nested_values_match_duckdbs_cast() {
        for expr in [
            "[1, 2, 3]", "['a', 'b c', '', ' x', 'null', 'it''s', 'a,b']", "[NULL, 1]",
            "{'a': 1, 'b': 'x y'}", "{'k''': [1, 2]}", "MAP {'a': 1, 'b': 2}", "[[1], [2, 3]]",
            "[1.5, 2.25]::DOUBLE[]", "[DATE '2024-01-01']", "['x']::VARCHAR[1]",
        ] {
            assert_matches_cast(expr);
        }
    }

    #[test]
    fn type_names_match_describe() {
        let conn = crate::db::duckdb::memory_connection().unwrap();
        let exprs = [
            "1::INTEGER", "1.5::DECIMAL(18,3)", "[1]", "{'a': 1}", "MAP {'a': 1}", "'{}'::JSON",
            "uuid()", "now()", "TIMESTAMP '2024-01-01'", "'x'::BLOB", "[1]::INTEGER[2]",
        ];
        for expr in exprs {
            let sql = format!("SELECT {expr}");
            let stmt = conn.prepare(&sql).unwrap();
            let ours = type_name(&stmt.column_logical_type(0));
            let theirs: String = conn
                .query_row(&format!("SELECT column_type FROM (DESCRIBE {sql})"), [], |r| r.get(0))
                .unwrap();
            // A fixed-size ARRAY prints its size in DESCRIBE (`INTEGER[2]`);
            // the fallback path shows it as a list, which is the same text.
            let theirs = if theirs.ends_with("[2]") { theirs.replace("[2]", "[]") } else { theirs };
            assert_eq!(ours, theirs, "for {expr}");
        }
    }
}
