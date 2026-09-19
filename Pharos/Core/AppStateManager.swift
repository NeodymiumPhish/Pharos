import Foundation
import Combine
import AppKit
import LocalAuthentication
import os

/// The device-owner authentication gate: Touch ID, an unlocked Apple Watch, or
/// the login password, whichever the Mac offers.
///
/// It guards two ACTIONS — connecting with a record, and showing that record's
/// stored password — for connections whose `requiresAuthentication` is set. It
/// does not change where the password is stored: the Keychain item is written
/// and read exactly as before.
///
/// A cancel is reported apart from a failure, because the two mean different
/// things to the caller: nothing went wrong when the user changed their mind,
/// so the caller must not leave an error behind.
enum DeviceOwnerGate {

    enum Outcome {
        /// The device owner proved who they are.
        case authenticated
        /// The user dismissed the prompt, or the system withdrew it. Nothing failed.
        case cancelled
        /// No policy is available on this Mac, or the attempt was refused.
        case failed(reason: String)
    }

    /// Asks the device owner to authenticate. `reason` completes the system's
    /// own sentence, so it reads as a verb phrase ("connect to prod-db").
    ///
    /// `evaluatePolicy` is callback-based and answers on a private queue, so it
    /// is bridged with a continuation: the caller awaits, and the main actor
    /// keeps running while the prompt is up.
    static func authenticate(reason: String) async -> Outcome {
        let context = LAContext()

        // `.deviceOwnerAuthentication` already falls back to the login password,
        // so this only fails where NO policy is available at all — no biometry
        // enrolled and no password set. Asking first turns that into a sentence
        // the user can act on instead of a bare refusal.
        var policyError: NSError?
        guard context.canEvaluatePolicy(.deviceOwnerAuthentication, error: &policyError) else {
            return .failed(reason: policyError?.localizedDescription
                ?? String(localized: "This Mac cannot ask you to authenticate."))
        }

        return await withCheckedContinuation { continuation in
            context.evaluatePolicy(.deviceOwnerAuthentication, localizedReason: reason) { success, error in
                if success {
                    continuation.resume(returning: .authenticated)
                    return
                }
                switch (error as? LAError)?.code {
                case .userCancel, .appCancel, .systemCancel:
                    continuation.resume(returning: .cancelled)
                default:
                    continuation.resume(returning: .failed(
                        reason: error?.localizedDescription
                            ?? String(localized: "Authentication did not succeed.")))
                }
            }
        }
    }
}

/// Central state manager for the Pharos app. Observable via Combine.
/// Manages connections, active connection, settings, and connection status.
@MainActor
final class AppStateManager: ObservableObject {

    static let shared = AppStateManager()

    // MARK: - Published State

    @Published private(set) var connections: [ConnectionConfig] = []
    @Published private(set) var connectionStatuses: [String: ConnectionStatus] = [:]
    @Published private(set) var settings: AppSettings = AppSettings() {
        didSet {
            // The model layer's mirror of one settings field — see
            // `ResultTabsPanelPrefs.visibleByDefault` for why it cannot read
            // this object itself. One writer, here, so the two cannot drift.
            ResultTabsPanelPrefs.visibleByDefault = settings.results.showResultTabsPanelByDefault
        }
    }

    /// Last error from a state operation (save, delete, load). Observed by UI to show alerts.
    @Published var lastError: String?

    // MARK: - Window sessions

    /// One per open main window, in the order the windows were made. The tabs,
    /// the active tab, the window's connection and its results all live there
    /// (`WindowSession`); this class keeps only what is app-wide.
    private(set) var sessions: [WindowSession] = []

    /// Build a session and wire it to the app around it. The caller
    /// (`MainWindowController`) owns the window; this owns the registry.
    func makeSession(id: String = UUID().uuidString) -> WindowSession {
        let session = WindowSession(id: id)
        session.hooks.defaultSchema = { [weak self] connId in
            self?.connections.first { $0.id == connId }?.defaultSchema
        }
        session.hooks.cancelQueries = { [weak self] tabs in
            self?.cancelQueries(beforeClosing: tabs)
        }
        session.hooks.markDirty = { [weak self] in
            self?.sessionDirty = true
        }
        session.hooks.activeConnectionDidChange = {
            do {
                try TagStore.shared.loadTagsIfNeeded()
            } catch {
                // A failure must not block the connection. The user then has
                // a working database and no tags, which is a degraded view,
                // not a broken state.
                Log.state.warning("Failed to load tags: \(error.localizedDescription, privacy: .public)")
            }
        }
        session.hooks.isRestoringSession = { [weak self] in
            self?.isRestoringSession ?? false
        }
        sessions.append(session)
        return session
    }

