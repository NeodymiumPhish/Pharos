import Foundation
import Combine

/// What a session needs from the app around it.
///
/// Everything here reaches OUTSIDE the window: the connection records, the
/// core's cancel call, the session store's dirty flag, the global tag cache.
/// `AppStateManager.makeSession()` fills them in. Each one defaults to a
/// no-op, so a unit test builds a bare `WindowSession` and gets the tab
/// behaviour with none of the app behind it.
@MainActor
struct WindowSessionHooks {
    /// The `defaultSchema` recorded on a connection, or nil.
    var defaultSchema: (String) -> String? = { _ in nil }
    /// Cancel every in-flight query of these tabs and tell observers.
    var cancelQueries: ([QueryTab]) -> Void = { _ in }
    /// The window's tab set or active tab changed: the stored session is stale.
    var markDirty: () -> Void = {}
    /// The window's active connection changed. Tags are global and load lazily.
    var activeConnectionDidChange: () -> Void = {}
    /// True while a stored session is being put back, when `ensureTab()` must
    /// not make a stray "Query 1".
    var isRestoringSession: () -> Bool = { false }
}

/// One main window's state: its editor tabs, which one is active, what that
/// window is connected to, and the results each tab holds.
///
/// Everything here used to sit on `AppStateManager.shared`, which made a
/// second window impossible — two windows would have shared one tab set. The
/// singleton keeps the parts that ARE app-wide (connection records, statuses,
/// settings) and holds the sessions in `AppStateManager.sessions`.
///
/// Controllers are handed their session at build time
/// (`MainWindowController` → `PharosSplitViewController` → the panes), never
/// by looking up `view.window`: a pane that is off screen, or a sheet that is
/// up, must still reach the right session.
@MainActor
final class WindowSession: ObservableObject {

    /// The window's identity in the session store. Written as `window_id`.
    let id: String

    var hooks = WindowSessionHooks()

    /// Where the window is on screen, as `"x,y,w,h"`. The window controller
    /// writes it on every move and resize; `snapshotSession()` reads it. It is
    /// a string, not a rect, so this type stays clear of AppKit — and so one
    /// `saveFrame(usingName:)` key does not have to serve N windows.
    var frameDescription: String?

    init(id: String = UUID().uuidString) {
        self.id = id
    }

    // MARK: - Connection and schema (this window's)

    @Published var activeConnectionId: String? {
        didSet {
            if activeConnectionId != oldValue {
                // Save current schema selection for the old connection
                if let oldId = oldValue, let schema = activeSchema {
                    schemaSelections[oldId] = schema
                }
                // Restore schema selection for new connection (nil if none saved)
                activeSchema = activeConnectionId.flatMap { schemaSelections[$0] }

                // Tags are global; this is a cheap no-op after the first call.
                // It stays on the connection hook so a first connection still
                // primes the cache before the first result arrives.
                //
                // It sits OUTSIDE the `if let`, so it also runs when the id goes
                // to nil — a disconnect, or a tab that is bound to nothing. That
                // is harmless by design: the call is idempotent, and a nil id
                // does not mean "drop the tags". Tags outlive a connection, so
                // there is nothing to clear and nothing to reload.
                hooks.activeConnectionDidChange()
            }
        }
    }

    @Published var activeSchema: String? {
        didSet {
            // Keep per-connection selection in sync
            if let connId = activeConnectionId {
                if let schema = activeSchema {
                    schemaSelections[connId] = schema
                } else {
                    schemaSelections.removeValue(forKey: connId)
                }
            }
        }
    }

    private var schemaSelections: [String: String] = [:]  // connectionId → schemaName

    // MARK: - Tabs

    @Published var tabs: [QueryTab] = [] {
        didSet {
            hooks.markDirty()
            tabsSettled.send(tabs)
        }
    }
    @Published var activeTabId: String? {
        didSet {
            hooks.markDirty()
            activeTabIdSettled.send(activeTabId)
        }
    }
    private var closedTabHistory: [QueryTab] = []
    private let maxClosedHistory = 20

    // MARK: - Query variables

    /// The `{{name}}` tokens the active editor's text references, kept fresh
    /// by `EditorPaneVC` (a debounced scan on every edit, and synchronously on
    /// a tab switch). The sidebar's Variables navigator reads it to mark which
    /// rows the current SQL uses — the variables themselves are app-wide
    /// (`QueryVariableStore`), only the references are per window.
    @Published var referencedVariableNames: Set<String> = []

    // MARK: - Pin state

    @Published var pinnedResult: QueryResult?
    @Published var pinnedTabId: String? {
        didSet { pinnedTabIdSettled.send(pinnedTabId) }
    }
    @Published var pinnedTabName: String?

    // MARK: - Result tabs

    /// Every editor tab's result tabs, keyed by editor tab id. It lived on
    /// `ContentViewController`, which is already one per window; it sits here
    /// so the whole of a window's state is in one place and a pending cell
    /// edit stays with the window that made it.
    var resultStore = ResultTabStore()

    // MARK: - Settled publishers

    // `@Published` emits from `willSet`: a subscriber that runs on the same
    // stack reads the OLD value back through the session, which is why every
    // sink used to hop to `RunLoop.main` and every caller that then needed
    // the UI to have caught up waited one turn (`DispatchQueue.main.async`).
    // These emit from `didSet`, carry the current value, and are delivered
    // synchronously: when `selectTab` or `createTab` returns, the content
    // controller and the editor have already applied the change. The class
    // is `@MainActor`, so every send is on main.
    let tabsSettled = CurrentValueSubject<[QueryTab], Never>([])
    let activeTabIdSettled = CurrentValueSubject<String?, Never>(nil)
    let pinnedTabIdSettled = CurrentValueSubject<String?, Never>(nil)

