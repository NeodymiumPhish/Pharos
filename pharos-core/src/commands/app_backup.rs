//! File ▸ Export App Data… and File ▸ Import App Data…: the user's own Pharos
//! data, written to one file and read back, on this Mac or another one.
//!
//! Five categories, any of them:
//!
//!   sessions     `saved_queries`, and optionally each Session's saved results
//!                (`saved_query_results`, the snapshot the Session points at).
//!   history      `query_history`, without the cached result blobs: the cache
//!                is the history's own and is rebuilt by running the query.
//!   connections  every connection record, WITH its Keychain secrets — the
//!                database password and the SSH password or key passphrase.
//!   tags         every tag with its rules.
//!   variables    the app-wide `{{name}}` list.
//!
//! # The file
//!
//! One JSON document, `BackupEnvelope`. Unencrypted, the payload is a plain
//! JSON object a person can read. Encrypted, the payload is gzipped JSON
//! sealed with AES-256-GCM under a key PBKDF2-HMAC-SHA256 derives from the
//! user's password; the header names the cipher, the KDF, its iteration count,
//! the salt and the nonce. A file holding connections is ALWAYS encrypted:
//! `export_app_data` refuses one without a password, because the file would
//! otherwise hold every saved password in clear text.
//!
//! # Tables are copied by column name
//!
//! Sessions and history are dumped as `TableDump`s, column name → value,
//! rather than through the app's own structs: those leave columns out (a
//! history row's workspace, line range and label; a Session's result
//! snapshot), and a backup that dropped them would not restore what the user
//! had. On import only the columns BOTH sides have are written, so a file from
//! an older or a newer build still imports: a column this build lacks is left
//! out, and one the file lacks takes the table's default.
//!
//! # Import never deletes
//!
//! An item the store does not have is added. One it has (the same id) is
//! replaced or kept, as the user chooses (`ConflictPolicy`). Nothing else in
//! the store is touched. History rows are never replaced: a row is a record of
//! one run, and the same id is the same run.

use std::collections::{HashMap, HashSet};
use std::io::{Read, Write};
use std::path::Path;

use aes_gcm::aead::{Aead, KeyInit, OsRng, Payload};
use aes_gcm::aead::rand_core::RngCore;
use aes_gcm::{Aes256Gcm, Nonce};
use base64::Engine as _;
use rusqlite::types::{Value as SqlValue, ValueRef};
use rusqlite::Connection;
use serde::{Deserialize, Serialize};
use serde_json::Value;

use crate::db::sqlite;
use crate::models::{ConnectionConfig, QueryVariable, Tag};
use crate::state::AppState;

/// `BackupEnvelope::format`: a file without it is not a Pharos backup.
pub(crate) const BACKUP_FORMAT: &str = "pharos-app-data";
/// The newest envelope this build writes and reads.
pub(crate) const BACKUP_VERSION: u32 = 1;

/// PBKDF2 rounds for a new file: OWASP's 2023 figure for PBKDF2-HMAC-SHA256.
/// Tests use far fewer, because a debug build derives slowly; the count is in
/// the header, so a file always opens with the count it was written with.
#[cfg(not(test))]
const KDF_ITERATIONS: u32 = 600_000;
#[cfg(test)]
const KDF_ITERATIONS: u32 = 1_000;
/// A header asking for more than this is refused rather than run: a damaged
/// or hostile file must not be able to hang the app for minutes.
const MAX_KDF_ITERATIONS: u32 = 10_000_000;
const CIPHER_NAME: &str = "aes-256-gcm";
const KDF_NAME: &str = "pbkdf2-hmac-sha256";
/// Bound into the GCM tag, so a ciphertext cannot be lifted into another
/// format that happens to share the key.
const AAD: &[u8] = b"pharos-app-data/1";

/// What a wrong password and a damaged ciphertext both look like: GCM cannot
/// tell the two apart, and saying "wrong password" for a damaged file would
/// send the user hunting for a password that is in fact right.
pub const WRONG_PASSWORD_MESSAGE: &str =
    "The password is not correct, or the file is damaged.";

// ==================== Wire types ====================

/// Which kinds of data an export writes, or an import reads.
#[derive(Debug, Clone, Copy, Default, Serialize, Deserialize, PartialEq, Eq)]
#[serde(rename_all = "camelCase")]
pub struct BackupCategories {
    #[serde(default)]
    pub sessions: bool,
    #[serde(default)]
    pub history: bool,
    #[serde(default)]
    pub connections: bool,
    #[serde(default)]
    pub tags: bool,
    #[serde(default)]
    pub variables: bool,
}

impl BackupCategories {
    fn any(&self) -> bool {
        self.sessions || self.history || self.connections || self.tags || self.variables
    }
}

#[derive(Debug, Clone, Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct ExportAppDataOptions {
    /// Where to write the file. Written beside itself first and renamed into
    /// place, so a failed export never leaves half a file under the name.
    pub path: String,
    pub categories: BackupCategories,
    /// Write each Session's saved results too. They can be large.
    #[serde(default)]
    pub include_session_results: bool,
    /// Encrypt with this password. Required when `categories.connections`.
    #[serde(default)]
    pub passphrase: Option<String>,
}

/// What to do with an item the store already has (the same id).
#[derive(Debug, Clone, Copy, Default, Serialize, Deserialize, PartialEq, Eq)]
#[serde(rename_all = "camelCase")]
pub enum ConflictPolicy {
    /// The file's copy wins.
    #[default]
    Replace,
    /// The store's copy stays; the file's is skipped.
    Keep,
}

#[derive(Debug, Clone, Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct ImportAppDataOptions {
    pub path: String,
    #[serde(default)]
    pub passphrase: Option<String>,
    /// The categories to read. One the file does not hold is ignored.
    pub categories: BackupCategories,
    #[serde(default)]
    pub conflict: ConflictPolicy,
}

/// What a file holds. For an encrypted file read without its password only
/// `encrypted`, `locked` and `version` are filled in.
#[derive(Debug, Clone, Default, Serialize, PartialEq, Eq)]
#[serde(rename_all = "camelCase")]
pub struct BackupSummary {
    pub version: u32,
    pub encrypted: bool,
    /// Encrypted and not yet opened: the counts are unknown.
    pub locked: bool,
    pub exported_at: Option<String>,
    /// Each count is None when the file does not hold that category, which is
    /// not the same as holding none of it.
    pub sessions: Option<usize>,
    /// Sessions' saved results in the file (with or without their rows).
    pub session_results: Option<usize>,
    pub history: Option<usize>,
    pub connections: Option<usize>,
    /// Connections that carry at least one secret.
    pub connection_secrets: Option<usize>,
    pub tags: Option<usize>,
    pub variables: Option<usize>,
}

#[derive(Debug, Clone, Serialize, PartialEq, Eq)]
#[serde(rename_all = "camelCase")]
pub struct ExportAppDataResult {
    pub summary: BackupSummary,
    /// The file's size on disk.
    pub bytes: u64,
}

/// One category's import.
#[derive(Debug, Clone, Copy, Default, Serialize, PartialEq, Eq)]
#[serde(rename_all = "camelCase")]
pub struct CategoryOutcome {
    pub added: usize,
    pub replaced: usize,
    /// Already in the store and kept (`ConflictPolicy::Keep`, or a history
    /// row, which is never replaced).
    pub skipped: usize,
}

/// Each field is None for a category that was not imported.
#[derive(Debug, Clone, Default, Serialize, PartialEq, Eq)]
#[serde(rename_all = "camelCase")]
pub struct ImportAppDataResult {
    pub sessions: Option<CategoryOutcome>,
    pub history: Option<CategoryOutcome>,
    pub connections: Option<CategoryOutcome>,
    pub tags: Option<CategoryOutcome>,
    pub variables: Option<CategoryOutcome>,
}

