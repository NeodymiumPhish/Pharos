//! DuckDB cloud storage credentials (Settings ▸ Connections ▸ DuckDB, D12).
//!
//! Each entry becomes a TEMPORARY secret of every DuckDB database when it
//! opens, so `read_parquet('s3://…')` works with no `CREATE SECRET` card —
//! a card's text stays in plain text in relaunch restore and in saved
//! Sessions. The secret key itself lives in the Keychain blob under
//! `duckdb-cloud/<id>`; the other fields are ordinary settings. Temporary
//! secrets belong to the instance and go with it (plan: no persistent
//! secrets, `secret_directory` private).

use crate::db::credentials;
use crate::db::duckdb::DuckDbInstance;
use crate::models::{CloudProvider, DuckdbCloudSecret};
use crate::state::AppState;

/// The Keychain key of an entry's secret.
pub fn secret_key(id: &str) -> String {
    format!("duckdb-cloud/{}", id)
}

/// The DuckDB secret's name for an entry: `pharos_cloud_` and the id's
/// letters and digits, so a user's own `CREATE SECRET` names never clash.
pub fn secret_name(id: &str) -> String {
    let safe: String = id.chars().map(|c| if c.is_ascii_alphanumeric() { c.to_ascii_lowercase() } else { '_' }).collect();
    format!("pharos_cloud_{}", safe)
}

fn literal(value: &str) -> String {
    format!("'{}'", value.replace('\'', "''"))
}

/// The `CREATE OR REPLACE TEMPORARY SECRET` for one entry, or None when it
/// cannot work (no key id, no secret, R2 with no account id).
pub fn create_statement(entry: &DuckdbCloudSecret, secret: &str) -> Option<String> {
    if entry.key_id.trim().is_empty() || secret.is_empty() {
        return None;
    }
    let mut options = vec![
        format!("TYPE {}", match entry.provider { CloudProvider::S3 => "s3", CloudProvider::R2 => "r2", CloudProvider::Gcs => "gcs" }),
        format!("KEY_ID {}", literal(entry.key_id.trim())),
        format!("SECRET {}", literal(secret)),
    ];
    match entry.provider {
        CloudProvider::S3 => {
            if !entry.region.trim().is_empty() {
                options.push(format!("REGION {}", literal(entry.region.trim())));
            }
            if !entry.endpoint.trim().is_empty() {
                options.push(format!("ENDPOINT {}", literal(entry.endpoint.trim())));
                // S3-compatible stores (MinIO and others) address buckets by path.
                options.push("URL_STYLE 'path'".to_string());
            }
        }
        CloudProvider::R2 => {
            if entry.account_id.trim().is_empty() {
                return None;
            }
            options.push(format!("ACCOUNT_ID {}", literal(entry.account_id.trim())));
        }
        CloudProvider::Gcs => {}
    }
    if !entry.scope.trim().is_empty() {
        options.push(format!("SCOPE {}", literal(entry.scope.trim())));
    }
    Some(format!("CREATE OR REPLACE TEMPORARY SECRET {} ({})", secret_name(&entry.id), options.join(", ")))
}

/// Make every configured entry a secret of this database. Run when a
/// database opens and when the settings change; a failing entry is logged
/// and skipped, never a failed connect.
pub fn apply(state: &AppState, instance: &DuckDbInstance) {
    let entries = state.settings().connections.duckdb_cloud_secrets.clone();
    let wanted: Vec<String> = entries.iter().map(|e| secret_name(&e.id)).collect();
    let Ok(conn) = instance.connect() else { return };
    // Entries removed since the last apply.
    if let Ok(mut stmt) = conn.prepare("SELECT name FROM duckdb_secrets() WHERE name LIKE 'pharos_cloud_%'") {
        let existing: Vec<String> = stmt
            .query_map([], |r| r.get::<_, String>(0))
            .map(|rows| rows.filter_map(Result::ok).collect())
            .unwrap_or_default();
        for name in existing.iter().filter(|n| !wanted.contains(n)) {
            let _ = conn.execute_batch(&format!("DROP TEMPORARY SECRET IF EXISTS {}", name));
        }
    }
    for entry in &entries {
        let secret = state.get_cached_password(&secret_key(&entry.id)).unwrap_or_default();
        match create_statement(entry, &secret) {
            Some(sql) => {
                if let Err(e) = conn.execute_batch(&sql) {
                    log::warn!("DuckDB: cloud secret \"{}\" was not set: {}", entry.name, e);
                }
            }
            None => {
                let _ = conn.execute_batch(&format!("DROP TEMPORARY SECRET IF EXISTS {}", secret_name(&entry.id)));
            }
        }
    }
}