    /// Drop a closed window's session. Its in-flight queries are cancelled
    /// first: a query belongs to the window that started it.
    /// Set by `applicationShouldTerminate` before its snapshot. AppKit closes
    /// every window on the way out, and each close reaches `retire`, which
    /// would rewrite the store with one window fewer each time until only the
    /// last-closed window survived (measured 2026-09-15: two windows open,
    /// quit, one stored). While terminating, the terminate snapshot is the
    /// truth and the closes must not touch the store.
    private(set) var isTerminating = false

    func beginTerminating() { isTerminating = true }

    func retire(_ session: WindowSession) {
        session.cancelAllRunningQueries()
        if isTerminating {
            sessions.removeAll { $0 === session }
            return
        }
        // The LAST window closing is the one case where the store must keep
        // what is going away. The app outlives its windows, so someone who
        // closes the window and then quits would otherwise find their tabs
        // gone — and `snapshotSession()` refuses to write an empty window
        // list, so nothing after this point would put them back.
        if sessions.count == 1 { snapshotSession() }
        sessions.removeAll { $0 === session }
        // With windows left, the store now matches what is on screen: the
        // closed one does not come back. With none left, this is a no-op and
        // the snapshot above stands.
        snapshotSession()
    }

    /// The session of the window the user is working in.
    ///
    /// A sheet or a panel is key while it is up, so the sheet's parent is
    /// tried next, then the frontmost main window, then the first session —
    /// the app never has an action with nowhere to put it.
    var keySession: WindowSession? {
        if let session = Self.session(of: NSApp.keyWindow) { return session }
        if let session = Self.session(of: NSApp.keyWindow?.sheetParent) { return session }
        if let session = Self.session(of: NSApp.mainWindow) { return session }
        for window in NSApp.orderedWindows {
            if let session = Self.session(of: window) { return session }
        }
        return sessions.first
    }

    private static func session(of window: NSWindow?) -> WindowSession? {
        (window?.windowController as? MainWindowController)?.session
    }

    /// The session holding tab `tabId` — the window that OWNS it, not the key
    /// one. A notification tap, an App Intent and the workspace activity all
    /// name a tab and must front the window it is in.
    func session(owningTabId tabId: String) -> WindowSession? {
        sessions.first { $0.tabs.contains { $0.id == tabId } }
    }

    /// The first tab anywhere that matches, with the window holding it. The
    /// key window is looked at first, so a tab the user just opened wins over
    /// an older copy in another window.
    func findTab(where predicate: (QueryTab) -> Bool) -> (session: WindowSession, tab: QueryTab)? {
        let ordered = [keySession].compactMap { $0 } + sessions.filter { $0 !== keySession }
        for session in ordered {
            if let tab = session.tabs.first(where: predicate) { return (session, tab) }
        }
        return nil
    }

    // MARK: - Notifications

    /// Posted when connections list changes. Object is the AppStateManager.
    static let connectionsDidChange = Notification.Name("PharosConnectionsDidChange")
    /// Posted when a connection's status changes. UserInfo has "connectionId" key.
    static let connectionStatusDidChange = Notification.Name("PharosConnectionStatusDidChange")
    /// Posted just before tabs are removed via close/closeOthers/closeToRight.
    /// userInfo carries `queryIds: [String]` — the queryIds whose completion
    /// notifications should be suppressed.
    static let queriesWillBeCancelled = Notification.Name("PharosQueriesWillBeCancelled")

    // MARK: - Init

    private init() {}

    // MARK: - Connection Management

    func loadConnections() {
        do {
            connections = try PharosCore.loadConnections()
            // Initialize all as disconnected
            for config in connections {
                if connectionStatuses[config.id] == nil {
                    connectionStatuses[config.id] = .disconnected
                }
            }
            NotificationCenter.default.post(name: Self.connectionsDidChange, object: self)
        } catch {
            Log.state.error("Failed to load connections: \(error.localizedDescription, privacy: .public)")
        }
    }

