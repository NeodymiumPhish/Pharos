import Foundation

/// Why a tab's cards cannot run, or nil when they can. The text is what the
/// greyed-out Run button says when the pointer rests on it, and what
/// VoiceOver reads as the button's help.
enum CardRunAvailability {
    /// - Parameters:
    ///   - connectionId: the tab's connection, nil when the tab has none.
    ///   - connectionName: that connection's name, nil when it no longer exists.
    ///   - status: that connection's status, nil when it was never connected.
    ///   - error: that connection's raw last error. A DuckDB file that is not
    ///     there, or that another app holds, gets the button the context row
    ///     shows for it (`TabContextState`), not Try Again.
    static func reason(connectionId: String?, connectionName: String?, status: ConnectionStatus?,
                       error: String? = nil) -> String? {
        guard connectionId != nil, let name = connectionName else {
            return String(localized: "This tab has no database connection. Choose one from the Connection pop-up above the cards.")
        }
        switch status {
        case .connected:
            return nil
        case .connecting:
            return String(localized: "Connecting to “\(name)”. You can run this card when the connection is ready.")
        case .error:
            if DuckDBOpenError.isMissing(error) {
                return String(localized: "The file for “\(name)” can’t be found. Click Locate… above the cards.")
            }
            if DuckDBOpenError.isTooNew(error) {
                return String(localized: "“\(name)” was written by a newer DuckDB, which this version of Pharos cannot open.")
            }
            if DuckDBOpenError.isLocked(error) {
                return String(localized: "Another app is using the file for “\(name)”. Click Open Read-Only above the cards, or quit that app and choose File ▸ Connect.")
            }
            return String(localized: "Could not connect to “\(name)”. Click Try Again above the cards, or choose File ▸ Connect.")
        case .disconnected, nil:
            return String(localized: "Not connected to “\(name)”. Click Connect above the cards, or choose File ▸ Connect.")
        }
    }
}
