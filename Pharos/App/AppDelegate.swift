import AppKit
import CoreSpotlight
import CPharosCore
import UniformTypeIdentifiers

class AppDelegate: NSObject, NSApplicationDelegate {

    /// Every open main window, in the order they were opened. That order is
    /// the order they are stored in and the order they come back in.
    private(set) var windowControllers: [MainWindowController] = []

    func applicationDidFinishLaunching(_ notification: Notification) {
        // First, before anything can throw: the uncaught-exception handler
        // that writes `~/Library/Logs/Pharos/pharos-crash-*.log`. It existed
        // since the crash logger was written but nothing installed it.
        CrashLogger.install()

        // Cap pharos-core's env_logger to "warn" by default (0 = don't overwrite a value the user already set in their shell).
        setenv("RUST_LOG", "warn", 0)

        // Initialize the Rust backend
        let appSupportDir = Self.appSupportDirectory()
        let success = appSupportDir.withCString { cStr in
            pharos_init(cStr)
        }
        guard success else {
            let alert = NSAlert()
            alert.messageText = "Initialization Failed"
            alert.informativeText = "Failed to initialize Pharos core. The app will now quit."
            alert.alertStyle = .critical
            alert.runModal()
            NSApp.terminate(nil)
            return
        }

        // Load initial state
        let state = AppStateManager.shared
        state.loadConnections()
        state.loadSettings()

        // Apply the saved theme, and follow it from here on: the Settings
        // window applies a new theme by saving it, with nothing to press.
        ThemeApplier.shared.start()

        // Build the main menu
        NSApp.mainMenu = MainMenu.build()

        // "Run in Pharos" in any app's Services menu. The item itself is
        // declared in Info.plist; this is the object that answers it.
        NSApp.servicesProvider = self

        // Register query-completion notification category and delegate.
        QueryNotifier.shared.registerCategories()

        // Listen for notification taps that request tab activation.
        NotificationCenter.default.addObserver(
            self,
            selector: #selector(handleActivateTabNotification(_:)),
            name: QueryNotifier.activateTabNotification,
            object: nil
        )

        // Start the background update checker. It gates internally on the
        // `checkForUpdates` setting, so no conditional is needed here.
        UpdateChecker.shared.start()

        // The settings that start and stop something: the Spotlight indexer,
        // the MetricKit subscriber and the toast duration. Each follows the
        // stored value, so Settings needs no relaunch. After `pharos_init` and
        // `loadSettings()`: the Spotlight effect reads the saved queries out of
        // the core.
        SettingsEffects.shared.start()

        // Read the app-wide query variables before any window exists, so each
        // sidebar can seed its Variables navigator directly from the store. A
        // failure is not fatal: the list is simply empty until the next save.
        do {
            try QueryVariableStore.shared.loadIfNeeded()
        } catch {
            Log.state.warning("Failed to load query variables: \(error.localizedDescription, privacy: .public)")
        }

        // Read the stored tab set BEFORE the window exists: its content
        // controller asks for a tab as soon as its view loads, and that "Query 1"
        // would otherwise sit beside the restored tabs.
        state.prepareSessionRestore()

        // Show the first main window, at the frame the stored session left it.
        openMainWindow(frame: state.pendingFirstWindowFrame)

        // Put the saved tabs — and any further saved windows — back. This needs
        // the content controller alive and observing, so it runs after the
        // first window is on screen.
        state.restoreSession()
    }

    // MARK: - Windows

    /// Open a main window and bring it to the front.
    ///
    /// `frame` is a stored frame to adopt; with none, the window cascades off
    /// the last one built (or centres, when it is the first).
    @MainActor
    @discardableResult
    func openMainWindow(frame: NSRect? = nil, connectionId: String? = nil) -> MainWindowController {
        let controller = MainWindowController(initialConnectionId: connectionId)
        windowControllers.append(controller)
        if let frame { controller.applyStoredFrame(frame) }
        controller.showWindow(nil)
        controller.window?.makeKeyAndOrderFront(nil)
        return controller
    }

    /// Drop a window that has closed. Called by the controller's
    /// `windowWillClose`, which has already retired its session.
    @MainActor
    func forget(_ controller: MainWindowController) {
        windowControllers.removeAll { $0 === controller }
    }

    /// The window the user is in, opening one when the app has none on screen.
    @MainActor
    @discardableResult
    func showMainWindow() -> MainWindowController {
        let controller = keyWindowController ?? windowControllers.first
        guard let controller else { return openMainWindow() }
        controller.showWindow(nil)
        controller.window?.makeKeyAndOrderFront(nil)
        return controller
    }

    /// The controller of the window that is key, or of the window a key sheet
    /// belongs to. Nil when the frontmost window is not one of ours.
    @MainActor
    var keyWindowController: MainWindowController? {
        let key = NSApp.keyWindow
        if let controller = key?.windowController as? MainWindowController { return controller }
        if let controller = key?.sheetParent?.windowController as? MainWindowController { return controller }
        if let controller = NSApp.mainWindow?.windowController as? MainWindowController { return controller }
        return nil
    }