    func saveConnection(_ config: ConnectionConfig) {
        do {
            try PharosCore.saveConnection(config)
            // The record the last attempt failed against no longer exists, so
            // the failure no longer describes anything: a port the user has
            // just corrected would otherwise keep showing "Connection refused"
            // beside the badge. A live pool is untouched — editing a connected
            // record does not close it.
            if connectionStatuses[config.id] == .error {
                connectionStatuses[config.id] = .disconnected
                connectionErrors.removeValue(forKey: config.id)
                postStatusChange(config.id)
            }
            loadConnections()
        } catch {
            Log.state.error("Failed to save connection: \(error.localizedDescription, privacy: .public)")
            lastError = "Failed to save connection: \(error.localizedDescription)"
        }
    }

    func deleteConnection(id: String) {
        do {
            try PharosCore.deleteConnection(id: id)
            connectionStatuses.removeValue(forKey: id)
            // Every window that was pointed at the deleted record, not just
            // the key one.
            for session in sessions where session.activeConnectionId == id {
                session.activeConnectionId = nil
            }
            loadConnections()
        } catch {
            Log.state.error("Failed to delete connection: \(error.localizedDescription, privacy: .public)")
            lastError = "Failed to delete connection: \(error.localizedDescription)"
        }
    }

    /// Persist a new ordering for all connections. Pass the full ordered ID list.
    func reorderConnections(ids: [String]) {
        do {
            try PharosCore.reorderConnections(ids: ids)
            loadConnections()
        } catch {
            Log.state.error("Failed to reorder connections: \(error.localizedDescription, privacy: .public)")
            lastError = "Failed to reorder connections: \(error.localizedDescription)"
        }
    }

    /// Binds tab `tabId` to `connectionId`: applies the connection's default
    /// schema when the connection changes, syncs the global active connection
    /// and schema when the tab is the active one, and connects when the
    /// connection is idle. The toolbar pull-down goes through here.
    ///
    /// "Idle" means `.disconnected` OR `.error`. A failed attempt leaves the
    /// record in `.error`, and nothing clears that by itself — so treating
    /// `.error` as busy made the error STICKY: picking the same connection
    /// again did nothing at all, and the only ways out were File ▸ Connect
    /// (whose own `canConnect` has always allowed `.error`) or a relaunch.
    /// Nothing is held on the failed attempt — the Rust side registers no pool
    /// unless the pool is created — so a repeat attempt is free to run the
    /// whole path again.
    func useConnection(_ connectionId: String, forTabId tabId: String, in session: WindowSession) {
        guard let tab = session.tabs.first(where: { $0.id == tabId }) else { return }
        let connectionChanged = tab.connectionId != connectionId
        let newSchema = connections.first(where: { $0.id == connectionId })?.defaultSchema ?? "public"
        session.updateTab(id: tabId) {
            $0.connectionId = connectionId
            if connectionChanged { $0.schemaName = newSchema }
        }
        if tabId == session.activeTabId {
            session.activeConnectionId = connectionId
            if connectionChanged { session.activeSchema = newSchema }
        }
        switch status(for: connectionId) {
        case .disconnected, .error:
            connect(id: connectionId, in: session)
        case .connecting, .connected:
            break
        }
    }

    /// Why the last connect attempt for a connection did not succeed, keyed by
    /// connection id. A `.error` status says THAT it failed; this says why, so
    /// the connections form can show the reason beside the badge.
    @Published private(set) var connectionErrors: [String: String] = [:]

    func connectionError(for connectionId: String) -> String? {
        connectionErrors[connectionId]
    }

    /// Connects, asking the device owner to authenticate first when the record
    /// requires it.
    ///
    /// The status goes to `.connecting` before the prompt, so the toolbar is not
    /// silent while the sheet is up. A CANCEL returns it to `.disconnected`, not
    /// `.error`: nothing failed, and an error state here would be sticky.
    ///
    /// `session` is the window the attempt belongs to — the one whose active
    /// connection and active tab follow a success. It defaults to the key
    /// window's, which is what a menu command or a Shortcut means.
    func connect(id: String, in session: WindowSession? = nil) {
        let target = session ?? keySession
        guard let config = connections.first(where: { $0.id == id }),
              config.requiresAuthentication,
              // A gate this connection passed moments ago still counts. One
              // connect can reach here three times in a few seconds — the
              // first attempt, the password prompt behind it, and the status
              // refresh after the password is typed — and gating each would
              // show three system prompts for one action while proving
              // nothing the first did not. See `DeviceOwnerGateRecency`.
              !gateIsFresh(for: id) else {
            performConnect(id: id, in: target)
            return
        }

        connectionStatuses[id] = .connecting
        connectionErrors.removeValue(forKey: id)
        postStatusChange(id)

        let name = DisplayEscape.escapedTrimmed(config.name)
        Task { @MainActor in
            switch await DeviceOwnerGate.authenticate(
                reason: String(localized: "connect to \(name)")
            ) {
            case .authenticated:
                self.noteGatePassed(for: id)
                self.performConnect(id: id, in: target)
            case .cancelled:
                self.connectionStatuses[id] = .disconnected
                self.postStatusChange(id)
            case .failed(let reason):
                self.connectionErrors[id] = reason
                self.connectionStatuses[id] = .error
                self.postStatusChange(id)
                Log.state.error("Connection gate refused: \(reason, privacy: .public)")
            }
        }
    }

