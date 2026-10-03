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
    /// These tabs are gone: close their own database connections (rolling
    /// back; the user was asked first).
    var tabsDidClose: ([String]) -> Void = { _ in }
    /// The window's tab set or active tab changed: the stored session is stale.
    var markDirty: () -> Void = {}
    /// The window's active connection changed. Tags are global and load lazily.
    var activeConnectionDidChange: () -> Void = {}
    /// The name for a new tab: "Query N", counted across every window, since
    /// every tab is its own window.
    var nextTabName: () -> String = { "Query 1" }
    /// True while a stored session is being put back, when `ensureTab()` must
    /// not make a stray "Query 1".
    var isRestoringSession: () -> Bool = { false }
}

/// One main window's state: its query tab, what that window is connected to,
/// and the tab's results.
///
/// Every query tab is its own window — a native window tab — so a session
/// holds exactly ONE tab once its window is built. `tabs` stays an array (with
/// one element) because much of the content controller reads it by id; `tab`
/// is the direct way in.
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

    // MARK: - The tab

    @Published private(set) var tabs: [QueryTab] = [] {
        didSet {
            hooks.markDirty()
            tabsSettled.send(tabs)
        }
    }
    @Published private(set) var activeTabId: String? {
        didSet {
            hooks.markDirty()
            activeTabIdSettled.send(activeTabId)
        }
    }

    // MARK: - Query variables

    /// The `{{name}}` tokens the active editor's text references, kept fresh
    /// by `EditorPaneVC` (a debounced scan on every edit, and synchronously on
    /// a tab switch). The sidebar's Variables navigator reads it to mark which
    /// rows the current SQL uses — the variables themselves are app-wide
    /// (`QueryVariableStore`), only the references are per window.
    @Published var referencedVariableNames: Set<String> = []

    // MARK: - Result tabs

    /// Every editor tab's result tabs, keyed by editor tab id. It lived on
    /// `ContentViewController`, which is already one per window; it sits here
    /// so the whole of a window's state is in one place and a pending cell
    /// edit stays with the window that made it.
    var resultStore = CardResultStore()

    // MARK: - Settled publishers

    // `@Published` emits from `willSet`: a subscriber that runs on the same
    // stack reads the OLD value back through the session, which is why every
    // sink used to hop to `RunLoop.main` and every caller that then needed
    // the UI to have caught up waited one turn (`DispatchQueue.main.async`).
    // These emit from `didSet`, carry the current value, and are delivered
    // synchronously: when `install` or `ensureTab` returns, the content
    // controller and the editor have already applied the change. The class
    // is `@MainActor`, so every send is on main.
    let tabsSettled = CurrentValueSubject<[QueryTab], Never>([])
    let activeTabIdSettled = CurrentValueSubject<String?, Never>(nil)

    // MARK: - Tab

    /// The window's one tab.
    var tab: QueryTab? { tabs.first }

    /// True while the window's own tab is on its way: the window controller
    /// installs it once the panes have loaded (they react to a tab at once,
    /// and must exist first), and `ensureTab()` must not make a blank one in
    /// between. `install` ends it.
    var awaitsTab = false

    var activeTab: QueryTab? { tab }

    func updateTab(id: String, _ updater: (inout QueryTab) -> Void) {
        guard let idx = tabs.firstIndex(where: { $0.id == id }) else { return }
        updater(&tabs[idx])
    }

    /// Make the window's tab, if it has none. It takes the window's connection
    /// and that connection's default schema.
    ///
    /// While a saved session is being put back this is a no-op: the content
    /// controller calls it as soon as its view loads, which is before the
    /// restored tab is installed, and an empty "Query 1" made here would be
    /// thrown away a moment later.
    func ensureTab() {
        guard !hooks.isRestoringSession(), !awaitsTab, tabs.isEmpty else { return }
        var tab = QueryTab(name: hooks.nextTabName())
        if let connId = activeConnectionId, let defaultSchema = hooks.defaultSchema(connId) {
            tab.connectionId = connId
            tab.schemaName = defaultSchema
        }
        install(tab)
    }

    /// Make `tab` the window's tab: an item opened into a new window, a
    /// restored tab, or one that replaces an untouched blank tab. The window's
    /// connection and schema follow it.
    func install(_ tab: QueryTab) {
        awaitsTab = false
        tabs = [tab]
        activeTabId = tab.id
        syncActiveConnectionAndSchema()
    }

    /// Sync the window's active connection/schema to the tab's values so the
    /// sidebar/schema browser follows it. Guarded sets + the `didSet` dedup on
    /// these properties make redundant calls a no-op.
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

    /// Cancel every in-flight query this window holds and close its tab's own
    /// connection. Called when the window closes: a query belongs to the
    /// window that started it.
    func cancelAllRunningQueries() {
        hooks.cancelQueries(tabs.filter { !$0.runningQueries.isEmpty })
        hooks.tabsDidClose(tabs.map(\.id))
    }
}
