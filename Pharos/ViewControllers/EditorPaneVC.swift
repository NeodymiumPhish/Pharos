import AppKit
import Combine

/// Delegate for EditorPaneVC events that need to be handled by the parent.
protocol EditorPaneDelegate: AnyObject {
    func editorPane(_ pane: EditorPaneVC, didRequestClosePane paneId: String)
    func editorPane(_ pane: EditorPaneVC, didRequestExpandPane paneId: String)
    func editorPane(_ pane: EditorPaneVC, didRequestAddPane paneId: String)
    func editorPane(_ pane: EditorPaneVC, didFocus paneId: String)
    func editorPane(_ pane: EditorPaneVC, didChangeActiveTab tabId: String?)
    func editorPane(_ pane: EditorPaneVC, didRequestRenameTab tabId: String)
}

/// Self-contained editor pane that owns a PaneTabBar and a QueryEditorVC.
/// Each pane manages its own set of tabs independently.
class EditorPaneVC: NSViewController {

    let paneId: String
    let editorVC = QueryEditorVC()
    private(set) var paneTabBar: PaneTabBar!

    weak var delegate: EditorPaneDelegate?

    private let stateManager = AppStateManager.shared
    private let metadataCache = MetadataCache.shared
    private var cancellables = Set<AnyCancellable>()\

    // MARK: - Init

