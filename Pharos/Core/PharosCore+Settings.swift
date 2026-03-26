import Foundation
import CPharosCore

// MARK: - Settings

extension PharosCore {

    /// Load application settings.
    static func loadSettings() throws -> AppSettings {
        try callSync { pharos_load_settings() }
    }

    /// Save application settings.
    static func saveSettings(_ settings: AppSettings) throws {
        try callSyncVoid(input: settings) { pharos_save_settings($0) }
    }
}
