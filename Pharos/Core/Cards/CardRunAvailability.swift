import Foundation

/// Why a tab's cards cannot run, or nil when they can. The text is what the
/// greyed-out Run button says when the pointer rests on it, and what
/// VoiceOver reads as the button's help.
enum CardRunAvailability {
    /// - Parameters:
    ///   - connectionId: the tab's connection, nil when the tab has none.
    ///   - connectionName: that connection's name, nil when it no longer exists.
    ///   - status: that connection's status, nil when it was never connected.
    static func reason(connectionId: String?, connectionName: String?, status: ConnectionStatus?) -> String? {
        guard connectionId != nil, let name = connectionName else {
            return String(localized: "This tab has no database connection. Choose one from the Connection menu in the toolbar to run this card.")
        }
        switch status {
        case .connected:
            return nil
        case .connecting:
            return String(localized: "Connecting to “\(name)”. You can run this card when the connection is ready.")
        case .error:
            return String(localized: "Could not connect to “\(name)”. Choose Connect from the Connection menu in the toolbar to try again.")
        case .disconnected, nil:
            return String(localized: "Not connected to “\(name)”. Choose Connect from the Connection menu in the toolbar to run this card.")
        }
    }
}
