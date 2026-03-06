import AppKit
import Combine

/// Tab bar for a single editor pane using a native NSSegmentedControl with capsule style.
///
/// Layout: [X close] [↗ expand] [  ‹SegmentedControl›  ] [+ add]
class PaneTabBar: NSView {

    // MARK: - Callbacks

    var onSelectTab: ((String) -> Void)?
    var onCloseTab: ((String) -> Void)?
    var onNewTab: (() -> Void)?
    var onAddPane: (() -> Void)?
    var onClosePane: (() -> Void)?
    var onExpandPane: (() -> Void)?
    var onDoubleClickTab: ((String) -> Void)?
    var onReorderTabs: (([String]) -> Void)?

    // MARK: - State

    let paneId: String
    private var tabs: [QueryTab] = []
    private var activeTabId: String?
    private var isExpanded: Bool = false
    private var canClose: Bool = true
    private var isFocused: Bool = false

    // MARK: - UI Elements

    private let closePaneButton = NSButton()
    private let expandPaneButton = NSButton()
    private let addButton = NSButton()
    private let segmentedControl = NSSegmentedControl()

    // Layout constants
    private let paneButtonWidth: CGFloat = 26
    private let addButtonWidth: CGFloat = 28
    private let barHeight: CGFloat = 28
    private let segmentInsetH: CGFloat = 4
    private let segmentInsetV: CGFloat = 3

    // MARK: - Init

