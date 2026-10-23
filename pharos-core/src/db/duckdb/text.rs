//! A DuckDB value or type as the text the grid shows.
//!
//! Every cell crosses the FFI as a string, as PostgreSQL's text format does.
//! The main path never comes here: `exec` asks DuckDB itself for the text
//! (`COLUMNS(*)::VARCHAR`), which is exact for every type. This formatter is
//! the fallback for a statement that cannot be wrapped in a SELECT — an
//! `INSERT … RETURNING`, a `PRAGMA`, a `CALL` — and it follows DuckDB's own
//! `CAST(… AS VARCHAR)` rules for the types those statements return. The tests
//! compare it with DuckDB's cast, in process.

use std::net::Ipv4Addr;

use chrono::{DateTime, Duration, NaiveDate, NaiveTime};
use duckdb::core::{LogicalTypeHandle, LogicalTypeId};
use duckdb::types::{OrderedMap, TimeUnit, Value};

/// The text of one value, or None for SQL NULL.
pub fn value_text(value: &Value) -> Option<String> {
    match value {
        Value::Null => None,
        other => Some(render(other, None, false)),
    }
}

/// The text of one value of a known column type. The type matters for an
/// alias type whose `Value` is its storage, not its text: an `INET` arrives
/// as the STRUCT it is stored as.
pub fn typed_value_text(value: &Value, ty: &LogicalTypeHandle) -> Option<String> {
    match value {
        Value::Null => None,
        other => Some(render(other, Some(ty), false)),
    }
}

/// `nested` is true inside a LIST, STRUCT, MAP or ARRAY, where strings are
/// quoted when they need to be and NULL prints as `NULL`. `ty`, when known,
/// is the value's logical type.
fn render(value: &Value, ty: Option<&LogicalTypeHandle>, nested: bool) -> String {
    if let (Some(t), Value::Struct(fields)) = (ty, value) {
        if t.get_alias().as_deref() == Some("INET") {
            if let Some(text) = inet_text(fields) {
                return text;
            }
        }
    }
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
            let item = child(ty, &[LogicalTypeId::List, LogicalTypeId::Array], 0);
            let parts: Vec<String> = items.iter().map(|v| render(v, item.as_ref(), true)).collect();
            format!("[{}]", parts.join(", "))
        }
        Value::Struct(fields) => {
            let parts: Vec<String> = fields
                .iter()
                .enumerate()
                .map(|(i, (k, v))| {
                    let field = child(ty, &[LogicalTypeId::Struct], i);
                    format!("{}: {}", quote_key(k), render(v, field.as_ref(), true))
                })
                .collect();
            format!("{{{}}}", parts.join(", "))
        }
        Value::Map(entries) => {
            let key = child(ty, &[LogicalTypeId::Map], 0);
            let val = child(ty, &[LogicalTypeId::Map], 1);
            let parts: Vec<String> = entries
                .iter()
                .map(|(k, v)| format!("{}={}", render(k, key.as_ref(), true), render(v, val.as_ref(), true)))
                .collect();
            format!("{{{}}}", parts.join(", "))
        }
        // The Value does not say which member it holds, so its type is unknown.
        Value::Union(inner) => render(inner, None, nested),
        other => format!("{:?}", other),
    }
}

/// Child `idx` of `ty` when `ty` is one of `ids` and has that child. A
/// handle that does not match the value (it never should) gives None, so the
/// value prints untyped instead of panicking in `child`.
fn child(ty: Option<&LogicalTypeHandle>, ids: &[LogicalTypeId], idx: usize) -> Option<LogicalTypeHandle> {
    let t = ty?;
    (ids.contains(&t.id()) && idx < t.num_children()).then(|| t.child(idx))
}

/// The inet extension's text for its `INET` struct (`ip_type`, `address`,
/// `mask`): the address, then `/mask` unless the mask covers every bit.
/// IPv6 `address` is the 128-bit value with its top bit flipped (`::` is the
/// smallest HUGEINT). None when the fields are not that shape.
fn inet_text(fields: &OrderedMap<String, Value>) -> Option<String> {
    let int = |name: &str| -> Option<i128> {
        match fields.get(&name.to_string())? {
            Value::TinyInt(v) => Some(*v as i128),
            Value::UTinyInt(v) => Some(*v as i128),
            Value::SmallInt(v) => Some(*v as i128),
            Value::USmallInt(v) => Some(*v as i128),
            Value::Int(v) => Some(*v as i128),
            Value::UInt(v) => Some(*v as i128),
            Value::BigInt(v) => Some(*v as i128),
            Value::UBigInt(v) => Some(*v as i128),
            Value::HugeInt(v) => Some(*v),
            _ => None,
        }
    };
    let address = int("address")?;
    let mask = int("mask")?;
    let (text, bits) = match int("ip_type")? {
        1 => (Ipv4Addr::from(u32::try_from(address).ok()?).to_string(), 32),
        2 => (ipv6_text((address as u128) ^ (1u128 << 127)), 128),
        _ => return None,
    };
    Some(if mask == bits { text } else { format!("{}/{}", text, mask) })
}