/// The file on disk.
#[derive(Debug, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
struct BackupEnvelope {
    format: String,
    version: u32,
    /// Absent for an unencrypted file.
    #[serde(default, skip_serializing_if = "Option::is_none")]
    encryption: Option<EncryptionHeader>,
    /// The sealed, gzipped payload, base64. Only with `encryption`.
    #[serde(default, skip_serializing_if = "Option::is_none")]
    ciphertext: Option<String>,
    /// The payload in clear. Only without `encryption`.
    #[serde(default, skip_serializing_if = "Option::is_none")]
    payload: Option<BackupPayload>,
}

#[derive(Debug, Clone, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
struct EncryptionHeader {
    cipher: String,
    kdf: String,
    iterations: u32,
    /// base64
    salt: String,
    /// base64
    nonce: String,
}

#[derive(Debug, Default, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
struct BackupPayload {
    #[serde(default)]
    exported_at: String,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    sessions: Option<SessionsDump>,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    history: Option<TableDump>,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    connections: Option<Vec<ConnectionConfig>>,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    tags: Option<Vec<Tag>>,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    variables: Option<Vec<QueryVariable>>,
}

#[derive(Debug, Default, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
struct SessionsDump {
    saved_queries: TableDump,
    /// Absent when the export left the results out.
    #[serde(default, skip_serializing_if = "Option::is_none")]
    results: Option<TableDump>,
}

/// Rows of one table, by column name. A BLOB is `{"base64": "..."}`; every
/// other SQLite value is its JSON counterpart.
#[derive(Debug, Default, Clone, Serialize, Deserialize, PartialEq)]
struct TableDump {
    columns: Vec<String>,
    rows: Vec<Vec<Value>>,
}

impl TableDump {
    fn column_index(&self, name: &str) -> Option<usize> {
        self.columns.iter().position(|c| c == name)
    }

    /// The text in `name` on `row`, if it is text.
    fn text(&self, row: &[Value], name: &str) -> Option<String> {
        self.column_index(name)
            .and_then(|i| row.get(i))
            .and_then(|v| v.as_str())
            .map(str::to_string)
    }

    fn set(&self, row: &mut [Value], name: &str, value: Value) {
        if let Some(cell) = self.column_index(name).and_then(|i| row.get_mut(i)) {
            *cell = value;
        }
    }
}

// ==================== Value conversion ====================

fn b64() -> base64::engine::GeneralPurpose {
    base64::engine::general_purpose::STANDARD
}

fn sql_to_json(value: ValueRef<'_>) -> Value {
    match value {
        ValueRef::Null => Value::Null,
        ValueRef::Integer(i) => Value::from(i),
        ValueRef::Real(f) => serde_json::Number::from_f64(f).map(Value::Number).unwrap_or(Value::Null),
        ValueRef::Text(t) => Value::String(String::from_utf8_lossy(t).into_owned()),
        ValueRef::Blob(b) => serde_json::json!({ "base64": b64().encode(b) }),
    }
}

fn json_to_sql(value: &Value) -> SqlValue {
    match value {
        Value::Null => SqlValue::Null,
        Value::Bool(b) => SqlValue::Integer(*b as i64),
        Value::Number(n) => match n.as_i64() {
            Some(i) => SqlValue::Integer(i),
            None => n.as_f64().map(SqlValue::Real).unwrap_or(SqlValue::Null),
        },
        Value::String(s) => SqlValue::Text(s.clone()),
        Value::Object(map) => match map.get("base64").and_then(Value::as_str) {
            Some(encoded) if map.len() == 1 => {
                b64().decode(encoded).map(SqlValue::Blob).unwrap_or(SqlValue::Null)
            }
            _ => SqlValue::Text(value.to_string()),
        },
        Value::Array(_) => SqlValue::Text(value.to_string()),
    }
}

// ==================== Table helpers ====================

fn table_columns(conn: &Connection, table: &str) -> rusqlite::Result<Vec<String>> {
    let mut stmt = conn.prepare(&format!("SELECT name FROM pragma_table_info('{}')", table))?;
    let names = stmt.query_map([], |row| row.get::<_, String>(0))?;
    names.collect()
}

fn quoted(name: &str) -> String {
    format!("\"{}\"", name.replace('"', "\"\""))
}

/// Every row of `table` matching `filter` (a trailing SQL clause, or empty),
/// every column but `exclude`.
fn dump_table(conn: &Connection, table: &str, exclude: &[&str], filter: &str) -> rusqlite::Result<TableDump> {
    let columns: Vec<String> =
        table_columns(conn, table)?.into_iter().filter(|c| !exclude.contains(&c.as_str())).collect();
    let list = columns.iter().map(|c| quoted(c)).collect::<Vec<_>>().join(", ");
    let mut stmt = conn.prepare(&format!("SELECT {} FROM {} {}", list, table, filter))?;
    let width = columns.len();
    let rows = stmt
        .query_map([], |row| (0..width).map(|i| row.get_ref(i).map(sql_to_json)).collect::<rusqlite::Result<Vec<_>>>())?
        .collect::<rusqlite::Result<Vec<_>>>()?;
    Ok(TableDump { columns, rows })
}

/// Insert one dumped row, writing only the columns `target` has. `verb` is
/// `INSERT` or `INSERT OR IGNORE`. Returns rows changed.
fn insert_row(
    conn: &Connection,
    verb: &str,
    table: &str,
    target: &HashSet<String>,
    dump: &TableDump,
    row: &[Value],
) -> rusqlite::Result<usize> {
    let mut names = Vec::new();
    let mut values = Vec::new();
    for (name, value) in dump.columns.iter().zip(row.iter()) {
        if target.contains(name) {
            names.push(quoted(name));
            values.push(json_to_sql(value));
        }
    }
    if names.is_empty() {
        return Ok(0);
    }
    let marks = (1..=names.len()).map(|i| format!("?{}", i)).collect::<Vec<_>>().join(", ");
    let sql = format!("{} INTO {} ({}) VALUES ({})", verb, table, names.join(", "), marks);
    conn.execute(&sql, rusqlite::params_from_iter(values))
}

fn row_exists(conn: &Connection, table: &str, id: &str) -> rusqlite::Result<bool> {
    conn.query_row(&format!("SELECT EXISTS(SELECT 1 FROM {} WHERE id = ?1)", table), [id], |r| r.get(0))
}

// ==================== Encryption ====================

fn derive_key(passphrase: &str, salt: &[u8], iterations: u32) -> [u8; 32] {
    let mut key = [0u8; 32];
    pbkdf2::pbkdf2_hmac::<sha2::Sha256>(passphrase.as_bytes(), salt, iterations, &mut key);
    key
}

fn gzip(bytes: &[u8]) -> Result<Vec<u8>, String> {
    let mut encoder = flate2::write::GzEncoder::new(Vec::new(), flate2::Compression::default());
    encoder.write_all(bytes).map_err(|e| e.to_string())?;
    encoder.finish().map_err(|e| e.to_string())
}

fn gunzip(bytes: &[u8]) -> Result<Vec<u8>, String> {
    let mut out = Vec::new();
    flate2::read::GzDecoder::new(bytes).read_to_end(&mut out).map_err(|e| e.to_string())?;
    Ok(out)
}