    init(paneId: String) {
        self.paneId = paneId
        super.init(frame: .zero)
        setup()
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) not implemented")
    }

    private func setup() {
        wantsLayer = true

        // Close pane button (X)
        let closeConfig = NSImage.SymbolConfiguration(pointSize: 10, weight: .medium)
        closePaneButton.image = NSImage(systemSymbolName: "xmark", accessibilityDescription: "Close Pane")?.withSymbolConfiguration(closeConfig)
        closePaneButton.bezelStyle = .recessed
        closePaneButton.isBordered = false
        closePaneButton.imageScaling = .scaleNone
        closePaneButton.contentTintColor = .secondaryLabelColor
        closePaneButton.target = self
        closePaneButton.action = #selector(closePaneTapped)
        addSubview(closePaneButton)

        // Expand pane button (↗)
        let expandConfig = NSImage.SymbolConfiguration(pointSize: 10, weight: .medium)
        expandPaneButton.image = NSImage(systemSymbolName: "arrow.up.left.and.arrow.down.right", accessibilityDescription: "Expand Pane")?.withSymbolConfiguration(expandConfig)
        expandPaneButton.bezelStyle = .recessed
        expandPaneButton.isBordered = false
        expandPaneButton.imageScaling = .scaleNone
        expandPaneButton.contentTintColor = .secondaryLabelColor
        expandPaneButton.target = self
        expandPaneButton.action = #selector(expandPaneTapped)
        addSubview(expandPaneButton)

        // Add button (+)
        let addConfig = NSImage.SymbolConfiguration(pointSize: 11, weight: .medium)
        addButton.image = NSImage(systemSymbolName: "plus", accessibilityDescription: "Add")?.withSymbolConfiguration(addConfig)
        addButton.bezelStyle = .recessed
        addButton.isBordered = false
        addButton.imageScaling = .scaleNone
        addButton.contentTintColor = .secondaryLabelColor
        addButton.target = self
        addButton.action = #selector(addButtonClicked(_:))
        addSubview(addButton)

        // Segmented control (capsule style)
        segmentedControl.segmentStyle = .capsule
        segmentedControl.trackingMode = .selectOne
        segmentedControl.controlSize = .regular
        segmentedControl.target = self
        segmentedControl.action = #selector(segmentChanged(_:))
        addSubview(segmentedControl)
    }

    // MARK: - Public API

    func update(tabs: [QueryTab], activeTabId: String?, isExpanded: Bool, canClose: Bool) {
        self.tabs = tabs
        self.activeTabId = activeTabId
        self.isExpanded = isExpanded
        self.canClose = canClose

        // Update expand button appearance
        if isExpanded {
            let config = NSImage.SymbolConfiguration(pointSize: 10, weight: .bold)
            expandPaneButton.image = NSImage(systemSymbolName: "arrow.down.right.and.arrow.up.left", accessibilityDescription: "Collapse Pane")?.withSymbolConfiguration(config)
            expandPaneButton.contentTintColor = .controlAccentColor
        } else {
            let config = NSImage.SymbolConfiguration(pointSize: 10, weight: .medium)
            expandPaneButton.image = NSImage(systemSymbolName: "arrow.up.left.and.arrow.down.right", accessibilityDescription: "Expand Pane")?.withSymbolConfiguration(config)
            expandPaneButton.contentTintColor = .secondaryLabelColor
        }

        closePaneButton.isHidden = !canClose
        expandPaneButton.isHidden = !canClose

        rebuildSegments()
    }

    func setFocused(_ focused: Bool) {
        isFocused = focused
        needsDisplay = true
    }

    // MARK: - Layout

    override var isFlipped: Bool { true }

    override var intrinsicContentSize: NSSize {
        NSSize(width: NSView.noIntrinsicMetric, height: barHeight)
    }

    override func layout() {
        super.layout()
        layoutSubviews()
    }

    private func layoutSubviews() {
        var x: CGFloat = 0

        // Close pane button
        if canClose {
            closePaneButton.frame = NSRect(x: x, y: 0, width: paneButtonWidth, height: barHeight)
            x += paneButtonWidth
        }

        // Expand button (hidden in single-pane mode)
        if canClose {
            expandPaneButton.frame = NSRect(x: x, y: 0, width: paneButtonWidth, height: barHeight)
            x += paneButtonWidth
        }

        // Add button at trailing edge
        addButton.frame = NSRect(x: bounds.width - addButtonWidth, y: 0, width: addButtonWidth, height: barHeight)

        // Segmented control fills between pane buttons and add button
        let segX = x + segmentInsetH
        let segWidth = bounds.width - x - addButtonWidth - segmentInsetH * 2
        segmentedControl.frame = NSRect(
            x: segX,
            y: segmentInsetV,
            width: max(0, segWidth),
            height: barHeight - segmentInsetV * 2
        )
    }

    // MARK: - Rebuild Segments

    private func rebuildSegments() {
        segmentedControl.segmentCount = tabs.count

        for (index, tab) in tabs.enumerated() {
            let label = segmentLabel(for: tab)
            segmentedControl.setLabel(label, forSegment: index)
            segmentedControl.setToolTip(tab.name, forSegment: index)
        }

        // Select the active segment
        if let activeId = activeTabId,
           let activeIndex = tabs.firstIndex(where: { $0.id == activeId }) {
            segmentedControl.selectedSegment = activeIndex
        } else {
            segmentedControl.selectedSegment = -1
        }

        layoutSubviews()
        needsDisplay = true
    }

    /// Build label with dirty/executing indicators.
    private func segmentLabel(for tab: QueryTab) -> String {
        if tab.isExecuting {
            return "⟳ \(tab.name)"
        } else if tab.isDirty {
            return "● \(tab.name)"
        }
        return tab.name
    }

    // MARK: - Segment Actions

    @objc private func segmentChanged(_ sender: NSSegmentedControl) {
        let index = sender.selectedSegment
        guard index >= 0, index < tabs.count else { return }
        onSelectTab?(tabs[index].id)
    }

    // MARK: - Button Actions

    @objc private func closePaneTapped() {
        onClosePane?()
    }

    @objc private func expandPaneTapped() {
        onExpandPane?()
    }

    @objc private func addButtonClicked(_ sender: NSButton) {
        let menu = NSMenu()

        let tabItem = NSMenuItem(title: "Tab", action: #selector(menuNewTab), keyEquivalent: "")
        tabItem.target = self
        tabItem.image = NSImage(systemSymbolName: "plus.square", accessibilityDescription: nil)
        menu.addItem(tabItem)

        let splitItem = NSMenuItem(title: "Editor Pane on Right", action: #selector(menuAddPane), keyEquivalent: "")
        splitItem.target = self
        splitItem.image = NSImage(systemSymbolName: "square.split.2x1", accessibilityDescription: nil)
        menu.addItem(splitItem)

        let location = NSPoint(x: 0, y: sender.bounds.maxY + 2)
        menu.popUp(positioning: nil, at: location, in: sender)
    }

    @objc private func menuNewTab() {
        onNewTab?()
    }

    @objc private func menuAddPane() {
        onAddPane?()
    }

    // MARK: - Right-Click Context Menu

    override func rightMouseDown(with event: NSEvent) {
        let localPoint = convert(event.locationInWindow, from: nil)

        // Check if click is within the segmented control
        guard segmentedControl.frame.contains(localPoint) else {
            super.rightMouseDown(with: event)
            return
        }

        // Determine which segment was clicked
        let segLocal = convert(localPoint, to: segmentedControl)
        guard let index = segmentIndex(at: segLocal) else {
            super.rightMouseDown(with: event)
            return
        }

        let tabId = tabs[index].id
        // Select the tab first
        onSelectTab?(tabId)
        showContextMenu(tabId: tabId, event: event)
    }

    /// Determine which segment index a point falls in.
    private func segmentIndex(at point: NSPoint) -> Int? {
        var x: CGFloat = 0
        for i in 0..<segmentedControl.segmentCount {
            let w = segmentedControl.width(forSegment: i)
            let segWidth = w > 0 ? w : segmentedControl.bounds.width / CGFloat(segmentedControl.segmentCount)
            if point.x >= x && point.x < x + segWidth {
                return i
            }
            x += segWidth
        }
        return nil
    }

    private func showContextMenu(tabId: String, event: NSEvent) {
        guard let tabIndex = tabs.firstIndex(where: { $0.id == tabId }) else { return }
        let menu = NSMenu()

        let closeItem = NSMenuItem(title: "Close", action: #selector(contextClose(_:)), keyEquivalent: "")
        closeItem.representedObject = tabId
        closeItem.target = self
        menu.addItem(closeItem)

        let closeOthersItem = NSMenuItem(title: "Close Others", action: #selector(contextCloseOthers(_:)), keyEquivalent: "")
        closeOthersItem.representedObject = tabId
        closeOthersItem.target = self
        closeOthersItem.isEnabled = tabs.count > 1
        menu.addItem(closeOthersItem)

        let closeRightItem = NSMenuItem(title: "Close to the Right", action: #selector(contextCloseRight(_:)), keyEquivalent: "")
        closeRightItem.representedObject = tabId
        closeRightItem.target = self
        closeRightItem.isEnabled = tabIndex < tabs.count - 1
        menu.addItem(closeRightItem)

        menu.addItem(.separator())

        let duplicateItem = NSMenuItem(title: "Duplicate", action: #selector(contextDuplicate(_:)), keyEquivalent: "")
        duplicateItem.representedObject = tabId
        duplicateItem.target = self
        menu.addItem(duplicateItem)

        let renameItem = NSMenuItem(title: "Rename...", action: #selector(contextRename(_:)), keyEquivalent: "")
        renameItem.representedObject = tabId
        renameItem.target = self
        menu.addItem(renameItem)

        NSMenu.popUpContextMenu(menu, with: event, for: self)
    }

    @objc private func contextClose(_ sender: NSMenuItem) {
        guard let tabId = sender.representedObject as? String else { return }
        onCloseTab?(tabId)
    }

    @objc private func contextCloseOthers(_ sender: NSMenuItem) {
        guard let tabId = sender.representedObject as? String else { return }
        AppStateManager.shared.closeOtherTabs(exceptId: tabId)
    }

    @objc private func contextCloseRight(_ sender: NSMenuItem) {
        guard let tabId = sender.representedObject as? String else { return }
        AppStateManager.shared.closeTabsToRight(ofId: tabId)
    }

    @objc private func contextDuplicate(_ sender: NSMenuItem) {
        guard let tabId = sender.representedObject as? String else { return }
        AppStateManager.shared.duplicateTab(id: tabId)
    }

    @objc private func contextRename(_ sender: NSMenuItem) {
        guard let tabId = sender.representedObject as? String else { return }
        onDoubleClickTab?(tabId)
    }

    // MARK: - Drawing

    override func draw(_ dirtyRect: NSRect) {
        super.draw(dirtyRect)

        // Bar background
        NSColor.windowBackgroundColor.setFill()
        bounds.fill()

        // Bottom border
        NSColor.separatorColor.setStroke()
        let borderPath = NSBezierPath()
        borderPath.move(to: NSPoint(x: bounds.minX, y: bounds.maxY - 0.5))
        borderPath.line(to: NSPoint(x: bounds.maxX, y: bounds.maxY - 0.5))
        borderPath.stroke()

        // Focused indicator: thin accent color top line
        if isFocused {
            NSColor.controlAccentColor.setFill()
            NSRect(x: 0, y: 0, width: bounds.width, height: 1.5).fill()
        }
    }
}
