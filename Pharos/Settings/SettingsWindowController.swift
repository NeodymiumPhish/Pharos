import AppKit

/// The Settings window: a sidebar of panes and a detail pane, no Save
/// button, and one instance for the life of the app.
///
/// A window, not the sheet it once was, for the reasons the HIG gives:
/// settings are not a modal errand attached to one document window, they are
/// app-wide and must be reachable with no window open at all — which is why
/// `show()` asks nothing of `NSApp.mainWindow`.
///
/// Every control applies immediately (see `SettingsPaneVC`), so there is
/// nothing to cancel and the window closes with ⌘W like any other.
@MainActor
final class SettingsWindowController: NSWindowController {

    static let shared = SettingsWindowController()

    let splitVC = SettingsSplitViewController()

    private init() {
        let window = SettingsWindow()
        super.init(window: window)
        window.contentViewController = splitVC
        window.title = String(localized: "Pharos Settings")
        // AFTER the content controller: assigning one resizes the window to
        // the controller's fitting size, which for a split view is its
        // minimum — the window came up at 720×500 instead of 900×640.
        // `setFrameUsingName` then puts back a remembered frame if there is
        // one, so a user's own size still wins.
        window.setContentSize(SettingsWindow.defaultSize)
        window.center()
        window.setFrameUsingName(SettingsWindow.frameAutosaveName)
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) not implemented")
    }

    // MARK: - Showing

    /// Open Settings in the pane the user left it in. Works with no window
    /// on screen.
    func show() {
        // Force the window and its content controller to load before
        // anything selects a pane: a selection made before the views exist
        // is thrown away when they load.
        _ = window
        _ = splitVC.view
        splitVC.navigate(to: SettingsPanePrefs.lastPane(), source: .restore)

        // The window survives a close, so its panes hold the values from the
        // last time it was open; anything changed since (a theme set from a
        // menu, a default schema set from the editor) is read back here.
        for pane in splitVC.instantiatedPanes { pane.reloadFromSettings() }

        NSApp.activate(ignoringOtherApps: true)
        showWindow(nil)
        window?.makeKeyAndOrderFront(nil)
    }

    /// Open Settings in a given pane (a menu item or a "Settings…" button in
    /// a sheet that knows which pane it means).
    func show(pane: SettingsPaneID) {
        show()
        splitVC.navigate(to: pane, source: .user)
    }

    /// ⌘W in this app is File ▸ Close Tab, and only the editor's content
    /// controller answers it — so with Settings key the shortcut did nothing
    /// at all. An `NSWindowController` is in its window's responder chain, so
    /// answering the same selector here gives the window the close that ⌘W
    /// means for a window with no tabs in it.
    @objc func menuCloseTab(_ sender: Any?) {
        window?.performClose(sender)
    }
}