    /// Open the connections whose "Connect when Pharos starts" is set.
    ///
    /// Call AFTER `restoreSession()`: a restored tab may already have brought
    /// its connection up, and `LaunchConnectPolicy` skips those rather than
    /// asking twice.
    ///
    /// Connections that will put a Touch ID prompt on screen are opened ONE
    /// AT A TIME, and last. Several `DeviceOwnerGate` prompts raised together
    /// stack on one another, and the user cannot tell which connection each
    /// belongs to. With no gated connection in the list, they all go at once,
    /// because there is nothing to queue behind.
    ///
    /// Nothing here blocks the launch: every connect is already a `Task`, and
    /// a connection that never answers leaves its own row spinning rather
    /// than holding up the window.
    func connectFlaggedConnectionsAtLaunch() {
        let candidates = connections.map { config in
            LaunchConnectPolicy.Candidate(
                id: config.id,
                name: config.name,
                connectOnLaunch: config.connectOnLaunch,
                isAlreadyConnected: connectionStatuses[config.id] == .connected,
                requiresAuthentication: config.requiresAuthentication)
        }
        let toOpen = LaunchConnectPolicy.connectionsToOpen(candidates)
        guard !toOpen.isEmpty else { return }

        Log.state.info("Opening \(toOpen.count, privacy: .public) connection(s) marked connect-on-launch")

        guard LaunchConnectPolicy.needsSerialPrompts(toOpen) else {
            for candidate in toOpen { connect(id: candidate.id, in: keySession) }
            return
        }

        // One at a time, each waiting for the one before to leave `.connecting`
        // — which is what keeps two Touch ID prompts off the screen together.
        Task { @MainActor in
            for candidate in toOpen {
                connect(id: candidate.id, in: keySession)
                await waitWhileConnecting(id: candidate.id)
            }
        }
    }

    /// Wait until `id` is no longer `.connecting`, or until the budget runs
    /// out. The budget matters: a connection that never answers must not
    /// strand the connections queued behind it for the life of the session.
    private func waitWhileConnecting(id: String, budget: TimeInterval = 60) async {
        let deadline = Date().addingTimeInterval(budget)
        while connectionStatuses[id] == .connecting, Date() < deadline {
            try? await Task.sleep(nanoseconds: 200_000_000)
        }
    }

    /// When the device-owner gate last passed, per connection. Not persisted
    /// and never written down: it dies with the process, which is the point.
    private var gatePassedAt: [String: Date] = [:]

    /// Record that the gate passed for this connection. Called by the connect
    /// path and by the password prompt, so one proof covers the whole piece
    /// of work rather than each step of it.
    func noteGatePassed(for id: String) {
        gatePassedAt[id] = Date()
    }

    /// Whether this connection's gate passed recently enough to stand in for
    /// another. A later, separate attempt is gated again.
    func gateIsFresh(for id: String) -> Bool {
        guard let passedAt = gatePassedAt[id] else { return false }
        return DeviceOwnerGateRecency.isFresh(passedAt: passedAt)
    }

    /// Forget every remembered gate pass. Called beside the session-password
    /// clearing on sleep: if the typed passwords go, the proof that the owner
    /// was present must go with them.
    func forgetGatePasses() {
        gatePassedAt.removeAll()
    }

