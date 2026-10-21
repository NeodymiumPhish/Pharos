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
    /// A DuckDB record's file is not there (moved, renamed, deleted, or its
    /// disk is not connected). The button locates it.
    case fileNotFound(reason: String?)

    /// - Parameters:
    ///   - connectionName: the tab's connection's name; nil when the tab has
    ///     none, or its connection no longer exists.
    ///   - status: that connection's status.
    ///   - failureReason: why its last connect attempt failed.
    ///   - missingFile: the failure was a DuckDB file that is not there.
    init(connectionName: String?, status: ConnectionStatus?, failureReason: String?, missingFile: Bool = false) {
        guard connectionName != nil else { self = .chooseConnection; return }
        switch status {
        case .connected: self = .connected
        case .connecting: self = .connecting
        case .error: self = missingFile ? .fileNotFound(reason: failureReason) : .failed(reason: failureReason)
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
        case .fileNotFound: return String(localized: "File not found")
        }
    }

    /// The button after the words, which connects; nil when there is none.
    var buttonTitle: String? {
        switch self {
        case .notConnected: return String(localized: "Connect")
        case .failed: return String(localized: "Try Again")
        case .fileNotFound: return String(localized: "Locate…")
        case .chooseConnection, .connecting, .connected: return nil
        }
    }

    var showsSpinner: Bool { self == .connecting }

    /// The failure's reason, on the words and the button.
    var toolTip: String? {
        switch self {
        case let .failed(reason), let .fileNotFound(reason): return reason
        default: return nil
        }
    }
}

/// Why a connection is open read-only, as the core opened it.
enum ReadOnlyReason: Equatable {
    /// The record's Read-only setting.
    case recordSetting
    /// The lock alert's Open Read-Only: another app holds the file.
    case otherAppHoldsFile
}

/// The context row's Read-only badge: shown while the tab's connection is
/// open read-only, with help that says why and how to write. A persistent
/// mark, not an alert (HIG, Alerts: avoid an alert merely to inform).
enum ReadOnlyBadge {
    /// The badge's help, or nil when no badge shows. `reportReadOnly`: the
    /// tab session's own report, which for PostgreSQL follows the record's
    /// CURRENT setting (each tab session reads it).
    static func help(isConnected: Bool, engine: DatabaseEngine, reason: ReadOnlyReason?, reportReadOnly: Bool?) -> String? {
        guard isConnected else { return nil }
        let effective: ReadOnlyReason?
        if engine == .postgres, let reportReadOnly {
            effective = reportReadOnly ? (reason ?? .recordSetting) : nil
        } else {
            effective = reason
        }
        switch effective {
        case nil:
            return nil
        case .otherAppHoldsFile:
            return String(localized: "Opened read-only because another app holds the file. Disconnect, then connect again when the other app closes it.")
        case .recordSetting:
            switch engine {
            case .duckdb:
                return String(localized: "This connection is set to Read-only. To write, turn off Read-only in the Connections Manager, then disconnect and connect again.")
            case .postgres:
                return String(localized: "This connection is set to Read-only, so the server refuses writes. To write, turn off Read-only in the Connections Manager.")
            }
        }
    }
}
