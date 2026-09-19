import AppKit

/// Sidebar of panes on the left, the chosen pane on the right. Owns the
/// navigation history and the pane cache; `navigate(to:source:)` is the one
/// place a pane change happens.
@MainActor
final class SettingsSplitViewController: NSSplitViewController {

    enum NavigationSource {
        /// The user clicked a sidebar row: recorded in history and remembered.
        case user
        /// Back or Forward: moves within history, remembered.
        case history
        /// The window opening in the remembered pane: recorded nowhere.
        case restore
    }

    let sidebar = SettingsSidebarVC()
    let detail = SettingsDetailVC()
    private(set) var history = SettingsNavigationHistory()
    private var panes: [SettingsPaneID: SettingsPaneVC] = [:]
    private(set) var currentPaneId: SettingsPaneID?

    override func viewDidLoad() {
        super.viewDidLoad()

        let sidebarItem = NSSplitViewItem(sidebarWithViewController: sidebar)
        sidebarItem.minimumThickness = 180
        sidebarItem.maximumThickness = 240
        sidebarItem.canCollapse = false
        sidebarItem.holdingPriority = .defaultLow + 1
        sidebarItem.titlebarSeparatorStyle = .none

        let detailItem = NSSplitViewItem(viewController: detail)
        detailItem.minimumThickness = 520
        detailItem.holdingPriority = .defaultLow
        detailItem.automaticallyAdjustsSafeAreaInsets = false
        detailItem.titlebarSeparatorStyle = .none

        addSplitViewItem(sidebarItem)
        addSplitViewItem(detailItem)
        splitView.autosaveName = "PharosSettingsSplit"
        splitView.dividerStyle = .thin

        sidebar.onSelect = { [weak self] id in self?.navigate(to: id, source: .user) }
        detail.header.onNavigate = { [weak self] direction in self?.step(direction) }
    }

    override func viewDidAppear() {
        super.viewDidAppear()
        // ↑/↓ change panes from the moment the window opens.
        view.window?.initialFirstResponder = sidebar.tableView
        if let window = view.window as? SettingsWindow {
            window.navigationHandler = { [weak self] direction in self?.step(direction) }
        }
    }

    // MARK: - Navigation

    func navigate(to id: SettingsPaneID, source: NavigationSource) {
        let spec = SettingsPaneRegistry.spec(for: id)
        let pane = self.pane(for: id)
        currentPaneId = id
        if source == .user { history.visit(id) }
        if history.current == nil && source == .restore {
            // The first pane shown is the root of the history, so Back from
            // the second pane returns to it.
            history.visit(id)
        }
        detail.show(pane, title: spec.title, canGoBack: history.canGoBack, canGoForward: history.canGoForward)
        sidebar.select(id)
        view.window?.title = String(localized: "Pharos Settings — \(spec.title)")
        if source != .restore { SettingsPanePrefs.setLastPane(id) }
    }

    func step(_ direction: SettingsWindow.NavigationDirection) {
        let target: SettingsPaneID?
        switch direction {
        case .back: target = history.goBack()
        case .forward: target = history.goForward()
        }
        guard let target else { return }
        navigate(to: target, source: .history)
    }

    /// Panes are made on first visit and kept.
    func pane(for id: SettingsPaneID) -> SettingsPaneVC {
        if let cached = panes[id] { return cached }
        let pane = SettingsPaneRegistry.makePane(id)
        panes[id] = pane
        return pane
    }

    /// The panes made so far, for `reloadFromSettings()` when the window opens.
    var instantiatedPanes: [SettingsPaneVC] { Array(panes.values) }
}