    /// Bring the window holding `session` to the front. Used by every path
    /// that names a TAB — a notification tap, an App Intent, a Spotlight or
    /// Handoff activity — which must front the window that OWNS it.
    @MainActor
    func front(_ session: WindowSession) {
        guard let controller = windowControllers.first(where: { $0.session === session }) else { return }
        controller.showWindow(nil)
        controller.window?.makeKeyAndOrderFront(nil)
    }

    /// File ▸ New Window (⌘N). A new window starts empty, with one "Query 1"
    /// bound to the key window's connection — not a copy of its tabs.
    @MainActor
    @objc func menuNewWindow(_ sender: Any?) {
        openMainWindow(connectionId: AppStateManager.shared.keySession?.activeConnectionId)
    }

    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        // Record the open tabs first: the session rows name the workspaces, and
        // the workspace snapshot below then refreshes what each one holds.
        // From here on, the windows AppKit closes on the way out must not
        // rewrite the store (see `AppStateManager.retire`).
        AppStateManager.shared.beginTerminating()
        AppStateManager.shared.snapshotSession()

        // Flush final editor snapshots for open workspaces before shutting down core.
        AppStateManager.shared.snapshotWorkspaces()

        // Watchdog: never hold termination longer than this even if the worker wedges.
        let watchdog = DispatchWorkItem {
            NSApp.reply(toApplicationShouldTerminate: true)
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + 5, execute: watchdog)