/// The inet extension's `ToStringIPv6` (its `ipaddress.cpp`), which is not
/// Rust's `Ipv6Addr` text: the longest run of two or more zero groups (the
/// left-most on a tie) becomes `::`, and three forms end in a dotted IPv4
/// address — `::a.b.c.d` (but not when the last group is 1, so `::0.1.0.1`
/// prints `::1:1`), `::ffff:a.b.c.d`, and `::ffff:0:a.b.c.d`.
fn ipv6_text(bits: u128) -> String {
    let groups: [u16; 8] = std::array::from_fn(|i| (bits >> (112 - 16 * i)) as u16);
    let (mut start, mut len) = (0, 0);
    let mut i = 0;
    while i < 8 {
        if groups[i] != 0 {
            i += 1;
            continue;
        }
        let run_start = i;
        while i < 8 && groups[i] == 0 {
            i += 1;
        }
        if i - run_start > 1 && i - run_start > len {
            (start, len) = (run_start, i - run_start);
        }
    }
    let end = start + len;
    let dotted_tail = start == 0
        && ((end == 6 && groups[7] != 1)
            || (end == 5 && groups[5] == 0xffff)
            || (end == 4 && groups[4] == 0xffff && groups[5] == 0));
    let mut out = String::new();
    let mut i = 0;
    while i < 8 {
        if i > 0 {
            out.push(':');
        }
        if (start..end).contains(&i) {
            if i == 0 {
                out.push(':');
            }
            i = end - 1;
            if i == 7 {
                out.push(':');
            }
        } else if i == 6 && dotted_tail {
            out.push_str(&Ipv4Addr::from(bits as u32).to_string());
            break;
        } else {
            out.push_str(&format!("{:x}", groups[i]));
        }
        i += 1;
    }
    out
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
    /// It reads the column's type as `exec`'s fallback does, so an alias
    /// type (INET) is checked as the grid shows it.
    fn assert_matches_cast(expr: &str) {
        let conn = crate::db::duckdb::memory_connection().unwrap();
        let sql = format!("SELECT {expr} AS v, CAST({expr} AS VARCHAR) AS t");
        let mut stmt = conn.prepare(&sql).unwrap();
        let (value, cast): (Value, Option<String>) =
            stmt.query_row([], |row| Ok((row.get(0)?, row.get(1)?))).unwrap();
        let ty = stmt.column_logical_type(0);
        assert_eq!(typed_value_text(&value, &ty), cast, "for {expr} (value {value:?})");
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

    /// INET (the built-in inet extension) is an alias over a STRUCT; its
    /// `Value` is that struct, and only the type says to print an address.
    #[test]
    fn inet_matches_duckdbs_cast() {
        for ip in [
            "134.209.25.199", "1.2.3.4/32", "10.0.0.0/8", "0.0.0.0/0", "255.255.255.255", "192.168.1.5/24",
            "2001:db8::1", "2001:db8:0:0:0:0:0:1", "2001:db8::/32", "::", "::/0", "::1", "::1/128",
            "::ffff:1.2.3.4", "::1.2.3.4", "::ffff:0:0", "fe80::1:0:0:1", "1:0:0:2:0:0:0:3",
            "ffff:ffff:ffff:ffff:ffff:ffff:ffff:ffff", "2001:DB8:A::/48", "1:2:3:4:5:6:7:8",
            // The extension's dotted-tail rules, quirks included.
            "::2", "::ffff", "::1:0", "::1:1", "::1:2", "::255.255.255.255", "::1.2.3.4/96",
            "::ffff:0:0", "::ffff:1.2.3.4/120", "::ffff:0:1.2.3.4", "::fffe:1.2.3.4", "64:ff9b::1.2.3.4",
            "0:0:0:0:1:ffff:1.2.3.4", "0:0:0:0:0:1:0:0", "1::", "0:1::", "1:0:0:1::", "1:0:1:0:1:0:1:0",
        ] {
            assert_matches_cast(&format!("INET '{ip}'"));
        }
        for expr in [
            "NULL::INET", "[INET '134.209.25.199', NULL, INET '2001:db8::/32']", "[]::INET[]",
            "[INET '10.0.0.0/8']::INET[1]", "{'a': INET '::1', 'b': [INET '1.2.3.4/16']}",
            "MAP {INET '1.2.3.4': INET 'fe80::1'}", "[[INET '1.2.3.4']]",
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
            "INET '1.2.3.4'", "[INET '1.2.3.4']",
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