/// Apply the entries to every open DuckDB database (each instance once).
pub fn sync_open(state: &AppState) {
    let mut seen: Vec<*const DuckDbInstance> = Vec::new();
    let instances: Vec<_> = {
        let dbs = state.duck_dbs.lock().unwrap_or_else(|e| e.into_inner());
        dbs.values().cloned().collect()
    };
    for instance in instances {
        let ptr = std::sync::Arc::as_ptr(&instance);
        if seen.contains(&ptr) {
            continue;
        }
        seen.push(ptr);
        apply(state, &instance);
    }
}

/// Keep an entry's secret key in the Keychain, then apply it.
pub fn store_secret(state: &AppState, id: &str, secret: &str) -> Result<(), String> {
    {
        let mut cache = state.password_cache.lock().unwrap_or_else(|e| e.into_inner());
        credentials::store_password_with_cache(&secret_key(id), secret, &mut cache)?;
    }
    sync_open(state);
    Ok(())
}

/// Remove an entry's secret key from the Keychain (the entry was deleted).
pub fn delete_secret(state: &AppState, id: &str) -> Result<(), String> {
    {
        let mut cache = state.password_cache.lock().unwrap_or_else(|e| e.into_inner());
        credentials::delete_password_with_cache(&secret_key(id), &mut cache)?;
    }
    sync_open(state);
    Ok(())
}

/// Whether an entry has a secret key stored (the UI shows "Saved").
pub fn has_secret(state: &AppState, id: &str) -> bool {
    state.get_cached_password(&secret_key(id)).is_some_and(|s| !s.is_empty())
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::db::duckdb::{OpenOptions, IN_MEMORY};

    fn entry(provider: CloudProvider) -> DuckdbCloudSecret {
        DuckdbCloudSecret {
            id: "A-1".into(), name: "lake".into(), provider, key_id: "AKIA".into(), region: "eu-west-1".into(),
            endpoint: String::new(), account_id: "acct".into(), scope: "s3://bucket".into(),
        }
    }

    #[test]
    fn statements_per_provider() {
        assert_eq!(create_statement(&entry(CloudProvider::S3), "s'k").as_deref(),
                   Some("CREATE OR REPLACE TEMPORARY SECRET pharos_cloud_a_1 (TYPE s3, KEY_ID 'AKIA', SECRET 's''k', REGION 'eu-west-1', SCOPE 's3://bucket')"));
        let mut minio = entry(CloudProvider::S3);
        minio.endpoint = "minio.local:9000".into();
        assert!(create_statement(&minio, "k").unwrap().contains("ENDPOINT 'minio.local:9000', URL_STYLE 'path'"));
        assert!(create_statement(&entry(CloudProvider::R2), "k").unwrap().contains("TYPE r2, KEY_ID 'AKIA', SECRET 'k', ACCOUNT_ID 'acct'"));
        let mut r2 = entry(CloudProvider::R2);
        r2.account_id.clear();
        assert_eq!(create_statement(&r2, "k"), None, "R2 needs its account id");
        assert_eq!(create_statement(&entry(CloudProvider::Gcs), "").as_deref(), None, "no secret, no statement");
    }

    /// A temporary secret made on one connection of an instance is seen by
    /// every other connection of it (a card's tab connection, a catalog
    /// read), and goes when the entry goes.
    #[test]
    fn a_secret_reaches_every_connection_of_the_instance() {
        let state = {
            let sqlite = rusqlite::Connection::open_in_memory().unwrap();
            crate::db::sqlite::create_schema(&sqlite).unwrap();
            AppState::new(sqlite)
        };
        let mut settings = (*state.settings()).clone();
        settings.connections.duckdb_cloud_secrets = vec![entry(CloudProvider::S3)];
        state.replace_settings(settings.clone());
        state.init_password_cache([(secret_key("A-1"), "topsecret".to_string())].into_iter().collect());
        let instance = DuckDbInstance::open(IN_MEMORY, false, &OpenOptions::default()).unwrap();
        apply(&state, &instance);
        let other = instance.connect().unwrap();
        let (name, scope): (String, String) = other
            .query_row("SELECT name, scope::VARCHAR FROM duckdb_secrets() WHERE name LIKE 'pharos_cloud_%'", [], |r| {
                Ok((r.get(0)?, r.get(1)?))
            })
            .unwrap();
        assert_eq!(name, "pharos_cloud_a_1");
        assert!(scope.contains("s3://bucket"), "{scope}");
        let shown: String = other.query_row("SELECT secret_string FROM duckdb_secrets() WHERE name = 'pharos_cloud_a_1'", [], |r| r.get(0)).unwrap();
        assert!(!shown.contains("topsecret"), "DuckDB redacts the secret: {shown}");
        // The entry removed: the secret goes at the next apply.
        settings.connections.duckdb_cloud_secrets.clear();
        state.replace_settings(settings);
        apply(&state, &instance);
        let left: i64 = other.query_row("SELECT count(*) FROM duckdb_secrets() WHERE name LIKE 'pharos_cloud_%'", [], |r| r.get(0)).unwrap();
        assert_eq!(left, 0);
    }
}
