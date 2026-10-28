import AppKit

/// The Tag Manager: one window for every tag, opened from the toolbar,
/// Window ▸ Tag Manager, Edit ▸ Manage Tags…, the grid's right-click menu and
/// the inspector's Edit button. It opens with no tags at all (to make the
/// first one) and with no results behind it.
///
/// The shared manager shell: tags in a Glass sidebar, **+** and the filter in
/// the toolbar, the chosen tag's detail on the right (`TagManagerHostVC`).
/// A save writes and keeps the window open; closing with unsaved edits asks
/// first. The grid's Add Tag… and Remove From Tag… stay sheets on the grid
/// (`TagManagerSheet`), with the same detail.
@MainActor
final class TagManagerWindowController: NSWindowController {

    static let shared = TagManagerWindowController()

    static let defaultSize = NSSize(width: 900, height: 600)
    static let minimumSize = NSSize(width: 760, height: 480)

    let host = TagManagerHostVC(tags: { TagStore.shared.tags }, committer: TagStore.shared)
    private var observer: NSObjectProtocol?

    private init() {
        let window = UtilityWindow(autosaveName: "PharosTagManagerWindow",
                                   title: String(localized: "Tag Manager"),
                                   defaultSize: Self.defaultSize,
                                   minimumSize: Self.minimumSize)
        super.init(window: window)
        window.contentViewController = host
        // After the assignment: `contentViewController` resizes the window to
        // the controller's fitting size (lessons, 2026-09-19).
        window.setContentSize(Self.defaultSize)
        window.center()
        window.setFrameUsingName("PharosTagManagerWindow")
        window.setAccessibilityIdentifier("window.tagManager")
        host.split.installToolbarIfNeeded(on: window)
        // Closing with unsaved edits asks first. False keeps the window open;
        // the question closes it itself once the user has answered Discard.
        window.shouldClose = { [weak self, weak window] in
            guard let self, let window else { return true }
            return self.host.confirmClose(in: window) { [weak window] in window?.close() }
        }
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
