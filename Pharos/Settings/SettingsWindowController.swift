import AppKit

/// A tab controller that reports the pane the user chose, so the choice can be
/// put back the next time Settings is opened.
private final class SettingsTabViewController: NSTabViewController {
    var onSelectPane: ((Int) -> Void)?

    override func tabView(_ tabView: NSTabView, didSelect tabViewItem: NSTabViewItem?) {
        super.tabView(tabView, didSelect: tabViewItem)
        onSelectPane?(selectedTabViewItemIndex)
    }
}

/// The Settings window: a preference-style toolbar of four panes, no Save
/// button, and one instance for the life of the app.
///
/// A window, not the sheet it used to be, for the reasons the HIG gives:
/// settings are not a modal errand attached to one document window, they are
/// app-wide and must be reachable with no window open at all — which is why
/// `show()` asks nothing of `NSApp.mainWindow`.
///
/// Every control applies immediately (see `SettingsPaneVC`), so there is
/// nothing to cancel and the window closes with ⌘W like any other.
@MainActor
final class SettingsWindowController: NSWindowController {

    static let shared = SettingsWindowController()

    /// The pane the user was last in. Kept in `UserDefaults`, not in
    /// `AppSettings`: it is where the user is looking, not a preference, and
    /// it should not travel with the settings record.
    private static let paneDefaultsKey = "PharosSettingsPane"

    private let tabVC = SettingsTabViewController()
    private let panes: [SettingsPaneVC]

    private init() {
        let general = GeneralSettingsPaneVC()
        let editor = EditorSettingsPaneVC()
        let query = QuerySettingsPaneVC()
        let charts = ChartsSettingsPaneVC()
        panes = [general, editor, query, charts]

        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: SettingsForm.minimumPaneWidth, height: 300),
            styleMask: [.titled, .closable, .miniaturizable],
            backing: .buffered,
            defer: false
        )
        super.init(window: window)

        tabVC.tabStyle = .toolbar
        for (pane, spec) in zip(panes, Self.paneSpecs) {
            let item = NSTabViewItem(viewController: pane)
            item.label = spec.label
            item.image = NSImage(systemSymbolName: spec.symbol, accessibilityDescription: spec.label)
            item.identifier = spec.identifier
            tabVC.addTabViewItem(item)
        }
        // Only the USER's choice is remembered. The tab controller also selects
        // its first item as it loads and as the window comes up, and recording
        // those would overwrite the remembered pane with General every time.
        tabVC.onSelectPane = { [weak self] index in
            guard self?.window?.isVisible == true else { return }
            UserDefaults.standard.set(index, forKey: Self.paneDefaultsKey)
        }

        window.title = String(localized: "Settings")
        window.toolbarStyle = .preference
        // The singleton holds the window. Without this an AppKit-created
        // window frees itself on close and the second ⌘, opens a zombie.
        window.isReleasedWhenClosed = false
        // Nothing here is worth restoring at the next launch; the window is
        // opened on demand.
        window.isRestorable = false
        window.contentViewController = tabVC
        window.center()
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) not implemented")
    }

    // MARK: - Panes

    private struct PaneSpec {
        let label: String
        let symbol: String
        let identifier: String
    }

    private static let paneSpecs: [PaneSpec] = [
        PaneSpec(label: String(localized: "General"), symbol: "gearshape", identifier: "settings.pane.general"),
        PaneSpec(label: String(localized: "Editor"), symbol: "text.cursor", identifier: "settings.pane.editor"),
        PaneSpec(label: String(localized: "Query"), symbol: "play.rectangle", identifier: "settings.pane.query"),
        PaneSpec(label: String(localized: "Charts"), symbol: "chart.bar", identifier: "settings.pane.charts"),
    ]

    /// The size a pane asks the window to take: what its content needs, never
    /// narrower than the shared minimum so the window does not change width as
    /// the user moves between panes.
    static func paneSize(for view: NSView) -> NSSize {
        let fitting = view.fittingSize
        return NSSize(width: max(fitting.width, SettingsForm.minimumPaneWidth),
                      height: fitting.height)
    }

    // MARK: - Showing

    /// Open Settings, in the pane the user left it in. Works with no window
    /// on screen.
    func show() {
        // Load the tab controller's view before anything else touches it: a
        // pane selection made before the view exists is thrown away when it
        // loads and selects its own first item.
        _ = tabVC.view

        // The window survives a close, so its panes hold the values from the
        // last time it was open; anything changed since (a default schema set
        // from the editor, a theme set elsewhere) is read back here.
        for pane in panes { pane.reloadFromSettings() }

        let stored = UserDefaults.standard.object(forKey: Self.paneDefaultsKey) as? Int
        let wanted = (stored.map { $0 >= 0 && $0 < panes.count } == true) ? stored : nil

        // Once before the window comes up, so the remembered pane is what
        // appears rather than a flash of General…
        if let wanted { tabVC.selectedTabViewItemIndex = wanted }

        NSApp.activate(ignoringOtherApps: true)
        showWindow(nil)
        window?.makeKeyAndOrderFront(nil)

        // …and once after, because bringing the window up re-selects the first
        // item. This one sticks, and is the selection the user then sees.
        if let wanted, tabVC.selectedTabViewItemIndex != wanted {
            tabVC.selectedTabViewItemIndex = wanted
        }
    }

    /// ⌘W in this app is File ▸ Close Tab, and only the editor's content
    /// controller answers it — so with Settings key the shortcut did nothing
    /// at all. An `NSWindowController` is in its window's responder chain, so
    /// answering the same selector here gives the window the close that ⌘W
    /// means for a window with no tabs in it.
    @MainActor
    @objc func menuCloseTab(_ sender: Any?) {
        window?.performClose(sender)
    }
}