    init(paneId: String) {
        self.paneId = paneId
        super.init(nibName: nil, bundle: nil)
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) not implemented")
    }

    // MARK: - View Lifecycle

    override func loadView() {
        let container = NSView()
        container.wantsLayer = true
        self.view = container

        // Tab bar
        paneTabBar = PaneTabBar(paneId: paneId)
        paneTabBar.translatesAutoresizingMaskIntoConstraints = false

        paneTabBar.onSelectTab = { [weak self] tabId in
            guard let self else { return }
            self.stateManager.selectTab(id: tabId, inPane: self.paneId)
        }
        paneTabBar.onCloseTab = { [weak self] tabId in
            guard let self else { return }
            self.stateManager.closeTab(id: tabId)
        }
        paneTabBar.onNewTab = { [weak self] in
            guard let self else { return }
            self.stateManager.createTab(inPane: self.paneId)
        }
        paneTabBar.onAddPane = { [weak self] in
            guard let self else { return }
            self.delegate?.editorPane(self, didRequestAddPane: self.paneId)
        }
        paneTabBar.onClosePane = { [weak self] in
            guard let self else { return }
            self.delegate?.editorPane(self, didRequestClosePane: self.paneId)
        }
        paneTabBar.onExpandPane = { [weak self] in
            guard let self else { return }
            self.delegate?.editorPane(self, didRequestExpandPane: self.paneId)
        }
        paneTabBar.onDoubleClickTab = { [weak self] tabId in
            guard let self else { return }
            self.delegate?.editorPane(self, didRequestRenameTab: tabId)
        }
        paneTabBar.onReorderTabs = { [weak self] newTabIds in
            guard let self else { return }
            self.stateManager.reorderTabs(newTabIds, inPane: self.paneId)
        }

        // Editor
        addChild(editorVC)

        container.addSubview(paneTabBar)
        container.addSubview(editorVC.view)

        NSLayoutConstraint.activate([
            paneTabBar.topAnchor.constraint(equalTo: container.topAnchor),
            paneTabBar.leadingAnchor.constraint(equalTo: container.leadingAnchor),
            paneTabBar.trailingAnchor.constraint(equalTo: container.trailingAnchor),
            paneTabBar.heightAnchor.constraint(equalToConstant: 28),
        ])

        // Editor view uses frame-based layout (NSSplitView parent requirement)
        // We'll layout it manually in viewDidLayout
        editorVC.view.autoresizingMask = [.width, .height]

        // Text change handler
        editorVC.textView.onTextChange = { [weak self] newText in
            self?.editorTextDidChange(newText)
        }

        // Observe pane state changes
        stateManager.$panes
            .receive(on: RunLoop.main)
            .sink { [weak self] panes in
                self?.paneStateChanged(panes)
            }
            .store(in: &cancellables)

        // Observe tab content changes (isDirty, isExecuting, name)
        stateManager.$tabs
            .receive(on: RunLoop.main)
            .sink { [weak self] _ in
                self?.refreshTabBar()
            }
            .store(in: &cancellables)

        // Observe focused pane changes
        stateManager.$focusedPaneId
            .receive(on: RunLoop.main)
            .sink { [weak self] focusedId in
                guard let self else { return }
                self.paneTabBar.setFocused(focusedId == self.paneId)
            }
            .store(in: &cancellables)

        // Push schema metadata to editor
        Publishers.CombineLatest3(
            metadataCache.$schemas,
            metadataCache.$tables,
            metadataCache.$columnsByTable
        )
        .receive(on: RunLoop.main)
        .sink { [weak self] schemas, tables, columns in
            self?.editorVC.updateSchemaMetadata(
                schemas: schemas, tables: tables, columnsByTable: columns)
        }
        .store(in: &cancellables)

        // Track focus: when editor text view becomes first responder, notify delegate
        NotificationCenter.default.addObserver(
            self, selector: #selector(windowDidUpdate(_:)),
            name: NSWindow.didUpdateNotification, object: nil
        )
    }

    override func viewDidLayout() {
        super.viewDidLayout()
        let editorTop: CGFloat = 28 // Tab bar height
        editorVC.view.frame = NSRect(
            x: 0, y: editorTop,
            width: view.bounds.width,
            height: max(0, view.bounds.height - editorTop)
        )
    }

    // MARK: - State Observation

    private var lastActiveTabId: String?

    private func paneStateChanged(_ panes: [EditorPane]) {
        guard let pane = panes.first(where: { $0.id == paneId }) else { return }

        let paneTabs = stateManager.tabs(forPane: paneId)
        let canClose = panes.count > 1

        paneTabBar.update(
            tabs: paneTabs,
            activeTabId: pane.activeTabId,
            isExpanded: pane.isExpanded,
            canClose: canClose
        )

        // Detect active tab change
        if pane.activeTabId != lastActiveTabId {
            let oldTabId = lastActiveTabId
            lastActiveTabId = pane.activeTabId
            tabChanged(from: oldTabId, to: pane.activeTabId)
            delegate?.editorPane(self, didChangeActiveTab: pane.activeTabId)
        }
    }

    private func refreshTabBar() {
        guard let pane = stateManager.panes.first(where: { $0.id == paneId }) else { return }
        let paneTabs = stateManager.tabs(forPane: paneId)
        let canClose = stateManager.panes.count > 1

        paneTabBar.update(
            tabs: paneTabs,
            activeTabId: pane.activeTabId,
            isExpanded: pane.isExpanded,
            canClose: canClose
        )
    }

    // MARK: - Tab Switching

    private func tabChanged(from oldTabId: String?, to newTabId: String?) {
        // Save cursor position of old tab
        if let oldTabId, editorVC.tabId == oldTabId {
            let cursorPos = editorVC.getCursorPosition()
            stateManager.updateTab(id: oldTabId) { $0.cursorPosition = cursorPos }
        }

        guard let newTabId,
              let tab = stateManager.tabs.first(where: { $0.id == newTabId }) else {
            editorVC.tabId = nil
            editorVC.setSQL("")
            return
        }

        editorVC.tabId = newTabId
        editorVC.setSQL(tab.sql)
        editorVC.setCursorPosition(tab.cursorPosition)
        editorVC.clearErrorMarkers()
    }

    // MARK: - Editor Text Changes

    private func editorTextDidChange(_ newText: String) {
        guard let tabId = editorVC.tabId else { return }
        editorVC.clearErrorMarkers()
        stateManager.updateTab(id: tabId) { tab in
            tab.sql = newText
            tab.isDirty = true
        }
    }

    // MARK: - Focus Tracking

    @objc private func windowDidUpdate(_ notification: Notification) {
        guard let window = view.window,
              let responder = window.firstResponder as? NSView else { return }

        if responder === editorVC.textView || responder.isDescendant(of: editorVC.textView) {
            if stateManager.focusedPaneId != paneId {
                stateManager.focusPane(id: paneId)
                delegate?.editorPane(self, didFocus: paneId)
            }
        }
    }

    // MARK: - Public API

    func focus() {
        editorVC.focus()
    }

    func getSQL() -> String {
        editorVC.getSQL()
    }

    func formatSQL() {
        editorVC.formatSQL()
    }

    func markError(charPosition: Int, tokenLength: Int) {
        editorVC.markError(charPosition: charPosition, tokenLength: tokenLength)
    }

    func clearErrorMarkers() {
        editorVC.clearErrorMarkers()
    }

    func insertText(_ text: String) {
        let range = editorVC.textView.selectedRange()
        editorVC.textView.insertText(text, replacementRange: range)
    }

    /// Save the current tab's cursor position.
    func saveCurrentTabState() {
        guard let tabId = editorVC.tabId else { return }
        let cursorPos = editorVC.getCursorPosition()
        stateManager.updateTab(id: tabId) { $0.cursorPosition = cursorPos }
    }

    deinit {
        NotificationCenter.default.removeObserver(self)
    }
}
