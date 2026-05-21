import AppKit
import CPharosCore
import UniformTypeIdentifiers

class AppDelegate: NSObject, NSApplicationDelegate {

    var mainWindowController: MainWindowController?

    func applicationDidFinishLaunching(_ notification: Notification) {
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

        // Apply saved theme
        SettingsSheet.applyTheme(state.settings.theme)

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

        // Show the main window
        mainWindowController = MainWindowController()
        mainWindowController?.showWindow(nil)
    }

    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
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

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool {
        return true
    }

    @MainActor
    @objc private func handleActivateTabNotification(_ notification: Notification) {
        NSApp.activate(ignoringOtherApps: true)
        mainWindowController?.window?.makeKeyAndOrderFront(nil)

        guard let tabId = notification.userInfo?["tabId"] as? String else { return }
        let state = AppStateManager.shared
        guard state.tabs.contains(where: { $0.id == tabId }) else {
            // Tab is gone (user closed it). App is already activated; graceful degrade.
            return
        }
        state.selectTab(id: tabId)
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

    private static func appSupportDirectory() -> String {
        let fm = FileManager.default
        let urls = fm.urls(for: .applicationSupportDirectory, in: .userDomainMask)
        guard let baseURL = urls.first else {
            return fm.temporaryDirectory.path
        }
        let dir = baseURL.appendingPathComponent("com.pharos.client")
        try? fm.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir.path
    }
}