fn seal(plain: &[u8], passphrase: &str, iterations: u32) -> Result<(EncryptionHeader, String), String> {
    let mut salt = [0u8; 16];
    let mut nonce = [0u8; 12];
    OsRng.fill_bytes(&mut salt);
    OsRng.fill_bytes(&mut nonce);
    let key = derive_key(passphrase, &salt, iterations);
    let cipher = Aes256Gcm::new_from_slice(&key).map_err(|e| e.to_string())?;
    let sealed = cipher
        .encrypt(Nonce::from_slice(&nonce), Payload { msg: plain, aad: AAD })
        .map_err(|_| "Encryption failed.".to_string())?;
    let header = EncryptionHeader {
        cipher: CIPHER_NAME.to_string(),
        kdf: KDF_NAME.to_string(),
        iterations,
        salt: b64().encode(salt),
        nonce: b64().encode(nonce),
    };
    Ok((header, b64().encode(sealed)))
}

fn open_sealed(header: &EncryptionHeader, ciphertext: &str, passphrase: &str) -> Result<Vec<u8>, String> {
    if header.cipher != CIPHER_NAME || header.kdf != KDF_NAME {
        return Err(format!(
            "This file is encrypted with {} / {}, which this version of Pharos cannot open.",
            header.cipher, header.kdf
        ));
    }
    if header.iterations == 0 || header.iterations > MAX_KDF_ITERATIONS {
        return Err("This file's encryption header is not valid.".to_string());
    }
    let damaged = || "This file's encryption header is not valid.".to_string();
    let salt = b64().decode(&header.salt).map_err(|_| damaged())?;
    let nonce = b64().decode(&header.nonce).map_err(|_| damaged())?;
    if nonce.len() != 12 {
        return Err(damaged());
    }
    let sealed = b64().decode(ciphertext).map_err(|_| WRONG_PASSWORD_MESSAGE.to_string())?;
    let key = derive_key(passphrase, &salt, header.iterations);
    let cipher = Aes256Gcm::new_from_slice(&key).map_err(|e| e.to_string())?;
    cipher
        .decrypt(Nonce::from_slice(&nonce), Payload { msg: &sealed, aad: AAD })
        .map_err(|_| WRONG_PASSWORD_MESSAGE.to_string())
}

// ==================== Reading a file ====================

fn read_envelope(path: &str) -> Result<BackupEnvelope, String> {
    let bytes = std::fs::read(path).map_err(|e| format!("Could not read {}: {}", path, e))?;
    parse_envelope(&bytes)
}

fn parse_envelope(bytes: &[u8]) -> Result<BackupEnvelope, String> {
    let not_a_backup = || "This file is not a Pharos app data export.".to_string();
    // Read the two header fields first, so a JSON file of some other kind is
    // named as that rather than as a decode error about a missing field.
    #[derive(Deserialize)]
    struct Head {
        format: Option<String>,
        version: Option<u32>,
    }
    let head: Head = serde_json::from_slice(bytes).map_err(|_| not_a_backup())?;
    if head.format.as_deref() != Some(BACKUP_FORMAT) {
        return Err(not_a_backup());
    }
    let version = head.version.unwrap_or(0);
    if version == 0 || version > BACKUP_VERSION {
        return Err(format!(
            "This file was exported by a newer version of Pharos (format {}). Update Pharos to import it.",
            version
        ));
    }
    serde_json::from_slice(bytes).map_err(|e| format!("This file is damaged: {}", e))
}

/// The payload, opened with `passphrase` when the file is encrypted. `Ok(None)`
/// is an encrypted file and no password.
fn open_payload(envelope: BackupEnvelope, passphrase: Option<&str>) -> Result<Option<BackupPayload>, String> {
    match envelope.encryption {
        None => Ok(Some(envelope.payload.unwrap_or_default())),
        Some(header) => {
            let Some(passphrase) = passphrase.filter(|p| !p.is_empty()) else { return Ok(None) };
            let ciphertext = envelope.ciphertext.ok_or_else(|| "This file is damaged: no ciphertext.".to_string())?;
            let plain = gunzip(&open_sealed(&header, &ciphertext, passphrase)?)
                .map_err(|e| format!("This file is damaged: {}", e))?;
            serde_json::from_slice(&plain).map(Some).map_err(|e| format!("This file is damaged: {}", e))
        }
    }
}

fn summarize(payload: &BackupPayload, version: u32, encrypted: bool) -> BackupSummary {
    BackupSummary {
        version,
        encrypted,
        locked: false,
        exported_at: Some(payload.exported_at.clone()).filter(|s| !s.is_empty()),
        sessions: payload.sessions.as_ref().map(|s| s.saved_queries.rows.len()),
        session_results: payload.sessions.as_ref().map(|s| s.results.as_ref().map_or(0, |r| r.rows.len())),
        history: payload.history.as_ref().map(|h| h.rows.len()),
        connections: payload.connections.as_ref().map(Vec::len),
        connection_secrets: payload.connections.as_ref().map(|list| {
            list.iter()
                .filter(|c| {
                    !c.password.is_empty() || c.ssh_tunnel.as_ref().is_some_and(|t| !t.secret.is_empty())
                })
                .count()
        }),
        tags: payload.tags.as_ref().map(Vec::len),
        variables: payload.variables.as_ref().map(Vec::len),
    }
}

/// What the file at `path` holds. An encrypted file read without a password
/// answers `locked`; with a wrong one it fails with `WRONG_PASSWORD_MESSAGE`.
pub fn inspect_app_data(path: &str, passphrase: Option<&str>) -> Result<BackupSummary, String> {
    let envelope = read_envelope(path)?;
    let version = envelope.version;
    let encrypted = envelope.encryption.is_some();
    match open_payload(envelope, passphrase)? {
        Some(payload) => Ok(summarize(&payload, version, encrypted)),
        None => Ok(BackupSummary { version, encrypted, locked: true, ..Default::default() }),
    }
}

// ==================== Export ====================

/// The columns of a Session that name its stored results. Cleared when the
/// export leaves the results out, so the imported Session does not point at a
/// snapshot that is not there.
const SESSION_RESULT_COLUMNS: [&str; 4] = ["results_snapshot_id", "results_saved_at", "results_bytes", "result_count"];
/// History's result cache. Never exported.
const HISTORY_RESULT_COLUMNS: [&str; 3] = ["result_columns", "result_rows", "result_row_identity"];

fn dump_sessions(conn: &Connection, include_results: bool) -> rusqlite::Result<SessionsDump> {
    let mut saved_queries = dump_table(conn, "saved_queries", &[], "ORDER BY created_at, id")?;
    let results = if include_results {
        // Only the snapshot each Session points at: a row of another snapshot
        // is a save in progress, or one a crash left behind.
        Some(dump_table(
            conn,
            "saved_query_results",
            &[],
            "WHERE snapshot_id = (SELECT results_snapshot_id FROM saved_queries \
             WHERE saved_queries.id = saved_query_results.saved_query_id) ORDER BY saved_query_id, priority",
        )?)
    } else {
        let indices: Vec<usize> =
            SESSION_RESULT_COLUMNS.iter().filter_map(|c| saved_queries.column_index(c)).collect();
        for row in saved_queries.rows.iter_mut() {
            for &index in &indices {
                row[index] = Value::Null;
            }
        }
        None
    };
    Ok(SessionsDump { saved_queries, results })
}

