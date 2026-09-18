use keyring::Entry;
use std::collections::HashMap;

const DEFAULT_SERVICE_NAME: &str = "com.pharos.client";
const CREDENTIALS_KEY: &str = "connection-passwords";

/// Keychain service name. `PHAROS_KEYCHAIN_SERVICE` overrides it so a
/// re-identified test copy of the app keeps its passwords apart from the
/// user's; the shipped app never sets it.
fn service_name() -> String {
    std::env::var("PHAROS_KEYCHAIN_SERVICE").unwrap_or_else(|_| DEFAULT_SERVICE_NAME.to_string())
}

/// Key convention inside the one Keychain blob.
///
/// The blob is a `HashMap<String, String>`. A connection's DATABASE password
/// is held under the bare connection id. Every other secret for the same
/// connection takes a suffixed key, so one map serves them all and the
/// existing migration path is untouched. Today there is one suffix:
///
///   `"<connection id>"`      the PostgreSQL password
///   `"<connection id>/ssh"`  the SSH password or key passphrase
///
/// A connection id is a UUID, so it can never contain `/` and the two key
/// spaces cannot collide.
pub fn ssh_secret_key(connection_id: &str) -> String {
    format!("{}/ssh", connection_id)
}

/// Get the single keychain entry that stores all connection passwords
fn get_credentials_entry() -> Result<Entry, String> {
    Entry::new(&service_name(), CREDENTIALS_KEY)
        .map_err(|e| format!("Failed to create keyring entry: {}", e))
}

/// Load all passwords from the keychain as a HashMap.
/// This is called once at startup to populate the in-memory cache.
pub fn load_all_passwords() -> Result<HashMap<String, String>, String> {
    let entry = get_credentials_entry()?;

    match entry.get_password() {
        Ok(json) => {
            serde_json::from_str(&json)
                .map_err(|e| format!("Failed to parse credentials: {}", e))
        }
        Err(keyring::Error::NoEntry) => Ok(HashMap::new()),
        Err(e) => Err(format!("Failed to retrieve credentials: {}", e)),
    }
}

/// Save all passwords to the keychain
fn save_all_passwords(passwords: &HashMap<String, String>) -> Result<(), String> {
    let entry = get_credentials_entry()?;

    if passwords.is_empty() {
        // Delete the entry if no passwords remain
        match entry.delete_credential() {
            Ok(()) => Ok(()),
            Err(keyring::Error::NoEntry) => Ok(()),
            Err(e) => Err(format!("Failed to delete credentials: {}", e)),
        }
    } else {
        let json = serde_json::to_string(passwords)
            .map_err(|e| format!("Failed to serialize credentials: {}", e))?;

        entry
            .set_password(&json)
            .map_err(|e| format!("Failed to store credentials: {}", e))
    }
}

/// Store one secret securely in the OS keychain (also updates the provided
/// cache). `key` follows the convention in `ssh_secret_key` above: the bare
/// connection id for the database password, `"<id>/ssh"` for the SSH secret.
pub fn store_password_with_cache(
    key: &str,
    password: &str,
    cache: &mut HashMap<String, String>,
) -> Result<(), String> {
    cache.insert(key.to_string(), password.to_string());
    save_all_passwords(cache)
}

/// Remove one secret from the OS keychain (also updates the provided cache).
/// `key` follows the same convention as `store_password_with_cache`.
pub fn delete_password_with_cache(
    key: &str,
    cache: &mut HashMap<String, String>,
) -> Result<(), String> {
    cache.remove(key);
    save_all_passwords(cache)
}

/// Delete EVERY secret a connection owns — the database password and the SSH
/// secret — in one Keychain write.
///
/// Deleting a connection must not leave an orphan secret behind, and two
/// separate deletes would write the blob twice and could leave the second
/// secret if the first write failed.
pub fn delete_connection_secrets_with_cache(
    connection_id: &str,
    cache: &mut HashMap<String, String>,
) -> Result<(), String> {
    forget_connection_secrets(connection_id, cache);
    save_all_passwords(cache)
}

/// Which keys a connection owns, as a pure cache edit. Split out so a test can
/// run the real rule without a Keychain.
fn forget_connection_secrets(connection_id: &str, cache: &mut HashMap<String, String>) {
    cache.remove(connection_id);
    cache.remove(&ssh_secret_key(connection_id));
}

/// Migrate passwords from old per-connection keychain entries to the new unified entry.
/// This should be called once during app startup.
/// Returns the final merged password map (including both migrated and existing).
pub fn migrate_legacy_passwords(connection_ids: &[String]) -> Result<HashMap<String, String>, String> {
    let mut passwords = load_all_passwords()?;
    let mut migrated_count = 0;

    for connection_id in connection_ids {
        // Skip if we already have this password in the new format
        if passwords.contains_key(connection_id) {
            continue;
        }

        // Try to read from the old per-connection entry
        let legacy_entry = match Entry::new(&service_name(), connection_id) {
            Ok(entry) => entry,
            Err(_) => continue,
        };

        if let Ok(password) = legacy_entry.get_password() {
            // Store in the new unified format
            passwords.insert(connection_id.clone(), password);
            migrated_count += 1;

            // Delete the old entry (best effort, don't fail if this doesn't work)
            let _ = legacy_entry.delete_credential();
        }
    }

    if migrated_count > 0 {
        save_all_passwords(&passwords)?;
        log::info!("Migrated {} passwords to unified keychain entry", migrated_count);
    }

    Ok(passwords)
}

#[cfg(test)]
mod key_convention_tests {
    use super::*;

    /// The suffix is a contract: `commands::connection` writes and reads the
    /// SSH secret under it, and `migrate_legacy_passwords` must never mistake
    /// it for a connection id. A connection id is a UUID, so the separator
    /// cannot appear inside one.
    #[test]
    fn the_ssh_key_suffixes_the_connection_id() {
        let id = "9d56a337-0000-4000-8000-000000000001";
        assert_eq!(ssh_secret_key(id), format!("{id}/ssh"));
        assert_ne!(ssh_secret_key(id), id, "the two secrets need distinct keys");
    }

    /// Deleting a connection clears BOTH keys and leaves every other
    /// connection's secrets alone.
    #[test]
    fn deleting_a_connection_clears_both_of_its_keys_only() {
        let mut cache = HashMap::new();
        cache.insert("a".to_string(), "db-a".to_string());
        cache.insert(ssh_secret_key("a"), "ssh-a".to_string());
        cache.insert("b".to_string(), "db-b".to_string());
        cache.insert(ssh_secret_key("b"), "ssh-b".to_string());

        // The production rule itself, without the Keychain write that follows
        // it in `delete_connection_secrets_with_cache`.
        forget_connection_secrets("a", &mut cache);

        assert!(!cache.contains_key("a"));
        assert!(!cache.contains_key(&ssh_secret_key("a")), "no orphan SSH secret");
        assert_eq!(cache.get("b").map(String::as_str), Some("db-b"));
        assert_eq!(cache.get(&ssh_secret_key("b")).map(String::as_str), Some("ssh-b"));
    }
}
