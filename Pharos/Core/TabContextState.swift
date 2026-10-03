import Foundation

/// What a tab's context row says about its connection, beside the connection
/// and schema pop-ups. Pure, so every state is tested without AppKit.
enum TabContextState: Equatable {
    /// The tab has no connection chosen.
    case chooseConnection
    case notConnected
    case connecting
    case connected
    case failed(reason: String?)

    /// - Parameters:
    ///   - connectionName: the tab's connection's name; nil when the tab has
    ///     none, or its connection no longer exists.
    ///   - status: that connection's status.
    ///   - failureReason: why its last connect attempt failed.
    init(connectionName: String?, status: ConnectionStatus?, failureReason: String?) {
        guard connectionName != nil else { self = .chooseConnection; return }
        switch status {
        case .connected: self = .connected
        case .connecting: self = .connecting
        case .error: self = .failed(reason: failureReason)
        case .disconnected, nil: self = .notConnected
        }
    }

    /// The words beside the pop-ups.
    var text: String {
        switch self {
        case .chooseConnection: return String(localized: "Choose a database for this tab.")
        case .notConnected: return String(localized: "Not connected")
        case .connecting: return String(localized: "Connecting…")
        case .connected: return String(localized: "Connected")
        case .failed: return String(localized: "Could not connect")
        }
    }

    /// The button after the words, which connects; nil when there is none.
    var buttonTitle: String? {
        switch self {
        case .notConnected: return String(localized: "Connect")
        case .failed: return String(localized: "Try Again")
        case .chooseConnection, .connecting, .connected: return nil
        }
    }

    var showsSpinner: Bool { self == .connecting }

    /// The failure's reason, on the words and the button.
    var toolTip: String? {
        if case let .failed(reason) = self { return reason }
        return nil
    }
}