fn build_payload(
    state: &AppState,
    options: &ExportAppDataOptions,
    connections: Option<Vec<ConnectionConfig>>,
) -> Result<BackupPayload, String> {
    let db = state.metadata_db.lock().map_err(|e| e.to_string())?;
    let categories = options.categories;
    let fail = |what: &str, e: rusqlite::Error| format!("Could not read {}: {}", what, e);
    Ok(BackupPayload {
        exported_at: chrono::Utc::now().to_rfc3339_opts(chrono::SecondsFormat::Secs, true),
        sessions: if categories.sessions {
            Some(dump_sessions(&db, options.include_session_results).map_err(|e| fail("Sessions", e))?)
        } else {
            None
        },
        history: if categories.history {
            Some(
                dump_table(&db, "query_history", &HISTORY_RESULT_COLUMNS, "ORDER BY executed_at, id")
                    .map_err(|e| fail("query history", e))?,
            )
        } else {
            None
        },
        connections,
        tags: if categories.tags {
            Some(sqlite::load_tags(&db).map_err(|e| fail("tags", e))?)
        } else {
            None
        },
        variables: if categories.variables {
            Some(sqlite::load_query_variables(&db).map_err(|e| fail("variables", e))?)
        } else {
            None
        },
    })
}

/// Encode `payload` as the file's bytes: sealed with `passphrase` when there
/// is one, plain JSON otherwise.
fn encode_envelope(payload: BackupPayload, passphrase: Option<&str>, iterations: u32) -> Result<Vec<u8>, String> {
    let envelope = match passphrase {
        Some(passphrase) => {
            let plain = serde_json::to_vec(&payload).map_err(|e| e.to_string())?;
            let (header, ciphertext) = seal(&gzip(&plain)?, passphrase, iterations)?;
            BackupEnvelope {
                format: BACKUP_FORMAT.to_string(),
                version: BACKUP_VERSION,
                encryption: Some(header),
                ciphertext: Some(ciphertext),
                payload: None,
            }
        }
        None => BackupEnvelope {
            format: BACKUP_FORMAT.to_string(),
            version: BACKUP_VERSION,
            encryption: None,
            ciphertext: None,
            payload: Some(payload),
        },
    };
    serde_json::to_vec_pretty(&envelope).map_err(|e| e.to_string())
}

/// Write `bytes` to `path` by way of a sibling temporary file, readable by
/// this user only: the file can hold passwords and query text.
fn write_private_file(path: &str, bytes: &[u8]) -> Result<u64, String> {
    let target = Path::new(path);
    let file_name = target.file_name().and_then(|n| n.to_str()).unwrap_or("export");
    let temp = target.with_file_name(format!(".{}.{}.tmp", file_name, uuid::Uuid::new_v4()));
    let write = || -> std::io::Result<()> {
        let mut options = std::fs::OpenOptions::new();
        options.write(true).create_new(true);
        #[cfg(unix)]
        {
            use std::os::unix::fs::OpenOptionsExt;
            options.mode(0o600);
        }
        let mut file = options.open(&temp)?;
        file.write_all(bytes)?;
        file.sync_all()?;
        std::fs::rename(&temp, target)
    };
    if let Err(e) = write() {
        let _ = std::fs::remove_file(&temp);
        return Err(format!("Could not write {}: {}", path, e));
    }
    Ok(bytes.len() as u64)
}

/// File ▸ Export App Data….
pub async fn export_app_data(options: ExportAppDataOptions, state: &AppState) -> Result<ExportAppDataResult, String> {
    export_app_data_with(options, state, KDF_ITERATIONS).await
}

async fn export_app_data_with(
    options: ExportAppDataOptions,
    state: &AppState,
    iterations: u32,
) -> Result<ExportAppDataResult, String> {
    if !options.categories.any() {
        return Err("Choose at least one kind of data to export.".to_string());
    }
    let passphrase = options.passphrase.as_deref().filter(|p| !p.is_empty());
    if options.categories.connections && passphrase.is_none() {
        return Err("Connections are exported with their passwords, so the file must be encrypted. Enter a password.".to_string());
    }
    // `load_connections` fills each record's secrets from the Keychain cache.
    // A record that does not remember its password carries none.
    let connections = if options.categories.connections {
        Some(super::connection::load_connections(state).await?)
    } else {
        None
    };
    let payload = build_payload(state, &options, connections)?;
    let summary = summarize(&payload, BACKUP_VERSION, passphrase.is_some());
    let bytes = encode_envelope(payload, passphrase, iterations)?;
    let written = write_private_file(&options.path, &bytes)?;
    Ok(ExportAppDataResult { summary, bytes: written })
}

// ==================== Import ====================

fn import_sessions(conn: &mut Connection, dump: &SessionsDump, policy: ConflictPolicy) -> rusqlite::Result<CategoryOutcome> {
    let tx = conn.transaction()?;
    let mut outcome = CategoryOutcome::default();
    let query_columns: HashSet<String> = table_columns(&tx, "saved_queries")?.into_iter().collect();
    let result_columns: HashSet<String> = table_columns(&tx, "saved_query_results")?.into_iter().collect();
    let queries = &dump.saved_queries;
    // The Sessions whose rows were written: only their results follow.
    let mut written: HashSet<String> = HashSet::new();
    let mut snapshot_of: HashMap<String, Option<String>> = HashMap::new();

    for row in &queries.rows {
        let Some(id) = queries.text(row, "id") else { continue };
        if row_exists(&tx, "saved_queries", &id)? {
            match policy {
                ConflictPolicy::Keep => {
                    outcome.skipped += 1;
                    continue;
                }
                ConflictPolicy::Replace => {
                    // Its stored results go with it (ON DELETE CASCADE).
                    tx.execute("DELETE FROM saved_queries WHERE id = ?1", [&id])?;
                    outcome.replaced += 1;
                }
            }
        } else {
            outcome.added += 1;
        }
        let mut row = row.clone();
        // A connection this store does not have becomes no connection, as
        // `create_saved_query` does: the foreign key would refuse the row.
        if let Some(connection_id) = queries.text(&row, "connection_id") {
            if !row_exists(&tx, "connections", &connection_id)? {
                queries.set(&mut row, "connection_id", Value::Null);
            }
        }
        insert_row(&tx, "INSERT", "saved_queries", &query_columns, queries, &row)?;
        snapshot_of.insert(id.clone(), queries.text(&row, "results_snapshot_id"));
        written.insert(id);
    }

    let mut has_results: HashSet<String> = HashSet::new();
    if let Some(results) = &dump.results {
        for row in &results.rows {
            let Some(owner) = results.text(row, "saved_query_id") else { continue };
            if !written.contains(&owner) {
                continue;
            }
            if insert_row(&tx, "INSERT OR IGNORE", "saved_query_results", &result_columns, results, row)? > 0 {
                has_results.insert(owner);
            }
        }
    }
    // A Session that names a snapshot the file did not bring has no results
    // here. Clear the pointer rather than leave the Session promising rows.
    for (id, snapshot) in &snapshot_of {
        if snapshot.is_some() && !has_results.contains(id) {
            let sets = SESSION_RESULT_COLUMNS
                .iter()
                .filter(|c| query_columns.contains(**c))
                .map(|c| format!("{} = NULL", c))
                .collect::<Vec<_>>()
                .join(", ");
            if !sets.is_empty() {
                tx.execute(&format!("UPDATE saved_queries SET {} WHERE id = ?1", sets), [id])?;
            }
        }
    }
    tx.commit()?;
    Ok(outcome)
}

