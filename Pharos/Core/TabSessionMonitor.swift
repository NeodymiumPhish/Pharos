import Foundation

/// What Pharos knows about each editor tab's own connection: the last report
/// pharos-core gave, when it arrived, and a reset the user has not dismissed.
/// Tab ids are unique across windows, so one store serves the app.
///
/// The banner reads it; every session call writes the report it got back,
/// and a failed call refreshes it with `PharosCore.tabSessionState`, because a
/// failure carries only a message.
@MainActor
final class TabSessionMonitor {
    static let shared = TabSessionMonitor()

    /// Posted with `userInfo["tabId"]` when a tab's report changes.
    static let didChange = Notification.Name("TabSessionMonitor.didChange")

    private(set) var reports: [String: TabSessionReport] = [:]
    /// When each report arrived: the idle-in-transaction countdown runs from here.
    private(set) var receivedAt: [String: Date] = [:]
    /// The last reset of each tab, until the user dismisses it.
    private(set) var pendingResets: [String: TabSessionReset] = [:]
    /// Connections whose server cannot hold a tab connection: their cards run on the pool.
    private(set) var unavailableConnections: Set<String> = []

    /// The core's state, injectable for tests.
    var fetchState: (String) -> TabSessionReport? = { PharosCore.tabSessionState(tabId: $0) }

    init() {}

    func report(for tabId: String) -> TabSessionReport? { reports[tabId] }

    func hasOpenTransaction(_ tabId: String) -> Bool { reports[tabId]?.hasOpenTransaction ?? false }

    /// The tabs among `tabIds` with an open transaction.
    func tabsWithOpenTransaction(_ tabIds: [String]) -> [String] { tabIds.filter(hasOpenTransaction) }

    func record(_ report: TabSessionReport, now: Date = Date()) {
        let tabId = report.sessionId
        reports[tabId] = report
        receivedAt[tabId] = now
        if let reset = report.reset { pendingResets[tabId] = reset }
        post(tabId)
    }

    /// Read the core's last report for a tab (after a failed call).
    func refresh(_ tabId: String) {
        if let report = fetchState(tabId) {
            record(report)
        } else if reports.removeValue(forKey: tabId) != nil {
            receivedAt[tabId] = nil
            post(tabId)
        }
    }

    func dismissReset(_ tabId: String) {
        guard pendingResets.removeValue(forKey: tabId) != nil else { return }
        post(tabId)
    }

    func markUnavailable(_ connectionId: String) { unavailableConnections.insert(connectionId) }

    func canUseSession(connectionId: String) -> Bool { !unavailableConnections.contains(connectionId) }

    /// Forget a tab's connection after it was closed.
    func forget(_ tabId: String) {
        let had = reports.removeValue(forKey: tabId) != nil
        receivedAt[tabId] = nil
        let hadReset = pendingResets.removeValue(forKey: tabId) != nil
        if had || hadReset { post(tabId) }
    }

    /// Forget every tab on a connection (disconnect, delete).
    func forgetConnection(_ connectionId: String) {
        for (tabId, report) in reports where report.connectionId == connectionId { forget(tabId) }
        unavailableConnections.remove(connectionId)
    }

    /// Close a tab's connection (rolling back) and forget it.
    func close(_ tabId: String) async -> TabSessionCloseOutcome? {
        let outcome = await PharosCore.closeTabSession(tabId: tabId)
        forget(tabId)
        return outcome
    }

    private func post(_ tabId: String) {
        NotificationCenter.default.post(name: Self.didChange, object: self, userInfo: ["tabId": tabId])
    }
}