    private func performConnect(id: String, in session: WindowSession?) {
        connectionStatuses[id] = .connecting
        connectionErrors.removeValue(forKey: id)
        postStatusChange(id)

        Task {
            do {
                let info = try await PharosCore.connect(connectionId: id)
                self.connectionStatuses[id] = info.status
                // A refused connection comes back as a value, not a throw, so
                // without this the reason was lost and the toolbar only turned
                // red.
                if info.status == .error {
                    let reason = info.error ?? String(localized: "No reason given.")
                    self.connectionErrors[id] = reason
                    Log.state.error("Connection failed: \(reason, privacy: .public)")
                }
                // Only the window that asked follows the new connection. A
                // second window stays on whatever it was showing.
                if let session {
                    session.activeConnectionId = id

                    // ONE schema, applied to the window AND to the active tab,
                    // so the toolbar's selector and the navigator never name
                    // different schemas. The tab's own schema wins: a tab
                    // restored at launch is linked to the schema it had last
                    // run, and "connect" keeps that link (the user asked for
                    // exactly this after a restored tab came back on the
                    // default instead). The connection's configured default
                    // is for a tab that has not chosen. See `ConnectSchema`.
                    let tabSchema = session.activeTab.flatMap {
                        $0.connectionId == id ? $0.schemaName : nil
                    }
                    let schema = ConnectSchema.resolve(
                        tabSchema: tabSchema,
                        configured: self.connections.first(where: { $0.id == id })?.defaultSchema,
                        windowRemembered: session.activeSchema)
                    session.activeSchema = schema

                    if let tabId = session.activeTabId {
                        session.updateTab(id: tabId) { tab in
                            if tab.connectionId == id { tab.schemaName = schema }
                        }
                    }
                }
                self.postStatusChange(id)
            } catch {
                self.connectionStatuses[id] = .error
                self.connectionErrors[id] = error.localizedDescription
                self.postStatusChange(id)
                Log.state.error("Connection failed: \(error.localizedDescription, privacy: .public)")
            }
        }
    }

    func disconnect(id: String) {
        Task {
            do {
                try await PharosCore.disconnect(connectionId: id)
                self.connectionStatuses[id] = .disconnected
                // The pool is app-wide, so every window pointed at it loses it.
                for session in self.sessions where session.activeConnectionId == id {
                    session.activeConnectionId = nil
                }
                self.postStatusChange(id)
            } catch {
                Log.state.error("Disconnect failed: \(error.localizedDescription, privacy: .public)")
            }
        }
    }

    // MARK: - Settings

    /// Set when the settings the core sent could not be decoded at launch.
    /// While it is set `saveSettings` refuses to write: `settings` holds the
    /// Swift default, not the user's values, and saving it would overwrite the
    /// stored blob with defaults. The core keeps its own copy of an unreadable
    /// blob (`app_settings_backup`); this guards the OTHER failure, a Swift
    /// field with no Rust mirror, which the core cannot see.
    private(set) var settingsLoadFailed = false

    /// The message shown when a save is refused. One string so the pane and
    /// the log say the same thing.
    static let settingsNotSavedMessage = String(
        localized: "Settings could not be read at launch; changes are not saved so the stored settings are kept.")

    func loadSettings() {
        do {
            settings = try PharosCore.loadSettings()
            settingsLoadFailed = false
        } catch {
            settingsLoadFailed = true
            Log.state.error("Failed to load settings: \(error.localizedDescription, privacy: .public)")
            // No migration on this path: `settings` holds the Swift defaults,
            // not the user's values, so folding the legacy keys in and saving
            // would write those defaults over the stored blob — the very thing
            // `settingsLoadFailed` exists to prevent.
            return
        }

        // Only after a successful load. The legacy keys are removed as they
        // are read, so this does nothing on every launch after the first.
        var migrated = settings
        if SettingsMigration.migrate(from: .standard, into: &migrated) {
            Log.state.info("Migrated legacy UserDefaults preferences into AppSettings")
            saveSettings(migrated)
        }
    }

    func saveSettings(_ newSettings: AppSettings) {
        guard !settingsLoadFailed else {
            Log.state.error("Refusing to save settings: \(Self.settingsNotSavedMessage, privacy: .public)")
            lastError = Self.settingsNotSavedMessage
            return
        }
        do {
            try PharosCore.saveSettings(newSettings)
            settings = newSettings
        } catch {
            Log.state.error("Failed to save settings: \(error.localizedDescription, privacy: .public)")
            lastError = "Failed to save settings: \(error.localizedDescription)"
        }
    }

    // MARK: - Workspace History Snapshots