fn import_history(conn: &mut Connection, dump: &TableDump) -> rusqlite::Result<CategoryOutcome> {
    let tx = conn.transaction()?;
    let mut outcome = CategoryOutcome::default();
    let columns: HashSet<String> = table_columns(&tx, "query_history")?
        .into_iter()
        .filter(|c| !HISTORY_RESULT_COLUMNS.contains(&c.as_str()))
        .collect();
    for row in &dump.rows {
        let mut row = row.clone();
        // A history row that belonged to a Results History workspace this
        // store does not have stands alone, as a row whose workspace was
        // deleted does.
        if let Some(workspace_id) = dump.text(&row, "workspace_id") {
            if !row_exists(&tx, "workspaces", &workspace_id)? {
                dump.set(&mut row, "workspace_id", Value::Null);
            }
        }
        // Never replaced: the same id is the same run. INSERT OR IGNORE keeps
        // the FTS index in step through its insert trigger.
        if insert_row(&tx, "INSERT OR IGNORE", "query_history", &columns, dump, &row)? > 0 {
            outcome.added += 1;
        } else {
            outcome.skipped += 1;
        }
    }
    tx.commit()?;
    Ok(outcome)
}

fn import_tags(conn: &mut Connection, tags: &[Tag], policy: ConflictPolicy) -> rusqlite::Result<CategoryOutcome> {
    let tx = conn.transaction()?;
    let mut outcome = CategoryOutcome::default();
    for tag in tags {
        if row_exists(&tx, "tags", &tag.id)? {
            match policy {
                ConflictPolicy::Keep => {
                    outcome.skipped += 1;
                    continue;
                }
                ConflictPolicy::Replace => {
                    // Its rules go with it (ON DELETE CASCADE).
                    tx.execute("DELETE FROM tags WHERE id = ?1", [&tag.id])?;
                    outcome.replaced += 1;
                }
            }
        } else {
            outcome.added += 1;
        }
        tx.execute(
            "INSERT INTO tags (id, name, color_index, note, created_at, updated_at) VALUES (?1, ?2, ?3, ?4, ?5, ?6)",
            (&tag.id, &tag.name, tag.color_index, &tag.note, &tag.created_at, &tag.updated_at),
        )?;
        for rule in &tag.rules {
            // As `insert_tag_tuple` writes it, with the rule's own id and date.
            let values_json = serde_json::to_string(&rule.conditions).unwrap_or_else(|_| "[]".to_string());
            tx.execute(
                "INSERT OR IGNORE INTO tag_tuples \
                 (id, tag_id, tuple_values, tuple_key, origin_connection, origin_table, created_at) \
                 VALUES (?1, ?2, ?3, ?4, ?5, ?6, ?7)",
                (
                    &rule.id,
                    &tag.id,
                    values_json,
                    &rule.tuple_key,
                    &rule.origin_connection,
                    &rule.origin_table,
                    &rule.created_at,
                ),
            )?;
        }
    }
    tx.commit()?;
    Ok(outcome)
}

/// The scope a variable is defined for: its sorted connection list, empty for
/// global. Two variables may share a name in different scopes.
fn variable_scope(variable: &QueryVariable) -> Vec<String> {
    let mut ids = variable.connection_ids.clone();
    ids.sort();
    ids
}

/// Merge `incoming` into `existing`. A variable is the same one when it has
/// the same id, or the same name in the same scope; a new one goes at the end.
fn merge_variables(
    existing: Vec<QueryVariable>,
    incoming: &[QueryVariable],
    policy: ConflictPolicy,
) -> (Vec<QueryVariable>, CategoryOutcome) {
    let mut merged = existing;
    let mut outcome = CategoryOutcome::default();
    for variable in incoming {
        let scope = variable_scope(variable);
        let found = merged.iter().position(|v| v.id == variable.id).or_else(|| {
            merged.iter().position(|v| v.name == variable.name && variable_scope(v) == scope)
        });
        match (found, policy) {
            (Some(_), ConflictPolicy::Keep) => outcome.skipped += 1,
            (Some(index), ConflictPolicy::Replace) => {
                // The store's id stays, so a match by name does not leave two
                // ids for one variable.
                let id = merged[index].id.clone();
                merged[index] = QueryVariable { id, ..variable.clone() };
                outcome.replaced += 1;
            }
            (None, _) => {
                merged.push(variable.clone());
                outcome.added += 1;
            }
        }
    }
    (merged, outcome)
}

async fn import_connections(
    state: &AppState,
    connections: &[ConnectionConfig],
    policy: ConflictPolicy,
) -> Result<CategoryOutcome, String> {
    let existing: HashSet<String> = {
        let db = state.metadata_db.lock().map_err(|e| e.to_string())?;
        sqlite::load_connections(&db).map_err(|e| e.to_string())?.into_iter().map(|c| c.id).collect()
    };
    let mut outcome = CategoryOutcome::default();
    for config in connections {
        if config.id.starts_with(super::connection::SCHEMA_FETCH_ID_PREFIX) || config.id.is_empty() {
            continue;
        }
        let exists = existing.contains(&config.id);
        if exists && policy == ConflictPolicy::Keep {
            outcome.skipped += 1;
            continue;
        }
        // The one path every connection save takes: the secrets go to the
        // Keychain (or, for a record that does not remember them, to this
        // run's memory), the record to SQLite.
        super::connection::save_connection(config.clone(), state)
            .await
            .map_err(|e| format!("Could not import the connection \u{201C}{}\u{201D}: {}", config.name, e))?;
        if exists {
            outcome.replaced += 1;
        } else {
            outcome.added += 1;
        }
    }
    Ok(outcome)
}

