import AppKit

/// The body of a manager window (Variables, Tags, Connections): the record
/// list in a Liquid Glass sidebar on the left, the chosen record's detail on
/// the right. Set up as `SettingsSplitViewController` is, so the three
/// managers and Settings share one look.
///
/// The detail is swapped with `setDetail(_:)` inside a container that stays
/// in the split view, rather than by replacing the split view item: a new
/// item would drop the divider's place and the safe-area setting below.
@MainActor
final class ManagerSplitViewController: NSSplitViewController {

    static let sidebarMinimum: CGFloat = 220
    static let sidebarMaximum: CGFloat = 320

    let sidebar: ManagerSidebarVC
    private let detailContainer: ManagerDetailContainerVC
    private let autosaveName: String
    private let detailMinimum: CGFloat

    /// The window's toolbar (+ and the filter field). Installed the first
    /// time the view is about to appear, or by `installToolbarIfNeeded(on:)`.
    /// Its filter field drives `sidebar.filterText`; the owner sets `onAdd`.
    var toolbarController: ManagerToolbarController? {
        didSet {
            toolbarController?.onFilterChange = { [weak self] text in self?.sidebar.filterText = text }
        }
    }

    /// The detail on show.
    var detail: NSViewController { detailContainer.content }

    /// - Parameters:
    ///   - autosaveName: the divider's remembered place, one per window.
    ///   - detailMinimum: the narrowest the detail may get. With the sidebar
    ///     minimum, this sets how narrow the window can usefully be.
    init(sidebar: ManagerSidebarVC, detail: NSViewController, autosaveName: String, detailMinimum: CGFloat) {
        self.sidebar = sidebar
        self.detailContainer = ManagerDetailContainerVC(content: detail)
        self.autosaveName = autosaveName
        self.detailMinimum = detailMinimum
        super.init(nibName: nil, bundle: nil)
    }

    required init?(coder: NSCoder) { fatalError("ManagerSplitViewController is built in code") }

    override func viewDidLoad() {
        super.viewDidLoad()

        // `sidebarWithViewController:` is what gives the glass.
        let sidebarItem = NSSplitViewItem(sidebarWithViewController: sidebar)
        sidebarItem.minimumThickness = Self.sidebarMinimum
        sidebarItem.maximumThickness = Self.sidebarMaximum
        sidebarItem.canCollapse = false
        // Low, so the divider still drags (lessons, top entry), but clear of
        // the detail's content hugging (the entry's correction): a label made
        // with `labelWithString:` hugs at 251, and the forms' section headers
        // span their width, so each pulls the detail narrower at 251. At
        // `.defaultLow + 1` two headers outvoted the sidebar, which grew to its
        // 320 pt maximum the moment a form appeared.
        sidebarItem.holdingPriority = .defaultLow + 50
        sidebarItem.titlebarSeparatorStyle = .none

        let detailItem = NSSplitViewItem(viewController: detailContainer)
        detailItem.minimumThickness = detailMinimum
        detailItem.holdingPriority = .defaultLow
        // Off: on, the detail grows its safe area under the glass sidebar and
        // paints its background there, and the two panes read as one opaque
        // plate with no divider (lessons, 2026-09-16).
        detailItem.automaticallyAdjustsSafeAreaInsets = false
        detailItem.titlebarSeparatorStyle = .none

        addSplitViewItem(sidebarItem)
        addSplitViewItem(detailItem)
        // After the items: the split view restores the divider when it is set.
        splitView.autosaveName = autosaveName
        splitView.dividerStyle = .thin
    }

    /// Before the window is on screen, so the toolbar does not pop in after
    /// the window has drawn without it.
    override func viewWillAppear() {
        super.viewWillAppear()
        guard let window = view.window else { return }
        installToolbarIfNeeded(on: window)
        // ↑/↓ walk the list from the moment the window opens. Only when the
        // owner has not chosen a first responder of its own.
        if window.initialFirstResponder == nil { window.initialFirstResponder = sidebar.tableView }
    }

    /// Give `window` the manager toolbar, ONCE. The utility windows survive
    /// a close, so this runs again on every re-open, and a second toolbar
    /// would replace the one whose controls are wired with an empty bar.
    func installToolbarIfNeeded(on window: NSWindow) {
        guard window.toolbar == nil, let toolbarController else { return }
        _ = view
        toolbarController.install(on: window, splitView: splitView)
    }

    /// Show `detail` in the right pane in place of the current one.
    func setDetail(_ detail: NSViewController) {
        detailContainer.setContent(detail)
    }
}

/// The right pane's fixed occupant: it holds whichever detail is on show.
@MainActor
final class ManagerDetailContainerVC: NSViewController {

    private(set) var content: NSViewController

    init(content: NSViewController) {
        self.content = content
        super.init(nibName: nil, bundle: nil)
    }

    required init?(coder: NSCoder) { fatalError("ManagerDetailContainerVC is built in code") }

    override func loadView() {
        view = NSView()
        view.translatesAutoresizingMaskIntoConstraints = false
        embed(content)
    }

    func setContent(_ next: NSViewController) {
        guard next !== content else { return }
        if isViewLoaded {
            content.view.removeFromSuperview()
            content.removeFromParent()
        }
        content = next
        guard isViewLoaded else { return }
        embed(next)
        // Tab walks the new detail's controls in reading order.
        view.window?.recalculateKeyViewLoop()
    }

    /// Pinned to the container's top, not its safe area: a detail whose
    /// first view is a scroll view insets itself under the toolbar
    /// (`automaticallyAdjustsContentInsets`), and pinning to the safe area
    /// too would inset it twice — as `SettingsDetailVC` explains. A detail
    /// whose top row is NOT a scroll view pins that row to its own
    /// `safeAreaLayoutGuide` (lessons, 2026-09-16).
    private func embed(_ child: NSViewController) {
        addChild(child)
        child.view.translatesAutoresizingMaskIntoConstraints = false
        view.addSubview(child.view)
        NSLayoutConstraint.activate([
            child.view.topAnchor.constraint(equalTo: view.topAnchor),
            child.view.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            child.view.trailingAnchor.constraint(equalTo: view.trailingAnchor),
            child.view.bottomAnchor.constraint(equalTo: view.bottomAnchor),
        ])
    }
}
