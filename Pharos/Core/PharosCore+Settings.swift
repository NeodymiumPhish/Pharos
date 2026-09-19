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

    /// Tell the engine how much to write to the system log.
    ///
    /// Returns false, having changed nothing, when `RUST_LOG` is set in the
    /// environment: a level named there is the developer's explicit choice
    /// and outranks the one stored in Settings.
    @discardableResult
    static func setLogLevel(_ level: LogLevel) -> Bool {
        level.rawValue.withCString { pharos_set_log_level($0) }
    }
}