/// File ▸ Import App Data….
///
/// Connections go first: a Session names its connection, and one the store
/// does not have would be imported without it.
pub async fn import_app_data(options: ImportAppDataOptions, state: &AppState) -> Result<ImportAppDataResult, String> {
    if !options.categories.any() {
        return Err("Choose at least one kind of data to import.".to_string());
    }
    let envelope = read_envelope(&options.path)?;
    let payload = open_payload(envelope, options.passphrase.as_deref())?
        .ok_or_else(|| "This file is encrypted. Enter its password.".to_string())?;
    let categories = options.categories;
    let policy = options.conflict;
    let mut result = ImportAppDataResult::default();

    if categories.connections {
        if let Some(connections) = &payload.connections {
            result.connections = Some(import_connections(state, connections, policy).await?);
        }
    }

    let mut db = state.metadata_db.lock().map_err(|e| e.to_string())?;
    if categories.sessions {
        if let Some(sessions) = &payload.sessions {
            result.sessions = Some(
                import_sessions(&mut db, sessions, policy).map_err(|e| format!("Could not import Sessions: {}", e))?,
            );
        }
    }
    if categories.history {
        if let Some(history) = &payload.history {
            result.history =
                Some(import_history(&mut db, history).map_err(|e| format!("Could not import query history: {}", e))?);
        }
    }
    if categories.tags {
        if let Some(tags) = &payload.tags {
            result.tags = Some(import_tags(&mut db, tags, policy).map_err(|e| format!("Could not import tags: {}", e))?);
        }
    }
    if categories.variables {
        if let Some(variables) = &payload.variables {
            let existing = sqlite::load_query_variables(&db).map_err(|e| format!("Could not read variables: {}", e))?;
            let (merged, outcome) = merge_variables(existing, variables, policy);
            sqlite::save_query_variables(&mut db, &merged)
                .map_err(|e| format!("Could not import variables: {}", e))?;
            result.variables = Some(outcome);
        }
    }
    Ok(result)
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::db::credentials;
    use crate::models::{CreateSavedQuery, CreateTag, NewTagRule, SslMode, TagCondition};
    use std::path::PathBuf;

    fn temp_dir(tag: &str) -> PathBuf {
        let dir = std::env::temp_dir().join(format!("pharos_backup_{}_{}", tag, uuid::Uuid::new_v4()));
        std::fs::create_dir_all(&dir).unwrap();
        dir
    }

    fn state_in(dir: &Path) -> AppState {
        AppState::new(sqlite::init_database(dir).expect("init_database"))
    }

    fn all() -> BackupCategories {
        BackupCategories { sessions: true, history: true, connections: true, tags: true, variables: true }
    }

    fn connection(id: &str, password: &str) -> ConnectionConfig {
        ConnectionConfig {
            id: id.to_string(),
            name: format!("conn-{}", id),
            host: "db.example.com".to_string(),
            port: 5432,
            database: "app".to_string(),
            username: "me".to_string(),
            password: password.to_string(),
            ssl_mode: SslMode::Require,
            default_schema: Some("public".to_string()),
            requires_authentication: false,
            ssh_tunnel: Some(crate::models::SshTunnelConfig {
                host: "bastion".to_string(),
                port: 22,
                user: Some("me".to_string()),
                auth: crate::models::SshAuth::Password,
                key_path: None,
                secret: format!("ssh-{}", password),
                accept_new_host_keys: false,
                remember_secret: true,
            }),
            read_only: false,
            remember_password: true,
            connect_on_launch: false,
            mcp_access: Default::default(),
            saved: true,
            session_time_zone: None,
            ssl_root_cert_path: None,
            engine: Default::default(),
        }
    }

    fn variable(id: &str, name: &str, value: &str) -> QueryVariable {
        QueryVariable {
            id: id.to_string(),
            name: name.to_string(),
            value: value.to_string(),
            kind: "literal".to_string(),
            connection_ids: Vec::new(),
            mcp_access: None,
        }
    }

    fn history_row(conn: &Connection, id: &str, connection_id: &str, sql: &str) {
        conn.execute(
            "INSERT INTO query_history (id, connection_id, connection_name, sql, row_count, execution_time_ms, \
             executed_at, result_columns, result_rows, raw_sql, line_start) \
             VALUES (?1, ?2, 'c', ?3, 1, 5, '2026-11-01T00:00:00Z', 'cols', 'rows', '{{x}}', 3)",
            (id, connection_id, sql),
        )
        .unwrap();
    }

    /// A store with one of everything, a Session with a stored result among it.
    async fn seed(state: &AppState) -> String {
        super::super::connection::save_connection(connection("c1", "hunter2"), state).await.unwrap();
        let db = state.metadata_db.lock().unwrap();
        let session = sqlite::create_saved_query(
            &db,
            "s1",
            &CreateSavedQuery {
                name: "Monthly".to_string(),
                folder: Some("Reports".to_string()),
                sql: "select 1".to_string(),
                connection_id: Some("c1".to_string()),
                variables: None,
                cards_json: Some("[]".to_string()),
                schema_name: Some("public".to_string()),
            },
        )
        .unwrap();
        // A stored result under the Session's snapshot, and a stray staged
        // row under another one, which must NOT travel.
        db.execute("UPDATE saved_queries SET results_snapshot_id = 'snap', result_count = 1 WHERE id = 's1'", [])
            .unwrap();
        for (id, snapshot) in [("r1", "snap"), ("r2", "stale")] {
            db.execute(
                "INSERT INTO saved_query_results (id, saved_query_id, snapshot_id, run_id, card_id, priority, kind, \
                 sql, executed_at, execution_time_ms, result_columns, result_rows, compressed_bytes) \
                 VALUES (?1, 's1', ?2, ?1, 'card', 0, 'rows', 'select 1', '2026-11-01', 1, X'0102', X'03FF', 4)",
                (id, snapshot),
            )
            .unwrap();
        }
        history_row(&db, "h1", "c1", "select 1");
        sqlite::create_tag(
            &db,
            "t1",
            &CreateTag {
                name: "Suspect".to_string(),
                color_index: 2,
                note: Some("n".to_string()),
                rules: vec![NewTagRule {
                    conditions: vec![TagCondition {
                        family: "text".to_string(),
                        kind: None,
                        value: "abc".to_string(),
                        operand2: None,
                        display: "ABC".to_string(),
                    }],
                    tuple_key: "K4:textV3:abc".to_string(),
                    origin_connection: "c1".to_string(),
                    origin_table: "public.t".to_string(),
                }],
            },
        )
        .unwrap();
        drop(db);
        let mut db = state.metadata_db.lock().unwrap();
        sqlite::save_query_variables(&mut db, &[variable("v1", "env", "prod")]).unwrap();
        session.id
    }

    fn export_options(path: &Path, categories: BackupCategories, passphrase: Option<&str>) -> ExportAppDataOptions {
        ExportAppDataOptions {
            path: path.to_string_lossy().to_string(),
            categories,
            include_session_results: true,
            passphrase: passphrase.map(str::to_string),
        }
    }

    fn import_options(path: &Path, passphrase: Option<&str>, conflict: ConflictPolicy) -> ImportAppDataOptions {
        ImportAppDataOptions {
            path: path.to_string_lossy().to_string(),
            passphrase: passphrase.map(str::to_string),
            categories: all(),
            conflict,
        }
    }

    /// Everything exported from one store arrives in an empty one: the
    /// connection with BOTH of its secrets, the Session with its stored result
    /// (and not the stray one), history without its result cache but with the
    /// columns the app's struct leaves out, the tag with its rule, the variable.
    #[test]
    fn a_full_export_restores_into_an_empty_store() {
        let _keychain = credentials::isolated_keychain("backup_full");
        let rt = tokio::runtime::Runtime::new().unwrap();
        let (from_dir, to_dir) = (temp_dir("from"), temp_dir("to"));
        let from = state_in(&from_dir);
        rt.block_on(seed(&from));
        // The cache is what `load_connections` reads the secrets from.
        assert_eq!(from.get_cached_password("c1").as_deref(), Some("hunter2"));

        let file = from_dir.join("backup.pharosdata");
        let exported = rt.block_on(export_app_data(export_options(&file, all(), Some("pw")), &from)).unwrap();
        assert!(exported.summary.encrypted);
        assert_eq!(exported.summary.sessions, Some(1));
        assert_eq!(exported.summary.session_results, Some(1), "only the Session's own snapshot");
        assert_eq!(exported.summary.connection_secrets, Some(1));
        let text = std::fs::read_to_string(&file).unwrap();
        assert!(!text.contains("hunter2") && !text.contains("Monthly"), "nothing readable in an encrypted file");
        #[cfg(unix)]
        {
            use std::os::unix::fs::PermissionsExt;
            let mode = std::fs::metadata(&file).unwrap().permissions().mode() & 0o777;
            assert_eq!(mode, 0o600, "the file is this user's alone");
        }

        let to = state_in(&to_dir);
        let result = rt.block_on(import_app_data(import_options(&file, Some("pw"), ConflictPolicy::Replace), &to)).unwrap();
        let added = |o: Option<CategoryOutcome>| o.map(|o| o.added);
        assert_eq!(added(result.connections), Some(1));
        assert_eq!(added(result.sessions), Some(1));
        assert_eq!(added(result.history), Some(1));
        assert_eq!(added(result.tags), Some(1));
        assert_eq!(added(result.variables), Some(1));

        let connections = rt.block_on(super::super::connection::load_connections(&to)).unwrap();
        assert_eq!(connections.len(), 1);
        assert_eq!(connections[0].password, "hunter2", "the database password came across");
        assert_eq!(connections[0].ssh_tunnel.as_ref().unwrap().secret, "ssh-hunter2", "and the SSH secret");
        assert_eq!(connections[0].default_schema.as_deref(), Some("public"));

        let db = to.metadata_db.lock().unwrap();
        let session = sqlite::get_saved_query(&db, "s1").unwrap().expect("the Session");
        assert_eq!(session.folder.as_deref(), Some("Reports"));
        assert_eq!(session.connection_id.as_deref(), Some("c1"));
        assert_eq!(session.results_snapshot_id.as_deref(), Some("snap"));
        let results: Vec<(String, Vec<u8>)> = db
            .prepare("SELECT id, result_rows FROM saved_query_results ORDER BY id")
            .unwrap()
            .query_map([], |r| Ok((r.get(0)?, r.get(1)?)))
            .unwrap()
            .collect::<rusqlite::Result<_>>()
            .unwrap();
        assert_eq!(results, vec![("r1".to_string(), vec![0x03, 0xFF])], "the blob round-trips byte for byte");

        let (raw_sql, line_start, cached): (Option<String>, Option<i64>, Option<String>) = db
            .query_row("SELECT raw_sql, line_start, result_rows FROM query_history WHERE id = 'h1'", [], |r| {
                Ok((r.get(0)?, r.get(1)?, r.get(2)?))
            })
            .unwrap();
        assert_eq!(raw_sql.as_deref(), Some("{{x}}"), "columns outside the app's struct travel too");
        assert_eq!(line_start, Some(3));
        assert_eq!(cached, None, "the result cache does not");
        let found: i64 = db
            .query_row("SELECT COUNT(*) FROM query_history_fts WHERE query_history_fts MATCH 'select'", [], |r| r.get(0))
            .unwrap();
        assert_eq!(found, 1, "imported history is searchable");

        let tags = sqlite::load_tags(&db).unwrap();
        assert_eq!(tags.len(), 1);
        assert_eq!(tags[0].rules.len(), 1);
        assert_eq!(tags[0].rules[0].conditions[0].display, "ABC");
        assert_eq!(sqlite::load_query_variables(&db).unwrap()[0].value, "prod");
        drop(db);

        let _ = std::fs::remove_dir_all(&from_dir);
        let _ = std::fs::remove_dir_all(&to_dir);
    }

    #[test]
    fn connections_are_never_written_in_clear_text() {
        let rt = tokio::runtime::Runtime::new().unwrap();
        let dir = temp_dir("clear");
        let state = state_in(&dir);
        let file = dir.join("x.pharosdata");
        let categories = BackupCategories { connections: true, ..Default::default() };
        let error = rt.block_on(export_app_data(export_options(&file, categories, None), &state)).unwrap_err();
        assert!(error.contains("encrypted"), "got {}", error);
        assert!(!file.exists());
        let none = rt.block_on(export_app_data(export_options(&file, BackupCategories::default(), None), &state));
        assert!(none.is_err(), "an export of nothing is refused");
        let _ = std::fs::remove_dir_all(&dir);
    }

    /// An unencrypted file is plain JSON, opens without a password, and holds
    /// only the categories asked for.
    #[test]
    fn an_unencrypted_export_is_readable_and_partial() {
        let _keychain = credentials::isolated_keychain("backup_plain");
        let rt = tokio::runtime::Runtime::new().unwrap();
        let dir = temp_dir("plain");
        let state = state_in(&dir);
        rt.block_on(seed(&state));
        let file = dir.join("plain.pharosdata");
        let categories = BackupCategories { variables: true, tags: true, ..Default::default() };
        rt.block_on(export_app_data(export_options(&file, categories, None), &state)).unwrap();
        let text = std::fs::read_to_string(&file).unwrap();
        assert!(text.contains("\"pharos-app-data\"") && text.contains("Suspect"));
        assert!(!text.contains("hunter2"));

        let summary = inspect_app_data(&file.to_string_lossy(), None).unwrap();
        assert!(!summary.encrypted && !summary.locked);
        assert_eq!(summary.tags, Some(1));
        assert_eq!(summary.variables, Some(1));
        assert_eq!(summary.sessions, None, "not in the file is not the same as zero");
        let _ = std::fs::remove_dir_all(&dir);
    }

    #[test]
    fn an_encrypted_file_needs_its_password() {
        let rt = tokio::runtime::Runtime::new().unwrap();
        let dir = temp_dir("locked");
        let state = state_in(&dir);
        {
            let mut db = state.metadata_db.lock().unwrap();
            sqlite::save_query_variables(&mut db, &[variable("v1", "env", "prod")]).unwrap();
        }
        let file = dir.join("locked.pharosdata");
        let categories = BackupCategories { variables: true, ..Default::default() };
        rt.block_on(export_app_data(export_options(&file, categories, Some("correct horse")), &state)).unwrap();
        let path = file.to_string_lossy().to_string();

        let locked = inspect_app_data(&path, None).unwrap();
        assert!(locked.encrypted && locked.locked);
        assert_eq!(locked.variables, None);
        assert_eq!(inspect_app_data(&path, Some("wrong")).unwrap_err(), WRONG_PASSWORD_MESSAGE);
        assert_eq!(inspect_app_data(&path, Some("correct horse")).unwrap().variables, Some(1));

        let without = rt.block_on(import_app_data(import_options(&file, None, ConflictPolicy::Replace), &state));
        assert!(without.unwrap_err().contains("encrypted"));
        let _ = std::fs::remove_dir_all(&dir);
    }

    /// A flipped byte in the ciphertext fails the GCM tag.
    #[test]
    fn a_damaged_ciphertext_is_refused() {
        let payload = BackupPayload { exported_at: "now".to_string(), ..Default::default() };
        let bytes = encode_envelope(payload, Some("pw"), 1_000).unwrap();
        let mut envelope: BackupEnvelope = serde_json::from_slice(&bytes).unwrap();
        let mut sealed = b64().decode(envelope.ciphertext.as_ref().unwrap()).unwrap();
        sealed[0] ^= 0x01;
        envelope.ciphertext = Some(b64().encode(sealed));
        let damaged = serde_json::to_vec(&envelope).unwrap();
        let error = open_payload(parse_envelope(&damaged).unwrap(), Some("pw")).unwrap_err();
        assert_eq!(error, WRONG_PASSWORD_MESSAGE);
    }

    #[test]
    fn other_files_and_newer_formats_are_named_as_such() {
        assert!(parse_envelope(b"{\"rows\": []}").unwrap_err().contains("not a Pharos"));
        assert!(parse_envelope(b"not json").unwrap_err().contains("not a Pharos"));
        let newer = format!("{{\"format\":\"{}\",\"version\":{}}}", BACKUP_FORMAT, BACKUP_VERSION + 1);
        assert!(parse_envelope(newer.as_bytes()).unwrap_err().contains("newer version"));
        let header = EncryptionHeader {
            cipher: CIPHER_NAME.to_string(),
            kdf: KDF_NAME.to_string(),
            iterations: MAX_KDF_ITERATIONS + 1,
            salt: b64().encode([0u8; 16]),
            nonce: b64().encode([0u8; 12]),
        };
        assert!(open_sealed(&header, "", "pw").unwrap_err().contains("not valid"), "no unbounded KDF");
    }

    /// Keep leaves the store's copy alone; Replace takes the file's. Nothing
    /// that is only in the store is ever removed.
    #[test]
    fn conflicts_follow_the_policy_and_nothing_is_deleted() {
        let _keychain = credentials::isolated_keychain("backup_conflict");
        let rt = tokio::runtime::Runtime::new().unwrap();
        let dir = temp_dir("conflict");
        let state = state_in(&dir);
        rt.block_on(seed(&state));
        let file = dir.join("c.pharosdata");
        rt.block_on(export_app_data(export_options(&file, all(), Some("pw")), &state)).unwrap();

        // Edit the store after the export, and add things the file lacks.
        {
            let mut db = state.metadata_db.lock().unwrap();
            db.execute("UPDATE saved_queries SET name = 'Edited' WHERE id = 's1'", []).unwrap();
            db.execute("UPDATE tags SET name = 'Edited' WHERE id = 't1'", []).unwrap();
            sqlite::save_query_variables(&mut db, &[variable("v1", "env", "dev"), variable("v2", "only-here", "1")])
                .unwrap();
            history_row(&db, "h2", "c1", "select 2");
        }

        let keep = rt.block_on(import_app_data(import_options(&file, Some("pw"), ConflictPolicy::Keep), &state)).unwrap();
        assert_eq!(keep.sessions.unwrap().skipped, 1);
        assert_eq!(keep.connections.unwrap().skipped, 1);
        assert_eq!(keep.history.unwrap().skipped, 1);
        {
            let db = state.metadata_db.lock().unwrap();
            assert_eq!(sqlite::get_saved_query(&db, "s1").unwrap().unwrap().name, "Edited");
            assert_eq!(sqlite::load_tags(&db).unwrap()[0].name, "Edited");
            assert_eq!(sqlite::load_query_variables(&db).unwrap()[0].value, "dev");
        }

        let replace =
            rt.block_on(import_app_data(import_options(&file, Some("pw"), ConflictPolicy::Replace), &state)).unwrap();
        assert_eq!(replace.sessions.unwrap().replaced, 1);
        assert_eq!(replace.tags.unwrap().replaced, 1);
        assert_eq!(replace.variables.unwrap().replaced, 1);
        assert_eq!(replace.history.unwrap().skipped, 1, "history is never replaced");
        let db = state.metadata_db.lock().unwrap();
        let session = sqlite::get_saved_query(&db, "s1").unwrap().unwrap();
        assert_eq!(session.name, "Monthly");
        assert_eq!(session.results_snapshot_id.as_deref(), Some("snap"), "its results came back with it");
        let results: i64 = db.query_row("SELECT COUNT(*) FROM saved_query_results", [], |r| r.get(0)).unwrap();
        assert_eq!(results, 1, "the stray staged row went with the Session it replaced");
        assert_eq!(sqlite::load_tags(&db).unwrap()[0].name, "Suspect");
        let variables = sqlite::load_query_variables(&db).unwrap();
        assert_eq!(variables.iter().map(|v| v.name.as_str()).collect::<Vec<_>>(), vec!["env", "only-here"]);
        assert_eq!(variables[0].value, "prod");
        let history: i64 = db.query_row("SELECT COUNT(*) FROM query_history", [], |r| r.get(0)).unwrap();
        assert_eq!(history, 2, "the row only the store had is still there");
        drop(db);
        let _ = std::fs::remove_dir_all(&dir);
    }

    /// Without its results, a Session arrives with no snapshot pointer; with a
    /// connection the store lacks, it arrives with no connection; a history
    /// row's missing workspace is dropped the same way.
    #[test]
    fn references_the_store_cannot_satisfy_are_cleared() {
        let _keychain = credentials::isolated_keychain("backup_refs");
        let rt = tokio::runtime::Runtime::new().unwrap();
        let (from_dir, to_dir) = (temp_dir("refs_from"), temp_dir("refs_to"));
        let from = state_in(&from_dir);
        rt.block_on(seed(&from));
        from.metadata_db
            .lock()
            .unwrap()
            .execute("UPDATE query_history SET workspace_id = 'w-gone' WHERE id = 'h1'", [])
            .unwrap();
        let file = from_dir.join("r.pharosdata");
        let mut options =
            export_options(&file, BackupCategories { sessions: true, history: true, ..Default::default() }, None);
        options.include_session_results = false;
        let exported = rt.block_on(export_app_data(options, &from)).unwrap();
        assert_eq!(exported.summary.session_results, Some(0));

        let to = state_in(&to_dir);
        rt.block_on(import_app_data(import_options(&file, None, ConflictPolicy::Replace), &to)).unwrap();
        let db = to.metadata_db.lock().unwrap();
        let session = sqlite::get_saved_query(&db, "s1").unwrap().unwrap();
        assert_eq!(session.connection_id, None, "no such connection here");
        assert_eq!(session.results_snapshot_id, None);
        assert_eq!(session.result_count, None);
        let workspace: Option<String> =
            db.query_row("SELECT workspace_id FROM query_history WHERE id = 'h1'", [], |r| r.get(0)).unwrap();
        assert_eq!(workspace, None);
        drop(db);
        let _ = std::fs::remove_dir_all(&from_dir);
        let _ = std::fs::remove_dir_all(&to_dir);
    }

    /// A column the file has and the store lacks is left out; one the store
    /// has and the file lacks takes its default. A file from another build
    /// still imports.
    #[test]
    fn rows_import_by_the_columns_both_sides_have() {
        let dir = temp_dir("columns");
        let state = state_in(&dir);
        let dump = TableDump {
            columns: vec![
                "id".into(), "connection_id".into(), "connection_name".into(), "sql".into(),
                "execution_time_ms".into(), "executed_at".into(), "from_the_future".into(),
            ],
            rows: vec![vec![
                "h9".into(), "c".into(), "n".into(), "select 9".into(), 7.into(), "2026-01-01".into(), true.into(),
            ]],
        };
        let mut db = state.metadata_db.lock().unwrap();
        let outcome = import_history(&mut db, &dump).unwrap();
        assert_eq!(outcome.added, 1);
        let status: String = db.query_row("SELECT status FROM query_history WHERE id = 'h9'", [], |r| r.get(0)).unwrap();
        assert_eq!(status, "ok", "the column the file lacks takes its default");
        drop(db);
        let _ = std::fs::remove_dir_all(&dir);
    }

    #[test]
    fn variables_merge_by_id_then_by_name_and_scope() {
        let mut scoped = variable("x", "env", "scoped");
        scoped.connection_ids = vec!["c1".into()];
        let existing = vec![variable("a", "env", "old"), scoped];
        let incoming = vec![
            variable("b", "env", "new"),   // same name, same (global) scope as "a"
            variable("a", "renamed", "r"), // same id as "a"
            variable("x", "other", "o"),   // same id as the scoped one: the id wins over the name
            variable("z", "fresh", "f"),   // new
        ];
        let (merged, outcome) = merge_variables(existing, &incoming, ConflictPolicy::Replace);
        assert_eq!(outcome.replaced, 3);
        assert_eq!(outcome.added, 1);
        assert_eq!(merged.len(), 3);
        assert_eq!(merged[0].id, "a", "the store's id stays");
        assert_eq!(merged[0].name, "renamed");
        assert_eq!(merged[2].name, "fresh");

        let mut global_only = variable("q", "env", "g");
        global_only.connection_ids = vec![];
        let mut linked = variable("w", "env", "linked");
        linked.connection_ids = vec!["c2".into()];
        let (merged, outcome) = merge_variables(vec![global_only], &[linked], ConflictPolicy::Keep);
        assert_eq!(outcome.added, 1, "the same name in another scope is another variable");
        assert_eq!(merged.len(), 2);
    }

    #[test]
    fn values_round_trip_through_json() {
        for value in [
            SqlValue::Null,
            SqlValue::Integer(-42),
            SqlValue::Real(1.5),
            SqlValue::Text("héllo".into()),
            SqlValue::Blob(vec![0, 1, 254, 255]),
        ] {
            let json = sql_to_json(ValueRef::from(&value));
            assert_eq!(json_to_sql(&json), value);
        }
    }
}