    /// Build the upsert payload capturing a tab's current editor snapshot for the
    /// given workspace id. Returns nil if the tab has no connection.
    func workspaceUpsertPayload(for tab: QueryTab, workspaceId: String) -> WorkspaceUpsert? {
        guard let connId = tab.connectionId else { return nil }
        let connName = connections.first { $0.id == connId }?.name ?? connId
        return WorkspaceUpsert(
            id: workspaceId,
            name: nil,
            nameIsCustom: false,
            connectionId: connId,
            connectionName: connName,
            editorText: tab.sql,
            // Legacy column: variables are app-wide now (`QueryVariableStore`),
            // so every snapshot writes an empty list and nothing reads it back.
            variablesJson: "[]",
            cursorPosition: tab.cursorPosition
        )
    }

    /// Flush a final editor snapshot for every tab already bound to a workspace.
    /// Called on tab close and app termination so the last edits are persisted.
    func snapshotWorkspaces() {
        for session in sessions {
            for tab in session.tabs where tab.workspaceId != nil {
                guard let payload = workspaceUpsertPayload(for: tab, workspaceId: tab.workspaceId!) else { continue }
                try? PharosCore.upsertWorkspace(payload)
            }
        }
    }

    // MARK: - Session (open tabs across launches)

    /// Set by the `tabs` / `activeTabId` hooks. The autosave timer writes only
    /// when it is set, so an idle app never touches the database.
    private var sessionDirty = false
    private var sessionAutosaveTimer: Timer?
    /// True from `prepareSessionRestore()` until the restore finishes. It gates
    /// `ensureTab()` (no stray "Query 1") and `snapshotSession()` (a half-built
    /// tab set must never overwrite the stored one).
    private(set) var isRestoringSession = false
    private var pendingSession: Session?

    /// A name the user authored, as opposed to the generated "Query <n>".
    ///
    /// A name the on-device model suggested is NOT covered here — it does not
    /// read as "Query <n>", so this answers true for it. `QueryTab
    /// .nameIsSuggested` is what tells the two apart, and `snapshotSession`
    /// consults both.
    static func isCustomTabName(_ name: String) -> Bool {
        let generated = try? Regex("^Query [0-9]+$")
        guard let generated else { return true }
        return name.wholeMatch(of: generated) == nil
    }

    /// Write every open window — its frame, its tabs, their order and its
    /// active tab — to the store. Called from the autosave timer and from
    /// `applicationShouldTerminate`.
    ///
    /// With NO window open this writes nothing at all. The app outlives its
    /// last window (`applicationShouldTerminateAfterLastWindowClosed` is
    /// false), and rewriting the table empty there would throw away the tab
    /// set the user left behind — the damage the Phase 6 disclosure names.
    func snapshotSession() {
        guard !isRestoringSession else { return }
        guard !sessions.isEmpty else { return }
        let windows = sessions.enumerated().map { windowIndex, session -> SessionWindow in
            let saved = session.tabs.enumerated().map { idx, tab -> SessionTab in
                return SessionTab(
                    tabIndex: idx,
                    workspaceId: tab.workspaceId,
                    name: tab.name,
                    nameIsCustom: !tab.nameIsSuggested && Self.isCustomTabName(tab.name),
                    connectionId: tab.connectionId,
                    schemaName: tab.schemaName,
                    sql: tab.sql,
                    cursorPosition: tab.cursorPosition,
                    // Legacy field, kept for the wire shape; never read back.
                    variablesJson: nil,
                    isActive: tab.id == session.activeTabId
                )
            }
            return SessionWindow(
                windowId: session.id,
                windowIndex: windowIndex,
                frame: session.frameDescription,
                tabs: saved
            )
        }
        do {
            try PharosCore.saveSession(Session(windows: windows))
            sessionDirty = false
        } catch {
            Log.state.error("Failed to save session: \(error.localizedDescription, privacy: .public)")
        }
    }

    /// Start the session autosave at the interval the user chose
    /// (Settings ▸ General ▸ Session). Idempotent.
    ///
    /// An interval of 0 is "off": no timer runs, and the session is written
    /// only at quit and on the other explicit snapshots. Turning it off does
    /// NOT mean losing the session.
    func startSessionAutosave() {
        guard sessionAutosaveTimer == nil else { return }
        restartSessionAutosave()
    }

