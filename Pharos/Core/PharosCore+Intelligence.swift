import Foundation
import CPharosCore

// The custom AI endpoint's API key (Settings ▸ Intelligence). The address and
// the model name are ordinary settings; the key is kept in the Keychain by
// the core and is never part of `AppSettings`.
extension PharosCore {

    /// Keep the key in the Keychain; false when the Keychain refused it.
    @discardableResult
    static func storeIntelligenceEndpointKey(_ key: String) -> Bool {
        key.withCString { pharos_intelligence_endpoint_key_store($0) }
    }

    /// Remove the key. Removing a key that is not there succeeds.
    @discardableResult
    static func deleteIntelligenceEndpointKey() -> Bool {
        pharos_intelligence_endpoint_key_delete()
    }

    /// The stored key, or nil when there is none. Read it when a request is
    /// built and do not keep it.
    static func intelligenceEndpointKey() -> String? {
        let key: String?? = try? callSync { pharos_intelligence_endpoint_key() }
        return key ?? nil
    }
}
