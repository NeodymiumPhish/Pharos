import Foundation
import CPharosCore

// MARK: - Settings

extension PharosCore {

    /// Load application settings.
    static func loadSettings() throws -> AppSettings {
        guard let ptr = pharos_load_settings() else {
            throw PharosCoreError.nullResult
        }
        defer { pharos_free_string(ptr) }
        let json = String(cString: ptr)
        return try JSONDecoder.pharos.decode(AppSettings.self, from: Data(json.utf8))
    }

    /// Save application settings.
    static func saveSettings(_ settings: AppSettings) throws {
        let json = try JSONEncoder.pharos.encode(settings)
        let jsonStr = String(data: json, encoding: .utf8)!
        let error = jsonStr.withCString { pharos_save_settings($0) }
        if let error {
            defer { pharos_free_string(error) }
            throw PharosCoreError.rustError(String(cString: error))
        }
    }
}
