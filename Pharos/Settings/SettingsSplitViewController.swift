import AppKit

/// Sidebar of panes on the left, the chosen pane on the right. Owns the
/// navigation history and the pane cache; `navigate(to:source:)` is the one
/// place a pane change happens.
@MainActor
final class SettingsSplitViewController: NSSplitViewController {

    /// Declared in `SettingsPanePrefs.swift`, so the two rules it carries are
    /// testable with no window. Spelled as before at every call site.
    typealias NavigationSource = SettingsNavigationSource

    let sidebar = SettingsSidebarVC()
    let detail = SettingsDetailVC()
    /// Back / Forward and the pane title, which live in the window's toolbar.
    /// Owned here rather than by the window controller because this is what
    /// knows when the history or the pane changed.
    let toolbar = SettingsToolbarController()
    private(set) var history = SettingsNavigationHistory()
    private var panes: [SettingsPaneID: SettingsPaneVC] = [:]
    private(set) var currentPaneId: SettingsPaneID?
    /// Built on the first keystroke and kept. See `searchEntries()`.
    private var searchIndex: [SettingsSearchEntry]?
    /// True while a query is filtering the sidebar.
    private(set) var isSearching = false

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
        toolbar.onNavigate = { [weak self] direction in self?.step(direction) }
        toolbar.onSearch = { [weak self] query in self?.search(query) }
    }

    override func viewDidAppear() {
        super.viewDidAppear()
        // ↑/↓ change panes from the moment the window opens.
        view.window?.initialFirstResponder = sidebar.tableView
        if let window = view.window as? SettingsWindow {
            window.navigationHandler = { [weak self] direction in self?.step(direction) }
            // Once. The window survives a close, so this runs again on every
            // re-open, and a second `install` would hand the window a brand
            // new NSToolbar — dropping the one whose controls are already
            // wired and showing an empty bar.
            if window.toolbar == nil { toolbar.install(on: window) }
        }
    }

    // MARK: - Navigation

    func navigate(to id: SettingsPaneID, source: NavigationSource) {
        let spec = SettingsPaneRegistry.spec(for: id)
        let pane = self.pane(for: id)
        currentPaneId = id
        if source.recordsHistory { history.visit(id) }
        if history.current == nil && source == .restore {
            // The first pane shown is the root of the history, so Back from
            // the second pane returns to it.
            history.visit(id)
        }
        detail.show(pane)
        toolbar.update(title: spec.title,
                       canGoBack: history.canGoBack,
                       canGoForward: history.canGoForward)
        sidebar.select(id)
        // After `detail.show`, which is what guarantees the pane's view has
        // loaded and therefore that its rows exist.
        if let itemId = revealTarget(for: id) { pane.reveal(itemId: itemId) }
        view.window?.title = String(localized: "Pharos Settings — \(spec.title)")
        if source.isRemembered { SettingsPanePrefs.setLastPane(id) }
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

    // MARK: - Search

    /// Every searchable entry in the window, built once.
    ///
    /// Built through `pane(for:)`, so the panes it constructs are CACHED and
    /// are the same instances the user then navigates to — nothing is made
    /// and thrown away. Reading a pane's `sections` builds no views, and the
    /// index is built on the first keystroke rather than at launch, because
    /// one pane (Connections) enumerates every time zone this Mac knows when
    /// its sections are read.
    func searchEntries() -> [SettingsSearchEntry] {
        if let searchIndex { return searchIndex }
        let built = SettingsPaneRegistry.all.flatMap { spec in
            pane(for: spec.id).searchEntries(paneTitle: spec.title)
        }
        searchIndex = built
        return built
    }

    /// Filter the sidebar to the panes matching `query`. An empty query puts
    /// all 16 back.
    func search(_ query: String) {
        let trimmed = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else {
            isSearching = false
            sidebar.setFilter(nil, keeping: currentPaneId)
            return
        }
        isSearching = true
        let hits = SettingsSearchIndex.hits(in: searchEntries(), query: trimmed)
        sidebar.setFilter(hits, keeping: currentPaneId)
        lastHits = hits
    }

    /// The hits behind the sidebar as it stands, so navigating to one of them
    /// knows which row to reveal.
    private var lastHits: [SettingsSearchIndex.Hit] = []

    /// The row to reveal in `id`, if the current search named one.
    private func revealTarget(for id: SettingsPaneID) -> String? {
        guard isSearching else { return nil }
        return lastHits.first { $0.paneId == id.rawValue }?.itemId
    }
}
