//! The API key of the custom AI endpoint (Settings ▸ Intelligence).
//!
//! The endpoint's address and model name are ordinary settings
//! (`IntelligenceSettings::endpoint`). The key is a secret, so it lives in
//! the Keychain blob under `intelligence/endpoint-key`, beside the
//! connection passwords, and is never written to the settings row, to a
//! backup file or to a log.
//!
//! There is one endpoint, so there is one key. The app reads it back
//! (`endpoint_key`) because the request to the endpoint is made there.

use crate::db::credentials;
use crate::state::AppState;

/// The Keychain key. A connection id is a UUID, so this cannot collide with
/// a connection's own entries (see `credentials::ssh_secret_key`).
pub const ENDPOINT_KEY: &str = "intelligence/endpoint-key";

/// Keep the endpoint's API key in the Keychain. An empty key is a removal:
/// an empty entry would read as "a key is stored" to anything that only
/// checks for presence.
pub fn store_endpoint_key(state: &AppState, key: &str) -> Result<(), String> {
    if key.is_empty() {
        return delete_endpoint_key(state);
    }
    let mut cache = state.password_cache.lock().unwrap_or_else(|e| e.into_inner());
    credentials::store_password_with_cache(ENDPOINT_KEY, key, &mut cache)
}

/// Remove the endpoint's API key from the Keychain.
pub fn delete_endpoint_key(state: &AppState) -> Result<(), String> {
    let mut cache = state.password_cache.lock().unwrap_or_else(|e| e.into_inner());
    if !cache.contains_key(ENDPOINT_KEY) {
        return Ok(());
    }
    credentials::delete_password_with_cache(ENDPOINT_KEY, &mut cache)
}

/// The stored key, or None when there is none.
pub fn endpoint_key(state: &AppState) -> Option<String> {
    state.get_cached_password(ENDPOINT_KEY).filter(|key| !key.is_empty())
}

#[cfg(test)]
mod tests {
    use super::*;

    fn state() -> AppState {
        let sqlite = rusqlite::Connection::open_in_memory().unwrap();
        crate::db::sqlite::create_schema(&sqlite).unwrap();
        AppState::new(sqlite)
    }

    #[test]
    fn the_key_is_stored_read_and_removed() {
        let _keychain = credentials::isolated_keychain("intelligence_key");
        let state = state();
        assert_eq!(endpoint_key(&state), None, "nothing stored to begin with");
        delete_endpoint_key(&state).expect("removing nothing is not an error");

        store_endpoint_key(&state, "sk-test-1").expect("store");
        assert_eq!(endpoint_key(&state).as_deref(), Some("sk-test-1"));
        let stored = credentials::load_all_passwords().expect("read keychain");
        assert_eq!(stored.get(ENDPOINT_KEY).map(String::as_str), Some("sk-test-1"), "it reached the Keychain");

        store_endpoint_key(&state, "sk-test-2").expect("replace");
        assert_eq!(endpoint_key(&state).as_deref(), Some("sk-test-2"), "a second store replaces the first");

        store_endpoint_key(&state, "").expect("an empty key removes");
        assert_eq!(endpoint_key(&state), None);
        let stored = credentials::load_all_passwords().expect("read keychain");
        assert!(!stored.contains_key(ENDPOINT_KEY), "no empty entry is left behind");
    }

    #[test]
    fn other_secrets_are_untouched() {
        let _keychain = credentials::isolated_keychain("intelligence_key_others");
        let state = state();
        {
            let mut cache = state.password_cache.lock().unwrap();
            credentials::store_password_with_cache("11111111-2222-3333-4444-555555555555", "db-password", &mut cache)
                .expect("store a connection password");
        }
        store_endpoint_key(&state, "sk-test").expect("store");
        delete_endpoint_key(&state).expect("delete");
        let stored = credentials::load_all_passwords().expect("read keychain");
        assert_eq!(
            stored.get("11111111-2222-3333-4444-555555555555").map(String::as_str),
            Some("db-password"),
            "a connection's password survives the key coming and going"
        );
    }
}
