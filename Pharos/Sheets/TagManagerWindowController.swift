import AppKit

/// The Tag Manager: one window for every tag, opened from the toolbar,
/// Window ▸ Tag Manager, Edit ▸ Manage Tags…, the grid's right-click menu and
/// the inspector's Edit button. Unlike the sheet it hosts, it opens with no
/// tags at all (to make the first one) and with no results behind it.
///
/// It hosts a `TagManagerSheet` in `.manage`. A save writes and keeps the
/// window open, on a fresh sheet built from the store; Cancel closes the
/// window. The grid's Add Tag… and Remove From Tag… stay sheets on the grid.
@MainActor
final class TagManagerWindowController: NSWindowController {

    static let shared = TagManagerWindowController()

    let host = TagManagerHostVC(tags: { TagStore.shared.tags }, committer: TagStore.shared)
    private var observer: NSObjectProtocol?

    private init() {
        let window = UtilityWindow(autosaveName: "PharosTagManagerWindow",
                                   title: String(localized: "Tag Manager"),
                                   defaultSize: NSSize(width: 900, height: 600),
                                   minimumSize: NSSize(width: 780, height: 500))
        super.init(window: window)
        window.contentViewController = host
        window.setContentSize(NSSize(width: 900, height: 600))
        window.center()
        window.setFrameUsingName("PharosTagManagerWindow")
        window.setAccessibilityIdentifier("window.tagManager")
        window.shouldClose = { [weak self] in self?.host.confirmClose() ?? true }
        host.closeWindow = { [weak window] in window?.close() }
        observer = NotificationCenter.default.addObserver(
            forName: TagStore.didChange, object: nil, queue: .main) { [weak self] _ in
                MainActor.assumeIsolated { self?.host.storeChanged() }
            }
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) not implemented") }

    /// Show the window, on `preselect` when given. `columns`/`loadedRows` are
    /// the results the live match count runs over (the grid that asked, or
    /// the front window's); none gives "No rows are loaded here".
    func show(preselect: String? = nil, columns: [ColumnDef] = [], loadedRows: [[String?]] = []) {
        _ = host.view
        host.setResults(columns: columns, loadedRows: loadedRows)
        if window?.isVisible != true || !host.hasEdits {
            host.reseed(preselect: preselect)
        } else if let preselect {
            host.select(tagId: preselect)
        }
        NSApp.activate(ignoringOtherApps: true)
        showWindow(nil)
        window?.makeKeyAndOrderFront(nil)
    }
}
