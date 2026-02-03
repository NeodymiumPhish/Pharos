use keyring::Entry;

const SERVICE_NAME: &str = "com.pharos.client";

/// Store a password securely in the OS keychain
pub fn store_password(connection_id: &str, password: &str) -> Result<(), String> {
    let entry = Entry::new(SERVICE_NAME, connection_id)
        .map_err(|e| format!("Failed to create keyring entry: {}", e))?;

    entry
        .set_password(password)
        .map_err(|e| format!("Failed to store password: {}", e))?;

    Ok(())
}

/// Retrieve a password from the OS keychain
pub fn get_password(connection_id: &str) -> Result<Option<String>, String> {
    let entry = Entry::new(SERVICE_NAME, connection_id)
        .map_err(|e| format!("Failed to create keyring entry: {}", e))?;

    match entry.get_password() {
        Ok(password) => Ok(Some(password)),
        Err(keyring::Error::NoEntry) => Ok(None),
        Err(e) => Err(format!("Failed to retrieve password: {}", e)),
    }
}

/// Delete a password from the OS keychain
pub fn delete_password(connection_id: &str) -> Result<(), String> {
    let entry = Entry::new(SERVICE_NAME, connection_id)
        .map_err(|e| format!("Failed to create keyring entry: {}", e))?;

    match entry.delete_credential() {
        Ok(()) => Ok(()),
        Err(keyring::Error::NoEntry) => Ok(()), // Already deleted, not an error
        Err(e) => Err(format!("Failed to delete password: {}", e)),
    }
}
