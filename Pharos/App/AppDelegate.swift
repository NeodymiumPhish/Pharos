import AppKit
import CPharosCore
import UniformTypeIdentifiers

class AppDelegate: NSObject, NSApplicationDelegate {

    var mainWindowController: MainWindowController?

    func applicationDidFinishLaunching(_ notification: Notification) {
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
        // MetricKit hang and crash diagnostics land in ~/Library/Logs/Pharos/.
        Diagnostics.start()

        // Build the main menu
        NSApp.mainMenu = MainMenu.build()

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

        // Read the stored tab set BEFORE the window exists: its content
        // controller asks for a tab as soon as its view loads, and that "Query 1"
        // would otherwise sit beside the restored tabs.
        state.prepareSessionRestore()

        // Show the main window
        mainWindowController = MainWindowController()
        mainWindowController?.showWindow(nil)

        // Put the saved tabs back. This needs the content controller alive and
        // observing, so it runs after the window is on screen.
        state.restoreSession()
    }

    /// The main window exists, showing it if it was closed.
    @MainActor
    @discardableResult
    func showMainWindow() -> MainWindowController {
        if mainWindowController == nil {
            mainWindowController = MainWindowController()
        }
        let controller = mainWindowController!
        controller.showWindow(nil)
        controller.window?.makeKeyAndOrderFront(nil)
        return controller
    }

    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        // Record the open tabs first: the session rows name the workspaces, and
        // the workspace snapshot below then refreshes what each one holds.
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
        let state = AppStateManager.shared
        guard state.tabs.contains(where: { $0.id == tabId }) else {
            // Tab is gone (user closed it). App is already activated; graceful degrade.
            return
        }
        state.selectTab(id: tabId)
    }

    @MainActor
    func application(_ application: NSApplication, open urls: [URL]) {
        let textType = UTType.text
        for url in urls {
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