    /// Put the timer on the current interval. Called when the interval
    /// changes, so a new value takes effect without a relaunch.
    func restartSessionAutosave() {
        sessionAutosaveTimer?.invalidate()
        sessionAutosaveTimer = nil
        let interval = TimeInterval(settings.session.autosaveIntervalSeconds)
        guard interval > 0 else { return }
        let timer = Timer.scheduledTimer(withTimeInterval: interval, repeats: true) { [weak self] _ in
            Task { @MainActor in
                guard let self, self.sessionDirty else { return }
                self.snapshotSession()
            }
        }
        // A sixth of the period, so a short interval keeps its shape and a
        // long one still lets the system coalesce wake-ups.
        timer.tolerance = interval / 6
        sessionAutosaveTimer = timer
    }

    /// Read the stored session and, if it has any tab, hold back `ensureTab()`.
    /// Call BEFORE the first main window is built: its content controller asks
    /// for a tab as soon as its view loads.
    func prepareSessionRestore() {
        guard settings.query.restoreOpenTabs else { return }
        guard let stored = try? PharosCore.loadSession(),
              stored.windows.contains(where: { !$0.tabs.isEmpty }) else { return }
        pendingSession = stored
        isRestoringSession = true
    }

    /// The stored window the first main window should adopt — its frame, before
    /// that window is shown. Nil when nothing is being restored.
    var pendingFirstWindowFrame: NSRect? {
        // Settings ▸ General ▸ Session. Off restores the TABS but lets the
        // window manager place the window, which is what a user with a
        // changed display arrangement wants.
        guard settings.session.restoreWindowFrames else { return nil }
        return pendingSession?.windows.min { $0.windowIndex < $1.windowIndex }?
            .frame.flatMap(SessionWindow.rect(from:))
    }

    /// Put the stored windows and their tabs back. Call AFTER the first main
    /// window is on screen: a tab bound to a workspace is rebuilt by that
    /// window's `ContentViewController`, which must be alive and observing
    /// `.openWorkspace`.
    func restoreSession() {
        guard let stored = pendingSession else {
            startSessionAutosave()
            return
        }
        pendingSession = nil

        Task { @MainActor in
            let windows = stored.windows.sorted { $0.windowIndex < $1.windowIndex }
            // One WINDOW at a time, and one TAB at a time inside it: the
            // workspace handler rebuilds off the main thread, so two windows
            // restoring at once would put two rebuilds in flight and land the
            // tabs in completion order rather than the order they were saved.
            for (index, window) in windows.enumerated() {
                guard let session = self.sessionForRestore(at: index, stored: window) else { continue }
                await self.restore(window, into: session)
            }

            self.isRestoringSession = false
            for session in self.sessions { session.ensureTab() }
            self.sessionDirty = false
            self.startSessionAutosave()
        }
    }

    /// The session a stored window restores into. The first one is the window
    /// the delegate already built and showed; the rest are opened here, in
    /// stored order, each with its own frame.
    private func sessionForRestore(at index: Int, stored: SessionWindow) -> WindowSession? {
        if index == 0 { return sessions.first }
        guard let delegate = NSApp.delegate as? AppDelegate else { return nil }
        let frame = stored.frame.flatMap(SessionWindow.rect(from:))
        return delegate.openMainWindow(frame: frame).session
    }

    private func restore(_ window: SessionWindow, into session: WindowSession) async {
        var restoredIds: [String] = []
        for saved in window.tabs.sorted(by: { $0.tabIndex < $1.tabIndex }) {
            if let wsId = saved.workspaceId,
               let id = await restoreWorkspaceTab(saved, workspaceId: wsId, in: session) {
                restoredIds.append(id)
            } else {
                // No workspace, or the workspace row is gone: the session's
                // own copy of the editor text still brings the tab back.
                restoredIds.append(restoreDraftTab(saved, in: session).id)
            }
        }
        if let idx = window.tabs.firstIndex(where: { $0.isActive }), idx < restoredIds.count {
            session.selectTab(id: restoredIds[idx])
        }
    }

    /// Ask the window's `ContentViewController` to rebuild a workspace tab, then
    /// wait for it to appear. Returns nil when the workspace no longer exists
    /// (the handler stays silent in that case, so the wait is what detects it).
    private func restoreWorkspaceTab(_ saved: SessionTab,
                                     workspaceId: String,
                                     in session: WindowSession) async -> String? {
        if let existing = session.tabs.first(where: { $0.workspaceId == workspaceId }) { return existing.id }
        // Named, not broadcast: every open window observes `.openWorkspace`,
        // and without the session id each of them would rebuild the tab.
        NotificationCenter.default.post(
            name: .openWorkspace, object: nil,
            userInfo: ["workspaceId": workspaceId, "sessionId": session.id]
        )
        let deadline = Date().addingTimeInterval(5)
        while Date() < deadline {
            try? await Task.sleep(nanoseconds: 40_000_000)
            guard let tab = session.tabs.first(where: { $0.workspaceId == workspaceId }) else { continue }
            // The workspace row owns the editor text and cursor. It does not
            // store the schema, so that comes from the session.
            session.updateTab(id: tab.id) { $0.schemaName = saved.schemaName }
            return tab.id
        }
        return nil
    }

