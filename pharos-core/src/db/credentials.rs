use keyring::Entry;
use std::collections::HashMap;

const SERVICE_NAME: &str = "com.pharos.client";
const CREDENTIALS_KEY: &str = "connection-passwords";

/// Get the single keychain entry that stores all connection passwords
fn get_credentials_entry() -> Result<Entry, String> {
    Entry::new(SERVICE_NAME, CREDENTIALS_KEY)
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

/// Store a password securely in the OS keychain (also updates the provided cache)
pub fn store_password_with_cache(
    connection_id: &str,
    password: &str,
    cache: &mut HashMap<String, String>,
) -> Result<(), String> {
    cache.insert(connection_id.to_string(), password.to_string());
    save_all_passwords(cache)
}

/// Delete a password from the OS keychain (also updates the provided cache)
pub fn delete_password_with_cache(
    connection_id: &str,
    cache: &mut HashMap<String, String>,
) -> Result<(), String> {
    cache.remove(connection_id);
    save_all_passwords(cache)
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
        let legacy_entry = match Entry::new(SERVICE_NAME, connection_id) {
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