        DispatchQueue.global(qos: .userInitiated).async {
            pharos_shutdown()
            DispatchQueue.main.async {
                watchdog.cancel()
                NSApp.reply(toApplicationShouldTerminate: true)
            }
        }
        return .terminateLater
    }

    /// Quick Look previews a cell by writing it to a temporary file. Closing
    /// the panel removes that session's folder, so this only has anything to do
    /// when the app is quit with the panel still open — or after a crash left
    /// a folder behind, which the next quit then sweeps.
    func applicationWillTerminate(_ notification: Notification) {
        QuickLookItemBuilder.cleanUp()
        ResultsCopyExport.cleanUpShareFiles()
    }

    /// Pharos does not ask to be quit when its window closes; the Dock icon
    /// brings the window back (see `applicationShouldHandleReopen`).
    ///
    /// A third-party utility that quits windowless apps sends a quit Apple
    /// Event a second or two after the close. That path still runs
    /// `applicationShouldTerminate`, so the session is saved either way.
    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool {
        return false
    }

    /// A Dock click, or `open` on the bundle, with no window on screen.
    /// `MainWindowController` is held by this delegate and survives the close,
    /// so the usual path just shows it again; it is rebuilt only if it is gone.
    @MainActor
    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        guard !flag else { return true }
        showMainWindow()
        return true
    }

    @MainActor
    @objc private func handleActivateTabNotification(_ notification: Notification) {
        NSApp.activate(ignoringOtherApps: true)
        // The window may have been closed — the app no longer quits with it.
        showMainWindow()

        guard let tabId = notification.userInfo?["tabId"] as? String else { return }
        // The window that OWNS the tab, not the key one: the query the
        // notification is about ran in one particular window.
        guard let session = AppStateManager.shared.session(owningTabId: tabId) else {
            // Tab is gone (user closed it). App is already activated; graceful degrade.
            return
        }
        front(session)
        session.selectTab(id: tabId)
    }

    @MainActor
    func application(_ application: NSApplication, open urls: [URL]) {
        let textType = UTType.text
        for url in urls {
            // A connection link is not a file. It opens the Connections window
            // on a new, unsaved record; nothing is stored until Save.
            if let scheme = url.scheme?.lowercased(),
               ConnectionURLParser.schemes.contains(scheme) {
                openConnectionLink(url)
                continue
            }
            let conforms: Bool
            if let type = try? url.resourceValues(forKeys: [.contentTypeKey]).contentType {
                conforms = type.conforms(to: textType)
            } else {
                // Fallback: trust the extension if Launch Services hasn't
                // populated a UTI yet (rare on first launch after install).
                conforms = ["sql", "txt", "md"].contains(url.pathExtension.lowercased())
            }
            guard conforms else { continue }
            AppStateManager.shared.openTextFile(at: url)
        }
    }

    // MARK: - User Activities (Spotlight, Handoff, App Intents)

    /// A Spotlight result, or a workspace activity the app itself donated.
    ///
    /// A saved query indexed through `CSSearchableIndex.indexAppEntities` is
    /// normally opened by the system running `OpenSavedQueryIntent`; this handler
    /// is the path for the plain-activity case, and for the workspace activity
    /// donated by `ContentViewController`.
    @MainActor
    func application(_ application: NSApplication,
                     continue userActivity: NSUserActivity,
                     restorationHandler: @escaping ([any NSUserActivityRestoring]) -> Void) -> Bool {
        showMainWindow()
        NSApp.activate()

        switch userActivity.activityType {
        case CSSearchableItemActionType:
            guard let identifier = userActivity.userInfo?[CSSearchableItemActivityIdentifier] as? String else {
                return false
            }
            return openSavedQuery(spotlightIdentifier: identifier)

        case PharosActivity.workspace:
            guard let workspaceId = userActivity.userInfo?[PharosActivity.workspaceIdKey] as? String else {
                return false
            }
            NotificationCenter.default.post(
                name: .openWorkspace, object: nil,
                userInfo: ["workspaceId": workspaceId]
            )
            return true

        default:
            return false
        }
    }

    /// Open the saved query a Spotlight item stands for.
    ///
    /// The item identifier is the entity id for an item this app indexed, but an
    /// item written by an older build (or by the App Intents machinery, which
    /// namespaces its own identifiers) can carry the id inside a longer string —
    /// so a direct match is tried first and a suffix match second.
    @MainActor
    private func openSavedQuery(spotlightIdentifier: String) -> Bool {
        let queries = (try? PharosCore.loadSavedQueries()) ?? []
        let match = queries.first { $0.id == spotlightIdentifier }
            ?? queries.first { spotlightIdentifier.hasSuffix($0.id) }
        guard let match else {
            Log.ui.error("Spotlight opened an unknown saved query")
            return false
        }
        NotificationCenter.default.post(
            name: .openSavedQuery, object: nil, userInfo: ["query": match]
        )
        return true
    }

    /// A `postgres://` / `postgresql://` link, pre-filled into the Connections
    /// window. The main window is brought up first, as the file-open path does,
    /// so the app is not left with the Connections window and nothing behind it.
    @MainActor
    private func openConnectionLink(_ url: URL) {
        showMainWindow()
        guard let parsed = ConnectionURLParser.parse(url) else {
            Log.ui.error("Unreadable connection link")
            let alert = NSAlert()
            alert.messageText = String(localized: "Pharos could not read this connection link.")
            // The link itself, escaped: it is the only thing that tells the
            // user WHICH link failed, and it comes from outside the app.
            alert.informativeText = DisplayEscape.escaped(url.absoluteString)
            alert.alertStyle = .warning
            alert.addButton(withTitle: String(localized: "OK"))
            alert.runModal()
            return
        }
        ConnectionsManagerWindowController.show(prefill: parsed)
    }

    // MARK: - Services

    /// The "Run in Pharos" service, declared in `Info.plist`. The selected text
    /// opens in a NEW editor tab and is NOT run: a service fires from another
    /// app's menu, where an accidental `DELETE` would have no confirmation step
    /// in front of it.
    ///
    /// The signature is the one Services dispatch expects —
    /// `-(void)message:(NSPasteboard *)pboard userData:(NSString *)data error:(NSString **)error`.
    @MainActor
    @objc func runSQLFromService(_ pboard: NSPasteboard,
                                 userData: String,
                                 error: AutoreleasingUnsafeMutablePointer<NSString?>) {
        guard let text = pboard.string(forType: .string) else {
            error.pointee = String(localized: "Pharos could not read the selected text.") as NSString
            return
        }
        let sql = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !sql.isEmpty else {
            error.pointee = String(localized: "The selection has no SQL in it.") as NSString
            return
        }
        let session = showMainWindow().session
        let tab = session.createTab(sql: sql)
        session.selectTab(id: tab.id)
        NSApp.activate(ignoringOtherApps: true)
    }

    @MainActor
    @objc func menuOpenSQLFile(_ sender: Any?) {
        let panel = NSOpenPanel()
        panel.canChooseFiles = true
        panel.canChooseDirectories = false
        panel.allowsMultipleSelection = true
        panel.message = "Choose a SQL or text file to open"
        if let sqlType = UTType("public.sql") {
            panel.allowedContentTypes = [sqlType, .text, .plainText]
        } else {
            panel.allowedContentTypes = [.text, .plainText]
        }
        panel.begin { response in
            guard response == .OK else { return }
            for url in panel.urls {
                AppStateManager.shared.openTextFile(at: url)
            }
        }
    }

    // MARK: - Helpers

    /// `~/Library/Application Support/<bundle id>`. The folder follows the
    /// bundle identifier so a re-identified test copy of the app gets its own
    /// empty store; the shipped app resolves to `com.pharos.client` as before.
    /// (`HOME` is not a way to redirect this: `NSHomeDirectory()` ignores it.)
    private static func appSupportDirectory() -> String {
        let fm = FileManager.default
        let urls = fm.urls(for: .applicationSupportDirectory, in: .userDomainMask)
        guard let baseURL = urls.first else {
            return fm.temporaryDirectory.path
        }
        let dir = baseURL.appendingPathComponent(Bundle.main.bundleIdentifier ?? "com.pharos.client")
        try? fm.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir.path
    }
}