    /// Rebuild a tab that never ran a query straight from the session row.
    @discardableResult
    private func restoreDraftTab(_ saved: SessionTab, in session: WindowSession) -> QueryTab {
        let tab = session.createTab(sql: saved.sql, name: saved.name)
        // The connection is recorded, not dialled: restoring must never open a
        // database connection the user did not ask for.
        session.updateTab(id: tab.id) {
            $0.connectionId = saved.connectionId
            $0.schemaName = saved.schemaName
            $0.cursorPosition = saved.cursorPosition
            $0.isDirty = false
        }
        return tab
    }

    // MARK: - Helpers

    var activeConnection: ConnectionConfig? {
        guard let id = keySession?.activeConnectionId else { return nil }
        return connections.first { $0.id == id }
    }

    func status(for connectionId: String) -> ConnectionStatus {
        connectionStatuses[connectionId] ?? .disconnected
    }

    /// A query failed in a way that means the CONNECTION is gone, not that
    /// the SQL was wrong. Move it to Error so the toolbar glyph tells the
    /// truth and Connect becomes available again.
    ///
    /// This closes a gap recorded during the SSH tunnel work: nothing in the
    /// app ever moved a connection to Error because of a failed QUERY — only
    /// the connect path did — so a dead tunnel showed a green glyph, and
    /// Connect then did nothing because `canConnect` treats `.connected` as
    /// busy and the user had to press Disconnect first.
    ///
    /// Deliberately narrow: `ConnectionLossClassifier` refuses to call a
    /// statement timeout or a cancellation a loss, because dropping the pool
    /// on the single most common failure in this app would disconnect the
    /// user every time a query ran long.
    func markConnectionLost(id: String, reason: String) {
        guard ConnectionLossClassifier.isConnectionLoss(reason) else { return }
        guard connectionStatuses[id] != .error else { return }
        connectionStatuses[id] = .error
        connectionErrors[id] = reason
        // The pool on the Rust side is already unusable; drop ours so a
        // reconnect builds a new one rather than handing back the dead pool.
        for session in sessions where session.activeConnectionId == id {
            session.activeConnectionId = nil
        }
        postStatusChange(id)
        Log.state.error("Connection \(id, privacy: .public) marked lost: \(reason, privacy: .public)")
    }

    private func postStatusChange(_ connectionId: String) {
        NotificationCenter.default.post(
            name: Self.connectionStatusDidChange,
            object: self,
            userInfo: ["connectionId": connectionId]
        )
    }

    /// Cancel in-flight queries for the given tabs (FFI cancel) and post a
    /// notification so observers (e.g. ContentViewController) can suppress
    /// completion notifications for these queryIds.
    func cancelQueries(beforeClosing closingTabs: [QueryTab]) {
        var queryIds: [String] = []
        for tab in closingTabs {
            guard let connectionId = tab.connectionId else { continue }
            for q in tab.runningQueries {
                queryIds.append(q.id)
                Task {
                    _ = try? await PharosCore.cancelQuery(connectionId: connectionId, queryId: q.id)
                }
            }
        }
        if !queryIds.isEmpty {
            NotificationCenter.default.post(
                name: Self.queriesWillBeCancelled,
                object: nil,
                userInfo: ["queryIds": queryIds]
            )
        }
    }

    /// Open a file as a new editor tab. Ensures the main window exists
    /// and is frontmost, then routes to its `ContentViewController`.
    ///
    /// This is the single entry point used by `File > Open…`,
    /// `application(_:open:)`, and any future drag-to-dock handlers.
    @MainActor
    func openTextFile(at url: URL) {
        guard let app = NSApp.delegate as? AppDelegate else { return }
        // The file opens in the window the user is in, or in a new one when
        // the app has none.
        let controller = app.showMainWindow()
        controller.splitViewController.contentVC.openTextFile(at: url)
    }
}
