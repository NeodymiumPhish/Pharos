import Foundation

/// What the banner above a tab's cards says about the tab's own connection.
/// Pure (Foundation only), so the harness tests every state without AppKit.
enum TabSessionBannerState: Equatable {
    /// A transaction is open. `idleRemaining` counts down the server's
    /// idle-in-transaction limit from the last statement; nil when there is none.
    case transaction(elapsed: TimeInterval, idleRemaining: TimeInterval?)
    /// An error aborted the transaction: only Roll Back works.
    case failed
    /// The connection was replaced; what it held is gone.
    case reset(reason: String)

    var message: String {
        switch self {
        case let .transaction(elapsed, idleRemaining):
            let open = String(localized: "Transaction open for \(TabSessionBannerModel.duration(elapsed)).")
            guard let idleRemaining else { return open }
            if idleRemaining <= 0 {
                return open + " " + String(localized: "The server's idle limit has passed; it has probably rolled the transaction back.")
            }
            return open + " " + String(localized: "The server rolls it back after \(TabSessionBannerModel.duration(idleRemaining)) more idle.")
        case .failed:
            return String(localized: "The transaction failed. Roll it back to run more cards.")
        case let .reset(reason):
            return String(localized: "The tab's connection was reset: \(reason). Its settings, temporary tables and any open transaction are gone.")
        }
    }

    /// The short title on the transaction chip in the tab's context row; the
    /// full `message` is its tooltip and the first line of its menu.
    var chipTitle: String {
        switch self {
        case let .transaction(elapsed, _):
            return String(localized: "Transaction open · \(TabSessionBannerModel.duration(elapsed))")
        case .failed:
            return String(localized: "Transaction failed")
        case .reset:
            return String(localized: "Connection reset")
        }
    }

    /// The banner's buttons, in reading order.
    var actions: [TabSessionBannerAction] {
        switch self {
        case .transaction: return [.rollBack, .commit]
        case .failed: return [.rollBack]
        case .reset: return [.dismiss]
        }
    }
}

enum TabSessionBannerAction: Equatable {
    case commit, rollBack, dismiss

    var title: String {
        switch self {
        case .commit: return String(localized: "Commit")
        case .rollBack: return String(localized: "Roll Back")
        case .dismiss: return String(localized: "OK")
        }
    }
}

enum TabSessionBannerModel {
    /// The banner for a tab, or nil when there is nothing to say. A transaction
    /// (open or failed) is the state now, so it wins over an older reset.
    static func state(report: TabSessionReport?, receivedAt: Date?, pendingReset: TabSessionReset?,
                      now: Date) -> TabSessionBannerState? {
        if let report, report.open {
            let age = receivedAt.map { now.timeIntervalSince($0) } ?? 0
            switch report.txn {
            case .failed:
                return .failed
            case .inTransaction:
                let elapsed = (report.txnElapsedSeconds ?? 0) + max(0, age)
                let limit = TimeInterval(report.idleInTransactionTimeoutSeconds)
                return .transaction(elapsed: elapsed, idleRemaining: limit > 0 ? limit - max(0, age) : nil)
            case .idle, .unknown:
                break
            }
        }
        if let pendingReset { return .reset(reason: pendingReset.reason) }
        return nil
    }

    /// "45 s", "2 min", "1 h 5 min".
    static func duration(_ seconds: TimeInterval) -> String {
        let s = max(0, Int(seconds.rounded(.down)))
        if s < 60 { return String(localized: "\(s) s") }
        let minutes = s / 60
        if minutes < 60 { return String(localized: "\(minutes) min") }
        let rest = minutes % 60
        return rest == 0 ? String(localized: "\(minutes / 60) h") : String(localized: "\(minutes / 60) h \(rest) min")
    }
}

/// The question asked before something would roll back a tab's open
/// transaction: closing the tab, quitting, disconnecting, moving the tab to
/// another connection.
/// Pharos never commits for the user; the only way out is a rollback, so the
/// destructive button names it (Apple HIG, Alerts: name the action).
enum OpenTransactionWarning {
    enum Action: Equatable {
        case closeTab, quit, disconnect, switchConnection

        var buttonTitle: String {
            switch self {
            case .closeTab: return String(localized: "Roll Back and Close")
            case .quit: return String(localized: "Roll Back and Quit")
            case .disconnect: return String(localized: "Roll Back and Disconnect")
            case .switchConnection: return String(localized: "Roll Back and Switch")
            }
        }
    }

    static func title(tabNames: [String], action: Action) -> String {
        if tabNames.count == 1, let name = tabNames.first {
            return String(localized: "“\(name)” has an open transaction.")
        }
        return String(localized: "\(tabNames.count) tabs have open transactions.")
    }

    static func message(tabNames: [String], action: Action) -> String {
        let what = tabNames.count == 1
            ? String(localized: "Its changes are not committed.")
            : String(localized: "Their changes are not committed: \(ListFormatter.localizedString(byJoining: tabNames)).")
        let then: String = switch action {
        case .closeTab: String(localized: "Closing rolls them back.")
        case .quit: String(localized: "Quitting rolls them back.")
        case .disconnect: String(localized: "Disconnecting rolls them back.")
        case .switchConnection: String(localized: "Changing the connection rolls them back.")
        }
        return what + " " + then + " "
            + String(localized: "To keep them, cancel, then choose Commit from the tab's transaction button.")
    }
}
