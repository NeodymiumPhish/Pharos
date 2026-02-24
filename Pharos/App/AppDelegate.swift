import AppKit
import CPharosCore

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

        // Show the main window
        mainWindowController = MainWindowController()
        mainWindowController?.showWindow(nil)
    }

    func applicationWillTerminate(_ notification: Notification) {
        pharos_shutdown()
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool {
        return true
    }

    // MARK: - Helpers

    private static func appSupportDirectory() -> String {
        let fm = FileManager.default
        let urls = fm.urls(for: .applicationSupportDirectory, in: .userDomainMask)
        let dir = urls.first!.appendingPathComponent("com.pharos.client")
        try? fm.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir.path
    }
}