    // MARK: - Tab Management

    var activeTab: QueryTab? {
        guard let id = activeTabId else { return nil }
        return tabs.first { $0.id == id }
    }

    func unpinResults() {
        pinnedResult = nil
        pinnedTabId = nil
        pinnedTabName = nil
    }

    func updateTab(id: String, _ updater: (inout QueryTab) -> Void) {
        guard let idx = tabs.firstIndex(where: { $0.id == id }) else { return }
        updater(&tabs[idx])
    }

    /// Ensure at least one tab exists and one of them is active. Call after
    /// connections load.
    ///
    /// While a saved session is being put back this is a no-op: the content
    /// controller calls it as soon as its view loads, which is before the
    /// restored tabs exist, and an empty "Query 1" made here would survive as
    /// an extra tab beside them.
    func ensureTab() {
        guard !hooks.isRestoringSession() else { return }
        if tabs.isEmpty {
            createTab()
        } else if !tabs.contains(where: { $0.id == activeTabId }) {
            activeTabId = tabs.first?.id
            syncActiveConnectionAndSchema()
        }
    }

    /// Append a tab and make it active.
    @discardableResult
    func createTab(sql: String = "", name: String? = nil) -> QueryTab {
        let tabName = name ?? "Query \(tabs.count + 1)"
        var tab = QueryTab(name: tabName, sql: sql)
        applyDefaultSchema(&tab)
        tabs.append(tab)
        activeTabId = tab.id
        return tab
    }

    /// Apply the active connection's default schema to a new tab.
    private func applyDefaultSchema(_ tab: inout QueryTab) {
        guard let connId = activeConnectionId else { return }
        if let defaultSchema = hooks.defaultSchema(connId) {
            tab.connectionId = connId
            tab.schemaName = defaultSchema
        }
    }

    /// Make a tab active. Assigns even when the tab is already active; the
    /// settled publisher's subscribers dedupe.
    func selectTab(id: String) {
        activeTabId = id
    }

    /// Sync the window's active connection/schema to the active tab's values so
    /// the sidebar/schema browser follows the active tab. Guarded sets + the
    /// `didSet` dedup on these properties make redundant calls (e.g. when
    /// EditorPaneVC.tabChanged also runs) a no-op.
    func syncActiveConnectionAndSchema() {
        guard let tab = activeTab else { return }
        if let connId = tab.connectionId, connId != activeConnectionId {
            activeConnectionId = connId
        } else if tab.connectionId == nil && activeConnectionId != nil {
            activeConnectionId = nil
        }
        if tab.schemaName != activeSchema {
            activeSchema = tab.schemaName
        }
    }

    // MARK: - Tab Closing

    /// Close a tab. Closing the active tab makes the tab now at its index
    /// active (the one to its right, or the last). Closing the last tab
    /// replaces it with a fresh one.
    func closeTab(id: String) {
        if let tab = tabs.first(where: { $0.id == id }) {
            hooks.cancelQueries([tab])
        }
        guard let idx = tabs.firstIndex(where: { $0.id == id }) else { return }
        closedTabHistory.append(tabs[idx])
        if closedTabHistory.count > maxClosedHistory {
            closedTabHistory.removeFirst()
        }

        tabs.remove(at: idx)
        if pinnedTabId == id { unpinResults() }

        if tabs.isEmpty {
            createTab()
        } else if activeTabId == id {
            activeTabId = tabs[min(idx, tabs.count - 1)].id
            syncActiveConnectionAndSchema()
        }
    }

    func closeOtherTabs(exceptId id: String) {
        guard tabs.contains(where: { $0.id == id }) else { return }
        let others = tabs.filter { $0.id != id }
        hooks.cancelQueries(others)
        closedTabHistory.append(contentsOf: others)
        if closedTabHistory.count > maxClosedHistory {
            closedTabHistory = Array(closedTabHistory.suffix(maxClosedHistory))
        }
        tabs = tabs.filter { $0.id == id }
        activeTabId = id
    }

    func closeTabsToRight(ofId id: String) {
        guard let idx = tabs.firstIndex(where: { $0.id == id }) else { return }
        let closing = Array(tabs[(idx + 1)...])
        guard !closing.isEmpty else { return }
        hooks.cancelQueries(closing)
        closedTabHistory.append(contentsOf: closing)
        if closedTabHistory.count > maxClosedHistory {
            closedTabHistory = Array(closedTabHistory.suffix(maxClosedHistory))
        }
        tabs = Array(tabs[...idx])

        if let activeId = activeTabId, closing.contains(where: { $0.id == activeId }) {
            activeTabId = id
        }
    }

    /// Insert a copy right after the source and make it active.
    func duplicateTab(id: String) {
        guard let idx = tabs.firstIndex(where: { $0.id == id }) else { return }
        let tab = tabs[idx]
        let newTab = QueryTab(name: "\(tab.name) Copy", connectionId: tab.connectionId, sql: tab.sql)
        tabs.insert(newTab, at: idx + 1)
        activeTabId = newTab.id
    }

    func reopenLastClosedTab() {
        guard !closedTabHistory.isEmpty else { return }
        let tab = closedTabHistory.removeLast()
        let reopened = QueryTab(name: tab.name, connectionId: tab.connectionId, sql: tab.sql)
        tabs.append(reopened)
        activeTabId = reopened.id
    }

    func selectTabByIndex(_ index: Int) {
        guard index >= 0, index < tabs.count else { return }
        selectTab(id: tabs[index].id)
    }

    /// Cancel every in-flight query this window holds. Called when the window
    /// closes: a query belongs to the session that started it.
    func cancelAllRunningQueries() {
        hooks.cancelQueries(tabs.filter { !$0.runningQueries.isEmpty })
    }
}
